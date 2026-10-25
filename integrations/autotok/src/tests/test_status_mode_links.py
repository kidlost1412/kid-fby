"""schedule_mode on desktop/lookup responses and the "@_" post link (owner request 25/10/2026).

Real case: a "now" job queued behind a scheduled one showed a schedule-like time because
planned_for of a "now" job is its creation time; and the account label "thic12hlam-lieu" is
not a handle, so posts had post_id but no link. TikTok redirects /@_/video/<id> to the post.
"""
from datetime import datetime, timedelta, timezone

from sqlmodel import Session, select

import api.db as db
from api.models import Account, ScheduledUpload, UploadHistory
from scheduler import worker
from tests.test_native_schedule_links import POST_ID, client, fake_client, post  # noqa: F401 (fixtures)


def _lookup(client, request_ids=()):
    rows = client.post("/api/history/lookup", json={"videos": [{"reel_id": "123", "request_ids": list(request_ids)}]}).json()
    return {e["request_id"]: e for e in rows[0]["entries"]}


def test_now_and_native_jobs_report_their_mode_while_waiting(client, fake_client):
    when = (datetime.now(timezone.utc) + timedelta(minutes=30)).replace(microsecond=0)
    native = post(client, scheduled_for=when.isoformat()).json()
    now = post(client).json()
    assert native["status"] == now["status"] == "pending"
    assert native["schedule_mode"] == "native" and now["schedule_mode"] == "now"
    # The bug: the "now" job also carries a planned_for (its creation time); only the mode tells them apart.
    assert now["planned_for"] is not None
    got = client.get(f"/api/desktop/jobs/{now['request_id']}").json()
    assert got["schedule_mode"] == "now"
    entries = _lookup(client, [native["request_id"], now["request_id"]])
    assert entries[native["request_id"]]["schedule_mode"] == "native"
    assert entries[now["request_id"]]["schedule_mode"] == "now"
    assert worker.tick() and worker.tick()
    entries = _lookup(client)
    assert entries[native["request_id"]]["schedule_mode"] == "native"
    assert entries[native["request_id"]]["link_state"] == "scheduled_on_tiktok"
    assert entries[now["request_id"]]["schedule_mode"] == "now"


def test_legacy_job_without_mode_is_local_and_reused_id_never_matches(client):
    with Session(db.engine) as s:
        acct = s.exec(select(Account)).first()
        job = ScheduledUpload(account_id=acct.id, source_type="local", source_ref="old.mp4", title="t",
                              options_json="{}", scheduled_for=datetime(2026, 10, 1, tzinfo=timezone.utc))
        s.add(job)
        s.flush()
        s.add(UploadHistory(key=f"schedule:{job.id}:2020-01-01T00:00:00.000000", schedule_id=job.id,
                            request_id="a" * 32, username="demo", reel_id="123", status="succeeded",
                            created_at=datetime(2020, 1, 1, tzinfo=timezone.utc)))  # same integer id, different job: unknown
        from api.services.history import track_schedule
        track_schedule(s, job, request_id="b" * 32, reel_id="123")
        s.commit()
    entries = _lookup(client)
    assert entries["b" * 32]["schedule_mode"] == "local"
    assert entries["a" * 32]["schedule_mode"] == ""


def test_label_that_is_not_a_handle_gets_redirect_link(client, fake_client):
    with Session(db.engine) as s:
        s.add(Account(username="thic12hlam-lieu", cookie_path="x", has_valid_session=True))
        s.commit()
    fake_client.result = {"item_id": POST_ID}
    body = post(client, username="thic12hlam-lieu").json()
    assert worker.tick() is True
    job = client.get(f"/api/desktop/jobs/{body['request_id']}").json()
    assert job["link_state"] == "found" and job["post_url"] == f"https://www.tiktok.com/@_/video/{POST_ID}"


def test_old_row_with_post_id_and_null_url_gets_link_on_read(client):
    with Session(db.engine) as s:  # stored by 3.0.0: post_id set, post_url NULL
        s.add(UploadHistory(key="request:" + "c" * 32, request_id="c" * 32, username="thic12hlam-lieu",
                            reel_id="123", status="succeeded", post_id=POST_ID, post_url=None, link_state="found"))
        s.commit()
    url = f"https://www.tiktok.com/@_/video/{POST_ID}"
    assert _lookup(client)["c" * 32]["post_url"] == url
    assert client.get("/api/history/entry/request:" + "c" * 32).json()["post_url"] == url
    with Session(db.engine) as s:  # computed on read; nothing written
        assert s.get(UploadHistory, "request:" + "c" * 32).post_url is None
