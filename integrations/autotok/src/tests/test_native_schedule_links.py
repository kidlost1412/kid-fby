"""TikTok-side scheduling ("Hẹn giờ trên TikTok") and public post links (schema v3).

Owner decisions under test: a scheduled post is handed to TikTok right away with schedule_time
(the PC may be off later); legacy PC-side jobs more than 2 h late are failed, never posted; the
late link lookup only reads and never publishes.
"""
import json
import sqlite3
from datetime import datetime, timedelta, timezone
from uuid import uuid4

import pytest
import responses
from fastapi.testclient import TestClient
from sqlmodel import Session, select

import api.db as db
from api.main import create_app
from api.models import Account, ScheduledUpload, UploadHistory
from api.services import history, links
from api.services import tiktok_adapter
from api.services.tiktok_adapter import UploadOutcome
from autotok import Client
from autotok.errors import PublishError, PublishUncertainError
from autotok.posts import match_post
from autotok.uploader import _extract_post_id, sanitize_response
from scheduler import worker
from tests.test_uploader import FakeSigner, mock_tiktok, publish_call

HEADERS = {"X-Requested-With": "autotok"}
POST_ID = "7429183650274961408"  # 19 digits, the shape of a real TikTok video id


# ---------- uploader: post id extraction + sanitizing -------------------------

@pytest.mark.parametrize("response", [
    {"status_code": 0, "item_id": POST_ID},
    {"status_code": 0, "aweme_id": int(POST_ID)},
    {"status_code": 0, "itemId": POST_ID},
    {"status_code": 0, "ItemID": POST_ID},
    {"status_code": 0, "data": {"item_id": POST_ID}},
    {"status_code": 0, "data": {"aweme_id": POST_ID}},
    {"status_code": 0, "single_post_resp_list": [{"batch_index": 0}, {"item_id": POST_ID}]},
    {"status_code": 0, "item_id": "12345678901234567"},  # 17 digits: lower bound
])
def test_post_id_found_on_explicit_paths(response):
    expected = str(response.get("item_id") or POST_ID)
    assert _extract_post_id(response) == expected


@pytest.mark.parametrize("response", [
    {"status_code": 0},
    {"status_code": 0, "item_id": "1234567890123456"},        # 16 digits
    {"status_code": 0, "item_id": "123456789012345678901"},   # 21 digits
    {"status_code": 0, "item_id": "74291836502749614O8"},     # letter O
    {"status_code": 0, "item_id": True},
    {"status_code": 0, "item_id": ""},
    {"status_code": 0, "video_id": POST_ID},                  # not an explicit post-id key
    {"status_code": 0, "data": {"inner": {"item_id": POST_ID}}},  # deeper than the known paths
    {"status_code": 0, "extra": {"logid": POST_ID}},
    {"status_code": 0, "single_post_resp_list": "nope"},
    ["not", "a", "dict"],
    None,
])
def test_post_id_never_guessed(response):
    assert _extract_post_id(response) is None


def test_sanitize_drops_secret_keys_everywhere_and_truncates():
    data = {"status_code": 0, "msToken": "a", "data": {"session_key": "b", "item_id": POST_ID,
            "list": [{"x_sign": "c", "ok": 1}], "Cookie": "d", "ticket_id": "e", "ApiToken": "f"}}
    text = sanitize_response(data)
    parsed = json.loads(text)
    assert parsed == {"status_code": 0, "data": {"item_id": POST_ID, "list": [{"ok": 1}]}}
    for secret in ('"a"', '"b"', '"c"', '"d"', '"e"', '"f"'):
        assert secret not in text
    long = sanitize_response({"blob": "é" * 20000})
    assert len(long) <= 8192 and long.endswith("...(truncated)")


# ---------- adapter -> real uploader (HTTP mocked) ------------------------------

@responses.activate
def test_adapter_schedules_on_tiktok_and_returns_post_id(saved_account, video_file, monkeypatch):
    real = Client.from_account
    monkeypatch.setattr(tiktok_adapter.Client, "from_account",
                        classmethod(lambda cls, name, **kw: real(name, signer=FakeSigner(), **kw)))
    mock_tiktok(responses, publish={"json": {"status_code": 0, "single_post_resp_list": [{"item_id": POST_ID}],
                                             "extra": {"now": 1}, "sec_token": "SECRET"}})
    when = (datetime.now(timezone.utc) + timedelta(hours=2)).replace(microsecond=0)
    outcome = tiktok_adapter.upload_from_options("alice", str(video_file), "caption", {
        "schedule_mode": "native", "tiktok_schedule_time": when.isoformat()})
    assert outcome.ok and outcome.post_id == POST_ID and outcome.creation_id
    assert outcome.tiktok_schedule_time == when
    feature = json.loads(publish_call(responses).request.body)["feature_common_info_list"][0]
    assert feature["schedule_time"] == int(when.timestamp())
    assert "SECRET" not in outcome.response_json and POST_ID in outcome.response_json


@responses.activate
def test_adapter_without_schedule_publishes_now(saved_account, video_file, monkeypatch):
    real = Client.from_account
    monkeypatch.setattr(tiktok_adapter.Client, "from_account",
                        classmethod(lambda cls, name, **kw: real(name, signer=FakeSigner(), **kw)))
    mock_tiktok(responses)
    outcome = tiktok_adapter.upload_from_options("alice", str(video_file), "caption", {"schedule_mode": "now"})
    assert outcome.ok and outcome.post_id is None and outcome.tiktok_schedule_time is None
    feature = json.loads(publish_call(responses).request.body)["feature_common_info_list"][0]
    assert "schedule_time" not in feature


def test_adapter_bad_schedule_option_is_definite_failure():
    outcome = tiktok_adapter.upload_from_options("alice", "x.mp4", "c", {"tiktok_schedule_time": "garbage"})
    assert not outcome.ok and not outcome.uncertain and not outcome.retryable


# ---------- API + worker -------------------------------------------------------

@pytest.fixture
def client(tmp_path):
    old = db.engine
    engine = db.make_engine(f"sqlite:///{tmp_path / 'v3.db'}")
    db.override_engine(engine)
    db.init_db()
    with Session(engine) as s:
        s.add(Account(username="demo", cookie_path=str(tmp_path / "absent.cookie"), has_valid_session=True))
        s.commit()
    with TestClient(create_app(), base_url="http://localhost", headers=HEADERS) as c:
        yield c
    db.override_engine(old)
    engine.dispose()


def post(client, **fields):
    return client.post("/api/desktop/jobs", data={"request_id": uuid4().hex, "username": "demo",
                                                  "title": "Mô tả  tiếng Việt 🌸", **fields},
                       files={"video": ("123-3-hoan-chinh.mp4", b"fixture-video", "video/mp4")})


class FakeClient:
    """Stands in for autotok.Client at the adapter boundary; records what the uploader was asked."""
    calls: list = []
    result = None
    error = None
    push = None

    @classmethod
    def from_account(cls, name, **kw):
        return cls()

    def upload(self, video, caption, **kw):
        FakeClient.calls.append(kw)
        if FakeClient.error:
            raise FakeClient.error
        from autotok.uploader import UploadResult
        when = kw.get("schedule")
        if when is not None and FakeClient.push:
            when = when + FakeClient.push  # the uploader moved it (slow upload, < 15 min left)
        return UploadResult(video_id="v1", creation_id="cid1", scheduled_for=when,
                            response={"status_code": 0, **(FakeClient.result or {})},
                            post_id=(FakeClient.result or {}).get("item_id"))


@pytest.fixture
def fake_client(monkeypatch):
    FakeClient.calls, FakeClient.result, FakeClient.error, FakeClient.push = [], None, None, None
    monkeypatch.setattr(tiktok_adapter, "Client", FakeClient)
    return FakeClient


def iso(delta):
    return (datetime.now(timezone.utc) + delta).isoformat()


@pytest.mark.parametrize("delta,ok", [
    (timedelta(minutes=19), False),
    (timedelta(minutes=20), True),
    (timedelta(days=10), True),
    (timedelta(days=10, minutes=1), False),
])
def test_desktop_schedule_window(client, delta, ok):
    r = post(client, scheduled_for=iso(delta))
    assert (r.status_code == 200) is ok, r.text
    if not ok:
        assert "20 phút đến 10 ngày" in r.json()["detail"]
        with Session(db.engine) as s:
            assert not s.exec(select(ScheduledUpload)).all()


@pytest.mark.parametrize("delta,ok", [(timedelta(minutes=19), False), (timedelta(minutes=20), True),
                                      (timedelta(days=10), True), (timedelta(days=10, minutes=1), False)])
def test_web_schedule_window(client, delta, ok):
    from autotok import settings
    (settings.videos_dir() / "w.mp4").write_bytes(b"w" * 10)
    r = client.post("/api/schedules", json={"username": "demo", "title": "t", "source_type": "local",
                                            "source_ref": "w.mp4", "scheduled_for": iso(delta)})
    assert r.status_code == (201 if ok else 422), r.text
    if not ok:
        assert "20 phút đến 10 ngày" in json.dumps(r.json(), ensure_ascii=False)


def test_private_plus_schedule_rejected(client):
    r = post(client, scheduled_for=iso(timedelta(hours=1)), options_json='{"visibility_type":1}')
    assert r.status_code == 422 and "riêng tư" in r.json()["detail"]
    # private without a schedule is still fine
    assert post(client, options_json='{"visibility_type":1}').status_code == 200


def test_native_job_is_claimed_now_and_uploader_gets_schedule(client, fake_client):
    when = (datetime.now(timezone.utc) + timedelta(hours=5)).replace(microsecond=0)
    body = post(client, scheduled_for=when.isoformat()).json()
    assert body["status"] == "pending"
    assert worker.tick() is True  # due immediately, not at the scheduled time
    assert len(fake_client.calls) == 1 and fake_client.calls[0]["schedule"] == when
    job = client.get(f"/api/desktop/jobs/{body['request_id']}").json()
    assert job["status"] == "succeeded" and job["link_state"] == "scheduled_on_tiktok"
    assert datetime.fromisoformat(job["tiktok_schedule_time"]) == when
    assert datetime.fromisoformat(job["planned_for"]) == when
    accepted = datetime.fromisoformat(job["accepted_at"])
    assert abs((accepted - datetime.now(timezone.utc)).total_seconds()) < 60  # when TikTok accepted
    with Session(db.engine) as s:
        entry = s.exec(select(UploadHistory).where(UploadHistory.request_id == body["request_id"])).one()
        assert entry.link_next_at.replace(tzinfo=timezone.utc) == when + timedelta(minutes=1)
        assert entry.caption == "Mô tả  tiếng Việt 🌸" and entry.creation_id == "cid1"
    assert worker.tick() is False  # posted once, nothing left


def test_time_tiktok_actually_got_is_recorded(client, fake_client):
    fake_client.push = timedelta(minutes=3)
    when = (datetime.now(timezone.utc) + timedelta(minutes=25)).replace(microsecond=0)
    body = post(client, scheduled_for=when.isoformat()).json()
    assert worker.tick() is True
    job = client.get(f"/api/desktop/jobs/{body['request_id']}").json()
    actual = when + timedelta(minutes=3)
    assert datetime.fromisoformat(job["tiktok_schedule_time"]) == actual
    # Owner decision (2026-10): planned_for keeps the requested time; the actual time is tiktok_schedule_time.
    assert datetime.fromisoformat(job["planned_for"]) == when


def test_immediate_job_with_post_id_gets_link(client, fake_client):
    fake_client.result = {"item_id": POST_ID}
    body = post(client).json()
    assert worker.tick() is True
    assert fake_client.calls[0]["schedule"] is None
    job = client.get(f"/api/desktop/jobs/{body['request_id']}").json()
    assert job["post_id"] == POST_ID and job["link_state"] == "found"
    assert job["post_url"] == f"https://www.tiktok.com/@demo/video/{POST_ID}"
    entry = client.post("/api/history/lookup", json={"videos": [{"reel_id": "123"}]}).json()[0]["entries"][0]
    assert entry["post_url"] == job["post_url"] and "publish_response_json" not in entry
    full = client.get(f"/api/history/entry/{entry['key']}").json()
    assert POST_ID in full["publish_response_json"]


def test_tiktok_rejecting_schedule_fails_definitely_without_retry(client, fake_client):
    fake_client.error = PublishError("TikTok rejected the post: schedule time invalid (status_code=1)")
    body = post(client, scheduled_for=iso(timedelta(hours=1))).json()
    assert worker.tick() is True and worker.tick() is False
    job = client.get(f"/api/desktop/jobs/{body['request_id']}").json()
    assert job["status"] == "failed" and not job["publish_uncertain"] and len(fake_client.calls) == 1


def test_uncertain_schedule_is_never_retried_or_reposted_now(client, fake_client):
    fake_client.error = PublishUncertainError("cut off")
    body = post(client, scheduled_for=iso(timedelta(hours=1))).json()
    assert worker.tick() is True and worker.tick() is False
    job = client.get(f"/api/desktop/jobs/{body['request_id']}").json()
    assert job["status"] == "failed" and job["publish_uncertain"] and len(fake_client.calls) == 1


def _legacy_job(late: timedelta, options="{}"):
    with Session(db.engine) as s:
        acct = s.exec(select(Account)).first()
        row = ScheduledUpload(account_id=acct.id, source_type="local", source_ref="legacy.mp4", title="t",
                              options_json=options, scheduled_for=db.now_utc() - late)
        s.add(row)
        s.commit()
        return row.id


def test_legacy_job_more_than_2h_late_fails_and_is_not_posted(client, fake_client):
    from autotok import settings
    (settings.videos_dir() / "legacy.mp4").write_bytes(b"l" * 10)
    job_id = _legacy_job(timedelta(hours=2, minutes=1))
    assert worker.tick() is False
    assert fake_client.calls == []
    with Session(db.engine) as s:
        row = s.get(ScheduledUpload, job_id)
        assert row.status == "failed" and not row.publish_uncertain
        assert row.result_text == "Lỡ giờ khi máy tắt — chưa đăng"
        entry = s.get(UploadHistory, history.schedule_key(row))
        assert entry.status == "failed" and not entry.publish_uncertain and entry.accepted_at is None


def test_legacy_job_less_than_2h_late_is_posted(client, fake_client):
    from autotok import settings
    (settings.videos_dir() / "legacy.mp4").write_bytes(b"l" * 10)
    job_id = _legacy_job(timedelta(hours=1, minutes=59))
    assert worker.tick() is True and len(fake_client.calls) == 1
    with Session(db.engine) as s:
        assert s.get(ScheduledUpload, job_id).status == "succeeded"


def test_new_immediate_job_is_not_treated_as_legacy(client, fake_client):
    from autotok import settings
    (settings.videos_dir() / "legacy.mp4").write_bytes(b"l" * 10)
    _legacy_job(timedelta(hours=3), options='{"schedule_mode": "now"}')
    assert worker.tick() is True and len(fake_client.calls) == 1


def test_patch_time_of_native_job_is_409_and_delete_keeps_history(client, fake_client):
    body = post(client, scheduled_for=iso(timedelta(hours=3))).json()
    sid = body["schedule_id"]
    r = client.patch(f"/api/schedules/{sid}", json={"scheduled_for": iso(timedelta(hours=4))})
    assert r.status_code == 409 and r.json()["detail"] == "Đã hẹn trên TikTok — sửa/hủy trong TikTok Studio"
    worker.tick()
    r = client.patch(f"/api/schedules/{sid}", json={"scheduled_for": iso(timedelta(hours=4))})
    assert r.status_code == 409 and "TikTok Studio" in r.json()["detail"]
    listed = client.get("/api/schedules").json()[0]
    assert listed["link_state"] == "scheduled_on_tiktok" and listed["tiktok_schedule_time"]
    assert client.delete(f"/api/schedules/{sid}").status_code == 204
    job = client.get(f"/api/desktop/jobs/{body['request_id']}").json()
    assert job["status"] == "succeeded" and job["link_state"] == "scheduled_on_tiktok"  # our record kept


# ---------- link state machine ------------------------------------------------

class Clock:
    def __init__(self):
        self.now = datetime.now(timezone.utc)

    def __call__(self):
        return self.now


@pytest.fixture
def clock(monkeypatch):
    c = Clock()
    monkeypatch.setattr(links, "now_utc", c)
    return c


def _entry(key="direct:x", **kw):
    values = dict(key=key, username="demo", status="succeeded", caption="cap", accepted_at=db.now_utc(),
                  link_state="pending", link_next_at=db.now_utc() - timedelta(seconds=1))
    values.update(kw)
    with Session(db.engine) as s:
        s.add(UploadHistory(**values))
        s.commit()
    return key


def _get(key):
    with Session(db.engine) as s:
        return s.get(UploadHistory, key)


@pytest.fixture
def no_publish(monkeypatch):
    def boom(*a, **k):
        raise AssertionError("the link lookup must never upload/publish")
    monkeypatch.setattr(tiktok_adapter, "upload_from_options", boom)
    monkeypatch.setattr(Client, "upload", boom)
    monkeypatch.setattr(Client, "_publish", boom)


def test_link_backoff_and_give_up(client, clock, no_publish, monkeypatch):
    seen = []
    monkeypatch.setattr(links, "_find_post", lambda u, c, n: seen.append((u, c)) or None)
    key = _entry()
    expected_waits = [2, 5, 10, 10, 10, 10, 10, 10, 10]
    for attempt in range(1, 11):
        assert links.tick() is True
        e = _get(key)
        assert e.link_attempts == attempt
        if attempt < 10:
            assert e.link_state == "pending"
            wait = (e.link_next_at.replace(tzinfo=timezone.utc) - clock.now)
            assert wait == timedelta(minutes=expected_waits[attempt - 1])
            assert links.tick() is False  # not due yet
            clock.now += wait
    e = _get(key)
    assert e.link_state == "gave_up" and e.link_next_at is None and len(seen) == 10
    clock.now += timedelta(days=1)
    assert links.tick() is False


def test_link_found_builds_url(client, clock, no_publish, monkeypatch):
    monkeypatch.setattr(links, "_find_post", lambda u, c, n: POST_ID)
    key = _entry()
    assert links.tick() is True
    e = _get(key)
    assert e.link_state == "found" and e.post_url == f"https://www.tiktok.com/@demo/video/{POST_ID}"


def test_scheduled_post_lookup_starts_after_schedule_time(client, clock, no_publish, monkeypatch):
    nears = []
    monkeypatch.setattr(links, "_find_post", lambda u, c, n: nears.append(n) or None)
    when = clock.now + timedelta(hours=1)
    key = _entry(link_state="scheduled_on_tiktok", tiktok_schedule_time=when,
                 link_next_at=when + timedelta(minutes=1))
    clock.now = when + timedelta(seconds=59)
    assert links.tick() is False
    clock.now = when + timedelta(minutes=1)
    assert links.tick() is True
    assert nears[0].replace(tzinfo=timezone.utc) == when  # matched around the TikTok time
    assert _get(key).link_state == "pending"


def test_stale_link_claim_cannot_overwrite_newer_state(client, clock, monkeypatch):
    key = _entry()
    with Session(db.engine) as s:
        row = links.claim_next(s)
        assert row.key == key and row.link_attempts == 1
    with Session(db.engine) as s:
        assert links.claim_next(s) is None  # leased: a second worker gets nothing
    r = client.post(f"/api/history/{key}/refresh-link")  # user reset meanwhile
    assert r.status_code == 200 and r.json()["link_state"] == "pending"
    with Session(db.engine) as s:
        assert links.finish(s, key, 1, POST_ID) is False  # the old claim lost
    e = _get(key)
    assert e.link_state == "pending" and e.link_attempts == 0 and e.post_id is None


def test_refresh_link_endpoint(client):
    key = _entry(link_state="gave_up", link_next_at=None, link_attempts=10)
    r = client.post(f"/api/history/{key}/refresh-link")
    assert r.status_code == 200 and r.json()["link_state"] == "pending" and r.json()["link_attempts"] == 0
    failed = _entry(key="direct:f", status="failed", link_state="")
    assert client.post(f"/api/history/{failed}/refresh-link").status_code == 409
    assert client.post("/api/history/direct:none/refresh-link").status_code == 404


def test_worker_idle_tick_runs_link_lookup_without_publishing(client, clock, no_publish, monkeypatch):
    calls = []
    monkeypatch.setattr(links, "_find_post", lambda u, c, n: calls.append(1) or POST_ID)
    key = _entry()
    assert worker.tick() is False  # no job processed
    assert calls == [1] and _get(key).link_state == "found"


def test_post_url_only_for_valid_parts():
    assert history.build_post_url("demo.user_1", POST_ID) == f"https://www.tiktok.com/@demo.user_1/video/{POST_ID}"
    # Not a handle: TikTok's "@_" redirect form (owner decision 25/10/2026); the label never enters the URL.
    assert history.build_post_url("bad-name", POST_ID) == f"https://www.tiktok.com/@_/video/{POST_ID}"
    assert history.build_post_url("demo", "123") is None
    assert history.build_post_url("demo/../x", POST_ID) == f"https://www.tiktok.com/@_/video/{POST_ID}"
    assert history.build_post_url("demo\n", POST_ID) == f"https://www.tiktok.com/@_/video/{POST_ID}"
    assert history.build_post_url("demo", POST_ID + "\n") is None
    assert history.build_post_url("demo", "٧" * 19) is None  # non-ASCII digits


def test_match_post_requires_single_exact_caption_near_time():
    near = datetime(2026, 10, 24, 12, 0, tzinfo=timezone.utc)
    t = int(near.timestamp())
    items = [{"id": "1" * 19, "desc": "Xin  chào\n#fyp", "createTime": t + 60},
             {"id": "2" * 19, "desc": "khác", "createTime": t}]
    assert match_post(items, "Xin chào #fyp", near) == "1" * 19
    assert match_post(items, "Xin chào #fyp", near + timedelta(minutes=17)) is None  # 16 min from the post
    dup = items + [{"id": "3" * 19, "desc": "Xin chào #fyp", "createTime": t - 60}]
    assert match_post(dup, "Xin chào #fyp", near) is None


# ---------- migration -----------------------------------------------------------

V3_COLUMNS = ["post_id", "post_url", "creation_id", "link_state", "link_attempts", "link_next_at",
              "tiktok_schedule_time", "publish_response_json", "caption"]


def test_migration_v2_to_v3_keeps_rows_with_defaults(tmp_path):
    path = tmp_path / "old.db"
    old = db.engine
    engine = db.make_engine(f"sqlite:///{path}")
    db.override_engine(engine)
    try:
        db.init_db()
        engine.dispose()
        con = sqlite3.connect(path)  # turn it into exactly what the v2 code left behind
        con.execute("DROP INDEX IF EXISTS ix_upload_history_link_state")
        for column in V3_COLUMNS:
            con.execute(f"ALTER TABLE upload_history DROP COLUMN {column}")
        con.execute("INSERT INTO upload_history (key, username, reel_id, sha256, original_name, status, "
                    "time_source, publish_uncertain, prior_uncertain, created_at) VALUES "
                    "('schedule:1:x', 'demo', '1', '', 'a.mp4', 'succeeded', 'acknowledgement', 0, 0, "
                    "'2026-01-01 00:00:00')")
        con.execute("PRAGMA user_version = 2")
        con.commit()
        con.close()
        db.init_db()
        db.init_db()  # repeatable
        con = sqlite3.connect(path)
        cols = {r[1] for r in con.execute("PRAGMA table_info(upload_history)")}
        assert set(V3_COLUMNS) <= cols
        assert con.execute("PRAGMA user_version").fetchone()[0] == 3
        con.close()
        with Session(engine) as s:
            e = s.get(UploadHistory, "schedule:1:x")
            assert e.link_state == "" and e.link_attempts == 0 and e.post_url is None
            assert e.tiktok_schedule_time is None and e.status == "succeeded"
        assert links.tick() is False  # old rows are never looked up
    finally:
        db.override_engine(old)
        engine.dispose()


def test_fresh_database_is_v3(tmp_path):
    path = tmp_path / "fresh.db"
    old = db.engine
    engine = db.make_engine(f"sqlite:///{path}")
    db.override_engine(engine)
    try:
        db.init_db()
        con = sqlite3.connect(path)
        assert set(V3_COLUMNS) <= {r[1] for r in con.execute("PRAGMA table_info(upload_history)")}
        assert con.execute("PRAGMA user_version").fetchone()[0] == 3
        con.close()
    finally:
        db.override_engine(old)
        engine.dispose()
