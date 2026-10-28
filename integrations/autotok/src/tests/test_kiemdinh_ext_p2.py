"""Independent QA (kiem-dinh) round 2: fix1 (late success / pending_ext / trigger), fix2 (auto-launch), schema v5.

Written from the owner's requirements before reading the coder's tests:
  * never post twice; a job that is known to be on TikTok must not be posted again;
  * rollback to v3.1.0 never posts a Chrome job through cookies AND keeps posting the other accounts;
  * the DB trigger never blocks the cookie path, cancels or deletes;
  * Chrome is opened at most once per profile per window, across threads and processes, never when online,
    never with a profile name that can smuggle extra switches.
Nothing here contacts TikTok or starts a real Chrome (conftest replaces ext.launcher; subprocesses replace it too).
"""
import ctypes
import json
import os
import sqlite3
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest
from sqlmodel import Session, select

from api.models import ExtensionClient, ExtensionJob
from api.services import ext
from scheduler import worker
from tests.test_chrome_ext import (  # noqa: F401  (fixtures)
    UID_A, Chrome, app, children, chrome_account, clock, cookie_calls, dispatched, engine, history, parent, schedule,
)
from tests.test_ext_migration import home, new_init, old_src, q, run_old  # noqa: F401  (fixtures)

POST_ID = "7701245450858351893"
SRC = Path(__file__).resolve().parents[1]


# ---------- never post twice ----------

def test_late_success_after_the_retry_failed_unsent_is_not_shown_as_not_posted(engine, app, clock, video_file):
    """Attempt 1 authorized then 'uncertain'. The owner retries; attempt 2 is never claimed (Chrome closed) and fails
    definitely ('not sent'). Then attempt 1's late 'posted' arrives with a post id. The video IS on TikTok: the job
    must not stay as a plain 'failed, nothing sent' (an invitation to post it again). The confirm_uncertain guard on
    retry is kept as is: the owner may have deleted the post and want to repost."""
    aid = chrome_account(engine)
    chrome = Chrome(app, "alice", UID_A)
    sid = schedule(engine, aid)
    job1 = dispatched(engine, app, chrome, sid)
    assert chrome.authorize(job1).json() == {"ok": True}
    clock["offset"] = timedelta(minutes=4)
    ext.reconcile_ext()  # attempt 1 -> uncertain
    assert parent(engine, sid).publish_uncertain is True
    clock["offset"] = timedelta(0)
    assert app.patch(f"/api/schedules/{sid}", json={"status": "pending", "confirm_uncertain": True}).status_code == 200
    worker.tick()
    assert parent(engine, sid).attempts == 2 and children(engine, sid)[-1].state == "queued"
    clock["offset"] = timedelta(seconds=200)  # attempt 2 never claimed (even counting a launch: 180 s)
    ext.reconcile_ext()
    row = parent(engine, sid)
    assert row.status == "failed" and row.publish_uncertain is False  # attempt 2: definitely not sent
    clock["offset"] = timedelta(0)
    assert chrome.post("result", job1, outcome="posted", status_code=0, item_id=POST_ID).status_code == 200
    assert history(engine, sid).post_id == POST_ID
    row, entry = parent(engine, sid), history(engine, sid)
    # What the owner sees: the job must not read "failed - not posted" for a video that is on TikTok.
    assert not (row.status == "failed" and not row.publish_uncertain), (row.status, ascii(row.result_text))
    assert entry.status != "failed" or entry.publish_uncertain, (entry.status, ascii(entry.result_text))


# ---------- the trigger never blocks legitimate paths ----------

def test_account_switched_back_to_cookies_posts_through_cookies(engine, app, saved_account, video_file, cookie_calls):
    aid = app.post("/api/accounts", json={"username": "alice"}).json()["id"]
    chrome = Chrome(app, "alice", UID_A)
    assert app.patch(f"/api/accounts/{aid}", json={"publisher": "chrome", "client_id": chrome.client_id}).status_code == 200
    assert app.patch(f"/api/accounts/{aid}", json={"publisher": "cookies"}).status_code == 200
    when = (datetime.now(timezone.utc) + timedelta(hours=1)).isoformat()
    r = app.post("/api/schedules", json={"username": "alice", "title": "t", "source_type": "local",
                                          "source_ref": "clip.mp4", "scheduled_for": when})
    assert r.status_code == 201 and r.json()["status"] == "pending", r.text
    con = sqlite3.connect(engine.url.database)
    con.execute("UPDATE scheduled_uploads SET scheduled_for='2020-01-01 00:00:00' WHERE id=?", (r.json()["id"],))
    con.commit()
    con.close()
    worker.tick()
    assert cookie_calls == ["alice"]
    assert parent(engine, r.json()["id"]).status == "succeeded"


def test_cancel_and_delete_of_chrome_jobs_are_not_blocked(engine, app, video_file):
    aid = chrome_account(engine)
    Chrome(app, "alice", UID_A)
    a = schedule(engine, aid, when_offset=3600)
    b = schedule(engine, aid, title="b", when_offset=3600)
    worker.tick()
    assert parent(engine, a).status == "pending_ext"
    assert app.patch(f"/api/schedules/{a}", json={"status": "cancelled"}).status_code == 200
    assert parent(engine, a).status == "cancelled"
    assert app.delete(f"/api/schedules/{b}").status_code in (200, 204)
    assert parent(engine, b) is None


def _chrome_and_cookie_rows_behave(db):
    """Raw SQL as any version (v3.1.0 included) would write it, on the database file `db`.
    Chrome account: never 'running', a 'pending' row is turned into 'pending_ext'. Cookie account: untouched."""
    con = sqlite3.connect(db)
    try:
        con.execute("INSERT INTO accounts (id, username, cookie_path, has_valid_session, created_at, updated_at,"
                    " publisher) VALUES (901, 'kd.chrome', '', 0, '2026-10-27 00:00:00', '2026-10-27 00:00:00',"
                    " 'chrome'), (902, 'kd.cookie', 'C:/x/c.cookie', 1, '2026-10-27 00:00:00',"
                    " '2026-10-27 00:00:00', 'cookies')")
        for sid, acct in ((901, 901), (902, 902)):
            con.execute("INSERT INTO scheduled_uploads (id, account_id, source_type, source_ref, title, options_json,"
                        " scheduled_for, status, publish_uncertain, attempts, created_at, updated_at) VALUES"
                        f" ({sid}, {acct}, 'local', 'clip.mp4', 't', '{{}}', '2020-01-01 00:00:00', 'pending', 0, 0,"
                        " '2026-10-27 00:00:00', '2026-10-27 00:00:00')")
        con.commit()
        st = lambda: dict(con.execute("SELECT id, status FROM scheduled_uploads WHERE id IN (901, 902)").fetchall())
        assert st() == {901: "pending_ext", 902: "pending"}  # insert: Chrome normalised, cookie untouched
        con.execute("UPDATE scheduled_uploads SET status='failed' WHERE id=901")
        con.execute("UPDATE scheduled_uploads SET status='pending' WHERE id IN (901, 902)")  # a retry, old style
        con.commit()
        assert st() == {901: "pending_ext", 902: "pending"}
        for sid in (901, 902):
            con.execute("UPDATE scheduled_uploads SET status='running', attempts=attempts+1 WHERE id=?", (sid,))
        con.commit()
        assert st() == {901: "pending_ext", 902: "running"}  # the claim is refused only for Chrome
        assert con.execute("SELECT attempts FROM scheduled_uploads WHERE id=901").fetchone()[0] == 0
        con.execute("UPDATE scheduled_uploads SET status='cancelled' WHERE id=901")  # other statuses: never blocked
        con.execute("UPDATE scheduled_uploads SET status='pending' WHERE id=902")
        con.commit()
        assert st() == {901: "cancelled", 902: "pending"}
        con.execute("DELETE FROM scheduled_uploads WHERE id IN (901, 902)")
        con.commit()
        assert st() == {}
    finally:
        con.close()


def test_chrome_rows_never_run_and_never_stay_pending_cookie_rows_untouched(engine, app):
    _chrome_and_cookie_rows_behave(engine.url.database)


# ---------- schema / rollback ----------

def test_v4_database_from_the_p1_build_gets_the_chrome_job_guards(tmp_path):
    """The owner's test copy is v4 from the first P1 build: no trigger. Upgrading it to v5 must add the
    guards, or a rollback from that copy can still post a Chrome job through cookies (or stall v3.1.0)."""
    db = tmp_path / "v4.db"
    new_init(db)
    con = sqlite3.connect(db)
    for (name,) in con.execute("SELECT name FROM sqlite_master WHERE type='trigger'").fetchall():
        con.execute(f"DROP TRIGGER {name}")  # the P1 build had none
    for table, col in (("extension_clients", "chrome_profile_dir"), ("extension_clients", "last_launch_at"),
                       ("extension_jobs", "launched_at")):
        con.execute(f"ALTER TABLE {table} DROP COLUMN {col}")
    con.execute("PRAGMA user_version = 4")
    con.commit()
    con.close()
    new_init(db)
    assert q(db, "PRAGMA user_version") == [(5,)]
    assert ("tr_chrome_job_never_running",) in q(db, "SELECT name FROM sqlite_master WHERE type='trigger'")
    _chrome_and_cookie_rows_behave(db)


def test_rollback_v31_a_chrome_row_in_pending_does_not_starve_other_accounts(old_src, home):
    """After a rollback, v3.1.0 still lists the Chrome account and the owner schedules a video for it (v3.1.0 knows
    no publisher, so the row is 'pending'). The trigger keeps it off the cookie path - but v3.1.0 always picks the
    oldest due 'pending' row first, so every later job of every other account must still be posted."""
    db = home / "tiktok.db"
    (home / "v" / "clip.mp4").write_bytes(b"\x00\x00\x00\x18ftypmp42" + b"x" * 100)
    new_init(db)
    con = sqlite3.connect(db)
    con.execute("INSERT INTO accounts (id, username, cookie_path, has_valid_session, created_at, updated_at, publisher,"
                " chrome_user_id) VALUES (1, 'alice', 'C:/x/alice.cookie', 1, '2026-10-27 00:00:00',"
                " '2026-10-27 00:00:00', 'chrome', '7000000000000000001')")
    con.execute("INSERT INTO accounts (id, username, cookie_path, has_valid_session, created_at, updated_at, publisher)"
                " VALUES (2, 'bob', 'C:/x/bob.cookie', 1, '2026-10-27 00:00:00', '2026-10-27 00:00:00', 'cookies')")
    for sid, acct, when in ((1, 1, "2020-01-01 00:00:00"), (2, 2, "2020-01-02 00:00:00")):
        con.execute("INSERT INTO scheduled_uploads (id, account_id, source_type, source_ref, title, options_json,"
                    " scheduled_for, status, publish_uncertain, attempts, created_at, updated_at) VALUES"
                    f" ({sid}, {acct}, 'local', 'clip.mp4', 't', '{{\"schedule_mode\": \"now\"}}', '{when}',"
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
for _ in range(5):
    worker.tick()
print(json.dumps(calls))
""")
    calls = json.loads(out.strip().splitlines()[-1])
    assert "alice" not in calls  # the Chrome job never went through cookies
    assert calls == ["bob"], f"v3.1.0 never reached bob's due job behind the blocked Chrome row: {calls}"


# ---------- opening Chrome ----------

@pytest.fixture
def fake_chrome(tmp_path, monkeypatch):
    exe = tmp_path / "Chrome x" / "chrome.exe"
    exe.parent.mkdir()
    exe.write_bytes(b"")
    monkeypatch.setenv("AUTOTOK_BROWSER_PATH", str(exe))
    monkeypatch.delenv("AUTOTOK_CHROME_LAUNCH", raising=False)
    return str(exe)


def _offline(engine, client_id, profile_dir="Profile 1"):
    with Session(engine) as s:
        c = s.get(ExtensionClient, client_id)
        c.last_seen_at = datetime.now(timezone.utc) - timedelta(minutes=10)
        c.chrome_profile_dir = profile_dir
        s.add(c)
        s.commit()


CHILD = r"""
import json, sys, time
from datetime import datetime, timezone
import api.db as db
from api.services import ext
out = sys.argv[1]
def rec(exe, profile):
    with open(out, "a", encoding="utf-8") as f:
        f.write(json.dumps([exe, profile]) + "\n")
    return True
ext.launcher = rec
start = float(sys.argv[2])
while time.time() < start:
    time.sleep(0.005)
ext.reconcile_ext()
"""


def test_two_processes_open_chrome_once(engine, app, video_file, fake_chrome, tmp_path):
    """The API and the scheduler are separate processes on the same database: only one may open Chrome."""
    import time
    aid = chrome_account(engine)
    chrome = Chrome(app, "alice", UID_A)
    _offline(engine, chrome.client_id)
    schedule(engine, aid)
    ext._promote(datetime.now(timezone.utc))
    out = tmp_path / "launches.txt"
    env = dict(os.environ, TIKTOK_API_DB_PATH=str(engine.url.database), AUTOTOK_BROWSER_PATH=fake_chrome,
               PYTHONPATH=os.pathsep.join([str(SRC), str(SRC / "web")]))
    env.pop("AUTOTOK_CHROME_LAUNCH", None)
    start = time.time() + 4
    procs = [subprocess.Popen([sys.executable, "-c", CHILD, str(out), str(start)], env=env,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE) for _ in range(4)]
    errs = [p.communicate(timeout=120) for p in procs]
    assert [p.returncode for p in procs] == [0, 0, 0, 0], errs
    lines = out.read_text(encoding="utf-8").splitlines() if out.exists() else []
    assert [json.loads(x) for x in lines] == [[fake_chrome, "Profile 1"]]


def test_launch_off_switch_never_calls_the_launcher(engine, app, video_file, fake_chrome, monkeypatch):
    monkeypatch.setenv("AUTOTOK_CHROME_LAUNCH", "OFF")
    aid = chrome_account(engine)
    chrome = Chrome(app, "alice", UID_A)
    _offline(engine, chrome.client_id)
    schedule(engine, aid)
    for _ in range(3):
        worker.tick()
    assert ext._test_launches == []


@pytest.mark.parametrize("value", [
    'Profile 1" --remote-debugging-port=9222', "Profile 1 & calc", "Profile 1\n--x", "Profile 1;calc",
    "%TEMP%", "Profile 1\t", "$(calc)", "a\\..\\b",
])
def test_profile_name_that_could_carry_switches_or_shell_syntax_is_refused(engine, app, value):
    chrome = Chrome(app, "alice", UID_A)
    r = app.patch(f"/api/ext/clients/{chrome.client_id}", json={"chrome_profile_dir": value})
    assert r.status_code == 400, (value, r.status_code, r.text)
    assert app.get("/api/ext/clients").json()[0]["chrome_profile_dir"] is None


@pytest.mark.skipif(os.name != "nt", reason="Windows command-line parsing")
@pytest.mark.parametrize("value", ["Profile 1 --incognito", "--remote-debugging-port", "Profile 1 -", "a.b_c-d e"])
def test_accepted_profile_name_reaches_chrome_as_exactly_one_argument(monkeypatch, value):
    """Whatever the regex lets through must still be a single --profile-directory switch on Windows."""
    assert ext.valid_profile_dir(value)
    seen = {}

    class FakePopen:
        def __init__(self, args, **kw):
            seen["cmd"] = subprocess.list2cmdline(args)

    monkeypatch.setattr(ext.subprocess, "Popen", FakePopen)
    assert ext.spawn_chrome(r"C:\Program Files\Google\Chrome\Application\chrome.exe", value) is True
    argc = ctypes.c_int()
    fn = ctypes.windll.shell32.CommandLineToArgvW
    fn.restype = ctypes.POINTER(ctypes.c_wchar_p)
    argv = fn(seen["cmd"], ctypes.byref(argc))
    parsed = [argv[i] for i in range(argc.value)]
    ctypes.windll.kernel32.LocalFree(argv)
    assert parsed == [r"C:\Program Files\Google\Chrome\Application\chrome.exe", f"--profile-directory={value}",
                      "--no-first-run"]


def test_reason_after_a_real_launch_is_not_the_stale_no_profile_text(engine, app, clock, video_file, fake_chrome):
    """Profile unknown at first, the owner picks it in the GUI, Chrome is then opened but never comes up: the failure
    text must not still say the profile is unknown."""
    aid = chrome_account(engine)
    chrome = Chrome(app, "alice", UID_A)
    _offline(engine, chrome.client_id, profile_dir=None)
    sid = schedule(engine, aid)
    worker.tick()
    assert ext._test_launches == []
    assert app.patch(f"/api/ext/clients/{chrome.client_id}", json={"chrome_profile_dir": "Profile 1"}).status_code == 200
    _offline(engine, chrome.client_id)  # the PATCH must not count as the extension being seen
    ext.reconcile_ext()
    assert len(ext._test_launches) == 1
    clock["offset"] = timedelta(seconds=200)
    ext.reconcile_ext()
    row = parent(engine, sid)
    assert row.status == "failed" and row.result_text != ext.NO_PROFILE_TEXT, row.result_text
