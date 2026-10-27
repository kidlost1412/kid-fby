"""Chrome extension publisher (backend side): PROTOCOL.md v1, contracts C1-C6, acceptance cases 1-6.

Nothing here contacts TikTok: the cookie adapter is replaced by a recorder that fails the test if a
Chrome job ever reaches it, and the "extension" is this test talking HTTP to the app.
"""
import json
import sqlite3
import threading
from datetime import datetime, timedelta, timezone

import pytest
from fastapi.testclient import TestClient
from sqlmodel import Session, SQLModel, select

import api.db as api_db
from api.main import create_app
from api.models import Account, ExtensionClient, ExtensionJob, ScheduledUpload, UploadHistory
from api.services import ext
from api.services.history import schedule_key, track_schedule
from scheduler import worker

UID_A, UID_B = "7000000000000000001", "7000000000000000002"
ORIGIN = ext.EXT_ORIGIN
SHA = "ab" * 32


class PowerLoss(Exception):
    """Stands for the process dying at this point: nothing after it runs."""


@pytest.fixture
def engine(tmp_path):
    eng = api_db.make_engine(f"sqlite:///{tmp_path / 'ext.db'}")
    old = api_db.engine
    api_db.override_engine(eng)
    api_db.init_db()
    yield eng
    api_db.override_engine(old)
    SQLModel.metadata.drop_all(eng)
    eng.dispose()


@pytest.fixture
def cookie_calls(monkeypatch):
    calls = []

    def fake(username, video_path, title, options):
        calls.append(username)
        from api.services.tiktok_adapter import UploadOutcome
        return UploadOutcome(ok=True, message="published", video_id="cookie-v")

    monkeypatch.setattr("api.services.tiktok_adapter.upload_from_options", fake)
    return calls


@pytest.fixture
def app(engine, cookie_calls):
    with TestClient(create_app(), base_url="http://127.0.0.1", headers={"X-Requested-With": "autotok"}) as c:
        yield c


@pytest.fixture
def clock(monkeypatch):
    """Shift ext's notion of 'now' (deadlines) without sleeping."""
    state = {"offset": timedelta(0)}
    real = ext.now_utc
    monkeypatch.setattr(ext, "now_utc", lambda: real() + state["offset"])
    return state


class Chrome:
    """A paired extension instance."""

    def __init__(self, app, username, user_id, protocol=1):
        self.app, self.protocol = app, protocol
        code = app.post("/api/ext/pair-code").json()["code"]
        r = app.post("/api/ext/pair", json={"code": code, "label": "Chrome " + username, "ext_version": "1.0.0",
                                            "protocol": protocol})
        assert r.status_code == 200, r.text
        self.token, self.client_id = r.json()["token"], r.json()["client_id"]
        self.hello(username, user_id)

    def h(self):
        return {"Authorization": "Bearer " + self.token, "X-Autotok-Protocol": str(self.protocol)}

    def hello(self, username, user_id, protocol=None):
        protocol = self.protocol if protocol is None else protocol
        return self.app.post("/api/ext/hello", headers=self.h(), json={
            "protocol": protocol, "ext_version": "1.0.0",
            "identity": {"username": username, "user_id": user_id} if user_id else None})

    def next(self):
        return self.app.get("/api/ext/next?wait=0", headers=self.h())

    def post(self, path, job, **body):
        return self.app.post("/api/ext/" + path, headers=self.h(),
                             json={"id": job["id"], "nonce": job["nonce"], "claim_token": job["claim_token"], **body})

    def ready(self, job):
        return self.post("progress", job, phase="ready")

    def authorize(self, job, **over):
        body = dict(body_sha256=SHA, creation_id="cid-1", visibility_type=job["visibility_type"],
                    schedule_time=job["schedule_unix"], identity={"username": job["expect_account"],
                                                                 "user_id": job["expect_user_id"]})
        body.update(over)
        return self.post("authorize", job, **body)


def chrome_account(engine, username="alice", user_id=UID_A, cookie_path=""):
    with Session(engine) as s:
        a = Account(username=username, cookie_path=cookie_path, has_valid_session=bool(cookie_path),
                    publisher="chrome", chrome_user_id=user_id)
        s.add(a)
        s.commit()
        return a.id


def schedule(engine, account_id, video_name="clip.mp4", title="xin chào #tag", options=None, when_offset=-1):
    opts = {"schedule_mode": "now", "visibility_type": 0, "allow_comment": 1, "allow_duet": 0,
            "allow_stitch": 0, "ai_label": 0}
    opts.update(options or {})
    with Session(engine) as s:
        row = ScheduledUpload(account_id=account_id, source_type="local", source_ref=video_name, title=title,
                              options_json=json.dumps(opts),
                              scheduled_for=datetime.now(timezone.utc) + timedelta(seconds=when_offset))
        s.add(row)
        s.flush()
        track_schedule(s, row)
        s.commit()
        return row.id


def parent(engine, sid):
    with Session(engine) as s:
        return s.get(ScheduledUpload, sid)


def children(engine, sid=None):
    with Session(engine) as s:
        q = select(ExtensionJob).order_by(ExtensionJob.created_at)
        if sid is not None:
            q = q.where(ExtensionJob.schedule_id == sid)
        return s.exec(q).all()


def history(engine, sid):
    with Session(engine) as s:
        return s.get(UploadHistory, schedule_key(s.get(ScheduledUpload, sid)))


def dispatched(engine, app, chrome, sid):
    """Scheduler tick -> child queued; the extension claims it and reports ready."""
    worker.tick()
    assert parent(engine, sid).status == "waiting_ext"
    r = chrome.next()
    assert r.status_code == 200, r.text
    job = r.json()
    assert chrome.ready(job).json()["state"] == "ready"
    return job


# ---------- acceptance 1: timeout vs authorize, both orders (C1) ----------

def test_timeout_first_revokes_and_authorize_is_then_denied(engine, app, clock, video_file, cookie_calls):
    aid = chrome_account(engine)
    chrome = Chrome(app, "alice", UID_A)
    sid = schedule(engine, aid)
    job = dispatched(engine, app, chrome, sid)
    clock["offset"] = timedelta(seconds=121)  # no heartbeat for > 120 s
    ext.reconcile_ext()
    row = parent(engine, sid)
    assert row.status == "failed" and row.publish_uncertain is False  # definite: nothing was sent
    assert children(engine, sid)[0].state == "revoked"
    clock["offset"] = timedelta(0)
    r = chrome.authorize(job)
    assert r.json() == {"ok": False, "reason": "revoked"}
    assert cookie_calls == []


def test_authorize_first_then_deadline_is_uncertain_never_definite(engine, app, clock, video_file):
    aid = chrome_account(engine)
    chrome = Chrome(app, "alice", UID_A)
    sid = schedule(engine, aid)
    job = dispatched(engine, app, chrome, sid)
    assert chrome.authorize(job).json() == {"ok": True}
    assert chrome.authorize(job).json() == {"ok": False, "reason": "already-authorized"}
    clock["offset"] = timedelta(seconds=150)  # pre-authorization deadlines no longer apply
    ext.reconcile_ext()
    assert children(engine, sid)[0].state == "authorized" and parent(engine, sid).status == "waiting_ext"
    assert chrome.post("cancel", job).json()["cancel_recorded"] is True  # never undone
    clock["offset"] = timedelta(seconds=181)
    ext.reconcile_ext()
    row = parent(engine, sid)
    assert row.status == "failed" and row.publish_uncertain is True
    assert children(engine, sid)[0].state == "uncertain"


def test_concurrent_revoke_and_authorize_exactly_one_wins(engine, app, video_file):
    aid = chrome_account(engine)
    chrome = Chrome(app, "alice", UID_A)
    for round_ in range(15):
        sid = schedule(engine, aid, title=f"t{round_}")
        job_wire = dispatched(engine, app, chrome, sid)
        with Session(engine) as s:
            job = s.get(ExtensionJob, job_wire["id"])
        results = {}
        barrier = threading.Barrier(2)

        def do_auth():
            barrier.wait()
            results["auth"] = ext.authorize(job, SHA, "cid")

        def do_revoke():
            barrier.wait()
            results["revoke"] = ext.revoke(job.id, "timeout")

        ts = [threading.Thread(target=do_auth), threading.Thread(target=do_revoke)]
        for t in ts:
            t.start()
        for t in ts:
            t.join()
        assert results["auth"] != results["revoke"], results
        ext.reconcile_ext()
        if results["auth"]:  # finish it so the account is free for the next round
            chrome.post("result", job_wire, outcome="posted", status_code=0, item_id="7701245450858351893")
        assert parent(engine, sid).status == ("succeeded" if results["auth"] else "failed")


def test_crash_after_result_stored_before_parent_finalized(engine, app, video_file, monkeypatch):
    aid = chrome_account(engine)
    chrome = Chrome(app, "alice", UID_A)
    sid = schedule(engine, aid)
    job = dispatched(engine, app, chrome, sid)
    chrome.authorize(job)
    monkeypatch.setattr(ext, "reconcile_ext", lambda: (_ for _ in ()).throw(PowerLoss("after result stored")))
    with pytest.raises(PowerLoss):
        chrome.post("result", job, outcome="posted", status_code=0, item_id="7701245450858351893")
    monkeypatch.undo()
    assert children(engine, sid)[0].result_json is not None  # durable before anything else
    assert parent(engine, sid).status == "waiting_ext"
    ext.reconcile_ext()
    assert parent(engine, sid).status == "succeeded"
    assert history(engine, sid).post_id == "7701245450858351893"


def test_crash_between_claim_and_dispatch_never_reaches_cookies(engine, app, video_file, cookie_calls, monkeypatch):
    aid = chrome_account(engine)
    sid = schedule(engine, aid)
    monkeypatch.setattr(worker, "dispatch_ext", lambda row: (_ for _ in ()).throw(PowerLoss("after claim")))
    with pytest.raises(PowerLoss):
        worker.tick()
    monkeypatch.undo()
    assert parent(engine, sid).status == "running" and children(engine) == []
    worker.tick()  # a fresh tick does not re-run a running row (reclaim_stale handles it later)
    assert cookie_calls == [] and children(engine) == []


# ---------- acceptance 2: late result after a restart ----------

def test_late_result_after_restart_reconciles_history_and_keeps_post_id(engine, cookie_calls, clock, video_file):
    aid = chrome_account(engine)
    with TestClient(create_app(), base_url="http://127.0.0.1", headers={"X-Requested-With": "autotok"}) as app:
        chrome = Chrome(app, "alice", UID_A)
        sid = schedule(engine, aid)
        job = dispatched(engine, app, chrome, sid)
        assert chrome.authorize(job).json()["ok"] is True
    clock["offset"] = timedelta(minutes=10)
    with TestClient(create_app(), base_url="http://127.0.0.1", headers={"X-Requested-With": "autotok"}) as app2:
        row = parent(engine, sid)  # startup reconcile: result deadline passed
        assert row.status == "failed" and row.publish_uncertain is True
        r = app2.post("/api/ext/result", headers=chrome.h(), json={
            "id": job["id"], "nonce": job["nonce"], "claim_token": job["claim_token"], "outcome": "posted",
            "status_code": 0, "item_id": "7701245450858351893", "video_id": "v0abc",
            "response": {"status_code": 0, "sessionid": "SECRET"}})
        assert r.json() == {"ok": True, "duplicate": False, "state": "posted"}
        dup = app2.post("/api/ext/result", headers=chrome.h(), json={
            "id": job["id"], "nonce": job["nonce"], "claim_token": job["claim_token"], "outcome": "rejected"})
        assert dup.json()["duplicate"] is True
    row = parent(engine, sid)
    entry = history(engine, sid)
    assert row.status == "succeeded" and row.publish_uncertain is False
    assert entry.post_id == "7701245450858351893" and entry.post_url.endswith("/video/7701245450858351893")
    assert entry.prior_uncertain is True  # the uncertain spell is never forgotten
    assert "SECRET" not in (entry.publish_response_json or "")
    assert cookie_calls == []


def test_late_success_of_attempt_1_withdraws_the_unauthorized_attempt_2(engine, app, clock, video_file):
    """QA fix 1: the video is known to be on TikTok, so attempt 2 must never be authorized."""
    aid = chrome_account(engine)
    chrome = Chrome(app, "alice", UID_A)
    sid = schedule(engine, aid)
    job = dispatched(engine, app, chrome, sid)
    chrome.authorize(job)
    clock["offset"] = timedelta(minutes=4)
    ext.reconcile_ext()
    clock["offset"] = timedelta(0)
    r = app.patch(f"/api/schedules/{sid}", json={"status": "pending", "confirm_uncertain": True})
    assert r.status_code == 200, r.text
    worker.tick()  # attempt 2 -> new child
    assert parent(engine, sid).attempts == 2 and parent(engine, sid).status == "waiting_ext"
    chrome.post("result", job, outcome="posted", status_code=0, item_id="7701245450858351893")
    row = parent(engine, sid)
    assert row.status == "succeeded" and row.attempts == 2
    assert [c.state for c in children(engine, sid)] == ["posted", "revoked"]
    entry = history(engine, sid)
    assert entry.post_id == "7701245450858351893" and entry.prior_uncertain is True
    assert chrome.next().status_code == 204


def test_late_success_keeps_an_already_authorized_newer_attempt_and_warns(engine, app, clock, video_file):
    aid = chrome_account(engine)
    chrome = Chrome(app, "alice", UID_A)
    sid = schedule(engine, aid)
    job = dispatched(engine, app, chrome, sid)
    chrome.authorize(job)
    clock["offset"] = timedelta(minutes=4)
    ext.reconcile_ext()
    clock["offset"] = timedelta(0)
    app.patch(f"/api/schedules/{sid}", json={"status": "pending", "confirm_uncertain": True})
    worker.tick()
    job2 = chrome.next().json()
    chrome.ready(job2)
    assert chrome.authorize(job2).json() == {"ok": True}  # attempt 2 may already be publishing
    chrome.post("result", job, outcome="posted", status_code=0, item_id="7701245450858351893")
    row = parent(engine, sid)
    assert row.status == "waiting_ext" and row.attempts == 2  # never overwritten
    entry = history(engine, sid)
    assert entry.post_id == "7701245450858351893" and "late success of attempt 1" in entry.result_text


def test_late_success_while_manual_retry_waits_prevents_repost(engine, app, clock, video_file):
    aid = chrome_account(engine)
    chrome = Chrome(app, "alice", UID_A)
    sid = schedule(engine, aid)
    job = dispatched(engine, app, chrome, sid)
    chrome.authorize(job)
    clock["offset"] = timedelta(minutes=4)
    ext.reconcile_ext()
    clock["offset"] = timedelta(0)
    app.patch(f"/api/schedules/{sid}", json={"status": "pending", "confirm_uncertain": True})
    chrome.post("result", job, outcome="posted", status_code=0, item_id="7701245450858351893")
    assert parent(engine, sid).status == "succeeded"
    worker.tick()
    assert len(children(engine, sid)) == 1  # no second attempt


# ---------- acceptance 3: cookie-free first account, end to end ----------

def test_cookie_free_first_account_through_desktop_submit_and_dispatch(engine, app, autotok_home, cookie_calls):
    assert not list(autotok_home.rglob("*.cookie"))
    chrome = Chrome(app, "mt.tri.2.pin", UID_A)
    r = app.post("/api/accounts/from-chrome", json={"client_id": chrome.client_id})
    assert r.status_code == 201, r.text
    acct = r.json()
    assert acct["publisher"] == "chrome" and acct["cookie_path"] == "" and acct["ready"] is True
    assert acct["has_valid_session"] is False
    assert app.post("/api/accounts/from-chrome", json={"client_id": chrome.client_id}).status_code == 409
    req = "a" * 32
    r = app.post("/api/desktop/jobs", data={"request_id": req, "username": "mt.tri.2.pin", "title": "Chào cả nhà 🌸"},
                 files={"video": ("1234-3-hoan-chinh.mp4", b"\x00\x00\x00\x18ftypmp42" + b"y" * 4096, "video/mp4")})
    assert r.status_code == 200, r.text
    worker.tick()
    job = chrome.next().json()
    assert job["caption"] == "Chào cả nhà 🌸" and job["expect_user_id"] == UID_A
    video = app.get(f"/api/ext/video?id={job['id']}", headers={**chrome.h(), "Range": "bytes=0-7"})
    assert video.status_code == 206 and video.content == b"\x00\x00\x00\x18ftyp"
    chrome.ready(job)
    assert chrome.authorize(job).json()["ok"] is True
    chrome.post("result", job, outcome="posted", status_code=0, item_id="7701245450858351893")
    d = app.get(f"/api/desktop/jobs/{req}").json()
    assert d["status"] == "succeeded" and d["post_id"] == "7701245450858351893"
    assert cookie_calls == [] and not list(autotok_home.rglob("*.cookie"))
    assert app.post(f"/api/accounts/{acct['id']}/check").status_code == 409  # no cookie session to check


def test_converting_a_cookie_account_leaves_its_cookie_file_byte_identical(engine, app, saved_account):
    from autotok import AccountStore
    path = AccountStore().path_for("alice")
    before = path.read_bytes()
    r = app.post("/api/accounts", json={"username": "alice"})
    assert r.status_code == 201
    aid = r.json()["id"]
    chrome = Chrome(app, "alice", UID_A)
    r = app.patch(f"/api/accounts/{aid}", json={"publisher": "chrome", "client_id": chrome.client_id})
    assert r.status_code == 200, r.text
    assert r.json()["publisher"] == "chrome" and r.json()["chrome_user_id"] == UID_A
    r = app.patch(f"/api/accounts/{aid}", json={"publisher": "cookies"})
    assert r.status_code == 200 and r.json()["publisher"] == "cookies"
    assert path.read_bytes() == before


def test_convert_needs_confirmation_when_tiktok_name_differs(engine, app, saved_account):
    aid = app.post("/api/accounts", json={"username": "alice"}).json()["id"]
    chrome = Chrome(app, "someone.else", UID_A)
    assert app.patch(f"/api/accounts/{aid}", json={"publisher": "chrome", "client_id": chrome.client_id}).status_code == 409
    r = app.patch(f"/api/accounts/{aid}", json={"publisher": "chrome", "client_id": chrome.client_id,
                                                 "confirm_username_mismatch": True})
    assert r.status_code == 200


# ---------- acceptance 4: same account, two entry points ----------

def test_direct_upload_is_409_and_queued_jobs_serialize_fifo(engine, app, video_file, cookie_calls):
    aid = chrome_account(engine)
    chrome = Chrome(app, "alice", UID_A)
    r = app.post("/api/uploads/library", json={"username": "alice", "title": "t", "name": "clip.mp4"})
    assert r.status_code == 409 and "Chrome" in r.json()["detail"]
    first = schedule(engine, aid, title="first", when_offset=-20)
    second = schedule(engine, aid, title="second", when_offset=-10)
    worker.tick()
    worker.tick()
    assert parent(engine, first).status == "waiting_ext" and parent(engine, second).status == "pending_ext"
    assert len(children(engine)) == 1
    job = chrome.next().json()
    assert job["caption"] == "first" and chrome.next().status_code == 204
    chrome.ready(job)
    chrome.authorize(job)
    chrome.post("result", job, outcome="posted", status_code=0, item_id="7701245450858351893")
    assert parent(engine, second).status == "waiting_ext"
    assert chrome.next().json()["caption"] == "second"
    assert cookie_calls == []


def test_partial_unique_index_blocks_a_second_active_child(engine, video_file):
    aid = chrome_account(engine)
    with Session(engine) as s:
        for i in (1, 2):
            s.add(ExtensionJob(id=f"ej_{i}", schedule_id=i, attempt=1, schedule_key="k", account_id=aid,
                               expect_user_id=UID_A, video_name="clip.mp4", caption="c", nonce="n"))
        with pytest.raises(Exception):
            s.commit()


# ---------- acceptance 5: reload / skew with an authorized job ----------

def test_reload_with_authorized_job_no_second_post_and_result_still_accepted(engine, app, video_file):
    aid = chrome_account(engine)
    chrome = Chrome(app, "alice", UID_A)
    sid = schedule(engine, aid)
    job = dispatched(engine, app, chrome, sid)
    assert chrome.authorize(job).json()["ok"] is True
    chrome.protocol = 2  # the extension was updated and reloaded: newer protocol than this backend
    hello = chrome.hello("alice", UID_A).json()
    assert hello["need_reload"] is True and "tải lại" in hello["message"]
    r = chrome.next()
    assert r.status_code == 409 and r.json()["error"] == "need_reload"
    assert app.get("/api/accounts").json()[0]["ready_reason"] == "chrome_need_reload"
    clients = app.get("/api/ext/clients").json()
    assert clients[0]["need_reload"] is True
    r = chrome.post("result", job, outcome="posted", status_code=0, item_id="7701245450858351893")
    assert r.json()["state"] == "posted"
    assert parent(engine, sid).status == "succeeded" and len(children(engine, sid)) == 1


def test_authorize_refused_on_protocol_skew(engine, app, video_file):
    aid = chrome_account(engine)
    chrome = Chrome(app, "alice", UID_A)
    sid = schedule(engine, aid)
    job = dispatched(engine, app, chrome, sid)
    chrome.protocol = 0
    assert chrome.authorize(job).json() == {"ok": False, "reason": "need-reload"}


# ---------- acceptance 6: two accounts, one stalled ----------

def test_two_accounts_progress_independently_while_one_chrome_stalls(engine, app, clock, video_file):
    a = chrome_account(engine, "alice", UID_A)
    b = chrome_account(engine, "bob", UID_B)
    ca, cb = Chrome(app, "alice", UID_A), Chrome(app, "bob", UID_B)
    sa, sb = schedule(engine, a, when_offset=-20), schedule(engine, b, when_offset=-10)
    worker.tick()
    worker.tick()
    ja = ca.next().json()  # alice's Chrome claims, then stalls
    jb = cb.next().json()
    assert ja["expect_user_id"] == UID_A and jb["expect_user_id"] == UID_B
    cb.ready(jb)
    assert cb.authorize(jb).json()["ok"] is True
    cb.post("result", jb, outcome="posted", status_code=0, item_id="7701245450858351894")
    assert parent(engine, sb).status == "succeeded" and parent(engine, sa).status == "waiting_ext"
    clock["offset"] = timedelta(seconds=130)
    ext.reconcile_ext()
    assert parent(engine, sa).status == "failed" and parent(engine, sa).publish_uncertain is False


def test_chrome_not_polling_fails_definitely_after_claim_window(engine, app, clock, video_file, cookie_calls):
    aid = chrome_account(engine)
    sid = schedule(engine, aid)
    worker.tick()
    clock["offset"] = timedelta(seconds=121)
    ext.reconcile_ext()
    row = parent(engine, sid)
    assert row.status == "failed" and not row.publish_uncertain and "Chrome chưa sẵn sàng" in row.result_text
    assert cookie_calls == []  # never falls back to cookies


# ---------- C6: validation and option mapping ----------

def test_private_scheduled_and_friends_are_refused_before_dispatch(engine, app, video_file):
    aid = chrome_account(engine)
    when = (datetime.now(timezone.utc) + timedelta(hours=1)).isoformat()
    s1 = schedule(engine, aid, options={"visibility_type": 1, "schedule_mode": "native", "tiktok_schedule_time": when})
    s2 = schedule(engine, aid, options={"visibility_type": 2})
    worker.tick()
    worker.tick()
    for sid in (s1, s2):
        row = parent(engine, sid)
        assert row.status == "failed" and not row.publish_uncertain
    assert children(engine) == []


def test_all_options_and_schedule_reach_the_job_and_authorize_checks_them(engine, app, video_file):
    aid = chrome_account(engine)
    chrome = Chrome(app, "alice", UID_A)
    when = (datetime.now(timezone.utc) + timedelta(hours=2)).replace(microsecond=0)
    sid = schedule(engine, aid, options={"schedule_mode": "native", "tiktok_schedule_time": when.isoformat(),
                                         "allow_comment": 0, "allow_duet": 1, "allow_stitch": 1, "ai_label": 1})
    job = dispatched(engine, app, chrome, sid)
    assert job["options"] == {"allow_comment": 0, "allow_duet": 1, "allow_stitch": 1, "ai_label": 1}
    assert job["visibility"] == "public" and job["schedule_unix"] == int(when.timestamp())
    assert job["schedule_time"] == when.strftime("%Y-%m-%dT%H:%M:%SZ")
    assert chrome.authorize(job, schedule_time=None).json()["reason"] == "schedule-mismatch"  # never immediate
    assert chrome.authorize(job, schedule_time=job["schedule_unix"] + 601).json()["reason"] == "schedule-mismatch"
    assert chrome.authorize(job, visibility_type=1).json()["reason"] == "visibility-mismatch"
    assert chrome.authorize(job, identity={"username": "alice", "user_id": UID_B}).json()["reason"] == "identity-mismatch"
    assert chrome.authorize(job, body_sha256="xyz").json()["reason"] == "bad-binding"
    assert chrome.authorize(job, schedule_time=job["schedule_unix"] + 300).json() == {"ok": True}
    chrome.post("result", job, outcome="posted", status_code=0, item_id="7701245450858351893",
                schedule_time=job["schedule_unix"] + 300)
    entry = history(engine, sid)
    assert parent(engine, sid).result_text.startswith("scheduled on TikTok")
    assert entry.tiktok_schedule_time.replace(tzinfo=timezone.utc) == when + timedelta(seconds=300)


def test_public_immediate_is_allowed_and_immediate_rejects_a_schedule_time(engine, app, video_file):
    aid = chrome_account(engine)
    chrome = Chrome(app, "alice", UID_A)
    job = dispatched(engine, app, chrome, schedule(engine, aid))
    assert job["schedule_time"] is None and job["visibility_type"] == 0
    assert chrome.authorize(job, schedule_time=1793367000).json()["reason"] == "schedule-mismatch"
    assert chrome.authorize(job).json() == {"ok": True}


def test_expired_schedule_fails_definitely_at_dispatch(engine, app, video_file):
    aid = chrome_account(engine)
    when = (datetime.now(timezone.utc) + timedelta(minutes=4)).isoformat()  # < 15 - 10 min ahead
    sid = schedule(engine, aid, options={"schedule_mode": "native", "tiktok_schedule_time": when})
    worker.tick()
    row = parent(engine, sid)
    assert row.status == "failed" and not row.publish_uncertain and children(engine) == []


@pytest.mark.parametrize("outcome,extra,state,status,uncertain", [
    ("rejected", {"status_code": 5, "status_msg": "bad"}, "rejected", "failed", False),
    ("uncertain", {"reason": "xhr-timeout"}, "uncertain", "failed", True),
    ("failed", {"reason": "error-after-send"}, "uncertain", "failed", True),  # authorized: maybe sent
    ("failed", {"not_sent": True, "reason": "blocked-by-hook"}, "failed", "failed", False),
])
def test_result_mapping_after_authorization(engine, app, video_file, outcome, extra, state, status, uncertain):
    aid = chrome_account(engine)
    chrome = Chrome(app, "alice", UID_A)
    sid = schedule(engine, aid)
    job = dispatched(engine, app, chrome, sid)
    chrome.authorize(job)
    assert chrome.post("result", job, outcome=outcome, **extra).json()["state"] == state
    row = parent(engine, sid)
    assert row.status == status and row.publish_uncertain is uncertain


def test_failure_before_authorization_is_definite(engine, app, video_file):
    aid = chrome_account(engine)
    chrome = Chrome(app, "alice", UID_A)
    sid = schedule(engine, aid)
    job = dispatched(engine, app, chrome, sid)
    chrome.post("result", job, outcome="failed", reason="identity-mismatch")
    row = parent(engine, sid)
    assert row.status == "failed" and not row.publish_uncertain and "identity-mismatch" in row.result_text


def test_waiting_ext_cannot_be_deleted_and_pending_ext_can_be_cancelled(engine, app, video_file):
    aid = chrome_account(engine)
    Chrome(app, "alice", UID_A)
    first, second = schedule(engine, aid, when_offset=-20), schedule(engine, aid, when_offset=-10)
    worker.tick()
    worker.tick()
    assert app.delete(f"/api/schedules/{first}").status_code == 409
    assert app.patch(f"/api/schedules/{second}", json={"status": "cancelled"}).json()["status"] == "cancelled"


# ---------- pairing, auth, CORS ----------

def test_pair_code_single_use_and_burnt_after_five_wrong_tries(engine, app):
    code = app.post("/api/ext/pair-code").json()["code"]
    wrong = "000000" if code != "000000" else "111111"
    for left in (4, 3, 2, 1):
        r = app.post("/api/ext/pair", json={"code": wrong, "protocol": 1})
        assert r.status_code == 403 and r.json()["tries_left"] == left
    assert app.post("/api/ext/pair", json={"code": wrong, "protocol": 1}).status_code == 410
    assert app.post("/api/ext/pair", json={"code": code, "protocol": 1}).status_code == 410  # burnt
    code = app.post("/api/ext/pair-code").json()["code"]
    r = app.post("/api/ext/pair", json={"code": code, "protocol": 1})
    assert r.status_code == 200
    token = r.json()["token"]
    assert app.post("/api/ext/pair", json={"code": code, "protocol": 1}).status_code == 410  # single use
    with Session(api_db.engine) as s:
        stored = s.exec(select(ExtensionClient)).all()
    assert [c.token_hash for c in stored] == [ext.token_hash(token)] and token not in stored[0].token_hash


def test_pair_code_expires_after_five_minutes(engine, app, clock):
    code = app.post("/api/ext/pair-code").json()["code"]
    clock["offset"] = timedelta(minutes=5, seconds=1)
    assert app.post("/api/ext/pair", json={"code": code, "protocol": 1}).status_code == 410


def test_bearer_required_and_removed_client_is_locked_out(engine, app):
    assert app.get("/api/ext/next").status_code == 401
    assert app.get("/api/ext/next", headers={"Authorization": "Bearer nope"}).json()["error"] == "unauthorized"
    chrome = Chrome(app, "alice", UID_A)
    assert app.delete(f"/api/ext/clients/{chrome.client_id}").status_code == 204
    assert chrome.next().status_code == 401


def test_cors_only_for_extension_origin_and_not_for_gui_endpoints(engine, app):
    pre = {"Origin": ORIGIN, "Access-Control-Request-Method": "POST",
           "Access-Control-Request-Headers": "authorization,content-type"}
    r = app.options("/api/ext/result", headers=pre)
    assert r.status_code == 204 and r.headers["access-control-allow-origin"] == ORIGIN
    assert "access-control-allow-origin" not in app.options("/api/ext/pair-code", headers=pre).headers
    evil = dict(pre, Origin="https://evil.example")
    assert "access-control-allow-origin" not in app.options("/api/ext/result", headers=evil).headers
    assert app.post("/api/ext/pair-code", headers={"Origin": ORIGIN}).status_code == 403
    assert app.get("/api/ext/clients", headers={"Origin": "https://evil.example"}).status_code == 403


def test_identity_conflict_blocks_jobs(engine, app, video_file):
    aid = chrome_account(engine)
    c1, c2 = Chrome(app, "alice", UID_A), Chrome(app, "alice", UID_A)
    schedule(engine, aid)
    worker.tick()
    assert c1.next().json()["error"] == "identity_conflict"
    assert c2.next().json()["error"] == "identity_conflict"
    assert app.get(f"/api/accounts/{aid}").json()["ready_reason"] == "chrome_conflict"
    app.delete(f"/api/ext/clients/{c2.client_id}")
    assert c1.next().status_code == 200


def test_bad_nonce_and_unknown_job(engine, app, video_file):
    aid = chrome_account(engine)
    chrome = Chrome(app, "alice", UID_A)
    job = dispatched(engine, app, chrome, schedule(engine, aid))
    assert chrome.post("result", dict(job, nonce="x"), outcome="posted").status_code == 403
    assert chrome.post("result", dict(job, claim_token=None), outcome="posted").status_code == 403
    assert chrome.post("result", dict(job, id="ej_missing"), outcome="posted").status_code == 404


def test_cookie_accounts_unchanged(engine, app, saved_account, video_file, cookie_calls):
    aid = app.post("/api/accounts", json={"username": "alice"}).json()["id"]
    acct = app.get(f"/api/accounts/{aid}").json()
    assert acct["publisher"] == "cookies" and acct["ready"] is True and acct["ready_reason"] == "ok"
    sid = schedule(engine, aid)
    worker.tick()
    assert cookie_calls == ["alice"] and parent(engine, sid).status == "succeeded" and children(engine) == []
    assert app.get("/health").json()["chrome_ext"] == 1


def _ready_child(engine, app, chrome, aid):
    sid = schedule(engine, aid)
    wire = dispatched(engine, app, chrome, sid)
    with Session(engine) as s:
        return sid, s.get(ExtensionJob, wire["id"])


def test_authorize_update_itself_refuses_a_revoked_child(engine, app, video_file):
    """The race: the router's pre-check passed, then a revoke landed before the UPDATE."""
    aid = chrome_account(engine)
    chrome = Chrome(app, "alice", UID_A)
    sid, job = _ready_child(engine, app, chrome, aid)
    assert ext.revoke(job.id, "timeout") is True
    assert ext.authorize(job, SHA, "cid") is False
    assert children(engine, sid)[0].state == "revoked"


def test_authorize_update_itself_refuses_a_superseded_attempt(engine, app, video_file):
    aid = chrome_account(engine)
    chrome = Chrome(app, "alice", UID_A)
    sid, job = _ready_child(engine, app, chrome, aid)
    with Session(engine) as s:  # a newer attempt took the parent meanwhile
        row = s.get(ScheduledUpload, sid)
        row.attempts += 1
        s.add(row)
        s.commit()
    assert ext.authorize(job, SHA, "cid") is False
    with Session(engine) as s:
        row = s.get(ScheduledUpload, sid)
        row.attempts -= 1
        row.status = "failed"  # parent no longer waiting for this child
        s.add(row)
        s.commit()
    assert ext.authorize(job, SHA, "cid") is False
    assert children(engine, sid)[0].state == "ready"


def test_hello_without_identity_gets_no_work_and_is_visible(engine, app, video_file, caplog):
    aid = chrome_account(engine)
    chrome = Chrome(app, "alice", None)
    schedule(engine, aid)
    worker.tick()
    r = chrome.next()
    assert r.status_code == 409 and r.json()["error"] == "no_identity"
    c = app.get("/api/ext/clients").json()[0]
    assert c["status"] == "no_identity" and c["has_identity"] is False
    assert any("without TikTok identity" in m for m in caplog.messages)
    assert children(engine)[0].state == "queued"  # still nobody's


def test_release_claim_hands_an_undelivered_job_back_only_while_still_claimed(engine, app, video_file):
    aid = chrome_account(engine)
    chrome = Chrome(app, "alice", UID_A)
    sid = schedule(engine, aid)
    worker.tick()
    wire = chrome.next().json()
    with Session(engine) as s:
        job = s.get(ExtensionJob, wire["id"])
    assert ext.release_claim(job) is True
    assert children(engine, sid)[0].state == "queued" and children(engine, sid)[0].claim_client is None
    again = chrome.next().json()
    assert again["id"] == wire["id"] and again["claim_token"] != wire["claim_token"]
    assert chrome.ready(again).json()["state"] == "ready"
    with Session(engine) as s:
        job = s.get(ExtensionJob, wire["id"])
    assert ext.release_claim(job) is False  # past 'claimed': never handed back
