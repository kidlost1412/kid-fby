"""Release review fixes: slow-upload schedule shift (P1) and signed-URL redaction (P2)."""
import json
import logging
import time
from datetime import datetime, timedelta, timezone

import pytest
import requests
import responses
from sqlmodel import Session

import api.db as db
import autotok.uploader as up
from api.models import ScheduledUpload
from api.services import tiktok_adapter
from autotok import Client
from autotok.errors import PublishUncertainError, UploadError, ValidationError
from scheduler import worker
from tests.test_qa_v3_break import api, desk, publishes, real_uploader  # noqa: F401 (fixtures)
from tests.test_uploader import FakeSigner, mock_tiktok, publish_call

EXPIRED = "Tải video quá lâu, giờ hẹn không còn hợp lệ — hãy chọn giờ mới"
SIGNED = ("https://www.tiktok.com/tiktok/web/project/post/v1/?aid=1988&msToken=MSTOKENSECRET"
          "&X-Bogus=XBOGUSSECRET&_signature=SIGSECRET&X-Gnarly=GNARLYSECRET&verifyFp=VERIFYSECRET")
SECRETS = ("MSTOKENSECRET", "XBOGUSSECRET", "SIGSECRET", "GNARLYSECRET", "VERIFYSECRET")


def _no_secret(text):
    return not any(s in (text or "") for s in SECRETS)


@pytest.fixture
def tt(saved_account, monkeypatch):
    monkeypatch.setattr(up, "probe_video", lambda path: None)
    return Client(saved_account, signer=FakeSigner())


def _clock(monkeypatch, at):
    """time.time() inside the uploader (the moment the schedule is checked after the transfer)."""
    monkeypatch.setattr(up.time, "time", lambda: float(at))


# ---- P1: slow upload vs. the requested schedule (uploader level, exact boundaries) ----

@responses.activate
def test_requested_time_still_valid_is_sent_unchanged(tt, video_file, monkeypatch):
    mock_tiktok(responses)
    when = (datetime.now(timezone.utc) + timedelta(minutes=40)).replace(microsecond=0)
    _clock(monkeypatch, when.timestamp() - 15 * 60)  # exactly 15 min left after the transfer
    result = tt.upload(video_file, "x", schedule=when)
    sent = json.loads(publish_call(responses).request.body)["feature_common_info_list"][0]["schedule_time"]
    assert sent == int(when.timestamp()) and result.scheduled_for == when


@responses.activate
def test_shift_of_exactly_ten_minutes_is_allowed(tt, video_file, monkeypatch):
    mock_tiktok(responses)
    when = (datetime.now(timezone.utc) + timedelta(minutes=40)).replace(microsecond=0)
    _clock(monkeypatch, when.timestamp() - 5 * 60)  # earliest allowed = when + 10 min
    result = tt.upload(video_file, "x", schedule=when)
    sent = json.loads(publish_call(responses).request.body)["feature_common_info_list"][0]["schedule_time"]
    assert sent == int(when.timestamp()) + 600
    assert result.scheduled_for == when + timedelta(minutes=10)


@responses.activate
def test_shift_over_ten_minutes_fails_before_publishing(tt, video_file, monkeypatch):
    mock_tiktok(responses)
    when = (datetime.now(timezone.utc) + timedelta(minutes=40)).replace(microsecond=0)
    _clock(monkeypatch, when.timestamp() - 5 * 60 + 1)  # needs 10 min 1 s
    with pytest.raises(ValidationError) as err:
        tt.upload(video_file, "x", schedule=when)
    assert str(err.value) == EXPIRED and err.value.retryable is False
    assert not [c for c in responses.calls if "/project/post/v1/" in c.request.url]


# ---- P1 end to end: what the history/job shows ----

def _job_and_entry(api, request_id):
    return api.get(f"/api/desktop/jobs/{request_id}").json()


def _shift_clock(monkeypatch, minutes):
    real_time = time.time
    monkeypatch.setattr(up.time, "time", lambda: real_time() + minutes * 60)


@responses.activate
def test_e2e_time_still_valid_keeps_requested_time(api, real_uploader, monkeypatch):  # noqa: F811
    mock_tiktok(responses)
    chosen = (datetime.now(timezone.utc) + timedelta(minutes=60)).replace(microsecond=0)
    r = desk(api, scheduled_for=chosen.isoformat())
    _shift_clock(monkeypatch, 10)
    assert worker.tick() is True
    ts = json.loads(publish_call(responses).request.body)["feature_common_info_list"][0]["schedule_time"]
    assert ts == int(chosen.timestamp())
    job = _job_and_entry(api, r.json()["request_id"])
    assert datetime.fromisoformat(job["tiktok_schedule_time"]) == chosen
    assert datetime.fromisoformat(job["planned_for"]) == chosen


@responses.activate
def test_e2e_small_shift_records_actual_time_and_keeps_planned_for(api, real_uploader, monkeypatch):  # noqa: F811
    mock_tiktok(responses)
    chosen = (datetime.now(timezone.utc) + timedelta(minutes=21)).replace(microsecond=0)
    r = desk(api, scheduled_for=chosen.isoformat())
    _shift_clock(monkeypatch, 10)  # 11 min left: shifted by about 4 min
    assert worker.tick() is True
    ts = json.loads(publish_call(responses).request.body)["feature_common_info_list"][0]["schedule_time"]
    assert int(chosen.timestamp()) < ts <= int(chosen.timestamp()) + 600
    job = _job_and_entry(api, r.json()["request_id"])
    assert job["status"] == "succeeded"
    assert datetime.fromisoformat(job["tiktok_schedule_time"]).timestamp() == ts
    assert datetime.fromisoformat(job["planned_for"]) == chosen  # the owner's time, never overwritten


@responses.activate
def test_e2e_big_shift_fails_definitely_and_publishes_nothing(api, real_uploader, monkeypatch):  # noqa: F811
    mock_tiktok(responses)
    chosen = (datetime.now(timezone.utc) + timedelta(minutes=21)).replace(microsecond=0)
    r = desk(api, scheduled_for=chosen.isoformat())
    _shift_clock(monkeypatch, 17)  # 4 min left: would need an 11 min shift
    for _ in range(3):
        worker.tick()
    assert publishes() == []
    job = _job_and_entry(api, r.json()["request_id"])
    assert job["status"] == "failed" and job["publish_uncertain"] is False
    assert EXPIRED in job["result_text"]
    assert job["tiktok_schedule_time"] is None
    assert datetime.fromisoformat(job["planned_for"]) == chosen


# ---- P2: signed URLs never reach logs, stored text or API answers ----

def test_redact_url_on_exception_text_keeps_the_rest():
    text = f"HTTPSConnectionPool: Max retries exceeded with url: {SIGNED} (Caused by ConnectTimeout)"
    out = up.redact_url(text)
    assert _no_secret(out)
    assert "(Caused by ConnectTimeout)" in out and "aid=1988" in out
    nested = "redirect to https://x.example/?next=" + requests.utils.quote(SIGNED, safe="")
    assert _no_secret(up.redact_url(nested))


@responses.activate
def test_network_error_before_publish_message_is_redacted(tt, video_file):
    mock_tiktok(responses)
    responses.replace(responses.GET, "https://www.tiktok.com/api/v1/video/upload/auth/",
                      body=requests.ConnectionError(f"Max retries exceeded with url: {SIGNED}"))
    with pytest.raises(UploadError) as err:
        tt.upload(video_file, "x")
    assert _no_secret(str(err.value)) and "network error" in str(err.value)


@responses.activate
def test_publish_network_error_message_is_redacted(tt, video_file):
    mock_tiktok(responses, publish={"body": requests.ConnectionError(f"reset while sending {SIGNED}")})
    with pytest.raises(PublishUncertainError) as err:
        tt.upload(video_file, "x")
    assert _no_secret(str(err.value)) and "may or may not" in str(err.value)


@responses.activate
def test_browser_publish_error_message_is_redacted(tt, video_file):
    mock_tiktok(responses)
    up.publish_in_browser.exc = RuntimeError(f"Request failed: {SIGNED}")
    with pytest.raises(PublishUncertainError) as err:
        tt.upload(video_file, "x", schedule=timedelta(hours=2))
    assert _no_secret(str(err.value))


def test_sanitized_response_has_no_signed_url():
    out = up.sanitize_response({"status_code": 5, "extra": {"url": SIGNED}, "body": f"see {SIGNED}"})
    assert _no_secret(out) and '"status_code": 5' in out


@responses.activate
def test_worker_stores_and_logs_no_signed_url(api, real_uploader, caplog):  # noqa: F811
    mock_tiktok(responses, publish={"body": requests.ConnectionError(f"reset while sending {SIGNED}")})
    r = desk(api)
    with caplog.at_level(logging.DEBUG):
        assert worker.tick() is True
    job = _job_and_entry(api, r.json()["request_id"])
    assert job["status"] == "failed" and job["publish_uncertain"] is True
    assert _no_secret(job["result_text"]) and "may or may not" in job["result_text"]
    assert _no_secret(json.dumps(job, ensure_ascii=False))
    assert _no_secret(caplog.text)
    assert _no_secret(json.dumps(api.get("/api/schedules").json(), ensure_ascii=False))


def test_unexpected_error_is_logged_and_returned_redacted(monkeypatch, caplog):
    class Boom:
        @classmethod
        def from_account(cls, *a, **k):
            raise RuntimeError(f"bug while calling {SIGNED}")

    monkeypatch.setattr(tiktok_adapter, "Client", Boom)
    with caplog.at_level(logging.DEBUG):
        outcome = tiktok_adapter.upload_from_options("demo", "v.mp4", "t", {})
    assert outcome.ok is False and outcome.uncertain is True
    assert _no_secret(outcome.message) and "bug while calling" in outcome.message
    assert _no_secret(caplog.text) and "RuntimeError" in caplog.text  # traceback kept, tokens gone


def test_scheduler_crash_is_logged_and_stored_redacted(api, monkeypatch, caplog):  # noqa: F811
    r = desk(api)
    assert r.status_code == 200

    def crash(row):
        raise RuntimeError(f"crash at {SIGNED}")

    monkeypatch.setattr(worker, "run_one", crash)
    with caplog.at_level(logging.DEBUG):
        assert worker.tick() is True
    with Session(db.engine) as s:
        rows = s.exec(__import__("sqlmodel").select(ScheduledUpload)).all()
    assert rows and all(_no_secret(row.result_text) for row in rows)
    assert _no_secret(caplog.text) and "crash at" in caplog.text
