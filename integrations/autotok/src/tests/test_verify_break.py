"""Independent verifier: breaking tests written from the resolved contracts (R1, R3, R4, R8, B2, B8).

No network, no real data: temp DB + temp library per test (conftest isolates AUTOTOK_HOME/videos).
"""
import json
import os
import random
import sqlite3
import subprocess
import sys
import threading
import time
import types
import shutil as real_shutil
from datetime import timedelta
from pathlib import Path
from urllib.parse import quote
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
# Pre-fix code copy used by the migration test: set VERIFY_PREFIX_REPO to enable; skipped when unset.
PREFIX_REPO = os.environ.get("VERIFY_PREFIX_REPO") or ""


@pytest.fixture
def db_path(tmp_path):
    return tmp_path / "verify.db"


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


def post(client, key=None, data=b"fixture-video-bytes" * 4, **fields):
    return client.post("/api/desktop/jobs", data={
        "request_id": key or uuid4().hex, "username": "demo", "title": "Mô tả 🌸", **fields,
    }, files={"video": ("video.mp4", data, "video/mp4")})


def names():
    return sorted(p.name for p in settings.videos_dir().iterdir())


def visible_kid_files():
    return [n for n in names() if n.startswith("kid-")]


class Gate:
    """Replaces desktop.shutil: writes the first chunk, then blocks until released."""

    def __init__(self):
        self.started = threading.Event()
        self.release = threading.Event()
        self.copyfileobj = self._copy

    def _copy(self, src, dst, length=1024 * 1024):
        first = src.read(4)
        dst.write(first)
        self.started.set()
        assert self.release.wait(30), "test gate never released"
        real_shutil.copyfileobj(src, dst, length)


# ---------------------------------------------------------------- R1 replay / recovery

def test_replay_while_first_attempt_is_copying_reports_preparing_and_never_copies_twice(client, monkeypatch):
    gate = Gate()
    monkeypatch.setattr(desktop, "shutil", gate)
    key = uuid4().hex
    first = {}
    t = threading.Thread(target=lambda: first.setdefault("r", post(client, key)))
    t.start()
    try:
        assert gate.started.wait(10)
        replay = post(client, key)
        assert replay.status_code == 200, replay.text
        body = replay.json()
        assert body["status"] == "preparing" and body["schedule_id"] is None
        got = client.get(f"/api/desktop/jobs/{key}").json()
        assert got["status"] == "preparing"
        # only the first attempt's .part exists; the replay created nothing
        assert len([n for n in names() if key in n]) == 1, names()
    finally:
        gate.release.set()
        t.join(30)
    r = first["r"]
    assert r.status_code == 200, r.text
    assert r.json()["status"] == "pending"
    with Session(db.engine) as s:
        assert len(s.exec(select(ScheduledUpload)).all()) == 1
    assert len(visible_kid_files()) == 1 and not [n for n in names() if n.endswith(".part")]


def test_startup_recovery_during_a_live_copy_keeps_the_copy(client, monkeypatch):
    gate = Gate()
    monkeypatch.setattr(desktop, "shutil", gate)
    key = uuid4().hex
    first = {}
    t = threading.Thread(target=lambda: first.setdefault("r", post(client, key)))
    t.start()
    try:
        assert gate.started.wait(10)
        before = names()
        with Session(db.engine) as s:
            desktop.recover_on_startup(s)
        assert names() == before  # the live attempt's .part survives
    finally:
        gate.release.set()
        t.join(30)
    assert first["r"].json()["status"] == "pending"
    assert len(visible_kid_files()) == 1


def test_expiry_racing_enqueue_always_ends_in_one_consistent_state(client, monkeypatch):
    """Copy runs right at the stale threshold while another thread keeps expiring stale
    preparations. Whatever wins, the end state must be coherent: never a job whose receipt
    says failed, never a failed receipt that left a file, never a queued receipt without job."""
    monkeypatch.setattr(desktop, "STALE_PREPARING_AFTER", timedelta(milliseconds=60))
    monkeypatch.setattr(desktop, "HEARTBEAT_EVERY", 0.0)

    class Slow:
        def __init__(self, delay):
            self.delay = delay

        def copyfileobj(self, src, dst, length=1024 * 1024):
            for _ in range(3):
                block = src.read(8)
                if not block:
                    break
                time.sleep(self.delay)
                dst.write(block)
            real_shutil.copyfileobj(src, dst, length)
            time.sleep(self.delay)  # quiet gap after the last heartbeat, before the enqueue

    stop = threading.Event()
    declared_failed = set()

    def hammer():
        while not stop.is_set():
            try:
                with Session(db.engine) as s:
                    desktop.expire_stale(s)
                    declared_failed.update(s.exec(select(DesktopReceipt.request_id).where(
                        DesktopReceipt.state == "preparation_failed")).all())
            except Exception:  # database busy: keep hammering
                pass

    h = threading.Thread(target=hammer)
    h.start()
    outcomes = []
    rng = random.Random(7)
    try:
        for _ in range(25):
            monkeypatch.setattr(desktop, "shutil", Slow(rng.choice([0.0, 0.03, 0.055, 0.06, 0.065, 0.09])))
            key = uuid4().hex
            r = post(client, key)
            outcomes.append((key, r.status_code, r.json().get("status")))
    finally:
        stop.set()
        h.join(10)
    with Session(db.engine) as s:
        for key, code, status in outcomes:
            receipt = s.get(DesktopReceipt, key)
            files = [n for n in names() if key in n]
            if receipt.state == "queued":
                job = s.get(ScheduledUpload, receipt.schedule_id)
                assert job is not None and job.source_ref.startswith(f"kid-{key}"), key
                assert files == [job.source_ref], (key, files)
                assert code == 200 and status == "pending"
            else:
                assert receipt.state == "preparation_failed", (key, receipt.state)
                assert receipt.schedule_id is None
                assert files == [], (key, files)
                assert code == 500 and status == "preparation_failed", (code, status)
                entry = history.entries_by_request(s, [key]).get(key)
                assert entry is not None and entry.status == "preparation_failed"
        jobs = s.exec(select(ScheduledUpload)).all()
        assert len(jobs) == sum(1 for o in outcomes if o[2] == "pending")
        # preparation_failed is terminal: once anyone saw it, it never turns into a job
        for key in declared_failed:
            assert s.get(DesktopReceipt, key).state == "preparation_failed", key
    statuses = [o[2] for o in outcomes]
    assert "pending" in statuses and "preparation_failed" in statuses, statuses  # both sides exercised


@pytest.mark.parametrize("status", ["cancelled", "failed", "succeeded", "pending"])
def test_startup_recovery_never_deletes_a_file_any_job_references(client, status):
    """Even when the receipt is gone, a file referenced by a job (which the user may retry) stays."""
    body = post(client).json()
    key, sid = body["request_id"], body["schedule_id"]
    with Session(db.engine) as s:
        job = s.get(ScheduledUpload, sid)
        job.status = status
        s.add(job)
        s.delete(s.get(DesktopReceipt, key))
        s.commit()
        ref = job.source_ref
    with TestClient(create_app(), base_url="http://localhost", headers=HEADERS):
        pass
    assert ref in names()


def test_startup_recovery_keeps_file_of_queued_receipt_whose_job_was_deleted(client):
    body = post(client).json()
    assert client.delete(f"/api/schedules/{body['schedule_id']}").status_code == 204
    before = visible_kid_files()
    assert len(before) == 1
    with TestClient(create_app(), base_url="http://localhost", headers=HEADERS):
        pass
    assert visible_kid_files() == before


# ---------------------------------------------------------------- R3 fencing interleavings

def _due_job(client):
    body = post(client).json()
    sid = body["schedule_id"]
    with Session(db.engine) as s:
        row = s.get(ScheduledUpload, sid)
        row.scheduled_for = db.now_utc() - timedelta(seconds=1)
        s.add(row)
        s.commit()
    return sid, body["request_id"]


def _claim_and_reclaim(sid):
    with Session(db.engine) as s:
        claimed = worker.claim_next_due(s)
    assert claimed.id == sid
    with Session(db.engine) as s:
        row = s.get(ScheduledUpload, sid)
        row.heartbeat_at = db.now_utc() - timedelta(minutes=10)
        s.add(row)
        s.commit()
    with Session(db.engine) as s:
        assert worker.reclaim_stale(s) == 1
    return claimed


def test_late_success_after_user_confirmed_retry_is_never_posted_again(client, monkeypatch):
    sid, key = _due_job(client)
    w1 = _claim_and_reclaim(sid)
    r = client.patch(f"/api/schedules/{sid}", json={"status": "pending", "confirm_uncertain": True})
    assert r.status_code == 200
    # the stalled first attempt wakes up: TikTok did accept it
    worker.finalize(w1.id, UploadOutcome(ok=True, message="published", video_id="v1"),
                    attempts=w1.attempts, key=history.schedule_key(w1))
    calls = []
    monkeypatch.setattr("api.services.tiktok_adapter.upload_from_options",
                        lambda *a: calls.append(a) or UploadOutcome(ok=True, message="published"))
    with Session(db.engine) as s:
        row = s.get(ScheduledUpload, sid)
        row.scheduled_for = db.now_utc() - timedelta(seconds=1)
        s.add(row)
        s.commit()
    worker.tick()
    assert calls == [], "the video was published a second time"
    got = client.get(f"/api/desktop/jobs/{key}").json()
    assert got["status"] == "succeeded" and got["prior_uncertain"] is True


def test_late_success_after_user_deleted_the_reclaimed_job_is_recorded(client):
    sid, key = _due_job(client)
    w1 = _claim_and_reclaim(sid)
    assert client.delete(f"/api/schedules/{sid}").status_code == 204
    worker.finalize(w1.id, UploadOutcome(ok=True, message="published", video_id="v9"),
                    attempts=w1.attempts, key=history.schedule_key(w1))
    got = client.get(f"/api/desktop/jobs/{key}").json()
    assert got["prior_uncertain"] is True
    entries = client.post("/api/history/lookup", json={"videos": [{"request_ids": [key]}]}).json()[0]["entries"]
    assert len(entries) == 1 and entries[0]["prior_uncertain"] is True
    assert "late success" in (entries[0]["result_text"] or "")


def test_heartbeat_of_reclaimed_attempt_cannot_revive_it(client):
    sid, _ = _due_job(client)
    w1 = _claim_and_reclaim(sid)
    hb = worker.Heartbeat(w1.id, w1.attempts)
    assert hb.beat() is False
    with Session(db.engine) as s:
        row = s.get(ScheduledUpload, sid)
        assert row.status == "failed" and row.publish_uncertain is True


# ---------------------------------------------------------------- R4 prior_uncertain monotonic

def test_prior_uncertain_is_monotonic_through_retry_success_delete_and_restart(client, monkeypatch):
    sid, key = _due_job(client)
    outcomes = iter([UploadOutcome(ok=False, message="publish cut off; may or may not", uncertain=True),
                     UploadOutcome(ok=True, message="published", video_id="v2")])
    monkeypatch.setattr("api.services.tiktok_adapter.upload_from_options", lambda *a: next(outcomes))
    assert worker.tick()
    assert client.get(f"/api/desktop/jobs/{key}").json()["prior_uncertain"] is True
    assert client.patch(f"/api/schedules/{sid}", json={"status": "pending", "confirm_uncertain": True}).status_code == 200
    assert client.get(f"/api/desktop/jobs/{key}").json()["prior_uncertain"] is True
    with Session(db.engine) as s:
        row = s.get(ScheduledUpload, sid)
        row.scheduled_for = db.now_utc() - timedelta(seconds=1)
        s.add(row)
        s.commit()
    assert worker.tick()
    got = client.get(f"/api/desktop/jobs/{key}").json()
    assert got["status"] == "succeeded" and got["publish_uncertain"] is False and got["prior_uncertain"] is True
    assert client.delete(f"/api/schedules/{sid}").status_code == 204
    with TestClient(create_app(), base_url="http://localhost", headers=HEADERS) as c2:
        e = c2.post("/api/history/lookup", json={"videos": [{"request_ids": [key]}]}).json()[0]["entries"]
    assert len(e) == 1 and e[0]["prior_uncertain"] is True and e[0]["status"] == "succeeded"


# ---------------------------------------------------------------- R8 lookup chunking

@pytest.mark.parametrize("n", [500, 501, 2000])
def test_lookup_chunk_boundaries_find_every_video_and_bind_at_most_500(client, n):
    with Session(db.engine) as s:
        for i in range(n):
            s.add(UploadHistory(key=f"k{i}", username="demo", sha256=f"{i:064x}", reel_id=f"r{i}",
                                request_id=f"{i:032x}", status="succeeded"))
        s.commit()
    biggest = []

    def spy(conn, cursor, statement, parameters, context, executemany):
        if not executemany and parameters:
            biggest.append(len(parameters))

    event.listen(db.engine, "before_cursor_execute", spy)
    try:
        videos = [{"sha256": f"{i:064x}", "reel_id": f"r{i}", "request_ids": [f"{i:032x}"]} for i in range(n)]
        r = client.post("/api/history/lookup", json={"videos": videos})
    finally:
        event.remove(db.engine, "before_cursor_execute", spy)
    assert r.status_code == 200, r.text[:300]
    rows = r.json()
    assert len(rows) == n
    for i, row in enumerate(rows):
        assert [e["key"] for e in row["entries"]] == [f"k{i}"], (i, row)
    assert max(biggest) <= 501, max(biggest)  # 500 ids (+ at most one extra bound value)


def test_lookup_over_2000_videos_is_rejected_not_500(client):
    r = client.post("/api/history/lookup", json={"videos": [{"sha256": "a"}] * 2001})
    assert r.status_code == 422


# ---------------------------------------------------------------- B2 legitimate names

LEGIT = ["my clip [1080p] (final).mp4", "Video tiếng Việt 🌸.mp4", "100% #1 & more+.mp4",
         "a;b,c=d@e~f!g$h'i.mp4", "-leading dash.mp4", "kid-notabridgefile.mov", "  spaced  name.webm",
         "[2024] {x}.mp4"]


@pytest.mark.parametrize("name", LEGIT)
def test_legitimate_library_names_still_stream_schedule_and_upload(client, name):
    path = settings.videos_dir() / name
    path.write_bytes(b"\x00\x00\x00\x18ftypmp42" + b"z" * 64)
    r = client.get(f"/api/videos/{quote(name, safe='')}/stream")
    assert r.status_code == 200, (name, r.status_code, r.text[:200])
    assert r.content.endswith(b"z" * 64)
    when = (db.now_utc() + timedelta(hours=1)).isoformat()
    r = client.post("/api/schedules", json={"username": "demo", "source_type": "local", "source_ref": name,
                                           "title": "t", "scheduled_for": when})
    assert r.status_code in (200, 201), (name, r.text)
    assert r.json()["source_ref"] == name
    assert library.resolve(name) == path.resolve()
    # absolute form of the same library file (older schedules), with forward slashes and other case
    absolute = str(settings.videos_dir().resolve() / name)
    assert library.resolve(absolute).name == name
    assert library.resolve(absolute.replace("\\", "/").upper() if os.name == "nt" else absolute).name.lower() == name.lower()


def test_library_names_with_wildcards_or_reserved_chars_never_500(client):
    for name in ["a?b.mp4", "a*b.mp4", "a<b>.mp4", 'a"b.mp4', "a|b.mp4", "CON.mp4", "NUL", "COM1.mp4"]:
        r = client.get(f"/api/videos/{quote(name, safe='')}/stream")
        assert r.status_code in (400, 404), (name, r.status_code)


# ---------------------------------------------------------------- B8 genuine success

@pytest.mark.parametrize("body", [
    {"status_code": 0},
    {"status_code": 0, "status_msg": ""},
    {"status_code": 0, "status_msg": "success", "data": {"post_id": "1"}, "extra": {"now": 1}},
    {"status_code": -0, "data": None},
])
def test_genuine_success_is_not_misclassified(body):
    from autotok.uploader import Client

    class Resp:
        status_code = 200
        text = json.dumps(body)

        def json(self):
            return json.loads(self.text)

    class Sess:
        cookies = {}

        def post(self, *a, **kw):
            return Resp()

    class Sig:
        x_bogus, signature = "x", "s"

    class Signer:
        def sign(self, url):
            return Sig()

    c = Client.__new__(Client)
    c._signer, c.user_agent, c.timeout, c.proxy = Signer(), "UA", 1, None
    assert c._publish(Sess(), {}) == body


# ---------------------------------------------------------------- R4 migration from the pre-fix code

PREFIX_SCRIPT = r"""
import os, sys, json
repo = sys.argv[1]
sys.path[:0] = [repo, os.path.join(repo, "web")]
os.environ["TIKTOK_API_DB_PATH"] = sys.argv[2]
os.environ["AUTOTOK_VIDEOS_DIR"] = sys.argv[3]
os.environ["AUTOTOK_HOME"] = sys.argv[4]
import api.db as db
assert db.__file__.startswith(repo), db.__file__
from sqlmodel import Session, select
from api.models import Account, DesktopReceipt, ScheduledUpload, UploadHistory
mode = sys.argv[5]
db.init_db()
with Session(db.engine) as s:
    if mode == "create":
        a = Account(username="demo", cookie_path="x"); s.add(a); s.commit(); s.refresh(a)
        s.add(UploadHistory(key="old-uncertain", username="demo", status="failed", publish_uncertain=True, sha256="a"*64))
        s.add(UploadHistory(key="old-ok", username="demo", status="succeeded", sha256="b"*64))
        s.add(DesktopReceipt(request_id="c"*32, state="preparing"))
        s.commit()
        print("OK")
    else:
        rows = s.exec(select(UploadHistory)).all()
        recs = s.exec(select(DesktopReceipt)).all()
        s.add(UploadHistory(key="written-by-old", username="demo", status="pending"))
        s.add(DesktopReceipt(request_id="d"*32, state="preparing"))
        s.commit()
        print(json.dumps({"history": sorted(r.key for r in rows), "receipts": sorted(r.request_id for r in recs)}))
"""


def _run_prefix(tmp_path, dbfile, mode):
    if not PREFIX_REPO or not Path(PREFIX_REPO).is_dir():
        pytest.skip("pre-fix code copy not found (set VERIFY_PREFIX_REPO)")
    script = tmp_path / "prefix_script.py"
    script.write_text(PREFIX_SCRIPT, encoding="utf-8")
    vids, home = tmp_path / "pv", tmp_path / "ph"
    vids.mkdir(exist_ok=True)
    home.mkdir(exist_ok=True)
    env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")
    out = subprocess.run([sys.executable, "-B", str(script), PREFIX_REPO, str(dbfile), str(vids), str(home), mode],
                         capture_output=True, text=True, env=env, cwd=str(tmp_path), timeout=120)
    assert out.returncode == 0, out.stderr[-2000:]
    return out.stdout.strip().splitlines()[-1]


def test_database_created_by_prefix_code_migrates_and_stays_readable_by_it(tmp_path):
    dbfile = tmp_path / "old.db"
    assert _run_prefix(tmp_path, dbfile, "create") == "OK"
    con = sqlite3.connect(dbfile)
    assert con.execute("PRAGMA user_version").fetchone()[0] == 1
    con.close()
    old = db.engine
    engine = db.make_engine(f"sqlite:///{dbfile}")
    db.override_engine(engine)
    try:
        db.init_db()
        db.init_db()  # already at version 2: no-op, no error
        with Session(engine) as s:
            assert s.get(UploadHistory, "old-uncertain").prior_uncertain is True
            assert s.get(UploadHistory, "old-ok").prior_uncertain is False
            rec = s.get(DesktopReceipt, "c" * 32)
            assert rec.attempt_token == "" and rec.heartbeat_at is None
        # an old preparing receipt (no heartbeat column value) is judged by created_at, not crashed on
        with Session(engine) as s:
            assert desktop.expire_stale(s) == 0
        con = sqlite3.connect(dbfile)
        assert con.execute("PRAGMA user_version").fetchone()[0] == 2
        con.close()
    finally:
        db.override_engine(old)
        engine.dispose()
    seen = json.loads(_run_prefix(tmp_path, dbfile, "read"))
    assert seen["history"] == ["old-ok", "old-uncertain"]
    assert seen["receipts"] == ["c" * 32]
    con = sqlite3.connect(dbfile)
    assert con.execute("SELECT prior_uncertain FROM upload_history WHERE key='written-by-old'").fetchone() == (0,)
    assert con.execute("SELECT attempt_token FROM desktop_receipts WHERE request_id=?", ("d" * 32,)).fetchone() == ("",)
    con.close()


# ---------------------------------------------------------------- B3 / B10 mixed load, old-build files

def test_concurrent_creates_lookups_and_gets_never_500(client):
    keys = [uuid4().hex for _ in range(12)]

    def create(k):
        return post(client, k).status_code

    def look(_):
        return client.post("/api/history/lookup", json={"videos": [{"request_ids": keys}]}).status_code

    def get(k):
        return client.get(f"/api/desktop/jobs/{k}").status_code

    from concurrent.futures import ThreadPoolExecutor
    with ThreadPoolExecutor(max_workers=12) as pool:
        futures = [pool.submit(create, k) for k in keys] + [pool.submit(look, i) for i in range(24)] \
            + [pool.submit(get, k) for k in keys]
        codes = [f.result() for f in futures]
    assert all(c in (200, 404) for c in codes), codes
    assert all(post(client, k).json()["status"] == "pending" for k in keys)
    assert len(visible_kid_files()) == 12


def test_startup_cleans_old_build_crash_leftovers_but_keeps_old_build_queued_files(client):
    lib = settings.videos_dir()
    crashed, queued = "a" * 32, "b" * 32
    old = db.now_utc() - timedelta(hours=3)
    (lib / f".kid-{crashed}.mp4.part").write_bytes(b"x")
    (lib / f"kid-{crashed}.mp4").write_bytes(b"x")
    (lib / f"kid-{queued}.mp4").write_bytes(b"y")
    with Session(db.engine) as s:
        acct = s.exec(select(Account)).first()
        job = ScheduledUpload(account_id=acct.id, source_type="local", source_ref=f"kid-{queued}.mp4", title="t",
                              scheduled_for=db.now_utc() + timedelta(days=1), status="failed")
        s.add(job)
        s.flush()
        s.add(DesktopReceipt(request_id=crashed, state="preparing", created_at=old))  # old build: no token/heartbeat
        s.add(DesktopReceipt(request_id=queued, state="queued", schedule_id=job.id, created_at=old))
        s.commit()
    with TestClient(create_app(), base_url="http://localhost", headers=HEADERS):
        pass
    assert names() == [f"kid-{queued}.mp4"]
    with Session(db.engine) as s:
        assert s.get(DesktopReceipt, crashed).state == "preparation_failed"
