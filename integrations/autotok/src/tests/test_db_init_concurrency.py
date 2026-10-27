"""Cold start: the API and the scheduler run init_db on the same fresh database at the same moment."""
import os
import sqlite3
import threading
import subprocess
import sys
import time
from pathlib import Path

import pytest

WEB = Path(__file__).resolve().parents[1] / "web"
SRC = Path(__file__).resolve().parents[1]

# Every process waits for the same wall-clock instant, then initialises the database.
_CHILD = r"""
import sys, time
from api.db import init_db  # imported first: only init_db itself must run at the same moment
start = float(sys.argv[1])
while time.time() < start:
    pass
time.sleep(float(sys.argv[2]))  # staggered: one process may be mid-migration when the next begins
init_db()
"""


@pytest.mark.parametrize("round_", range(2))
def test_concurrent_init_on_fresh_db_all_succeed(tmp_path, round_):
    db = tmp_path / "thư mục có dấu" / "dashboard.db"
    db.parent.mkdir()
    env = dict(os.environ, TIKTOK_API_DB_PATH=str(db), PYTHONPATH=os.pathsep.join([str(SRC), str(WEB)]))
    start = time.time() + 3.0  # enough for every interpreter to import before the start line
    logs = [tmp_path / f"child{i}.log" for i in range(4)]
    procs = []
    for i, log in enumerate(logs):  # output to files, not pipes: a full pipe would block the child
        with open(log, "wb") as out:
            procs.append(subprocess.Popen([sys.executable, "-c", _CHILD, repr(start), str(0.05 * i * round_)], env=env,
                                          cwd=str(tmp_path), stdout=out, stderr=subprocess.STDOUT))
    results = [(p.wait(timeout=120), log.read_text("utf-8", "replace")) for p, log in zip(procs, logs)]
    assert [code for code, _ in results] == [0, 0, 0, 0], "\n".join(err for _, err in results)
    con = sqlite3.connect(db)
    try:
        assert con.execute("PRAGMA user_version").fetchone()[0] == 4
        cols = {r[1] for r in con.execute("PRAGMA table_info(upload_history)")}
        assert {"prior_uncertain", "tiktok_schedule_time", "post_id"} <= cols
    finally:
        con.close()


def _schema_ok(db):
    con = sqlite3.connect(db)
    try:
        cols = {r[1] for r in con.execute("PRAGMA table_info(upload_history)")}
        return con.execute("PRAGMA user_version").fetchone()[0] == 4 and "prior_uncertain" in cols
    finally:
        con.close()


def test_concurrent_init_from_separate_connections_never_hits_database_locked(tmp_path):
    # Separate engines = separate SQLite connections, which lock exactly like separate processes;
    # threads start together far more precisely than processes, so the race shows up reliably.
    import api.db as api_db

    for round_ in range(15):
        db = tmp_path / f"r{round_}" / "dashboard.db"
        db.parent.mkdir()
        engines = [api_db.make_engine(f"sqlite:///{db}") for _ in range(4)]
        barrier, errors = threading.Barrier(4), []

        def run(eng):
            barrier.wait()
            try:
                api_db.init_db(eng)
            except Exception as exc:  # collected and asserted below
                errors.append(repr(exc)[:200])

        threads = [threading.Thread(target=run, args=(e,)) for e in engines]
        for t in threads:
            t.start()
        for t in threads:
            t.join(120)
        for e in engines:
            e.dispose()
        assert errors == [], f"round {round_}: {errors}"
        assert _schema_ok(db)
