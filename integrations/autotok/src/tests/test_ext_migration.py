"""Schema v4 (Chrome publisher) migration and rollback safety (contract C3).

"Old version" = the real backend source of the last release before v4 (git commit OLD_COMMIT), run in
a subprocess against the same database file. Skipped when git or that commit is not available.
"""
import io
import json
import os
import sqlite3
import subprocess
import sys
import time
import zipfile
from pathlib import Path

import pytest
from sqlmodel import SQLModel

import api.db as api_db

OLD_COMMIT = "e403d90"  # v3.1.0, schema 3
SRC = Path(__file__).resolve().parents[1]
WEB = SRC / "web"


@pytest.fixture(scope="module")
def old_src(tmp_path_factory):
    repo = subprocess.run(["git", "-C", str(SRC), "rev-parse", "--show-toplevel"], capture_output=True, text=True)
    if repo.returncode != 0:
        pytest.skip("git not available")
    top = Path(repo.stdout.strip())
    rel = SRC.relative_to(top).as_posix()
    data = subprocess.run(["git", "-C", str(top), "archive", "--format=zip", OLD_COMMIT, rel], capture_output=True)
    if data.returncode != 0:
        pytest.skip(f"commit {OLD_COMMIT} not available")
    out = tmp_path_factory.mktemp("old")
    zipfile.ZipFile(io.BytesIO(data.stdout)).extractall(out)
    return out / rel


def run_old(old_src, db, home, code):
    env = dict(os.environ, TIKTOK_API_DB_PATH=str(db), AUTOTOK_HOME=str(home), AUTOTOK_VIDEOS_DIR=str(home / "v"),
               PYTHONPATH=os.pathsep.join([str(old_src), str(old_src / "web")]))
    r = subprocess.run([sys.executable, "-c", code], env=env, cwd=str(home), capture_output=True, text=True, timeout=120)
    assert r.returncode == 0, r.stdout + r.stderr
    return r.stdout


OLD_CREATE = r"""
from datetime import datetime, timezone
from sqlmodel import Session
import api.db as db
from api.models import Account, ScheduledUpload
db.init_db()
with Session(db.engine) as s:
    a = Account(username="old", cookie_path="C:/x/tiktok_session-old.cookie")
    s.add(a); s.commit(); s.refresh(a)
    s.add(ScheduledUpload(account_id=a.id, source_type="local", source_ref="clip.mp4", title="t",
                          options_json='{"schedule_mode": "now"}', scheduled_for=datetime.now(timezone.utc)))
    s.commit()
"""


def new_init(db):
    eng = api_db.make_engine(f"sqlite:///{db}")
    old = api_db.engine
    api_db.override_engine(eng)
    try:
        api_db.init_db()
    finally:
        api_db.override_engine(old)
        eng.dispose()


def q(db, sql):
    con = sqlite3.connect(db)
    try:
        return con.execute(sql).fetchall()
    finally:
        con.close()


@pytest.fixture
def home(tmp_path):
    h = tmp_path / "nhà có dấu"
    (h / "v").mkdir(parents=True)
    return h


def test_fresh_install_is_v5_with_tables_defaults_and_index(tmp_path):
    db = tmp_path / "fresh.db"
    new_init(db)
    assert q(db, "PRAGMA user_version") == [(5,)]
    cols = {r[1]: r for r in q(db, "PRAGMA table_info(accounts)")}
    assert "'cookies'" in str(cols["publisher"][4]) and cols["publisher"][3] == 1  # SQL default, NOT NULL
    names = {r[0] for r in q(db, "SELECT name FROM sqlite_master")}
    assert {"extension_clients", "extension_jobs", "ux_extension_jobs_active_account"} <= names


def test_v3_to_v5_keeps_rows_and_defaults_publisher(old_src, home):
    db = home / "tiktok.db"
    run_old(old_src, db, home, OLD_CREATE)
    assert q(db, "PRAGMA user_version") == [(3,)]
    new_init(db)
    new_init(db)  # repeatable
    assert q(db, "PRAGMA user_version") == [(5,)]
    assert q(db, "SELECT username, cookie_path, publisher, chrome_user_id FROM accounts") == [
        ("old", "C:/x/tiktok_session-old.cookie", "cookies", None)]
    assert q(db, "SELECT status, attempts FROM scheduled_uploads") == [("pending", 0)]


def test_interrupted_migration_is_finished_on_next_start(old_src, home):
    db = home / "tiktok.db"
    run_old(old_src, db, home, OLD_CREATE)
    # Died after create_all made the new tables and one column existed, before user_version was set.
    eng = api_db.make_engine(f"sqlite:///{db}")
    from api import models  # noqa: F401
    SQLModel.metadata.tables["extension_jobs"].create(eng)
    eng.dispose()
    con = sqlite3.connect(db)
    con.execute("ALTER TABLE accounts ADD COLUMN publisher VARCHAR(16) NOT NULL DEFAULT 'cookies'")
    con.commit()
    con.close()
    new_init(db)
    assert q(db, "PRAGMA user_version") == [(5,)]
    assert {r[1] for r in q(db, "PRAGMA table_info(accounts)")} >= {"publisher", "chrome_user_id"}
    assert q(db, "SELECT count(*) FROM sqlite_master WHERE name='ux_extension_jobs_active_account'") == [(1,)]


_CONCURRENT = r"""
import sys, time
from api.db import init_db
start = float(sys.argv[1])
while time.time() < start:
    pass
init_db()
"""


def test_concurrent_start_on_a_v3_database(old_src, home):
    db = home / "tiktok.db"
    run_old(old_src, db, home, OLD_CREATE)
    env = dict(os.environ, TIKTOK_API_DB_PATH=str(db), PYTHONPATH=os.pathsep.join([str(SRC), str(WEB)]))
    start = time.time() + 3.0
    procs = [subprocess.Popen([sys.executable, "-c", _CONCURRENT, repr(start)], env=env, cwd=str(home),
                              stdout=subprocess.DEVNULL, stderr=subprocess.PIPE) for _ in range(3)]
    errs = [p.communicate(timeout=120)[1] for p in procs]
    assert [p.returncode for p in procs] == [0, 0, 0], errs
    assert q(db, "PRAGMA user_version") == [(5,)]


def test_old_version_insert_after_v5_gets_cookies_publisher(old_src, home):
    db = home / "tiktok.db"
    new_init(db)
    run_old(old_src, db, home, r"""
from sqlmodel import Session
import api.db as db
from api.models import Account
db.init_db()
with Session(db.engine) as s:
    s.add(Account(username="made.by.old", cookie_path="x")); s.commit()
""")
    assert q(db, "PRAGMA user_version") == [(5,)]  # the old version never lowers it
    assert q(db, "SELECT publisher FROM accounts WHERE username='made.by.old'") == [("cookies",)]


def test_rollback_to_v3_leaves_pending_chrome_work_untouched(old_src, home):
    db = home / "tiktok.db"
    (home / "v" / "clip.mp4").write_bytes(b"\x00\x00\x00\x18ftypmp42" + b"x" * 100)
    new_init(db)
    con = sqlite3.connect(db)
    con.execute("INSERT INTO accounts (id, username, cookie_path, has_valid_session, created_at, updated_at, publisher,"
                " chrome_user_id) VALUES (1, 'alice', 'C:/x/alice.cookie', 1, '2026-10-27 00:00:00',"
                " '2026-10-27 00:00:00', 'chrome', '7000000000000000001')")
    for sid, status in ((1, "pending_ext"), (2, "waiting_ext")):
        con.execute("INSERT INTO scheduled_uploads (id, account_id, source_type, source_ref, title, options_json,"
                    " scheduled_for, status, publish_uncertain, attempts, created_at, updated_at) VALUES"
                    f" ({sid}, 1, 'local', 'clip.mp4', 't', '{{\"schedule_mode\": \"now\"}}', '2026-10-27 00:00:00',"
                    f" '{status}', 0, 1, '2026-10-27 00:00:00', '2026-10-27 00:00:00')")
    con.execute("INSERT INTO extension_jobs (id, schedule_id, attempt, schedule_key, account_id, expect_user_id,"
                " video_name, caption, options_json, state, nonce, cancel_requested, duplicate_results, created_at,"
                " updated_at, authorized_at) VALUES ('ej_1', 2, 1, 'k', 1, '7000000000000000001', 'clip.mp4', 't',"
                " '{}', 'authorized', 'n', 0, 0, '2026-10-27 00:00:00', '2026-10-27 00:00:00', '2026-10-27 00:00:00')")
    con.commit()
    con.close()
    before = q(db, "SELECT id, status, attempts, result_text FROM scheduled_uploads ORDER BY id")
    out = run_old(old_src, db, home, r"""
import json
import api.db as db
from api.services import tiktok_adapter
from scheduler import worker
calls = []
tiktok_adapter.upload_from_options = lambda *a, **k: calls.append(a) or (_ for _ in ()).throw(AssertionError("posted"))
db.init_db()
for _ in range(3):
    worker.tick()
print(json.dumps(calls))
""")
    assert json.loads(out.strip().splitlines()[-1]) == []  # the old cookie path never ran them
    assert q(db, "SELECT id, status, attempts, result_text FROM scheduled_uploads ORDER BY id") == before
    assert q(db, "SELECT state FROM extension_jobs") == [("authorized",)]
    assert q(db, "PRAGMA user_version") == [(5,)]

V5_COLUMNS = {"extension_clients": {"chrome_profile_dir", "last_launch_at"}, "extension_jobs": {"launched_at"}}


def _cols(db, table):
    return {r[1] for r in q(db, f"PRAGMA table_info({table})")}


def test_fresh_install_has_the_v5_columns(tmp_path):
    db = tmp_path / "fresh.db"
    new_init(db)
    for table, cols in V5_COLUMNS.items():
        assert cols <= _cols(db, table)


def test_v4_database_from_the_p1_build_gets_the_v5_columns(tmp_path):
    """The owner's test copy: user_version 4, tables from the first P1 build without the fix2 columns."""
    db = tmp_path / "v4.db"
    new_init(db)
    con = sqlite3.connect(db)
    for table, cols in V5_COLUMNS.items():
        for col in cols:
            con.execute(f"ALTER TABLE {table} DROP COLUMN {col}")
    con.execute("INSERT INTO extension_clients (token_hash, label, ext_version, protocol, created_at)"
                " VALUES ('h', 'Chrome', '1.0.0', 1, '2026-10-27 00:00:00')")
    con.execute("PRAGMA user_version = 4")
    con.commit()
    con.close()
    assert not (V5_COLUMNS["extension_clients"] & _cols(db, "extension_clients"))
    new_init(db)
    new_init(db)  # repeatable
    assert q(db, "PRAGMA user_version") == [(5,)]
    for table, cols in V5_COLUMNS.items():
        assert cols <= _cols(db, table)
    assert q(db, "SELECT label, chrome_profile_dir FROM extension_clients") == [("Chrome", None)]


def test_v4_database_that_already_has_the_columns_migrates_cleanly(tmp_path):
    """Columns added by hand while user_version stayed 4: harmless."""
    db = tmp_path / "v4-hand.db"
    new_init(db)
    con = sqlite3.connect(db)
    con.execute("PRAGMA user_version = 4")
    con.commit()
    con.close()
    new_init(db)
    assert q(db, "PRAGMA user_version") == [(5,)]
    for table, cols in V5_COLUMNS.items():
        assert cols <= _cols(db, table)
