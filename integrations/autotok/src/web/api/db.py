"""SQLite engine + session factory.

One engine per process. WAL mode is set on every new connection so the api
service and scheduler service can read/write the same file concurrently without
sharing a connection. Time comparisons against `scheduled_for` happen in
Python (`datetime.now(timezone.utc)`) — not SQL — so container TZ drift can't
silently break the scheduler.
"""
from __future__ import annotations

import os
import time
from contextlib import contextmanager
from datetime import datetime, timezone
from typing import Iterator

from sqlalchemy import event
from sqlalchemy.engine import Engine
from sqlalchemy.exc import OperationalError
from sqlmodel import Session, SQLModel, create_engine


def _db_path() -> str:
    """Resolve the SQLite file path. Defaults to /data/tiktok.db (the shared
    Docker volume mount) but falls back to a repo-local ./data/tiktok.db so
    tests and local CLI usage work without Docker."""
    env = os.getenv("TIKTOK_API_DB_PATH")
    if env:
        return env
    if os.path.isdir("/data"):
        return "/data/tiktok.db"
    local = os.path.join(os.getcwd(), "data")
    os.makedirs(local, exist_ok=True)
    return os.path.join(local, "tiktok.db")


def make_engine(url: str | None = None) -> Engine:
    if url is None:
        url = f"sqlite:///{_db_path()}"
    # check_same_thread=False — FastAPI runs handlers in a threadpool; each
    # request still gets its own Session so there's no shared-connection bug.
    eng = create_engine(
        url,
        echo=False,
        connect_args={"check_same_thread": False},
    )

    @event.listens_for(eng, "connect")
    def _set_pragmas(dbapi_conn, _record):
        cur = dbapi_conn.cursor()
        cur.execute("PRAGMA journal_mode=WAL;")
        cur.execute("PRAGMA synchronous=NORMAL;")
        cur.execute("PRAGMA busy_timeout=5000;")
        cur.execute("PRAGMA foreign_keys=ON;")
        cur.close()

    return eng


# Module-level engine; overridden in tests via `override_engine`.
engine: Engine = make_engine()


def override_engine(new_engine: Engine) -> None:
    """Swap the module-level engine. Used only by the test fixture."""
    global engine
    engine = new_engine


# How long a process waits for another one to finish initialising the same database.
INIT_LOCK_TIMEOUT = 120.0


@contextmanager
def _init_lock(eng: Engine):
    """Hold an OS file lock next to the database while it is created/migrated.

    On a fresh file, SQLite's switch to WAL (first connection of each process) fails at once
    with "database is locked" when another process does the same, without waiting for
    busy_timeout; create_all and _migrate race too. The API and the scheduler start together,
    so initialisation is serialised across processes here. Released by the OS if a process dies."""
    path = eng.url.database
    if not path or path == ":memory:" or path.startswith("file:"):
        yield
        return
    with open(f"{path}.init-lock", "a+b") as fh:
        if os.name == "nt":
            import msvcrt

            deadline = time.monotonic() + INIT_LOCK_TIMEOUT
            while True:
                fh.seek(0)
                try:
                    msvcrt.locking(fh.fileno(), msvcrt.LK_NBLCK, 1)
                    break
                except OSError:
                    if time.monotonic() >= deadline:
                        raise TimeoutError(f"database initialisation lock still held after {INIT_LOCK_TIMEOUT:.0f}s: "
                                           f"{path}.init-lock") from None
                    time.sleep(0.05)
            try:
                yield
            finally:
                fh.seek(0)
                msvcrt.locking(fh.fileno(), msvcrt.LK_UNLCK, 1)
        else:
            import fcntl

            fcntl.flock(fh.fileno(), fcntl.LOCK_EX)
            try:
                yield
            finally:
                fcntl.flock(fh.fileno(), fcntl.LOCK_UN)


def init_db(eng: Engine | None = None) -> None:
    """Create tables if they don't exist and migrate (the module engine unless ``eng`` is given).
    Idempotent, and safe when several processes call it on the same database at once (see _init_lock)."""
    # Import models so SQLModel.metadata sees them.
    from api import models  # noqa: F401

    eng = eng or engine
    with _init_lock(eng):
        SQLModel.metadata.create_all(eng)
        _migrate(eng)


# Stored in SQLite's PRAGMA user_version once every step of _migrate has finished.
SCHEMA_VERSION = 3


def _add_column(conn, table: str, column: str, ddl: str) -> bool:
    """Add ``column`` if missing. False when ``table`` does not exist (create_all makes it whole)."""
    columns = {row[1] for row in conn.exec_driver_sql(f"PRAGMA table_info({table})")}
    if not columns:
        return False
    if column not in columns:
        try:
            conn.exec_driver_sql(f"ALTER TABLE {table} ADD COLUMN {column} {ddl}")
        except OperationalError as exc:
            if "duplicate column name" not in str(exc).lower():
                raise
            # The other container added it at the same moment.
    return True


def _migrate(eng: Engine) -> None:
    """Bring databases created by older versions up to date.

    ``create_all`` creates missing tables but never alters existing ones. Every step here is
    safe to repeat, and ``user_version`` is only set at the end, so a migration interrupted
    half way is finished on the next start. The api and scheduler containers both run this at
    startup on the same database, so the other one may get to a step first."""
    with eng.begin() as conn:
        version = conn.exec_driver_sql("PRAGMA user_version").scalar()
        if version >= SCHEMA_VERSION:
            return
        if version < 1:
            _add_column(conn, "scheduled_uploads", "publish_uncertain", "BOOLEAN NOT NULL DEFAULT 0")
            # Jobs that failed this way before the column existed.
            conn.exec_driver_sql(
                "UPDATE scheduled_uploads SET publish_uncertain = 1 WHERE status = 'failed' AND "
                "(result_text LIKE '%may or may not%' OR result_text LIKE 'unexpected error:%')"
            )
        if version < 2:
            # Desktop bridge attempt fencing and the monotonic "an attempt was ever uncertain" flag.
            _add_column(conn, "desktop_receipts", "attempt_token", "VARCHAR NOT NULL DEFAULT ''")
            _add_column(conn, "desktop_receipts", "heartbeat_at", "DATETIME")
            if _add_column(conn, "upload_history", "prior_uncertain", "BOOLEAN NOT NULL DEFAULT 0"):
                conn.exec_driver_sql("UPDATE upload_history SET prior_uncertain = 1 WHERE publish_uncertain = 1")
        if version < 3:
            # Public post link + TikTok-side scheduling. Older rows: no link, nothing to fetch.
            for column, ddl in (("post_id", "VARCHAR"), ("post_url", "VARCHAR"), ("creation_id", "VARCHAR"),
                                ("link_state", "VARCHAR NOT NULL DEFAULT ''"),
                                ("link_attempts", "INTEGER NOT NULL DEFAULT 0"), ("link_next_at", "DATETIME"),
                                ("tiktok_schedule_time", "DATETIME"), ("publish_response_json", "VARCHAR"),
                                ("caption", "VARCHAR")):
                exists = _add_column(conn, "upload_history", column, ddl)
            if exists:
                conn.exec_driver_sql("CREATE INDEX IF NOT EXISTS ix_upload_history_link_state "
                                     "ON upload_history (link_state)")
        conn.exec_driver_sql(f"PRAGMA user_version = {SCHEMA_VERSION}")


def get_session() -> Iterator[Session]:
    """FastAPI dependency. One short-lived session per request."""
    with Session(engine) as session:
        yield session


def now_utc() -> datetime:
    """Single source of truth for 'now' across the API and scheduler."""
    return datetime.now(timezone.utc)
