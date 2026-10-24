"""Durable local upload history, shared by desktop, direct upload and scheduler."""
from __future__ import annotations
import hashlib
import logging
import os
import re
import sys
from datetime import timedelta
from pathlib import Path
from uuid import uuid4
from sqlalchemy import update
from sqlalchemy.orm import defer
from sqlalchemy.exc import IntegrityError, OperationalError
from sqlmodel import Session, select
from api.db import now_utc
from api.models import Account, DesktopReceipt, ScheduledUpload, UploadHistory
from api.services import videos as library

log = logging.getLogger("api.history")

# Keeps every IN (...) query well below SQLite's bound-parameter limit.
IN_CHUNK = 500
# Direct-upload rows written before the owner was recorded in the key: no live owner can be proven.
LEGACY_DIRECT_STALE_AFTER = timedelta(hours=2)


# Big text columns that list/lookup queries never show: not read from disk (see GET /entry/{key}).
LIGHT = (defer(UploadHistory.publish_response_json), defer(UploadHistory.caption))
LINK_FIRST_DELAY = timedelta(minutes=1)
_HANDLE = re.compile(r"[A-Za-z0-9._]{2,24}")
_POST_ID = re.compile(r"[0-9]{17,20}")


def build_post_url(username: str, post_id: str | None) -> str | None:
    """The only place a public post link is made. None unless both parts are well-formed. A label that
    is not a valid TikTok handle (e.g. "kid-main") gives no URL; the post id is still stored."""
    if not post_id or not _POST_ID.fullmatch(post_id):
        return None
    if not _HANDLE.fullmatch(username or ""):
        return None
    return f"https://www.tiktok.com/@{username}/video/{post_id}"


def record_success(entry: UploadHistory, outcome, caption: str | None = None) -> None:
    """Store what TikTok answered for an accepted post and decide how its link is found."""
    now = now_utc()
    entry.media_video_id = outcome.video_id
    entry.creation_id = getattr(outcome, "creation_id", None)
    entry.publish_response_json = getattr(outcome, "response_json", "") or None
    if caption is not None:
        entry.caption = caption
    scheduled = getattr(outcome, "tiktok_schedule_time", None)
    if scheduled is not None:
        entry.tiktok_schedule_time = scheduled
        entry.planned_for = scheduled  # TikTok publishes then, not when it accepted the request
    post_id = getattr(outcome, "post_id", None)
    url = build_post_url(entry.username, post_id)
    entry.link_attempts = 0
    if post_id and _POST_ID.fullmatch(post_id):  # id known: the link is final, with or without a URL
        entry.post_id, entry.post_url = post_id, url
        entry.link_state, entry.link_next_at = "found", None
    elif scheduled is not None:
        entry.post_id = post_id
        entry.link_state, entry.link_next_at = "scheduled_on_tiktok", scheduled + LINK_FIRST_DELAY
    else:
        entry.post_id = post_id
        entry.link_state, entry.link_next_at = "pending", now + LINK_FIRST_DELAY


def record_failure(entry: UploadHistory, outcome) -> None:
    """Keep what TikTok answered for a failed or uncertain attempt (the latest attempt wins)."""
    text = getattr(outcome, "response_json", "") or None
    if text:
        entry.publish_response_json = text


def reel_id_from_name(name: str) -> str:
    match = re.match(r"^(\d+)-3-hoan-chinh\.mp4$", name or "", re.I)
    return match.group(1) if match else ""


def identity(path: str | Path, original_name: str = "") -> tuple[str, str]:
    digest = hashlib.sha256()
    with open(path, "rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest(), reel_id_from_name(original_name or Path(path).name)


def local_identity(source_ref: str, original_name: str = "") -> tuple[str, str]:
    """Hash a library file; ("", "") if it is gone. Call it before opening a write transaction."""
    try:
        return identity(library.resolve(source_ref), original_name)
    except (ValueError, OSError):
        return "", ""  # retain outcome even if an old file has already been removed


def chunks(values, size: int = IN_CHUNK):
    values = list(values)
    for start in range(0, len(values), size):
        yield values[start:start + size]


def schedule_key(job: ScheduledUpload) -> str:
    # SQLite may reuse deleted integer IDs; the immutable creation timestamp prevents aliasing.
    return f"schedule:{job.id}:{job.created_at.replace(tzinfo=None).isoformat(timespec='microseconds')}"


def receipt_owns(receipt: DesktopReceipt | None, job: ScheduledUpload | None) -> bool:
    """A receipt's schedule_id may point at an unrelated job after SQLite reused a deleted ID."""
    return bool(receipt and job and job.source_type == "local"
                and job.source_ref.startswith(f"kid-{receipt.request_id}"))


def track_schedule(session: Session, job: ScheduledUpload, *, request_id: str | None = None,
                   sha256: str = "", reel_id: str = "", original_name: str = "",
                   legacy: bool = False) -> UploadHistory:
    key = schedule_key(job)
    entry = session.get(UploadHistory, key)
    if entry is None:
        account = session.get(Account, job.account_id)
        receipt = session.exec(select(DesktopReceipt).where(DesktopReceipt.schedule_id == job.id)).first()
        if not receipt_owns(receipt, job):
            receipt = None
        if job.source_type == "local" and not sha256:
            sha256, inferred = local_identity(job.source_ref, original_name)
            reel_id = reel_id or inferred
        entry = UploadHistory(key=key, schedule_id=job.id,
            request_id=request_id or (receipt.request_id if receipt else None),
            username=account.username if account else "(tài khoản đã xóa)",
            reel_id=reel_id, sha256=sha256, original_name=original_name or job.source_ref,
            planned_for=job.scheduled_for, created_at=job.created_at)
    if sha256:
        entry.sha256 = sha256
    if reel_id:
        entry.reel_id = reel_id
    if request_id:
        entry.request_id = request_id
    if job.publish_uncertain or entry.publish_uncertain:
        entry.prior_uncertain = True  # a confirmed retry clears the job flag, never this one
    previous_status = entry.status
    entry.status = job.status
    entry.publish_uncertain = job.publish_uncertain
    entry.result_text = job.result_text
    if job.status in ("succeeded", "failed", "cancelled"):
        if entry.finished_at is None or previous_status != job.status:
            entry.finished_at = job.updated_at if legacy else now_utc()
    if job.status == "succeeded" and entry.accepted_at is None:
        entry.accepted_at = job.updated_at if legacy else now_utc()
        entry.time_source = "legacy_result_time" if legacy else "acknowledgement"
    session.add(entry)
    return entry


def entries_by_request(session: Session, request_ids) -> dict[str, UploadHistory]:
    """The entry each request_id really belongs to: the earliest one recorded for it.

    A request has at most one genuine entry. Older builds could copy a deleted desktop
    request's ID onto a later job that reused its integer ID; such rows are always newer."""
    found: dict[str, UploadHistory] = {}
    for chunk in chunks(sorted({r for r in request_ids if r})):
        for entry in session.exec(select(UploadHistory).options(*LIGHT).where(UploadHistory.request_id.in_(chunk))).all():
            current = found.get(entry.request_id)
            if current is None or (entry.created_at, entry.key) < (current.created_at, current.key):
                found[entry.request_id] = entry
    return found


def backfill(session: Session) -> int:
    """Old retained job rows can be recovered; missing historical data is not invented.

    Runs at startup while the scheduler may write the same rows: a conflicting insert rolls
    back and the pass is recomputed. Files are hashed before the write transaction starts,
    never while holding SQLite's write lock."""
    for _ in range(3):
        existing = set(session.exec(select(UploadHistory.key)).all())
        missing = [job for job in session.exec(select(ScheduledUpload)).all() if schedule_key(job) not in existing]
        if not missing:
            return 0
        identities = {job.id: local_identity(job.source_ref) if job.source_type == "local" else ("", "")
                      for job in missing}
        try:
            for job in missing:
                sha256, reel_id = identities[job.id]
                track_schedule(session, job, sha256=sha256, reel_id=reel_id, legacy=True)
            session.commit()
            return len(missing)
        except (IntegrityError, OperationalError) as exc:
            session.rollback()
            log.info("history backfill raced with another writer (%s); recomputing", type(exc).__name__)
    log.warning("history backfill gave up after repeated write conflicts; it runs again on next start")
    return 0


# ---------- direct uploads: the owner process is recorded in the key ----------

def _kernel32():
    import ctypes
    from ctypes import wintypes
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel32.OpenProcess.restype = wintypes.HANDLE
    kernel32.OpenProcess.argtypes = (wintypes.DWORD, wintypes.BOOL, wintypes.DWORD)
    return ctypes, wintypes, kernel32


def _process_start(pid: int) -> str:
    """Creation time of ``pid`` (guards against PID reuse), or "" when unknown."""
    if sys.platform == "win32":
        ctypes, wintypes, kernel32 = _kernel32()
        handle = kernel32.OpenProcess(0x1000, False, pid)  # PROCESS_QUERY_LIMITED_INFORMATION
        if not handle:
            return ""
        try:
            times = [wintypes.FILETIME() for _ in range(4)]
            if not kernel32.GetProcessTimes(wintypes.HANDLE(handle), *[ctypes.byref(t) for t in times]):
                return ""
            return str((times[0].dwHighDateTime << 32) | times[0].dwLowDateTime)
        finally:
            kernel32.CloseHandle(wintypes.HANDLE(handle))
    try:
        with open(f"/proc/{pid}/stat", "rb") as stat:
            return stat.read().rsplit(b")", 1)[1].split()[19].decode()
    except (OSError, IndexError):
        return ""


def _process_alive(pid: int, start: str) -> bool:
    if sys.platform == "win32":
        ctypes, wintypes, kernel32 = _kernel32()
        handle = kernel32.OpenProcess(0x1000, False, pid)
        if not handle:
            return ctypes.get_last_error() == 5  # ERROR_ACCESS_DENIED: it exists, owned by someone else
        try:
            code = wintypes.DWORD()
            if not kernel32.GetExitCodeProcess(wintypes.HANDLE(handle), ctypes.byref(code)):
                return True  # cannot tell: keep the row running rather than guess it failed
            if code.value != 259:  # STILL_ACTIVE
                return False
        finally:
            kernel32.CloseHandle(wintypes.HANDLE(handle))
    else:
        try:
            os.kill(pid, 0)  # POSIX only: on Windows os.kill would terminate the process
        except ProcessLookupError:
            return False
        except PermissionError:
            return True
    current = _process_start(pid)
    return not (start and current and current != start)


_OWNER = f"{os.getpid()}.{_process_start(os.getpid())}"


def begin_direct(session: Session, username: str, path: str, original_name: str = "") -> UploadHistory:
    sha, reel_id = identity(path, original_name)
    entry = UploadHistory(key=f"direct:{_OWNER}:{uuid4().hex}", username=username, sha256=sha,
        reel_id=reel_id, original_name=original_name or Path(path).name, status="running")
    session.add(entry)
    session.commit()
    session.refresh(entry)
    return entry


def finish_direct(session: Session, entry: UploadHistory, outcome, caption: str | None = None) -> None:
    entry.status = "succeeded" if outcome.ok else "failed"
    entry.publish_uncertain = outcome.uncertain
    entry.prior_uncertain = entry.prior_uncertain or outcome.uncertain
    entry.finished_at = now_utc()
    if outcome.ok:
        entry.accepted_at = entry.finished_at
    entry.media_video_id = outcome.video_id
    entry.result_text = outcome.message
    if outcome.ok:
        record_success(entry, outcome, caption)
    else:
        record_failure(entry, outcome)
    session.add(entry)
    session.commit()


def _direct_owner_dead(entry: UploadHistory) -> bool:
    parts = entry.key.split(":")
    if len(parts) == 3:
        pid, _, start = parts[1].partition(".")
        try:
            return not _process_alive(int(pid), start)
        except ValueError:
            return False
    created = entry.created_at.replace(tzinfo=None)
    return created < now_utc().replace(tzinfo=None) - LEGACY_DIRECT_STALE_AFTER


def recover_direct(session: Session) -> int:
    """Direct uploads whose server process died would otherwise stay 'running' forever. They
    may have been posted, so they become failed + uncertain (never retried automatically)."""
    running = session.exec(select(UploadHistory).where(
        UploadHistory.status == "running", UploadHistory.key.startswith("direct:"))).all()
    recovered = 0
    for entry in running:
        if not _direct_owner_dead(entry):
            continue
        result = session.exec(update(UploadHistory)
            .where(UploadHistory.key == entry.key, UploadHistory.status == "running")
            .values(status="failed", publish_uncertain=True, prior_uncertain=True, finished_at=now_utc(),
                    result_text="the server stopped during this upload; it may or may not have been "
                                "posted. Check TikTok before retrying."))
        recovered += result.rowcount
    if recovered:
        session.commit()
        log.warning("marked %d interrupted direct upload(s) as failed (uncertain)", recovered)
    return recovered
