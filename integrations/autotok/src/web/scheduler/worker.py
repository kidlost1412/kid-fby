"""Atomic claim + heartbeat + upload.

Pulled out of main.py so it can be unit-tested directly (freeze time, patch
the adapter, patch the heartbeat). The real service composes these.

Duplicate posts are the failure mode that matters most, so the rules are:
  * a job is retried automatically only when the upload failed before anything
    reached TikTok's publish endpoint (``UploadOutcome.retryable``);
  * a job found stuck in 'running' (the worker died mid-upload) is marked
    failed, not retried: it may already be live. The user can retry it;
  * every write about a claimed attempt (heartbeat, stale reclaim, finalize) is
    fenced on (id, attempts): a stalled worker that wakes up after its attempt was
    reclaimed and retried can never overwrite or requeue the newer attempt.
"""
from __future__ import annotations

import json
import logging
import threading
import time
import traceback
from datetime import timedelta
from typing import Optional

from sqlalchemy import and_, update
from sqlmodel import Session, select

import api.db as _api_db
from api.db import now_utc
from api.models import Account, ScheduledUpload, UploadHistory
from api.services import ext, tiktok_adapter, youtube
from autotok.browser_publish import redact_url
from api.services import videos as library
from api.services import links
from api.services.history import record_failure, record_success, schedule_key, track_schedule
from api.services.tiktok_adapter import SCHEDULE_MODE_OPTION, UploadOutcome

log = logging.getLogger("scheduler.worker")

STALE_RUNNING_AFTER = timedelta(minutes=5)
MAX_ATTEMPTS = 3
RETRY_DELAY = timedelta(minutes=2)
HEARTBEAT_INTERVAL = 30.0  # seconds
# Jobs from before TikTok-side scheduling waited on this PC. If the PC was off at the due time, posting
# hours later is not what the owner asked for: past this lateness they fail (definitely not posted).
LEGACY_MAX_LATENESS = timedelta(hours=2)
LATE_TEXT = "Lỡ giờ khi máy tắt — chưa đăng"


def _is_legacy(row: ScheduledUpload) -> bool:
    """Created before TikTok-side scheduling: new jobs always record their schedule mode."""
    try:
        options = json.loads(row.options_json or "{}")
    except ValueError:
        return True
    return not (isinstance(options, dict) and options.get(SCHEDULE_MODE_OPTION))


def expire_late_legacy(session: Session) -> int:
    """Legacy pending jobs more than LEGACY_MAX_LATENESS past due become failed (not uncertain:
    nothing was sent). Conditional on still being pending, so a concurrent claim wins."""
    cutoff = now_utc() - LEGACY_MAX_LATENESS
    rows = session.exec(select(ScheduledUpload).where(ScheduledUpload.status == "pending",
                                                      ScheduledUpload.scheduled_for < cutoff)).all()
    expired = 0
    for r in rows:
        if not _is_legacy(r):
            continue
        result = session.exec(update(ScheduledUpload)
                              .where(ScheduledUpload.id == r.id, ScheduledUpload.status == "pending",
                                     ScheduledUpload.attempts == r.attempts)
                              .values(status="failed", publish_uncertain=False, result_text=LATE_TEXT,
                                      updated_at=now_utc()))
        if result.rowcount == 1:
            session.refresh(r)
            track_schedule(session, r)
            expired += 1
    if expired:
        session.commit()
        log.warning("%d legacy scheduled job(s) were more than %s late and were not posted", expired,
                    LEGACY_MAX_LATENESS)
    else:
        session.rollback()
    return expired


def reclaim_stale(session: Session) -> int:
    """Rows stuck in 'running' beyond STALE_RUNNING_AFTER (no heartbeat, so the
    worker died) are marked failed. Called at the top of every poll cycle."""
    cutoff = now_utc() - STALE_RUNNING_AFTER
    rows = session.exec(
        select(ScheduledUpload).where(
            and_(
                ScheduledUpload.status == "running",
                ScheduledUpload.heartbeat_at < cutoff,
            )
        )
    ).all()
    reclaimed = 0
    for r in rows:
        # Re-checked inside the UPDATE: a heartbeat or finalize that landed after the SELECT wins.
        result = session.exec(
            update(ScheduledUpload)
            .where(ScheduledUpload.id == r.id)
            .where(ScheduledUpload.status == "running")
            .where(ScheduledUpload.attempts == r.attempts)
            .where(ScheduledUpload.heartbeat_at < cutoff)
            .values(
                status="failed",
                publish_uncertain=True,
                result_text=(
                    "the scheduler stopped during this upload; it may or may not have been posted. "
                    "Check TikTok before retrying."
                ),
                updated_at=now_utc(),
            )
        )
        if result.rowcount == 1:
            session.refresh(r)
            track_schedule(session, r)
            reclaimed += 1
    if reclaimed:
        session.commit()
    else:
        session.rollback()
    return reclaimed


def claim_next_due(session: Session) -> Optional[ScheduledUpload]:
    """Pick one pending row whose scheduled_for is past and atomically claim
    it. Returns None if nothing is due. The UPDATE...WHERE status='pending'
    clause is the race guard: only one worker wins if two race."""
    now = now_utc()
    row = session.exec(
        select(ScheduledUpload)
        .where(ScheduledUpload.status == "pending")
        .where(ScheduledUpload.scheduled_for <= now)
        # Chrome accounts' jobs go through reconcile_ext (pending_ext), never through here.
        .where(ScheduledUpload.account_id.not_in(select(Account.id).where(Account.publisher == "chrome")))
        .order_by(ScheduledUpload.scheduled_for)
        .limit(1)
    ).first()
    if not row:
        return None

    result = session.exec(
        update(ScheduledUpload)
        .where(ScheduledUpload.id == row.id)
        .where(ScheduledUpload.status == "pending")
        .values(
            status="running",
            attempts=ScheduledUpload.attempts + 1,
            heartbeat_at=now,
            updated_at=now,
        )
    )
    if result.rowcount != 1:
        session.rollback()
        return None  # lost the race
    session.refresh(row)
    track_schedule(session, row)
    session.commit()
    session.refresh(row)
    return row


class Heartbeat:
    """Background thread that bumps heartbeat_at every HEARTBEAT_INTERVAL
    while an upload is in flight. Lets reclaim_stale distinguish a wedged
    worker from a healthy long-running upload."""

    def __init__(self, schedule_id: int, attempts: int):
        self.schedule_id = schedule_id
        self.attempts = attempts
        self._stop = threading.Event()
        self._thread: Optional[threading.Thread] = None

    def start(self) -> None:
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        if self._thread:
            self._thread.join(timeout=HEARTBEAT_INTERVAL + 5)

    def beat(self) -> bool:
        """One heartbeat for this attempt only. False once the attempt is no longer running."""
        with Session(_api_db.engine) as s:
            result = s.exec(
                update(ScheduledUpload)
                .where(ScheduledUpload.id == self.schedule_id)
                .where(ScheduledUpload.status == "running")
                .where(ScheduledUpload.attempts == self.attempts)
                .values(heartbeat_at=now_utc())
            )
            s.commit()
            return result.rowcount == 1

    def _run(self) -> None:
        while not self._stop.wait(HEARTBEAT_INTERVAL):
            try:
                if not self.beat():
                    return
            except Exception:  # pragma: no cover - best-effort
                log.exception("heartbeat write failed")


def run_one(row: ScheduledUpload) -> UploadOutcome:
    """Execute a single claimed row. Never raises."""
    with Session(_api_db.engine) as s:
        acct = s.get(Account, row.account_id)
        if not acct:
            return UploadOutcome(ok=False, message="account row missing")
        username = acct.username

    if row.source_type == "youtube":
        try:
            video_path = youtube.download(row.source_ref)
        except Exception as e:
            return UploadOutcome(ok=False, message=f"youtube download failed: {redact_url(e)}", retryable=True)
    else:
        try:
            video_path = str(library.resolve(row.source_ref))
        except ValueError as e:
            return UploadOutcome(ok=False, message=str(e))

    try:
        options = json.loads(row.options_json or "{}")
    except ValueError:
        return UploadOutcome(ok=False, message="invalid options_json")
    return tiktok_adapter.upload_from_options(username, video_path, row.title, options)


def _record_superseded(s: Session, schedule_id: int, attempts: int, outcome: UploadOutcome,
                       key: Optional[str]) -> None:
    """A newer attempt owns the job now, so the job row is left alone. A success must not be
    dropped, though: the history keeps it as prior_uncertain so any repost needs confirmation."""
    log.warning("job %s: attempt %s finished after a newer attempt took over; job left unchanged (%s)",
                schedule_id, attempts, "succeeded" if outcome.ok else outcome.message)
    if not outcome.ok:
        return
    entry = s.get(UploadHistory, key) if key else None
    if entry is None:
        log.error("job %s: late success of attempt %s has no history entry to record it on", schedule_id, attempts)
        return
    note = (f"late success of attempt {attempts}"
            + (f" (video id {outcome.video_id})" if outcome.video_id else "")
            + ": TikTok accepted it after it was declared stalled; check the account before reposting")
    entry.prior_uncertain = True
    entry.result_text = f"{entry.result_text} | {note}" if entry.result_text else note
    s.add(entry)
    s.commit()


def finalize(schedule_id: int, outcome: UploadOutcome, *, attempts: int, key: Optional[str] = None) -> None:
    """Record the outcome of claimed attempt ``attempts``; ``key`` is the history key of the
    claimed job. Every write is conditional on the attempt still being the current one."""
    for _ in range(3):
        with Session(_api_db.engine) as s:
            row = s.get(ScheduledUpload, schedule_id)
            if not row or row.attempts != attempts:
                _record_superseded(s, schedule_id, attempts, outcome, key or (schedule_key(row) if row else None))
                return
            now = now_utc()
            if outcome.ok:
                changes = dict(status="succeeded", publish_uncertain=False,
                               result_text=f"{outcome.message} (video id {outcome.video_id})" if outcome.video_id else outcome.message)
            elif row.status != "running":
                # Changed by someone else while uploading (e.g. marked failed as stale): record what
                # actually happened, but never requeue.
                changes = dict(result_text=outcome.message, publish_uncertain=outcome.uncertain)
            elif outcome.retryable and row.attempts < MAX_ATTEMPTS:
                changes = dict(status="pending", scheduled_for=now + RETRY_DELAY * row.attempts,
                               result_text=f"attempt {row.attempts} failed, will retry: {outcome.message}")
            else:
                changes = dict(status="failed", publish_uncertain=outcome.uncertain, result_text=outcome.message)
            result = s.exec(
                update(ScheduledUpload)
                .where(ScheduledUpload.id == schedule_id)
                .where(ScheduledUpload.attempts == attempts)
                .where(ScheduledUpload.status == row.status)
                .values(updated_at=now, **changes)
            )
            if result.rowcount != 1:
                s.rollback()
                continue  # changed between the read and the write: decide again on fresh data
            s.refresh(row)
            if outcome.ok:
                acct = s.get(Account, row.account_id)
                if acct:
                    acct.last_used_at = now
                    s.add(acct)
            entry = track_schedule(s, row)
            if outcome.ok:
                record_success(entry, outcome, row.title)
                s.add(entry)
            else:
                record_failure(entry, outcome)
                s.add(entry)
            s.commit()
            return
    log.error("job %s attempt %s: outcome not recorded after repeated concurrent changes: %s",
              schedule_id, attempts, "succeeded" if outcome.ok else outcome.message)


def tick() -> bool:
    """One poll cycle. Returns True if a job was processed, False if idle.
    Visible in tests so they can drive the worker deterministically."""
    with Session(_api_db.engine) as s:
        reclaim_stale(s)
        expire_late_legacy(s)
    try:
        ext.reconcile_ext()  # Chrome accounts: deadlines, results, promotion of due pending_ext jobs
    except Exception:
        log.exception("reconcile_ext failed")
    with Session(_api_db.engine) as s:
        claimed = claim_next_due(s)
    if not claimed:
        try:
            links.tick()  # idle: look up one missing post link (read-only, never posts)
        except Exception:
            log.exception("post link lookup failed")
        return False  # True only means "a job was processed"

    hb = Heartbeat(claimed.id, claimed.attempts)
    hb.start()
    try:
        outcome = run_one(claimed)
    except Exception as e:  # pragma: no cover - run_one is defensive already
        log.error("job %s crashed\n%s", claimed.id, redact_url(traceback.format_exc()))
        outcome = UploadOutcome(ok=False, message=f"scheduler error: {redact_url(e)}")
    finally:
        hb.stop()
    finalize(claimed.id, outcome, attempts=claimed.attempts, key=schedule_key(claimed))
    log.info("job %s: %s", claimed.id, "succeeded" if outcome.ok else outcome.message)
    return True


def loop(poll_interval: float = 30.0) -> None:  # pragma: no cover - driven by tick() in tests
    log.info("scheduler loop starting, poll_interval=%ss", poll_interval)
    while True:
        try:
            busy = tick()
        except Exception:
            log.exception("tick failed")
            busy = False
        if not busy:
            time.sleep(poll_interval)
