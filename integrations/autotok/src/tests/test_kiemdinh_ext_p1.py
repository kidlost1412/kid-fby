"""Independent QA (kiem-dinh) breaking tests for the Chrome publisher P1 backend.

Written from the owner's requirements and PROTOCOL.md, not from the implementation:
  * never post twice; never report "not sent" after authorization;
  * rollback to v3.1.0 never posts Chrome jobs through cookies;
  * Host / CSRF guards hold for every route (errors, streaming, long poll);
  * CORS only for the extension origin, never for GUI-only endpoints;
  * pairing cannot be brute-forced; reconcile is idempotent; per-account serialization holds under concurrency.
Nothing here contacts TikTok.
"""
import json
import sqlite3
import threading
from datetime import timedelta

import pytest
from sqlmodel import Session, select

from api.models import ExtensionJob, ScheduledUpload, UploadHistory
from api.services import ext
from scheduler import worker
from tests.test_chrome_ext import (  # noqa: F401  (fixtures)
    ORIGIN, UID_A, UID_B, Chrome, app, children, chrome_account, clock, cookie_calls, dispatched, engine,
    history, parent, schedule,
)
from tests.test_ext_migration import home, new_init, old_src, q, run_old  # noqa: F401  (fixtures)

POST_ID = "7701245450858351893"


# ---------- never post twice: a late success of attempt N must stop attempt N+1 before it is sent ----------

def test_late_success_of_old_attempt_blocks_the_not_yet_authorized_retry(engine, app, clock, video_file):
    """Owner retried an 'uncertain' Chrome job (confirmed it was not on TikTok yet). Attempt 2 is queued and
    Chrome has NOT been authorized for it. Then attempt 1's late 'posted' arrives with a post id. The backend now
    KNOWS the video is on TikTok; granting attempt 2 would post it a second time."""
    aid = chrome_account(engine)
    chrome = Chrome(app, "alice", UID_A)
    sid = schedule(engine, aid)
    job1 = dispatched(engine, app, chrome, sid)
    assert chrome.authorize(job1).json() == {"ok": True}
    clock["offset"] = timedelta(minutes=4)
    ext.reconcile_ext()  # attempt 1 -> uncertain
    clock["offset"] = timedelta(0)
    assert app.patch(f"/api/schedules/{sid}", json={"status": "pending", "confirm_uncertain": True}).status_code == 200
    worker.tick()  # attempt 2 child queued
    assert parent(engine, sid).attempts == 2
    r = chrome.post("result", job1, outcome="posted", status_code=0, item_id=POST_ID)
    assert r.status_code == 200
    # Chrome now picks attempt 2 (if it still exists) and asks for authorization.
    nxt = chrome.next()
    if nxt.status_code == 204:
        return  # attempt 2 was withdrawn: fine
    job2 = nxt.json()
    chrome.ready(job2)
    granted = chrome.authorize(job2).json()
    assert granted.get("ok") is not True, "attempt 2 authorized although attempt 1 is known to be posted (double post)"


# ---------- rollback to v3.1.0 ----------

def test_rollback_v31_never_posts_a_chrome_accounts_due_job_through_cookies(old_src, home):
    """A converted account (publisher='chrome', its old cookie file still there) has a due job that the new
    backend has not claimed yet (status 'pending'). After rolling back to v3.1.0 the old scheduler must not post
    it through cookies."""
    db = home / "tiktok.db"
    (home / "v" / "clip.mp4").write_bytes(b"\x00\x00\x00\x18ftypmp42" + b"x" * 100)
    new_init(db)
    con = sqlite3.connect(db)
    con.execute("INSERT INTO accounts (id, username, cookie_path, has_valid_session, created_at, updated_at, publisher,"
                " chrome_user_id) VALUES (1, 'alice', 'C:/x/alice.cookie', 1, '2026-10-27 00:00:00',"
                " '2026-10-27 00:00:00', 'chrome', '7000000000000000001')")
    con.execute("INSERT INTO scheduled_uploads (id, account_id, source_type, source_ref, title, options_json,"
                " scheduled_for, status, publish_uncertain, attempts, created_at, updated_at) VALUES"
                " (1, 1, 'local', 'clip.mp4', 't', '{\"schedule_mode\": \"now\"}', '2020-01-01 00:00:00',"
                " 'pending', 0, 0, '2026-10-27 00:00:00', '2026-10-27 00:00:00')")
    con.commit()
    con.close()
    out = run_old(old_src, db, home, r"""
import json
import api.db as db
from api.services import tiktok_adapter
from api.services.tiktok_adapter import UploadOutcome
from scheduler import worker
calls = []
def fake(*a, **k):
    calls.append(a[0])
    return UploadOutcome(ok=True, message="published", video_id="cookie")
tiktok_adapter.upload_from_options = fake
db.init_db()
for _ in range(3):
    worker.tick()
print(json.dumps(calls))
""")
    assert json.loads(out.strip().splitlines()[-1]) == [], "v3.1.0 posted a Chrome account's job with cookies"


# ---------- Host / CSRF guards on every kind of route ----------

@pytest.mark.parametrize("method,path", [
    ("get", "/api/ext/next?wait=0"),
    ("get", "/api/ext/video?id=ej_x"),
    ("get", "/api/ext/video/meta?id=ej_x"),
    ("get", "/api/ext/job_state?id=ej_x"),
    ("get", "/api/ext/clients"),
    ("get", "/api/does-not-exist"),
    ("get", "/api/accounts"),
    ("get", "/health"),
])
def test_unknown_host_is_refused_everywhere(engine, app, method, path):
    r = getattr(app, method)(path, headers={"Host": "evil.example"})
    assert r.status_code == 403 and "Host" in r.text


def test_unknown_host_is_refused_even_with_a_valid_bearer_and_extension_origin(engine, app, video_file):
    aid = chrome_account(engine)
    chrome = Chrome(app, "alice", UID_A)
    sid = schedule(engine, aid)
    worker.tick()
    r = app.get("/api/ext/next?wait=0", headers={**chrome.h(), "Host": "evil.example", "Origin": ORIGIN})
    assert r.status_code == 403
    assert children(engine, sid)[0].state == "queued"  # nothing claimed behind the refusal


@pytest.mark.parametrize("path", ["/api/ext/pair", "/api/ext/hello", "/api/ext/result", "/api/ext/authorize",
                                  "/api/ext/progress", "/api/ext/cancel", "/api/ext/pair-code",
                                  "/api/accounts/from-chrome", "/api/ext/nope"])
def test_post_without_csrf_header_is_refused(engine, app, path):
    from fastapi.testclient import TestClient
    from api.main import create_app
    with TestClient(create_app(), base_url="http://127.0.0.1") as raw:  # no X-Requested-With
        r = raw.post(path, json={})
    assert r.status_code == 403 and "X-Requested-With" in r.text


def test_streaming_video_refused_without_known_host_even_for_claimer(engine, app, video_file):
    aid = chrome_account(engine)
    chrome = Chrome(app, "alice", UID_A)
    sid = schedule(engine, aid)
    job = dispatched(engine, app, chrome, sid)
    ok = app.get(f"/api/ext/video?id={job['id']}", headers=chrome.h())
    assert ok.status_code == 200 and ok.content == video_file.read_bytes()
    bad = app.get(f"/api/ext/video?id={job['id']}", headers={**chrome.h(), "Host": "rebind.evil"})
    assert bad.status_code == 403 and bad.content != video_file.read_bytes()


# ---------- CORS ----------

def test_cors_never_granted_to_other_origins_or_non_ext_routes(engine, app):
    for origin in ("https://evil.example", "chrome-extension://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "null"):
        r = app.options("/api/ext/hello", headers={"Origin": origin, "Access-Control-Request-Method": "POST"})
        assert "access-control-allow-origin" not in {k.lower() for k in r.headers}, origin
    for path in ("/api/accounts", "/api/schedules", "/api/accounts/from-chrome", "/api/ext/clients/1",
                 "/api/ext/pair-code"):
        r = app.options(path, headers={"Origin": ORIGIN, "Access-Control-Request-Method": "POST"})
        assert "access-control-allow-origin" not in {k.lower() for k in r.headers}, path


def test_gui_only_endpoints_refuse_the_extension_origin(engine, app):
    chrome = Chrome(app, "alice", UID_A)
    for method, path in (("post", "/api/ext/pair-code"), ("get", "/api/ext/clients"),
                         ("delete", f"/api/ext/clients/{chrome.client_id}")):
        r = getattr(app, method)(path, headers={"Origin": ORIGIN})
        assert r.status_code == 403, (path, r.status_code)
    assert app.post("/api/ext/hello", headers=chrome.h(), json={"protocol": 1, "identity": None}).status_code == 200


# ---------- pairing brute force ----------

def test_pairing_cannot_be_brute_forced_concurrently(engine, app):
    code = app.post("/api/ext/pair-code").json()["code"]
    wrong = [f"{(int(code) + i) % 10**6:06d}" for i in range(1, 41)]
    results = []
    lock = threading.Lock()

    def guess(c):
        r = app.post("/api/ext/pair", json={"code": c, "label": "x", "ext_version": "1", "protocol": 1})
        with lock:
            results.append(r.status_code)

    ts = [threading.Thread(target=guess, args=(c,)) for c in wrong]
    for t in ts:
        t.start()
    for t in ts:
        t.join()
    assert results.count(403) <= 4 and 200 not in results
    r = app.post("/api/ext/pair", json={"code": code, "label": "x", "ext_version": "1", "protocol": 1})
    assert r.status_code == 410  # burnt: the real code no longer works after 5 wrong tries


def test_pair_code_type_confusion_does_not_pair(engine, app):
    code = app.post("/api/ext/pair-code").json()["code"]
    for bad in (None, [], {"code": code}, code + " ", " " + code, int(code) + 1):
        r = app.post("/api/ext/pair", json={"code": bad, "label": "x", "ext_version": "1", "protocol": 1})
        assert r.status_code != 200, bad


# ---------- reconcile idempotency ----------

def test_reconcile_is_idempotent_and_finalizes_history_once(engine, app, video_file):
    aid = chrome_account(engine)
    chrome = Chrome(app, "alice", UID_A)
    sid = schedule(engine, aid)
    job = dispatched(engine, app, chrome, sid)
    assert chrome.authorize(job).json() == {"ok": True}
    chrome.post("result", job, outcome="posted", status_code=0, item_id=POST_ID)
    first = history(engine, sid)
    snap = (first.status, first.post_id, first.result_text, first.finished_at, first.accepted_at)
    for _ in range(5):
        ext.reconcile_ext()
        worker.tick()
    again = history(engine, sid)
    assert (again.status, again.post_id, again.result_text, again.finished_at, again.accepted_at) == snap
    assert parent(engine, sid).status == "succeeded" and parent(engine, sid).attempts == 1
    with Session(engine) as s:
        assert len(s.exec(select(UploadHistory)).all()) == 1


def test_late_success_note_is_not_appended_twice_on_repeated_reconcile(engine, app, clock, video_file):
    aid = chrome_account(engine)
    chrome = Chrome(app, "alice", UID_A)
    sid = schedule(engine, aid)
    job = dispatched(engine, app, chrome, sid)
    chrome.authorize(job)
    clock["offset"] = timedelta(minutes=4)
    ext.reconcile_ext()
    clock["offset"] = timedelta(0)
    app.patch(f"/api/schedules/{sid}", json={"status": "pending", "confirm_uncertain": True})
    worker.tick()  # attempt 2 owns the parent
    chrome.post("result", job, outcome="posted", status_code=0, item_id=POST_ID)
    text = history(engine, sid).result_text
    for _ in range(4):
        ext.reconcile_ext()
    assert history(engine, sid).result_text == text
    assert text.count("late success of attempt 1") == 1


def test_authorized_job_never_ends_definite_failed_without_not_sent(engine, app, video_file):
    """After authorization only an explicit not_sent=true may produce a definite 'not sent'."""
    aid = chrome_account(engine)
    chrome = Chrome(app, "alice", UID_A)
    for i, body in enumerate(({"outcome": "failed"}, {"outcome": "failed", "not_sent": "true"},
                              {"outcome": "failed", "not_sent": 1}, {"outcome": ""}, {"outcome": "Posted"},
                              {"outcome": "revoked"})):
        sid = schedule(engine, aid, title=f"t{i}")
        job = dispatched(engine, app, chrome, sid)
        assert chrome.authorize(job).json() == {"ok": True}
        chrome.post("result", job, **body)
        row = parent(engine, sid)
        assert row.status == "failed" and row.publish_uncertain is True, (body, row.status, row.publish_uncertain)


def test_cancel_after_authorize_never_reports_not_sent(engine, app, clock, video_file):
    aid = chrome_account(engine)
    chrome = Chrome(app, "alice", UID_A)
    sid = schedule(engine, aid)
    job = dispatched(engine, app, chrome, sid)
    assert chrome.authorize(job).json() == {"ok": True}
    r = chrome.post("cancel", job, reason="user closed tab")
    assert r.json()["state"] == "authorized"
    clock["offset"] = timedelta(minutes=20)  # every pre-authorization deadline long gone
    ext.reconcile_ext()
    row = parent(engine, sid)
    assert row.status == "failed" and row.publish_uncertain is True
    assert children(engine, sid)[0].state == "uncertain"


# ---------- per-account serialization under concurrency ----------

def test_concurrent_reconcile_creates_one_active_child_per_account_fifo(engine, app, video_file):
    aid = chrome_account(engine)
    other = chrome_account(engine, username="bob", user_id=UID_B)
    sids = [schedule(engine, aid, title=f"a{i}", when_offset=-100 + i) for i in range(4)]
    sid_b = schedule(engine, other, title="b0", when_offset=-50)
    for _ in range(6):
        worker.tick()  # every due row: running -> pending_ext (first one maybe waiting_ext)
    errors = []
    barrier = threading.Barrier(8)

    def run():
        try:
            barrier.wait()
            ext.reconcile_ext()
        except Exception as exc:  # pragma: no cover - reported below
            errors.append(exc)

    ts = [threading.Thread(target=run) for _ in range(8)]
    for t in ts:
        t.start()
    for t in ts:
        t.join()
    assert errors == []
    with Session(engine) as s:
        active = s.exec(select(ExtensionJob).where(ExtensionJob.state.not_in(ext.EXT_TERMINAL))).all()
    by_acct = {}
    for j in active:
        by_acct.setdefault(j.account_id, []).append(j.schedule_id)
    assert by_acct == {aid: [sids[0]], other: [sid_b]}
    assert [parent(engine, s_).status for s_ in sids] == ["waiting_ext", "pending_ext", "pending_ext", "pending_ext"]


def test_concurrent_result_and_deadline_never_lose_the_post_id(engine, app, clock, video_file):
    aid = chrome_account(engine)
    chrome = Chrome(app, "alice", UID_A)
    for round_ in range(8):
        sid = schedule(engine, aid, title=f"r{round_}")
        job = dispatched(engine, app, chrome, sid)
        assert chrome.authorize(job).json() == {"ok": True}
        clock["offset"] = timedelta(seconds=181)
        barrier = threading.Barrier(2)
        out = {}

        def res():
            barrier.wait()
            out["r"] = chrome.post("result", job, outcome="posted", status_code=0, item_id=POST_ID).status_code

        def rec():
            barrier.wait()
            ext.reconcile_ext()

        ts = [threading.Thread(target=res), threading.Thread(target=rec)]
        for t in ts:
            t.start()
        for t in ts:
            t.join()
        ext.reconcile_ext()
        clock["offset"] = timedelta(0)
        assert out["r"] == 200
        row = parent(engine, sid)
        assert row.status == "succeeded", (round_, row.status, row.result_text)
        assert history(engine, sid).post_id == POST_ID


# ---------- identity / binding ----------

def test_claim_token_of_one_profile_cannot_authorize_from_another_tiktok_user(engine, app, video_file):
    aid = chrome_account(engine)
    alice = Chrome(app, "alice", UID_A)
    mallory = Chrome(app, "bob", UID_B)
    sid = schedule(engine, aid)
    job = dispatched(engine, app, alice, sid)
    r = mallory.authorize(job)
    assert r.json().get("ok") is not True
    assert children(engine, sid)[0].state == "ready"


def test_switching_tiktok_login_mid_job_refuses_authorize(engine, app, video_file):
    aid = chrome_account(engine)
    chrome = Chrome(app, "alice", UID_A)
    sid = schedule(engine, aid)
    job = dispatched(engine, app, chrome, sid)
    chrome.hello("bob", UID_B)  # the profile logged into another TikTok account
    r = chrome.authorize(job)  # even if the extension lies in the body identity
    assert r.json() == {"ok": False, "reason": "identity-mismatch"}


def test_removed_client_cannot_claim_but_its_authorized_result_is_still_accepted(engine, app, video_file):
    aid = chrome_account(engine)
    chrome = Chrome(app, "alice", UID_A)
    sid = schedule(engine, aid)
    job = dispatched(engine, app, chrome, sid)
    assert chrome.authorize(job).json() == {"ok": True}
    assert app.delete(f"/api/ext/clients/{chrome.client_id}").status_code == 204
    assert chrome.post("result", job, outcome="posted", item_id=POST_ID).status_code == 401
    other = Chrome(app, "alice", UID_A)  # re-paired profile, same TikTok user
    r = other.post("result", job, outcome="posted", status_code=0, item_id=POST_ID)
    assert r.status_code == 200 and r.json()["state"] == "posted"
    assert parent(engine, sid).status == "succeeded"
