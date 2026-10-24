"""Independent QA (v3): breaking tests written from the owner's requirements."""
import json
import time
from datetime import datetime, timedelta, timezone
from uuid import uuid4

import pytest
import responses
import sqlalchemy
from fastapi.testclient import TestClient
from sqlmodel import Session, select

import api.db as db
from api.main import create_app
from api.models import Account, ScheduledUpload, UploadHistory
from api.services import tiktok_adapter
from autotok import Account as TTAccount, AccountStore, Client
from autotok.uploader import _extract_post_id, sanitize_response
from scheduler import worker
from tests.test_uploader import FakeSigner, mock_tiktok, publish_call

H = {"X-Requested-With": "autotok"}
PID = "7429183650274961408"


@pytest.fixture
def api(tmp_path):
    old = db.engine
    engine = db.make_engine(f"sqlite:///{tmp_path / 'qa.db'}")
    db.override_engine(engine)
    db.init_db()
    with Session(engine) as s:
        s.add(Account(username="demo", cookie_path=str(tmp_path / "c"), has_valid_session=True))
        s.commit()
    AccountStore().save(TTAccount.from_session_id("demo", "sess-qa", datacenter="useast5", user_agent="UA"))
    with TestClient(create_app(), base_url="http://localhost", headers=H) as c:
        yield c
    db.override_engine(old)
    engine.dispose()


class RealClient(Client):
    """The real uploader; only the request signer is faked (HTTP is mocked with `responses`)."""
    @classmethod
    def from_account(cls, name, **kw):
        return super().from_account(name, signer=FakeSigner(), proxy=None)


@pytest.fixture
def real_uploader(monkeypatch):
    monkeypatch.setattr(tiktok_adapter, "Client", RealClient)


def desk(c, **fields):
    return c.post("/api/desktop/jobs",
                  data={"request_id": uuid4().hex, "username": "demo", "title": "Cap #qa", **fields},
                  files={"video": ("555-3-hoan-chinh.mp4", b"\x00\x00\x00\x18ftypmp42" + b"q" * 4096, "video/mp4")})


def publishes():
    return [c for c in responses.calls if "/project/post/v1/" in c.request.url]


# ---- (a) exact time sent to TikTok, timezone handling, end to end with the real uploader ----

@responses.activate
def test_e2e_vietnam_offset_reaches_tiktok_as_same_utc_epoch(api, real_uploader):
    mock_tiktok(responses, publish={"json": {"status_code": 0, "status_msg": "",
                                             "single_post_resp_list": [{"item_id": PID}]}})
    # Owner in UTC+7 picks 19:00 local two days ahead; the GUI sends UTC in .NET 'o' format (7 fraction digits).
    local = (datetime.now(timezone(timedelta(hours=7))) + timedelta(days=2)).replace(hour=19, minute=0, second=0,
                                                                                    microsecond=0)
    ps_o = local.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S") + ".0000000Z"
    r = desk(api, scheduled_for=ps_o)
    assert r.status_code == 200, r.text
    assert worker.tick() is True
    body = json.loads(publish_call(responses).request.body)
    assert body["feature_common_info_list"][0]["schedule_time"] == int(local.timestamp())
    job = api.get(f"/api/desktop/jobs/{r.json()['request_id']}").json()
    assert job["status"] == "succeeded" and job["link_state"] == "found"
    assert datetime.fromisoformat(job["tiktok_schedule_time"]) == local
    assert job["post_url"] == f"https://www.tiktok.com/@demo/video/{PID}"
    assert worker.tick() is False
    assert len(publishes()) == 1


@responses.activate
def test_native_job_whose_time_passed_while_backend_was_down_is_never_posted(api, real_uploader):
    mock_tiktok(responses)
    r = desk(api, scheduled_for=(datetime.now(timezone.utc) + timedelta(minutes=25)).isoformat())
    assert r.status_code == 200
    # backend was off: by the time the worker runs, only 14 minutes are left
    with Session(db.engine) as s:
        row = s.exec(select(ScheduledUpload)).one()
        opts = json.loads(row.options_json)
        opts["tiktok_schedule_time"] = (datetime.now(timezone.utc) + timedelta(minutes=14)).isoformat()
        row.options_json = json.dumps(opts)
        s.add(row)
        s.commit()
    for _ in range(4):
        worker.tick()
    assert len(responses.calls) == 0  # nothing sent to TikTok at all
    job = api.get(f"/api/desktop/jobs/{r.json()['request_id']}").json()
    assert job["status"] == "failed" and job["publish_uncertain"] is False


@responses.activate
def test_slow_upload_never_publishes_before_the_chosen_time(api, real_uploader, monkeypatch):
    mock_tiktok(responses)
    chosen = (datetime.now(timezone.utc) + timedelta(minutes=21)).replace(microsecond=0)
    r = desk(api, scheduled_for=chosen.isoformat())
    assert r.status_code == 200
    import autotok.uploader as up
    real_time = time.time
    monkeypatch.setattr(up.time, "time", lambda: real_time() + 10 * 60)  # the transfer took 10 minutes
    assert worker.tick() is True
    ts = json.loads(publish_call(responses).request.body)["feature_common_info_list"][0]["schedule_time"]
    assert ts >= int(chosen.timestamp())
    job = api.get(f"/api/desktop/jobs/{r.json()['request_id']}").json()
    assert datetime.fromisoformat(job["tiktok_schedule_time"]).timestamp() == ts


@pytest.mark.parametrize("delta,ok", [
    (timedelta(minutes=19, seconds=25), False),
    (timedelta(minutes=19, seconds=40), True),
    (timedelta(days=10, seconds=-5), True),
    (timedelta(days=10, seconds=5), False),
])
def test_window_edges(api, delta, ok):
    r = desk(api, scheduled_for=(datetime.now(timezone.utc) + delta).isoformat())
    assert (r.status_code == 200) is ok, r.text


def test_naive_timestamp_rejected(api):
    naive = (datetime.now() + timedelta(hours=2)).replace(tzinfo=None).isoformat()
    assert desk(api, scheduled_for=naive).status_code == 422


def test_private_and_schedule_rejected_on_web_too(api):
    from autotok import settings
    (settings.videos_dir() / "w.mp4").write_bytes(b"w")
    r = api.post("/api/schedules", json={
        "username": "demo", "title": "t", "source_type": "local", "source_ref": "w.mp4",
        "scheduled_for": (datetime.now(timezone.utc) + timedelta(hours=2)).isoformat(),
        "options": {"visibility_type": 1}})
    assert r.status_code == 422


def test_native_job_retry_after_retryable_failure_keeps_original_time(api, monkeypatch):
    sent = []
    from autotok.errors import UploadError

    class Flaky:
        n = 0

        @classmethod
        def from_account(cls, *a, **k):
            return cls()

        def upload(self, video, caption, **kw):
            Flaky.n += 1
            sent.append(kw["schedule"])
            if Flaky.n == 1:
                raise UploadError("transfer: network error")
            from autotok.uploader import UploadResult
            return UploadResult(video_id="v", creation_id="c", scheduled_for=kw["schedule"], response={})
    monkeypatch.setattr(tiktok_adapter, "Client", Flaky)
    when = (datetime.now(timezone.utc) + timedelta(hours=3)).replace(microsecond=0)
    r = desk(api, scheduled_for=when.isoformat())
    assert worker.tick() is True
    with Session(db.engine) as s:  # skip the 2-minute retry delay
        row = s.exec(select(ScheduledUpload)).one()
        row.scheduled_for = db.now_utc()
        s.add(row)
        s.commit()
    assert worker.tick() is True
    assert sent == [when, when]
    job = api.get(f"/api/desktop/jobs/{r.json()['request_id']}").json()
    assert job["status"] == "succeeded" and datetime.fromisoformat(job["tiktok_schedule_time"]) == when


# ---- legacy guard ----

def _legacy(late, options='{"visibility_type": 0}'):
    from autotok import settings
    (settings.videos_dir() / "legacy.mp4").write_bytes(b"l")
    with Session(db.engine) as s:
        acct = s.exec(select(Account)).first()
        row = ScheduledUpload(account_id=acct.id, source_type="local", source_ref="legacy.mp4", title="t",
                              options_json=options, scheduled_for=db.now_utc() - late)
        s.add(row)
        s.commit()
        return row.id


def test_legacy_future_job_still_waits_for_its_time(api, monkeypatch):
    calls = []
    monkeypatch.setattr(tiktok_adapter, "upload_from_options", lambda *a: calls.append(a))
    _legacy(-timedelta(hours=3))
    assert worker.tick() is False and calls == []


def test_legacy_v2_options_job_5h_late_is_not_posted(api, monkeypatch):
    calls = []
    monkeypatch.setattr(tiktok_adapter, "upload_from_options", lambda *a: calls.append(a))
    _legacy(timedelta(hours=5), options='{"visibility_type": 0, "allow_comment": 1, "proxy": null}')
    for _ in range(3):
        worker.tick()
    assert calls == []


# ---- (c) sanitization ----

def test_sanitize_nested_and_list_secret_keys():
    resp = {"status_code": 0,
            "data": {"x_tt_token": "T1", "nested": [{"session_key": "S1", "ok": 1},
                                                     {"deep": {"Cookie": "C1", "SIGNATURE": "Z1"}}]},
            "ticket_guard": "G1", "msToken": "M1"}
    text = sanitize_response(resp)
    for secret in ("T1", "S1", "C1", "Z1", "G1", "M1"):
        assert secret not in text
    assert json.loads(text)["data"]["nested"][0]["ok"] == 1


@pytest.mark.parametrize("key", ["authorization", "password", "secret_access_key", "sid_tt", "csrf",
                                 "passport_auth", "ttwid", "odin_tt", "uid_tt"])
def test_sanitize_other_credential_keys(key):
    assert "VALUE-SECRET" not in sanitize_response({"data": {key: "VALUE-SECRET"}})


def test_sanitize_value_that_is_a_cookie_string():
    text = sanitize_response({"extra": {"set_header": "sessionid=abcdef0123456789; tt_csrf_token=xyz"}})
    assert "abcdef0123456789" not in text


def test_sanitize_truncates_and_never_raises():
    assert len(sanitize_response({"data": ["x" * 100] * 1000})) <= 8 * 1024
    assert sanitize_response({"a": object()})


# ---- post id ----

@pytest.mark.parametrize("resp", [
    {"data": {"item_id": "12345"}},
    {"data": {"post": {"item_id": PID}}},
    {"item_id": 7.429183650274961e18},
    {"video_id": PID, "creation_id": PID},
    {"item_id": True},
    {"item_id": "７" * 19},
])
def test_post_id_not_guessed(resp):
    assert _extract_post_id(resp) is None


# ---- link fetch path never uploads (real HTTP endpoint + the real stub) ----

def test_refresh_link_with_real_stub_never_publishes_and_ends_gave_up(api, monkeypatch):
    hits = []

    def boom(*a, **k):  # recorded, not raised: links.tick swallows exceptions from the lookup
        hits.append(a)
        raise AssertionError("link lookup must never upload/publish")
    monkeypatch.setattr(tiktok_adapter, "upload_from_options", boom)
    monkeypatch.setattr(Client, "upload", boom)
    monkeypatch.setattr(Client, "_publish", boom)
    key = "schedule:9:2026-10-24T08:00:00.123456"
    with Session(db.engine) as s:
        s.add(UploadHistory(key=key, username="demo", status="succeeded", caption="c",
                            accepted_at=db.now_utc(), link_state="gave_up", link_attempts=10))
        s.commit()
    r = api.post("/api/history/schedule%3A9%3A2026-10-24T08%3A00%3A00.123456/refresh-link")
    assert r.status_code == 200 and r.json()["link_state"] == "pending"
    for _ in range(10):
        with Session(db.engine) as s:
            s.exec(sqlalchemy.update(UploadHistory).values(link_next_at=db.now_utc() - timedelta(seconds=1)))
            s.commit()
        assert worker.tick() is False
    with Session(db.engine) as s:
        assert s.get(UploadHistory, key).link_state == "gave_up"
    assert hits == []


def test_refresh_link_on_pending_job_does_not_touch_it(api):
    desk(api)
    with Session(db.engine) as s:
        key = s.exec(select(UploadHistory)).one().key
    assert api.post(f"/api/history/{key}/refresh-link").status_code == 409
    with Session(db.engine) as s:
        e = s.get(UploadHistory, key)
        assert e.status == "pending" and e.link_state == ""


def test_known_post_id_with_hyphenated_account_name_still_gives_a_link(api, monkeypatch):
    """Account names may contain '-', TikTok handles may not. TikTok named the post id: a link must exist."""
    with Session(db.engine) as s:
        s.add(Account(username="kid-main", cookie_path="x", has_valid_session=True))
        s.commit()

    class C:
        @classmethod
        def from_account(cls, *a, **k):
            return cls()

        def upload(self, *a, **kw):
            from autotok.uploader import UploadResult
            return UploadResult(video_id="v", creation_id="c", response={"item_id": PID}, post_id=PID)
    monkeypatch.setattr(tiktok_adapter, "Client", C)
    r = api.post("/api/desktop/jobs", data={"request_id": uuid4().hex, "username": "kid-main", "title": "x"},
                 files={"video": ("777-3-hoan-chinh.mp4", b"abc", "video/mp4")})
    assert r.status_code == 200, r.text
    assert worker.tick() is True
    job = api.get(f"/api/desktop/jobs/{r.json()['request_id']}").json()
    assert job["post_id"] == PID
    assert job["link_state"] == "found", job["link_state"]


def test_health_contract(api):
    h = api.get("/health").json()
    assert h["history_version"] == 2 and h["native_schedule"] == 1


def test_user_retry_of_failed_legacy_job_is_not_instantly_expired(api, monkeypatch):
    """Owner clicks 'Thu lai' on a legacy job that failed 3 h ago: it should run (or say why), not be
    silently re-failed as 'missed while the PC was off'."""
    calls = []
    monkeypatch.setattr(tiktok_adapter, "upload_from_options", lambda *a: calls.append(a) or
                        tiktok_adapter.UploadOutcome(ok=True, message="published", video_id="v"))
    job_id = _legacy(timedelta(hours=3))
    with Session(db.engine) as s:
        row = s.get(ScheduledUpload, job_id)
        row.status, row.result_text = "failed", "network"
        s.add(row)
        s.commit()
    r = api.patch(f"/api/schedules/{job_id}", json={"status": "pending"})
    assert r.status_code == 200, r.text
    worker.tick()
    with Session(db.engine) as s:
        row = s.get(ScheduledUpload, job_id)
    assert row.result_text != "Lỡ giờ khi máy tắt — chưa đăng", "retry was re-failed as a missed legacy job"
