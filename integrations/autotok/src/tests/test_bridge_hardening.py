"""Desktop bridge / history / scheduler hardening.

The first part are the independent QA reproductions (written from the requirements, red
before these fixes). Four QA cases were judged non-bugs and are left out on purpose:
  * Range ``bytes=5-2`` -> 400 (Starlette's answer to an unsatisfiable range is acceptable),
  * HEAD on /stream -> 405 (the GUI and browsers only GET),
  * ``sample.mp4::$DATA`` (covered below as an ADS name rejected before any filesystem call),
  * ``"SAMPLE.MP4 "`` trailing space (Windows maps it to the same library file; not an escape).
The second part proves each fix (see the plan items in the test names/docstrings).
"""
import hashlib
import json
import ntpath
import os
import sqlite3
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from pathlib import Path
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import event
from sqlmodel import Session, select

import api.db as db
from api.main import create_app
from api.models import Account, DesktopReceipt, ScheduledUpload, UploadHistory
from api.routers import desktop
from api.services import history
from api.services import videos as library
from api.services.tiktok_adapter import UploadOutcome
from autotok import settings
from scheduler import worker

HEADERS = {"X-Requested-With": "autotok"}


@pytest.fixture
def db_path(tmp_path):
    return tmp_path / "qa.db"


@pytest.fixture
def client(db_path, tmp_path):
    old = db.engine
    engine = db.make_engine(f"sqlite:///{db_path}")
    db.override_engine(engine)
    db.init_db()
    with Session(engine) as s:
        s.add(Account(username="demo", cookie_path=str(tmp_path / "absent.cookie"), has_valid_session=True))
        s.commit()
    with TestClient(create_app(), base_url="http://localhost", headers=HEADERS) as c:
        yield c
    db.override_engine(old)
    engine.dispose()


def restart(client):
    """Run the API startup again (same database), like restarting the service."""
    with TestClient(create_app(), base_url="http://localhost", headers=HEADERS) as c:
        return c


def post(client, key=None, data=b"fixture-video-bytes", **fields):
    return client.post("/api/desktop/jobs", data={
        "request_id": key or uuid4().hex, "username": "demo", "title": "Mô tả 🌸", **fields,
    }, files={"video": ("video.mp4", data, "video/mp4")})


def lookup(client, **identity):
    r = client.post("/api/history/lookup", json={"videos": [identity]})
    assert r.status_code == 200, r.text
    return r.json()[0]["entries"]


def make_due(job_id):
    with Session(db.engine) as s:
        row = s.get(ScheduledUpload, job_id)
        row.scheduled_for = db.now_utc() - timedelta(seconds=1)
        s.add(row)
        s.commit()


def library_names():
    return sorted(p.name for p in settings.videos_dir().iterdir())


# ======================= QA reproductions =======================

def test_web_schedule_with_negative_offset_does_not_run_early(client):
    (settings.videos_dir() / "a.mp4").write_bytes(b"x" * 10)
    instant = datetime.now(timezone.utc) + timedelta(hours=1)
    local = instant.astimezone(timezone(timedelta(hours=-5)))
    r = client.post("/api/schedules", json={"username": "demo", "title": "t", "source_type": "local",
                                           "source_ref": "a.mp4", "scheduled_for": local.isoformat()})
    assert r.status_code == 201, r.text
    # Owner decision (TikTok-side scheduling): the offset time is converted exactly and handed to
    # TikTok as the schedule; the job itself runs right away (it no longer waits on this PC).
    got = datetime.fromisoformat(r.json()["tiktok_schedule_time"])
    assert abs((got - instant).total_seconds()) < 1


def test_web_schedule_with_positive_offset_history_planned_for(client):
    (settings.videos_dir() / "b.mp4").write_bytes(b"y" * 10)
    instant = datetime.now(timezone.utc) + timedelta(hours=2)
    local = instant.astimezone(timezone(timedelta(hours=7)))
    r = client.post("/api/schedules", json={"username": "demo", "title": "t", "source_type": "local",
                                           "source_ref": "b.mp4", "scheduled_for": local.isoformat()})
    assert r.status_code == 201
    entries = lookup(client, sha256=hashlib.sha256(b"y" * 10).hexdigest())
    assert abs((datetime.fromisoformat(entries[0]["planned_for"]) - instant).total_seconds()) < 1


def test_desktop_schedule_with_offset_is_exact_and_not_early(client):
    instant = datetime.now(timezone.utc) + timedelta(hours=3)
    local = instant.astimezone(timezone(timedelta(hours=-8)))
    body = post(client, scheduled_for=local.isoformat()).json()
    assert abs((datetime.fromisoformat(body["planned_for"]) - instant).total_seconds()) < 1
    with Session(db.engine) as s:  # TikTok-side scheduling: the exact instant goes to TikTok
        options = json.loads(s.get(ScheduledUpload, body["schedule_id"]).options_json)
    assert abs((datetime.fromisoformat(options["tiktok_schedule_time"]) - instant).total_seconds()) < 1


@pytest.mark.parametrize("value", ["2030-01-01T10:00:00", "2030-01-01 10:00", "not-a-date", "2000-01-01T00:00:00+07:00"])
def test_desktop_rejects_naive_garbage_and_past(client, value):
    assert post(client, scheduled_for=value).status_code == 422
    with Session(db.engine) as s:
        assert not s.exec(select(DesktopReceipt)).all()


def test_many_concurrent_same_request_id_creates_one_job_one_file(client):
    key = uuid4().hex
    barrier = threading.Barrier(8)

    def go(_):
        barrier.wait()
        return post(client, key)
    with ThreadPoolExecutor(max_workers=8) as pool:
        results = list(pool.map(go, range(8)))
    assert [r.status_code for r in results] == [200] * 8
    assert all("status" in r.json() for r in results)
    with Session(db.engine) as s:
        assert len(s.exec(select(ScheduledUpload)).all()) == 1
    assert len(library_names()) == 1


def test_two_request_ids_same_video_concurrently(client):
    """Documents behaviour: two keys for the same bytes/account -> two jobs (=> two posts)."""
    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(lambda _: post(client, data=b"same-bytes"), range(2)))
    assert all(r.status_code == 200 for r in results)
    with Session(db.engine) as s:
        n = len(s.exec(select(ScheduledUpload)).all())
    if n > 1:
        pytest.xfail(f"product decision: {n} jobs created for the same video+account (no server-side dedup)")


def test_same_request_id_after_schedule_delete_never_recreates(client):
    key = uuid4().hex
    first = post(client, key).json()
    assert client.delete(f"/api/schedules/{first['schedule_id']}").status_code == 204
    again = post(client, key)
    assert again.status_code == 200 and again.json()["status"] == "cancelled"
    with Session(db.engine) as s:
        assert not s.exec(select(ScheduledUpload)).all()


def _reuse_id_for_web_job(client, key):
    """Desktop job deleted; a web-dashboard job for a different video reuses its integer ID."""
    first = post(client, key, data=b"desktop-video").json()
    old_id = first["schedule_id"]
    assert client.delete(f"/api/schedules/{old_id}").status_code == 204
    (settings.videos_dir() / "other.mp4").write_bytes(b"web-video")
    r = client.post("/api/schedules", json={"username": "demo", "title": "web", "source_type": "local",
                                           "source_ref": "other.mp4",
                                           "scheduled_for": (datetime.now(timezone.utc) + timedelta(days=1)).isoformat()})
    assert r.status_code == 201
    assert r.json()["id"] == old_id, "precondition: SQLite reused the ID"
    return old_id


def test_id_reuse_does_not_attach_old_desktop_request_to_new_web_job(client, monkeypatch):
    key = uuid4().hex
    old_id = _reuse_id_for_web_job(client, key)
    monkeypatch.setattr("api.services.tiktok_adapter.upload_from_options",
                        lambda *a: UploadOutcome(ok=True, message="published", video_id="v"))
    make_due(old_id)
    assert worker.tick()
    assert sorted(e["status"] for e in lookup(client, request_ids=[key])) == ["cancelled"]
    assert client.get(f"/api/desktop/jobs/{key}").json()["status"] == "cancelled"


def test_failure_after_copy_leaves_no_visible_orphan_in_library(client, monkeypatch):
    def boom(*a, **kw):
        raise RuntimeError("fixture: db failure after file copy")
    monkeypatch.setattr("api.services.history.track_schedule", boom)
    assert post(client).status_code == 500
    assert [v["name"] for v in client.get("/api/videos").json()] == []
    assert library_names() == []


def test_failure_mid_copy_leaves_no_part_file(client, monkeypatch):
    def partial(src, dst, length=0):
        dst.write(b"half")
        raise OSError("fixture: disk full")
    monkeypatch.setattr("api.routers.desktop.shutil.copyfileobj", partial)
    assert post(client).status_code == 500
    assert library_names() == []


def test_crashed_preparation_has_a_recovery_path(client):
    """Process killed mid-copy (older build: no heartbeat column value)."""
    key = uuid4().hex
    with Session(db.engine) as s:
        s.add(DesktopReceipt(request_id=key, created_at=db.now_utc() - timedelta(days=2)))
        s.add(UploadHistory(key=f"request:{key}", request_id=key, username="demo", status="preparing"))
        s.commit()
    assert client.get(f"/api/desktop/jobs/{key}").json()["status"] == "preparation_failed"
    assert [e["status"] for e in lookup(client, request_ids=[key])] == ["preparation_failed"]


def test_concurrent_lookup_backfill_does_not_500(client):
    with Session(db.engine) as s:
        acct = s.exec(select(Account)).first()
        for i in range(300):
            s.add(ScheduledUpload(account_id=acct.id, source_type="youtube", source_ref=f"https://youtu.be/{i}",
                                  title="t", scheduled_for=db.now_utc(), status="succeeded"))
        s.commit()
    tc = TestClient(client.app, base_url="http://localhost", headers=HEADERS, raise_server_exceptions=False)
    barrier = threading.Barrier(6)

    def go(_):
        barrier.wait()
        return tc.post("/api/history/lookup", json={"videos": [{"reel_id": "1"}]}).status_code
    with ThreadPoolExecutor(max_workers=6) as pool:
        assert list(pool.map(go, range(6))) == [200] * 6


def test_concurrent_backfill_calls_do_not_raise(client):
    with Session(db.engine) as s:
        acct = s.exec(select(Account)).first()
        for i in range(300):
            s.add(ScheduledUpload(account_id=acct.id, source_type="youtube", source_ref=f"https://youtu.be/{i}",
                                  title="t", scheduled_for=db.now_utc(), status="succeeded"))
        s.commit()
    errors = []
    barrier = threading.Barrier(4)

    def go(_):
        barrier.wait()
        try:
            with Session(db.engine) as s:
                history.backfill(s)
        except Exception as e:
            errors.append(f"{type(e).__name__}: {str(e)[:120]}")
    with ThreadPoolExecutor(4) as p:
        list(p.map(go, range(4)))
    assert not errors
    with Session(db.engine) as s:
        assert len(s.exec(select(UploadHistory)).all()) == 300


def test_lookup_over_2000_rejected_cleanly(client):
    r = client.post("/api/history/lookup", json={"videos": [{"reel_id": str(i)} for i in range(2001)]})
    assert r.status_code == 422


@pytest.fixture
def sample():
    p = settings.videos_dir() / "sample.mp4"
    p.write_bytes(b"0123456789")
    return p


def test_range_suffix(client, sample):
    r = client.get("/api/videos/sample.mp4/stream", headers={"Range": "bytes=-3"})
    assert r.status_code == 206 and r.content == b"789"
    assert r.headers["content-range"] == "bytes 7-9/10"


def test_range_end_beyond_size_clipped(client, sample):
    r = client.get("/api/videos/sample.mp4/stream", headers={"Range": "bytes=8-100"})
    assert r.status_code == 206 and r.content == b"89"


def test_range_multi(client, sample):
    r = client.get("/api/videos/sample.mp4/stream", headers={"Range": "bytes=0-1,4-5"})
    assert r.status_code in (200, 206)
    assert b"01" in r.content and b"45" in r.content


@pytest.mark.parametrize("name", ["..%2F..%2Fqa.db", "..%5Cqa.db", "%2e%2e%5c%2e%2e%5cqa.mp4", ".sample.mp4.part"])
def test_traversal_and_private_names(client, sample, name):
    (settings.videos_dir() / ".sample.mp4.part").write_bytes(b"partial")
    assert client.get(f"/api/videos/{name}/stream").status_code == 404


def test_absolute_path_outside_library_rejected(client, sample, tmp_path):
    from urllib.parse import quote
    outside = tmp_path / "outside.mp4"
    outside.write_bytes(b"secret")
    assert client.get(f"/api/videos/{quote(str(outside), safe='')}/stream").status_code == 404


def test_unc_name_does_not_touch_network(client, monkeypatch):
    touched = []
    real = os.path.realpath

    def spy(p, *a, **kw):
        if str(p).startswith("\\\\attacker"):
            touched.append(str(p))
            return str(p)
        return real(p, *a, **kw)
    monkeypatch.setattr(os.path, "realpath", spy)
    monkeypatch.setattr(ntpath, "realpath", spy)
    r = client.get("/api/videos/%5C%5Cattacker.example%5Cshare%5Cx.mp4/stream", headers={"X-Requested-With": ""})
    assert r.status_code == 404
    assert touched == []


def test_desktop_post_without_csrf_header_rejected(client):
    tc = TestClient(client.app, base_url="http://127.0.0.1:8765")
    r = tc.post("/api/desktop/jobs", data={"request_id": uuid4().hex, "username": "demo", "title": "x"},
                files={"video": ("video.mp4", b"x", "video/mp4")})
    assert r.status_code == 403


def test_rebinding_host_rejected(client):
    tc = TestClient(client.app, base_url="http://evil.example:8765", headers=HEADERS)
    assert tc.post("/api/history/lookup", json={"videos": []}).status_code == 403
    assert tc.get("/api/videos").status_code == 403


@pytest.mark.parametrize("fname", ["../../evil.mp4", "C:\\Windows\\x.mp4", "a.mp4\x00.exe", "x.MP4", "con.mp4", "noext"])
def test_filename_never_escapes_library(client, fname):
    r = client.post("/api/desktop/jobs", data={"request_id": uuid4().hex, "username": "demo", "title": "t"},
                    files={"video": (fname, b"bytes", "video/mp4")})
    assert r.status_code in (200, 422), r.status_code
    for p in settings.videos_dir().iterdir():
        assert p.name.startswith("kid-"), p.name


def _claim(sid):
    with Session(db.engine) as s:
        claimed = worker.claim_next_due(s)
    assert claimed is not None and claimed.id == sid
    return claimed


def _stall(sid):
    with Session(db.engine) as s:
        row = s.get(ScheduledUpload, sid)
        row.heartbeat_at = db.now_utc() - timedelta(minutes=10)
        s.add(row)
        s.commit()


def _due_desktop_job(client):
    body = post(client).json()
    make_due(body["schedule_id"])
    return body["schedule_id"], body["request_id"]


def _reclaim_and_reclaim_newer(client, sid):
    """W1 claims and goes silent >5 min; it is reclaimed; the user confirms a retry; W2 claims."""
    w1 = _claim(sid)
    _stall(sid)
    with Session(db.engine) as s:
        assert worker.reclaim_stale(s) == 1
    assert client.patch(f"/api/schedules/{sid}", json={"status": "pending", "confirm_uncertain": True}).status_code == 200
    make_due(sid)
    w2 = _claim(sid)
    assert w2.attempts == w1.attempts + 1
    return w1, w2


def test_stale_old_worker_finalize_does_not_clobber_newer_attempt(client):
    sid, _ = _due_desktop_job(client)
    w1, w2 = _reclaim_and_reclaim_newer(client, sid)
    # QA's call adapted to the fenced API: finalize must say which attempt it is reporting.
    worker.finalize(w1.id, UploadOutcome(ok=False, message="old attempt: upload auth timeout", retryable=True),
                    attempts=w1.attempts, key=history.schedule_key(w1))
    with Session(db.engine) as s:
        row = s.get(ScheduledUpload, sid)
        assert row.status == "running" and row.attempts == w2.attempts, row.result_text


class _Resp:
    def __init__(self, status, body):
        self.status_code = status
        self._body = body
        self.text = body if isinstance(body, str) else json.dumps(body)

    def json(self):
        if isinstance(self._body, str):
            raise ValueError("no json")
        return self._body


class _Sess:
    def __init__(self, resp):
        self.resp = resp
        self.cookies = {}

    def post(self, *a, **kw):
        return self.resp


class _Sig:
    x_bogus = "x"
    signature = "s"


class _Signer:
    def sign(self, url):
        return _Sig()


def _publish(resp):
    from autotok.uploader import Client
    c = Client.__new__(Client)
    c._signer = _Signer()
    c.user_agent = "UA"
    c.timeout = 1
    c.proxy = None
    return c._publish(_Sess(resp), {})


@pytest.mark.parametrize("body", [
    {"data": {}},                      # missing
    {"status_code": None},             # null
    {"status_code": "0"},              # string zero
    {"status_code": True},             # bool (an int subclass in Python)
    {"status_code": False},
    {"status_code": 0.0},              # float
    {"status_code": 1.5},
    [],                                # JSON list
    "<html>",                          # not JSON
], ids=["missing", "null", "string", "true", "false", "float0", "float", "list", "html"])
def test_ambiguous_200_publish_responses_are_uncertain(body):
    from autotok.errors import PublishUncertainError
    with pytest.raises(PublishUncertainError):
        _publish(_Resp(200, body))


@pytest.mark.parametrize("status", [408, 429, 502, 599])
def test_transient_http_publish_responses_are_uncertain(status):
    from autotok.errors import PublishUncertainError
    with pytest.raises(PublishUncertainError):
        _publish(_Resp(status, "x"))


def test_int_status_codes_keep_their_meaning():
    from autotok.errors import PublishError, PublishUncertainError
    assert _publish(_Resp(200, {"status_code": 0, "data": {"x": 1}}))["data"] == {"x": 1}
    with pytest.raises(PublishError) as exc:
        _publish(_Resp(200, {"status_code": 10004, "status_msg": "guidelines"}))
    assert not isinstance(exc.value, PublishUncertainError) and exc.value.status_code == 10004


def test_running_job_cannot_be_edited_cancelled_or_deleted(client):
    sid, _ = _due_desktop_job(client)
    _claim(sid)
    assert client.patch(f"/api/schedules/{sid}", json={"status": "cancelled"}).status_code == 409
    assert client.patch(f"/api/schedules/{sid}", json={"title": "x"}).status_code == 409
    assert client.delete(f"/api/schedules/{sid}").status_code == 409
    with Session(db.engine) as s:
        assert s.get(ScheduledUpload, sid).status == "running"


def test_reschedule_updates_history_planned_for(client):
    when = datetime.now(timezone.utc) + timedelta(days=1)
    body = post(client, scheduled_for=when.isoformat()).json()
    with Session(db.engine) as s:  # a legacy (PC-side) job: only those can still be rescheduled
        row = s.get(ScheduledUpload, body["schedule_id"])
        row.options_json = "{}"
        s.add(row)
        s.commit()
    later = when + timedelta(days=2)
    assert client.patch(f"/api/schedules/{body['schedule_id']}", json={"scheduled_for": later.isoformat()}).status_code == 200
    planned = datetime.fromisoformat(client.get(f"/api/desktop/jobs/{body['request_id']}").json()["planned_for"])
    assert abs((planned - later).total_seconds()) < 1
    planned = datetime.fromisoformat(lookup(client, request_ids=[body["request_id"]])[0]["planned_for"])
    assert abs((planned - later).total_seconds()) < 1


def test_retry_backoff_does_not_overwrite_planned_for(client, monkeypatch):
    when = datetime.now(timezone.utc) + timedelta(days=1)
    body = post(client, scheduled_for=when.isoformat()).json()
    make_due(body["schedule_id"])
    monkeypatch.setattr("api.services.tiktok_adapter.upload_from_options",
                        lambda *a: UploadOutcome(ok=False, message="net", retryable=True))
    assert worker.tick()
    with Session(db.engine) as s:
        assert s.get(ScheduledUpload, body["schedule_id"]).status == "pending"  # backoff really happened
    planned = datetime.fromisoformat(client.get(f"/api/desktop/jobs/{body['request_id']}").json()["planned_for"])
    assert abs((planned - when).total_seconds()) < 1


def test_uncertain_never_auto_reposted_and_not_success(client, monkeypatch):
    calls = []

    def fake(*a):
        calls.append(a)
        return UploadOutcome(ok=False, message="publish: HTTP 502", uncertain=True)
    monkeypatch.setattr("api.services.tiktok_adapter.upload_from_options", fake)
    sid, _ = _due_desktop_job(client)
    assert worker.tick()
    for _ in range(3):
        make_due(sid)
        worker.tick()
    assert len(calls) == 1
    with Session(db.engine) as s:
        e = s.exec(select(UploadHistory).where(UploadHistory.schedule_id == sid)).first()
        assert e.status == "failed" and e.publish_uncertain and e.prior_uncertain and e.accepted_at is None


# ======================= fix proofs =======================

# ---- B1: SQLite ID reuse ----

def test_history_contaminated_by_an_older_build_is_not_reported_for_the_old_request(client):
    """Older builds copied the deleted desktop request_id onto the reusing job's history row."""
    key = uuid4().hex
    old_id = _reuse_id_for_web_job(client, key)
    with Session(db.engine) as s:
        job = s.get(ScheduledUpload, old_id)
        web_entry = s.get(UploadHistory, history.schedule_key(job))
        web_entry.request_id = key  # what the old code wrote
        web_entry.status = "succeeded"
        s.add(web_entry)
        s.commit()
    entries = lookup(client, request_ids=[key])
    assert [(e["status"], e["original_name"]) for e in entries] == [("cancelled", "video.mp4")]
    got = client.get(f"/api/desktop/jobs/{key}").json()
    assert got["status"] == "cancelled" and got["accepted_at"] is None
    # The web job's own history is still found by its content.
    assert [e["status"] for e in lookup(client, sha256=hashlib.sha256(b"web-video").hexdigest())] == ["succeeded"]


def test_backfill_does_not_attach_a_receipt_to_an_unrelated_job(client):
    """A legacy job with no history row that reuses a deleted desktop job's ID."""
    key = uuid4().hex
    first = post(client, key, data=b"desktop-video").json()
    assert client.delete(f"/api/schedules/{first['schedule_id']}").status_code == 204
    (settings.videos_dir() / "legacy.mp4").write_bytes(b"legacy")
    with Session(db.engine) as s:
        acct = s.exec(select(Account)).first()
        s.add(ScheduledUpload(id=first["schedule_id"], account_id=acct.id, source_type="local",
                              source_ref="legacy.mp4", title="t", scheduled_for=db.now_utc(), status="succeeded"))
        s.commit()
    restart(client)  # startup backfill
    entries = lookup(client, sha256=hashlib.sha256(b"legacy").hexdigest())
    assert len(entries) == 1 and entries[0]["request_id"] is None


# ---- B2: names are checked before any filesystem call ----

BAD_NAMES = ["\\\\attacker.example\\share\\x.mp4", "//attacker.example/share/x.mp4", "C:\\Windows\\attacker.mp4",
             "C:attacker.mp4", "sample.mp4::$DATA", "attacker.mp4:stream", "sub\\attacker.mp4", "a/attacker.mp4",
             "attacker\x00.mp4"]


@pytest.fixture
def fs_spy(monkeypatch):
    touched = []

    def wrap(fn):
        def spy(p, *a, **kw):
            text = os.fspath(p) if isinstance(p, (str, bytes, os.PathLike)) else str(p)
            text = text.decode(errors="replace") if isinstance(text, bytes) else text
            if any(mark in text for mark in ("attacker", "$DATA")):
                touched.append((fn.__name__, text))
                raise AssertionError(f"filesystem touched: {text}")
            return fn(p, *a, **kw)
        return spy
    for mod, name in ((os, "stat"), (os, "lstat"), (os.path, "realpath"), (ntpath, "realpath"),
                      (os.path, "exists"), (os.path, "isfile"), (os, "open"), (os, "scandir")):
        monkeypatch.setattr(mod, name, wrap(getattr(mod, name)))
    return touched


@pytest.mark.parametrize("name", BAD_NAMES)
def test_resolve_rejects_unc_drive_ads_and_separators_without_filesystem_access(fs_spy, sample, name):
    with pytest.raises(ValueError):
        library.resolve(name)
    assert fs_spy == []


@pytest.mark.parametrize("name", [n for n in BAD_NAMES if "\x00" not in n and "/" not in n])
def test_http_name_endpoints_reject_unsafe_names_without_filesystem_access(client, fs_spy, sample, name):
    from urllib.parse import quote
    enc = quote(name, safe="")
    assert client.get(f"/api/videos/{enc}/stream", headers={"X-Requested-With": ""}).status_code == 404
    assert client.delete(f"/api/videos/{enc}").status_code == 404
    r = client.post("/api/uploads/library", json={"username": "demo", "title": "t", "name": name})
    assert r.status_code in (404, 409, 422)
    assert fs_spy == []


def test_absolute_ref_inside_the_library_still_resolves(sample):
    assert library.resolve(str(sample)) == sample.resolve()
    assert library.resolve("sample.mp4") == sample.resolve()


# ---- B3: backfill at startup, race-safe, lookup never writes history ----

def test_legacy_jobs_are_backfilled_at_startup_not_by_lookup(client):
    (settings.videos_dir() / "old.mp4").write_bytes(b"old-video")
    with Session(db.engine) as s:
        acct = s.exec(select(Account)).first()
        s.add(ScheduledUpload(account_id=acct.id, source_type="local", source_ref="old.mp4", title="t",
                              scheduled_for=db.now_utc(), status="succeeded"))
        s.commit()
    sha = hashlib.sha256(b"old-video").hexdigest()
    assert lookup(client, sha256=sha) == []  # lookup alone never invents rows
    restart(client)
    entries = lookup(client, sha256=sha)
    assert len(entries) == 1 and entries[0]["time_source"] == "legacy_result_time"


def test_backfill_concurrent_with_job_creation(client):
    with Session(db.engine) as s:
        acct = s.exec(select(Account)).first()
        for i in range(200):
            s.add(ScheduledUpload(account_id=acct.id, source_type="youtube", source_ref=f"https://youtu.be/{i}",
                                  title="t", scheduled_for=db.now_utc(), status="succeeded"))
        s.commit()
    errors, codes = [], []
    barrier = threading.Barrier(6)

    def backfill(_):
        barrier.wait()
        try:
            with Session(db.engine) as s:
                history.backfill(s)
        except Exception as e:
            errors.append(repr(e))

    def create(i):
        barrier.wait()
        codes.append(post(client, data=f"video-{i}".encode()).status_code)
    with ThreadPoolExecutor(6) as pool:
        futures = [pool.submit(backfill, 0), pool.submit(backfill, 1), pool.submit(backfill, 2)]
        futures += [pool.submit(create, i) for i in range(3)]
        for f in futures:
            f.result()
    assert errors == [] and codes == [200] * 3
    with Session(db.engine) as s:
        jobs = s.exec(select(ScheduledUpload)).all()
        keys = [e.key for e in s.exec(select(UploadHistory)).all()]
        assert len(jobs) == 203
        assert sorted(keys) == sorted(history.schedule_key(j) for j in jobs)  # exactly one row per job


# ---- B4 / R1: failures delete only this attempt's files; terminal preparation_failed ----

def test_rename_failure_cleans_up_and_is_terminal(client, monkeypatch):
    copies = []
    real_copy = desktop.shutil.copyfileobj
    monkeypatch.setattr("api.routers.desktop.shutil.copyfileobj",
                        lambda *a, **kw: (copies.append(1), real_copy(*a, **kw))[1])
    real_replace = Path.replace

    def failing_replace(self, target):
        raise OSError("fixture: rename failed")
    monkeypatch.setattr(Path, "replace", failing_replace)
    key = uuid4().hex
    r = post(client, key)
    assert r.status_code == 500 and r.json()["status"] == "preparation_failed"
    assert library_names() == []
    monkeypatch.setattr(Path, "replace", real_replace)
    again = post(client, key)  # same key replay: report only, never prepare again
    assert again.status_code == 200 and again.json()["status"] == "preparation_failed"
    assert len(copies) == 1
    with Session(db.engine) as s:
        assert not s.exec(select(ScheduledUpload)).all()


def test_db_failure_at_enqueue_rolls_back_job_and_files(client, monkeypatch):
    other = post(client, data=b"other").json()  # a different request's file must survive
    def boom(*a, **kw):
        raise RuntimeError("fixture: db failure at enqueue")
    monkeypatch.setattr("api.services.history.track_schedule", boom)
    key = uuid4().hex
    r = post(client, key)
    assert r.status_code == 500 and r.json()["status"] == "preparation_failed" and r.json()["request_id"] == key
    with Session(db.engine) as s:
        jobs = s.exec(select(ScheduledUpload)).all()
        assert [j.id for j in jobs] == [other["schedule_id"]]
        assert s.get(DesktopReceipt, key).state == "preparation_failed"
        assert len(library_names()) == 1 and library_names()[0] == jobs[0].source_ref


def test_successful_replay_never_copies_again(client, monkeypatch):
    copies = []
    real_copy = desktop.shutil.copyfileobj
    monkeypatch.setattr("api.routers.desktop.shutil.copyfileobj",
                        lambda *a, **kw: (copies.append(1), real_copy(*a, **kw))[1])
    key = uuid4().hex
    first = post(client, key).json()
    again = post(client, key, data=b"different bytes").json()
    assert first["status"] == again["status"] == "pending" and first["schedule_id"] == again["schedule_id"]
    assert len(copies) == 1 and len(library_names()) == 1


# ---- B5 / R1: stale preparation, heartbeat, late commit ----

@pytest.mark.parametrize("beat_every", [100.0, 0.0], ids=["late-commit", "late-heartbeat"])
def test_stalled_copy_declared_failed_then_late_commit_is_refused(client, monkeypatch, beat_every):
    monkeypatch.setattr(desktop, "STALE_PREPARING_AFTER", timedelta(seconds=1))
    monkeypatch.setattr(desktop, "HEARTBEAT_EVERY", beat_every)
    stalled_key = uuid4().hex
    started, release = threading.Event(), threading.Event()
    real_copy = desktop.shutil.copyfileobj

    def copy(src, dst, length=0):
        if getattr(dst, "key", "") == stalled_key:
            started.set()
            assert release.wait(10)
        return real_copy(src, dst, length)
    monkeypatch.setattr("api.routers.desktop.shutil.copyfileobj", copy)
    with ThreadPoolExecutor(1) as pool:
        future = pool.submit(post, client, stalled_key, b"stalled")
        assert started.wait(5)
        other = post(client, data=b"healthy").json()  # another request completes meanwhile
        time.sleep(1.3)
        assert client.get(f"/api/desktop/jobs/{stalled_key}").json()["status"] == "preparation_failed"
        release.set()
        late = future.result()
    assert late.status_code == 500 and late.json()["status"] == "preparation_failed"
    with Session(db.engine) as s:
        jobs = s.exec(select(ScheduledUpload)).all()
        assert [j.id for j in jobs] == [other["schedule_id"]]  # the late attempt never enqueued
        assert library_names() == [jobs[0].source_ref]  # only its own files were deleted
        assert s.get(DesktopReceipt, stalled_key).schedule_id is None
    assert client.get(f"/api/desktop/jobs/{stalled_key}").json()["status"] == "preparation_failed"


def test_heartbeat_keeps_a_slow_live_copy_from_expiring(client, monkeypatch):
    monkeypatch.setattr(desktop, "STALE_PREPARING_AFTER", timedelta(seconds=0.5))
    monkeypatch.setattr(desktop, "HEARTBEAT_EVERY", 0.05)

    def slow_copy(src, dst, length=0):
        for _ in range(20):  # ~2 s, four times the stale threshold
            dst.write(b"x" * 1024)
            time.sleep(0.1)
    monkeypatch.setattr("api.routers.desktop.shutil.copyfileobj", slow_copy)
    key = uuid4().hex
    with ThreadPoolExecutor(1) as pool:
        future = pool.submit(post, client, key)
        seen = []
        while not future.done():
            r = client.get(f"/api/desktop/jobs/{key}")
            if r.status_code == 200:
                seen.append(r.json()["status"])
            time.sleep(0.1)
        result = future.result()
    assert result.status_code == 200 and result.json()["status"] == "pending"
    assert len(seen) >= 10 and set(seen) == {"preparing"}, seen
    entry = lookup(client, request_ids=[key])[0]
    assert entry["sha256"] == hashlib.sha256(b"x" * 1024 * 20).hexdigest()


def test_startup_expires_stalled_preparations_and_removes_only_unusable_bridge_files(client):
    lib = settings.videos_dir()
    k_failed, k_missing, k_queued, k_ref, k_live, k_stale = (uuid4().hex for _ in range(6))
    tok = uuid4().hex
    files = {
        "failed": f"kid-{k_failed}-{tok}.mp4", "failed_part": f".kid-{k_failed}-{tok}.mp4.part",
        "missing": f"kid-{k_missing}.mp4", "queued": f"kid-{k_queued}-{tok}.mp4",
        "referenced": f"kid-{k_ref}-{tok}.mp4", "live_part": f".kid-{k_live}-{tok}.mp4.part",
        "stale_part": f".kid-{k_stale}-{tok}.mp4.part", "user": "kid-holiday.mp4", "user2": "clip.mp4",
    }
    for name in files.values():
        (lib / name).write_bytes(b"v")
    now = db.now_utc()
    with Session(db.engine) as s:
        acct = s.exec(select(Account)).first()
        s.add(DesktopReceipt(request_id=k_failed, state="preparation_failed"))
        s.add(DesktopReceipt(request_id=k_queued, state="queued", schedule_id=999))  # its job was deleted
        s.add(DesktopReceipt(request_id=k_ref, state="preparation_failed"))
        s.add(DesktopReceipt(request_id=k_live, state="preparing", attempt_token=tok, heartbeat_at=now))
        s.add(DesktopReceipt(request_id=k_stale, state="preparing", attempt_token=tok,
                             heartbeat_at=now - timedelta(hours=1)))
        s.add(ScheduledUpload(account_id=acct.id, source_type="local", source_ref=files["referenced"], title="t",
                              scheduled_for=now + timedelta(days=1)))
        s.commit()
    restart(client)
    assert library_names() == sorted([files["queued"], files["referenced"], files["live_part"],
                                      files["user"], files["user2"]])
    with Session(db.engine) as s:
        assert s.get(DesktopReceipt, k_stale).state == "preparation_failed"
        assert s.get(DesktopReceipt, k_live).state == "preparing"


# ---- B6: indexed, chunked lookup ----

def test_lookup_2000_videos_against_5000_entries_is_fast_and_correct(client):
    with Session(db.engine) as s:
        for i in range(5000):
            s.add(UploadHistory(key=f"direct:{i}", username="demo", reel_id=str(i), sha256=f"{i:064x}",
                                request_id=f"{i:032x}", status="succeeded"))
        s.commit()
    # Each video matches one entry by reel, a different one by sha and a third by request_id.
    videos = [{"reel_id": str(i), "sha256": f"{i + 2000:064x}", "request_ids": [f"{i + 4000:032x}"] if i < 1000 else []}
              for i in range(2000)]
    t = time.perf_counter()
    r = client.post("/api/history/lookup", json={"videos": videos})
    elapsed = time.perf_counter() - t
    assert r.status_code == 200
    rows = r.json()
    assert len(rows) == 2000
    assert sorted(e["key"] for e in rows[0]["entries"]) == ["direct:0", "direct:2000", "direct:4000"]
    assert sorted(e["key"] for e in rows[1999]["entries"]) == ["direct:1999", "direct:3999"]
    assert sum(len(v["entries"]) for v in rows) == 2000 * 2 + 1000
    assert {"sha256", "prior_uncertain", "publish_uncertain", "request_id"} <= rows[0]["entries"][0].keys()
    assert elapsed < 1.0, f"lookup took {elapsed:.2f}s"


# ---- B7 / R3: attempt fencing ----

def test_stale_heartbeat_never_refreshes_a_newer_attempt(client):
    sid, _ = _due_desktop_job(client)
    w1, w2 = _reclaim_and_reclaim_newer(client, sid)
    _stall(sid)
    assert worker.Heartbeat(sid, w1.attempts).beat() is False
    with Session(db.engine) as s:
        assert s.get(ScheduledUpload, sid).heartbeat_at.replace(tzinfo=timezone.utc) < db.now_utc() - timedelta(minutes=5)
    assert worker.Heartbeat(sid, w2.attempts).beat() is True


def _before_update(engine, marker, action):
    """Run ``action`` on another connection right before the first UPDATE containing ``marker``."""
    fired = []

    @event.listens_for(engine, "before_cursor_execute")
    def hook(conn, cursor, statement, *args):
        if not fired and statement.startswith("UPDATE scheduled_uploads") and marker in statement:
            fired.append(statement)
            action()
    return fired, lambda: event.remove(engine, "before_cursor_execute", hook)


def test_reclaim_loses_to_a_heartbeat_that_lands_after_its_select(client, db_path):
    sid, _ = _due_desktop_job(client)
    w1 = _claim(sid)
    _stall(sid)

    def beat():
        con = sqlite3.connect(db_path)
        con.execute("UPDATE scheduled_uploads SET heartbeat_at = ? WHERE id = ?",
                    (db.now_utc().replace(tzinfo=None).isoformat(sep=" "), sid))
        con.commit()
        con.close()
    fired, remove = _before_update(db.engine, "status", beat)
    try:
        with Session(db.engine) as s:
            assert worker.reclaim_stale(s) == 0
    finally:
        remove()
    assert fired
    with Session(db.engine) as s:
        row = s.get(ScheduledUpload, sid)
        assert row.status == "running" and row.attempts == w1.attempts


def test_finalize_racing_a_reclaim_records_but_never_requeues(client, db_path):
    sid, _ = _due_desktop_job(client)
    w1 = _claim(sid)

    def reclaim():
        con = sqlite3.connect(db_path)
        con.execute("UPDATE scheduled_uploads SET status='failed', publish_uncertain=1, "
                    "result_text='the scheduler stopped' WHERE id = ?", (sid,))
        con.commit()
        con.close()
    fired, remove = _before_update(db.engine, "status", reclaim)
    try:
        worker.finalize(sid, UploadOutcome(ok=False, message="network blip", retryable=True),
                        attempts=w1.attempts, key=history.schedule_key(w1))
    finally:
        remove()
    assert fired
    with Session(db.engine) as s:
        row = s.get(ScheduledUpload, sid)
        assert row.status == "failed" and row.result_text == "network blip"
        assert not worker.claim_next_due(s)


def test_late_success_of_a_stale_attempt_is_kept_as_prior_uncertain(client):
    sid, key = _due_desktop_job(client)
    w1, w2 = _reclaim_and_reclaim_newer(client, sid)
    worker.finalize(sid, UploadOutcome(ok=True, message="published", video_id="late-vid"),
                    attempts=w1.attempts, key=history.schedule_key(w1))
    with Session(db.engine) as s:
        row = s.get(ScheduledUpload, sid)
        assert row.status == "running" and row.attempts == w2.attempts  # the newer attempt is untouched
    got = client.get(f"/api/desktop/jobs/{key}").json()
    assert got["prior_uncertain"] is True
    entry = lookup(client, request_ids=[key])[0]
    assert entry["prior_uncertain"] is True and "late success of attempt 1" in entry["result_text"]
    worker.finalize(sid, UploadOutcome(ok=False, message="guidelines"), attempts=w2.attempts,
                    key=history.schedule_key(w2))
    entry = lookup(client, request_ids=[key])[0]
    assert entry["status"] == "failed" and entry["prior_uncertain"] is True


def test_late_success_of_the_current_reclaimed_attempt_marks_success(client):
    sid, key = _due_desktop_job(client)
    w1 = _claim(sid)
    _stall(sid)
    with Session(db.engine) as s:
        assert worker.reclaim_stale(s) == 1
    worker.finalize(sid, UploadOutcome(ok=True, message="published", video_id="v1"),
                    attempts=w1.attempts, key=history.schedule_key(w1))
    got = client.get(f"/api/desktop/jobs/{key}").json()
    assert got["status"] == "succeeded" and got["prior_uncertain"] is True and got["publish_uncertain"] is False


# ---- B10: no hashing while SQLite's write lock is held ----

def _write_lock_free(path):
    con = sqlite3.connect(path, timeout=0)
    try:
        con.execute("BEGIN IMMEDIATE")
        con.rollback()
        return True
    except sqlite3.OperationalError:
        return False
    finally:
        con.close()


def test_desktop_hashes_while_copying_without_the_write_lock(client, monkeypatch, db_path):
    probes = []
    real_write = desktop._AttemptWriter.write

    def write(self, data):
        probes.append(_write_lock_free(db_path))
        return real_write(self, data)
    monkeypatch.setattr(desktop._AttemptWriter, "write", write)
    monkeypatch.setattr(history, "identity", lambda *a, **kw: pytest.fail("desktop must not re-hash the file"))
    key = uuid4().hex
    assert post(client, key, data=b"z" * 5000).status_code == 200
    assert probes and all(probes)
    assert lookup(client, request_ids=[key])[0]["sha256"] == hashlib.sha256(b"z" * 5000).hexdigest()


def test_web_schedule_hashes_before_the_write_transaction(client, monkeypatch, db_path):
    (settings.videos_dir() / "w.mp4").write_bytes(b"w" * 100)
    probes = []
    real = history.identity

    def identity(path, original_name=""):
        probes.append(_write_lock_free(db_path))
        return real(path, original_name)
    monkeypatch.setattr(history, "identity", identity)
    r = client.post("/api/schedules", json={"username": "demo", "title": "t", "source_type": "local",
                                           "source_ref": "w.mp4",
                                           "scheduled_for": (datetime.now(timezone.utc) + timedelta(days=1)).isoformat()})
    assert r.status_code == 201
    assert probes == [True]


def test_finalize_is_not_blocked_by_a_slow_desktop_preparation(client, monkeypatch):
    """QA probe: a 6 s copy (> busy_timeout 5 s) must not block the worker's finalize."""
    other = post(client).json()["schedule_id"]
    make_due(other)
    claimed = _claim(other)
    started = threading.Event()
    real_copy = desktop.shutil.copyfileobj

    def slow(src, dst, length=0):
        started.set()
        time.sleep(6)
        return real_copy(src, dst, length)
    monkeypatch.setattr("api.routers.desktop.shutil.copyfileobj", slow)
    t = threading.Thread(target=lambda: post(client))
    t.start()
    try:
        assert started.wait(5)
        worker.finalize(claimed.id, UploadOutcome(ok=True, message="published", video_id="v"),
                        attempts=claimed.attempts, key=history.schedule_key(claimed))
    finally:
        t.join()
    with Session(db.engine) as s:
        assert s.get(ScheduledUpload, claimed.id).status == "succeeded"


# ---- B11: direct uploads interrupted by a dead server process ----

def _dead_process_owner():
    proc = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(1.5)"])
    try:
        start = history._process_start(proc.pid)
    finally:
        proc.wait()
    assert start
    return f"{proc.pid}.{start}"


def test_startup_fails_direct_uploads_only_when_their_owner_process_is_dead(client):
    now = db.now_utc()
    rows = {
        "dead": f"direct:{_dead_process_owner()}:{uuid4().hex}",
        "alive": f"direct:{history._OWNER}:{uuid4().hex}",
        "reused_pid": f"direct:{os.getpid()}.1:{uuid4().hex}",  # same PID, different start time
        "legacy_old": f"direct:{uuid4().hex}",
        "legacy_new": f"direct:{uuid4().hex}",
    }
    with Session(db.engine) as s:
        for label, key in rows.items():
            created = now - timedelta(hours=3) if label == "legacy_old" else now
            s.add(UploadHistory(key=key, username="demo", status="running", created_at=created,
                                sha256=hashlib.sha256(label.encode()).hexdigest()))
        s.commit()
    restart(client)
    with Session(db.engine) as s:
        got = {label: s.get(UploadHistory, key) for label, key in rows.items()}
    for label in ("dead", "reused_pid", "legacy_old"):
        e = got[label]
        assert (e.status, e.publish_uncertain, e.prior_uncertain) == ("failed", True, True), label
        assert e.accepted_at is None and "may or may not" in e.result_text
    for label in ("alive", "legacy_new"):
        assert got[label].status == "running", label


def test_direct_upload_key_records_the_live_owner(client, monkeypatch):
    monkeypatch.setattr("api.services.tiktok_adapter.upload_from_options",
                        lambda *a: UploadOutcome(ok=False, message="cut off", uncertain=True))
    r = client.post("/api/uploads/file", data={"username": "demo", "title": "t"},
                    files={"video": ("a.mp4", b"direct-bytes", "video/mp4")})
    assert r.status_code == 200 and r.json()["uncertain"] is True
    entry = lookup(client, sha256=hashlib.sha256(b"direct-bytes").hexdigest())[0]
    assert entry["key"].startswith(f"direct:{os.getpid()}.") and entry["prior_uncertain"] is True


# ---- B12 / R4: prior_uncertain is monotonic and durable ----

def test_prior_uncertain_survives_confirmed_retry_failure_and_reopen(client, monkeypatch, db_path):
    sid, key = _due_desktop_job(client)
    monkeypatch.setattr("api.services.tiktok_adapter.upload_from_options",
                        lambda *a: UploadOutcome(ok=False, message="cut off", uncertain=True))
    assert worker.tick()
    first = client.get(f"/api/desktop/jobs/{key}").json()
    assert first["status"] == "failed" and first["publish_uncertain"] and first["prior_uncertain"]
    assert client.patch(f"/api/schedules/{sid}", json={"status": "pending", "confirm_uncertain": True}).status_code == 200
    retried = client.get(f"/api/desktop/jobs/{key}").json()
    assert retried["status"] == "pending" and not retried["publish_uncertain"] and retried["prior_uncertain"]
    make_due(sid)
    monkeypatch.setattr("api.services.tiktok_adapter.upload_from_options",
                        lambda *a: UploadOutcome(ok=False, message="guidelines"))
    assert worker.tick()
    entry = lookup(client, request_ids=[key])[0]
    assert entry["status"] == "failed" and entry["publish_uncertain"] is False and entry["prior_uncertain"] is True
    # Durable: a fresh engine/process on the same file sees it.
    fresh = db.make_engine(f"sqlite:///{db_path}")
    try:
        with Session(fresh) as s:
            assert s.exec(select(UploadHistory).where(UploadHistory.request_id == key)).one().prior_uncertain is True
    finally:
        fresh.dispose()


# ---- R4: migration on fresh and existing databases ----

def _columns(path, table):
    con = sqlite3.connect(path)
    try:
        return {r[1] for r in con.execute(f"PRAGMA table_info({table})")}
    finally:
        con.close()


def test_fresh_database_has_new_columns_and_version(client, db_path):
    assert {"attempt_token", "heartbeat_at"} <= _columns(db_path, "desktop_receipts")
    assert "prior_uncertain" in _columns(db_path, "upload_history")
    con = sqlite3.connect(db_path)
    assert con.execute("PRAGMA user_version").fetchone()[0] == db.SCHEMA_VERSION == 5
    con.close()


def test_existing_v1_database_from_the_previous_bridge_build_is_migrated(tmp_path):
    path = tmp_path / "v1.db"
    con = sqlite3.connect(path)
    con.executescript("""
        CREATE TABLE accounts (id INTEGER PRIMARY KEY, username VARCHAR(128) NOT NULL UNIQUE, display_name VARCHAR(128),
            cookie_path VARCHAR NOT NULL, has_valid_session BOOLEAN NOT NULL, created_at DATETIME NOT NULL,
            updated_at DATETIME NOT NULL, last_used_at DATETIME);
        CREATE TABLE desktop_receipts (request_id VARCHAR(32) PRIMARY KEY, schedule_id INTEGER, state VARCHAR NOT NULL,
            created_at DATETIME NOT NULL);
        CREATE TABLE upload_history (key VARCHAR PRIMARY KEY, schedule_id INTEGER, request_id VARCHAR,
            username VARCHAR NOT NULL, reel_id VARCHAR NOT NULL, sha256 VARCHAR NOT NULL, original_name VARCHAR NOT NULL,
            status VARCHAR NOT NULL, planned_for DATETIME, accepted_at DATETIME, finished_at DATETIME,
            time_source VARCHAR NOT NULL, media_video_id VARCHAR, publish_uncertain BOOLEAN NOT NULL,
            result_text VARCHAR, created_at DATETIME NOT NULL);
        PRAGMA user_version = 1;
    """)
    old_key = "a" * 32
    con.execute("INSERT INTO desktop_receipts VALUES (?, NULL, 'preparing', '2026-01-01 00:00:00.000000')", (old_key,))
    for key, uncertain in (("direct:u", 1), ("direct:c", 0)):
        con.execute("INSERT INTO upload_history VALUES (?, NULL, NULL, 'demo', '', '', 'v.mp4', 'failed', NULL, NULL, "
                    "NULL, 'acknowledgement', NULL, ?, NULL, '2026-01-01 00:00:00.000000')", (key, uncertain))
    con.commit()
    con.close()
    old = db.engine
    eng = db.make_engine(f"sqlite:///{path}")
    db.override_engine(eng)
    try:
        db.init_db()
        db.init_db()  # idempotent
        with Session(eng) as s:
            assert s.get(UploadHistory, "direct:u").prior_uncertain is True
            assert s.get(UploadHistory, "direct:c").prior_uncertain is False
            assert s.get(DesktopReceipt, old_key).attempt_token == ""
        with TestClient(create_app(), base_url="http://localhost", headers=HEADERS) as c:
            # A preparation left by the old build (no heartbeat) ages by created_at.
            assert c.get(f"/api/desktop/jobs/{old_key}").json()["status"] == "preparation_failed"
    finally:
        db.override_engine(old)
        eng.dispose()
    assert {"attempt_token", "heartbeat_at"} <= _columns(path, "desktop_receipts")
    assert "prior_uncertain" in _columns(path, "upload_history")


def test_source_sha256_becomes_history_identity(client):
    src = hashlib.sha256(b"original-file").hexdigest()
    uploaded = hashlib.sha256(b"cleaned-remux").hexdigest()
    r = post(client, data=b"cleaned-remux", source_sha256=src.upper())  # case-insensitive input
    assert r.status_code == 200, r.text
    assert [e["request_id"] for e in lookup(client, sha256=src)] == [r.json()["request_id"]]
    assert lookup(client, sha256=uploaded) == []


def test_invalid_source_sha256_is_422_and_leaves_no_receipt(client):
    for bad in ("abc", "g" * 64, "a" * 63, "a" * 65):
        key = uuid4().hex
        assert post(client, key=key, source_sha256=bad).status_code == 422
        with Session(db.engine) as s:
            assert s.get(DesktopReceipt, key) is None
            assert s.exec(select(UploadHistory).where(UploadHistory.request_id == key)).all() == []


def test_absent_source_sha256_keeps_uploaded_bytes_identity(client):
    r = post(client, data=b"plain-bytes")
    assert r.status_code == 200, r.text
    assert len(lookup(client, sha256=hashlib.sha256(b"plain-bytes").hexdigest())) == 1



# ======================= TikTok error response is kept =======================

def _fail_json(exc):
    from api.services.tiktok_adapter import error_response_json
    return json.loads(error_response_json(exc))


def test_rejected_publish_keeps_sanitized_response_with_step_and_http_status():
    from autotok.errors import PublishError
    body = {"status_code": 5, "status_msg": "Invalid parameters", "log_id": "2026LOG1",
            "extra": {"description": "caption bad", "now": 1}, "message": "m",
            "sessionid": "SECRET1", "msToken": "SECRET2", "data": {"cookie_jar": "SECRET3"},
            "detail": "sessionid=SECRET4; Path=/"}
    with pytest.raises(PublishError) as exc:
        _publish(_Resp(200, body))
    stored = _fail_json(exc.value)
    assert stored["step"] == "publish" and stored["http_status"] == 200
    resp = stored["response"]
    assert (resp["status_code"], resp["status_msg"], resp["log_id"]) == (5, "Invalid parameters", "2026LOG1")
    assert resp["extra"] == {"description": "caption bad", "now": 1} and resp["message"] == "m"
    assert resp["detail"] == "[removed]"
    assert "SECRET" not in json.dumps(stored)


def test_publish_http_4xx_keeps_body_text_when_not_json():
    from autotok.errors import PublishError
    with pytest.raises(PublishError) as exc:
        _publish(_Resp(403, "<html>forbidden</html>"))
    stored = _fail_json(exc.value)
    assert stored == {"step": "publish", "http_status": 403, "response": {"body": "<html>forbidden</html>"}}


def test_uncertain_publish_responses_are_kept():
    from autotok.errors import PublishUncertainError
    with pytest.raises(PublishUncertainError) as exc:
        _publish(_Resp(502, {"status_msg": "bad gateway"}))
    assert _fail_json(exc.value) == {"step": "publish", "http_status": 502,
                                     "response": {"status_msg": "bad gateway"}}
    with pytest.raises(PublishUncertainError) as exc:
        _publish(_Resp(200, {"data": {}, "log_id": "L9"}))  # 200 without status_code
    assert _fail_json(exc.value)["response"] == {"data": {}, "log_id": "L9"}
    with pytest.raises(PublishUncertainError) as exc:
        _publish(_Resp(200, "<html>"))
    assert _fail_json(exc.value) == {"step": "publish", "http_status": 200, "body": "<html>"}


class _ReqSess:
    def __init__(self, resp):
        self.resp = resp

    def request(self, *a, **kw):
        return self.resp


def _client_for_requests():
    from autotok.uploader import Client
    c = Client.__new__(Client)
    c.timeout = 1
    return c


def test_upload_error_with_non_json_body_keeps_first_2kb():
    from autotok.errors import UploadError
    text = "x" * 5000
    with pytest.raises(UploadError) as exc:
        _client_for_requests()._request(_ReqSess(_Resp(500, text)), "POST", "http://t", "create project")
    stored = _fail_json(exc.value)
    assert stored["step"] == "create project" and stored["http_status"] == 500
    assert stored["body"] == "x" * 2048 and "response" not in stored


def test_upload_error_with_json_body_keeps_parsed_response_and_transfer_step():
    from autotok.errors import UploadError
    with pytest.raises(UploadError) as exc:
        _client_for_requests()._request(_ReqSess(_Resp(403, {"status_msg": "denied", "token": "T"})),
                                        "GET", "http://t", "upload auth")
    stored = _fail_json(exc.value)
    assert stored["step"] == "transfer" and stored["http_status"] == 403
    assert stored["response"] == {"status_msg": "denied"}


def test_error_without_tiktok_answer_stores_nothing():
    from api.services.tiktok_adapter import error_response_json
    from autotok.errors import NotLoggedInError
    assert error_response_json(NotLoggedInError("x")) == ""


@pytest.mark.parametrize("uncertain", [False, True])
def test_failed_attempt_response_reaches_history_and_api(client, monkeypatch, uncertain):
    stored = json.dumps({"step": "publish", "http_status": 200,
                         "response": {"status_code": 5, "status_msg": "Invalid parameters", "log_id": "L1"}})
    monkeypatch.setattr("api.services.tiktok_adapter.upload_from_options",
                        lambda *a: UploadOutcome(ok=False, message="TikTok rejected the post: Invalid parameters (status_code=5)",
                                                 uncertain=uncertain, response_json=stored))
    sid, _ = _due_desktop_job(client)
    assert worker.tick()
    with Session(db.engine) as s:
        key = history.schedule_key(s.get(ScheduledUpload, sid))
        assert s.get(UploadHistory, key).publish_response_json == stored
    entry = client.get(f"/api/history/entry/{key}").json()
    assert json.loads(entry["publish_response_json"])["response"]["status_msg"] == "Invalid parameters"
    row = next(r for r in client.get("/api/schedules").json() if r["id"] == sid)
    assert row["tiktok_response"]["step"] == "publish" and row["tiktok_response"]["http_status"] == 200
    assert client.get(f"/api/schedules/{sid}").json()["tiktok_response"]["response"]["log_id"] == "L1"


def test_schedules_do_not_expose_response_for_non_failed_rows(client, monkeypatch):
    monkeypatch.setattr("api.services.tiktok_adapter.upload_from_options",
                        lambda *a: UploadOutcome(ok=True, message="published", video_id="v",
                                                 response_json='{"status_code": 0}'))
    sid, _ = _due_desktop_job(client)
    assert worker.tick()
    row = next(r for r in client.get("/api/schedules").json() if r["id"] == sid)
    assert row["status"] == "succeeded" and row["tiktok_response"] is None
