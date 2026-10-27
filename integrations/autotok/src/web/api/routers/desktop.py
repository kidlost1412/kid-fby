"""Local desktop bridge: streamed file -> durable, idempotent scheduler job.

Uses the original account store, scheduler and uploader. A reservation is saved
before copying; interrupted preparations require inspection, never automatic retry.

Per request_id: preparing -> queued (job created) or preparation_failed (terminal). The
preparing attempt owns a random token; only that attempt may enqueue (conditional UPDATE)
and it deletes only its own token-named files. A preparation whose heartbeat stopped for
STALE_PREPARING_AFTER is declared preparation_failed, after which its late commit is refused.
"""
from __future__ import annotations

import hashlib
import json
import logging
import os
import re
import shutil
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path
from uuid import uuid4

from fastapi import APIRouter, Depends, File, Form, HTTPException, UploadFile
from fastapi.responses import JSONResponse
from pydantic import BaseModel, field_validator
from sqlalchemy import func, update
from sqlalchemy.exc import IntegrityError, OperationalError
from sqlmodel import Session, select

import api.db as _api_db
from api.db import get_session, now_utc
from api.models import DesktopReceipt, ScheduledUpload, UploadHistory
from api.services import history
from api.routers.uploads import _require_account
from api.schemas import UploadOptions, check_native_schedule
from api.services.tiktok_adapter import SCHEDULE_MODE_OPTION, SCHEDULE_OPTION
from api.services import ext
from api.services import videos as library

router = APIRouter(prefix="/api/desktop/jobs", tags=["desktop"])
log = logging.getLogger("api.desktop")

STALE_PREPARING_AFTER = timedelta(minutes=float(os.getenv("AUTOTOK_DESKTOP_STALE_MINUTES", "10")))
HEARTBEAT_EVERY = 5.0  # seconds between heartbeat writes while copying
FAILED_TEXT = "video preparation failed before enqueue"
STALE_TEXT = "video preparation stopped making progress; it was never queued"
_OWN_NAME = re.compile(r"^kid-([0-9a-f]{32})(?:-[0-9a-f]{32})?\.(?:mp4|webm|mov)$")


class DesktopJobRead(BaseModel):
    request_id: str
    schedule_id: int | None
    status: str
    publish_uncertain: bool = False
    prior_uncertain: bool = False
    result_text: str | None = None
    username: str | None = None
    accepted_at: datetime | None = None
    planned_for: datetime | None = None
    time_source: str | None = None
    post_id: str | None = None
    post_url: str | None = None
    link_state: str = ""
    tiktok_schedule_time: datetime | None = None
    schedule_mode: str = ""  # "now" | "native" | "local" | "" (see history.schedule_modes)

    @field_validator("accepted_at", "planned_for", "tiktok_schedule_time")
    @classmethod
    def _utc_dates(cls, value):
        return value.replace(tzinfo=timezone.utc) if value is not None and value.tzinfo is None else value


def _key(key: str) -> str:
    if not re.fullmatch(r"[a-f0-9]{32}", key):
        raise HTTPException(422, "request_id must be 32 lowercase hex characters")
    return key


def _read(receipt: DesktopReceipt, session: Session) -> DesktopJobRead:
    job = session.get(ScheduledUpload, receipt.schedule_id) if receipt.schedule_id else None
    if not history.receipt_owns(receipt, job):
        job = None  # an integer schedule ID may have been reused after deleting the old row
    entry = history.entries_by_request(session, [receipt.request_id]).get(receipt.request_id)
    if job:
        status = job.status
    elif receipt.schedule_id:
        status = entry.status if entry else "missing"
    elif receipt.state == "preparation_failed":
        status = receipt.state  # terminal, whatever the placeholder says
    else:
        status = entry.status if entry else receipt.state
    return DesktopJobRead(
        request_id=receipt.request_id, schedule_id=receipt.schedule_id, status=status,
        publish_uncertain=job.publish_uncertain if job else (entry.publish_uncertain if entry else False),
        prior_uncertain=bool(entry and entry.prior_uncertain) or bool(job and job.publish_uncertain),
        result_text=job.result_text if job else (entry.result_text if entry else None),
        username=entry.username if entry else None,
        accepted_at=entry.accepted_at if entry else None,
        planned_for=entry.planned_for if entry else None,
        time_source=entry.time_source if entry else None,
        post_id=entry.post_id if entry else None,
        post_url=history.post_url_of(entry) if entry else None,
        link_state=(entry.link_state or "") if entry else "",
        tiktok_schedule_time=entry.tiktok_schedule_time if entry else None,
        schedule_mode=history.schedule_mode_of(entry, job) if entry else "",  # job already loaded: no extra query
    )


def _failure(session: Session, key: str) -> JSONResponse:
    """500, but still carrying the receipt's current status like every desktop job response."""
    receipt = session.get(DesktopReceipt, key)
    body = _read(receipt, session).model_dump(mode="json") if receipt else {"request_id": key, "status": "missing"}
    body["detail"] = "desktop preparation interrupted; inspect the receipt before retrying"
    return JSONResponse(body, status_code=500)


def expire_stale(session: Session, request_id: str | None = None) -> int:
    """Preparations without a heartbeat for STALE_PREPARING_AFTER become preparation_failed
    (terminal). Conditional, so an attempt that has just written a heartbeat is never expired."""
    cutoff = now_utc() - STALE_PREPARING_AFTER
    stale = [DesktopReceipt.state == "preparing",
             func.coalesce(DesktopReceipt.heartbeat_at, DesktopReceipt.created_at) < cutoff]
    if request_id:
        stale.append(DesktopReceipt.request_id == request_id)
    keys = session.exec(select(DesktopReceipt.request_id).where(*stale)).all()
    expired = 0
    for chunk in history.chunks(keys):
        expired += session.exec(update(DesktopReceipt).where(*stale, DesktopReceipt.request_id.in_(chunk))
                                .values(state="preparation_failed")).rowcount
        failed = select(DesktopReceipt.request_id).where(
            DesktopReceipt.request_id.in_(chunk), DesktopReceipt.state == "preparation_failed")
        session.exec(update(UploadHistory).where(
            UploadHistory.key.in_([f"request:{k}" for k in chunk]), UploadHistory.status == "preparing",
            UploadHistory.request_id.in_(failed),
        ).values(status="preparation_failed", finished_at=now_utc(), result_text=STALE_TEXT))
    if keys:
        session.commit()
    if expired:
        log.warning("desktop: %d stalled preparation(s) marked preparation_failed", expired)
    return expired


def _mark_failed(session: Session, key: str, token: str) -> None:
    won = session.exec(update(DesktopReceipt).where(
        DesktopReceipt.request_id == key, DesktopReceipt.state == "preparing",
        DesktopReceipt.attempt_token == token).values(state="preparation_failed")).rowcount
    if won:
        session.exec(update(UploadHistory).where(
            UploadHistory.key == f"request:{key}", UploadHistory.status == "preparing",
        ).values(status="preparation_failed", finished_at=now_utc(), result_text=FAILED_TEXT))
    session.commit()


def _beat(key: str, token: str) -> bool:
    """Short separate transaction. False only when this attempt no longer owns the receipt."""
    try:
        with Session(_api_db.engine) as s:
            won = s.exec(update(DesktopReceipt).where(
                DesktopReceipt.request_id == key, DesktopReceipt.state == "preparing",
                DesktopReceipt.attempt_token == token).values(heartbeat_at=now_utc())).rowcount
            s.commit()
            return won == 1
    except OperationalError:
        log.warning("desktop %s: heartbeat write failed (database busy); retrying later", key)
        return True


class _AttemptLost(Exception):
    pass


class _AttemptWriter:
    """copyfileobj target: hashes while copying and keeps the attempt's heartbeat fresh."""

    def __init__(self, out, key: str, token: str):
        self.out, self.key, self.token = out, key, token
        self.digest = hashlib.sha256()
        self.next_beat = time.monotonic() + HEARTBEAT_EVERY

    def write(self, data) -> int:
        self.digest.update(data)
        written = self.out.write(data)
        if time.monotonic() >= self.next_beat:
            if not _beat(self.key, self.token):
                raise _AttemptLost("the preparation was declared stalled")
            self.next_beat = time.monotonic() + HEARTBEAT_EVERY
        return written


def _remove_own(paths) -> None:
    for path in paths:
        try:
            path.unlink(missing_ok=True)
        except OSError as exc:  # removed again at the next startup
            log.warning("desktop: could not remove %s: %s", path.name, exc)


def recover_on_startup(session: Session) -> int:
    """Expire stalled preparations, then delete bridge files no job can use: owned by a
    preparation_failed (or missing) receipt and referenced by no ScheduledUpload."""
    expire_stale(session)
    referenced = set(session.exec(select(ScheduledUpload.source_ref)
                                  .where(ScheduledUpload.source_type == "local")).all())
    removed = 0
    for path in library.library_dir().iterdir():
        name = path.name
        visible = name[1:-len(".part")] if name.startswith(".") and name.endswith(".part") else name
        match = _OWN_NAME.match(visible)
        if not match or visible in referenced or not path.is_file():
            continue
        receipt = session.get(DesktopReceipt, match.group(1))
        if receipt is not None and receipt.state != "preparation_failed":
            continue
        _remove_own([path])
        removed += not path.exists()
    if removed:
        log.warning("desktop: removed %d file(s) left by failed preparations", removed)
    return removed


@router.get("/{request_id}", response_model=DesktopJobRead)
def get_job(request_id: str, session: Session = Depends(get_session)):
    key = _key(request_id)
    receipt = session.get(DesktopReceipt, key)
    if receipt is None:
        raise HTTPException(404, "desktop request not found")
    if expire_stale(session, key):
        session.refresh(receipt)
    return _read(receipt, session)


@router.post("", response_model=DesktopJobRead)
def create_job(
    request_id: str = Form(...), username: str = Form(...),
    title: str = Form(..., min_length=1, max_length=2200),
    scheduled_for: str = Form(""), options_json: str = Form("{}"),
    reel_id: str = Form("", max_length=128), source_sha256: str = Form(""),
    video: UploadFile = File(...), session: Session = Depends(get_session),
):
    key = _key(request_id)
    source_sha = source_sha256.strip().lower()  # identity of the user's original file, not the cleaned remux
    if source_sha and not re.fullmatch(r"[0-9a-f]{64}", source_sha):
        raise HTTPException(422, "source_sha256 must be 64 hex characters")
    existing = session.get(DesktopReceipt, key)
    if existing:  # same key replay: report it, never prepare again
        if expire_stale(session, key):
            session.refresh(existing)
        return _read(existing, session)
    acct = _require_account(session, username, allow_chrome=True)
    token = uuid4().hex
    try:
        options = UploadOptions.model_validate_json(options_json)
        when = datetime.fromisoformat(scheduled_for.replace("Z", "+00:00")) if scheduled_for else None
        if when:  # scheduled ON TikTok: same window and private rule as the web schedules
            when = check_native_schedule(when, options.visibility_type, now_utc())
        name = library.safe_filename(f"kid-{key}-{token}{os.path.splitext(video.filename or '')[1]}")
    except ValueError as exc:
        raise HTTPException(422, str(exc)) from None
    receipt = DesktopReceipt(request_id=key, attempt_token=token, heartbeat_at=now_utc())
    session.add(receipt)
    preparing = UploadHistory(key=f"request:{key}", request_id=key, username=username,
        reel_id=reel_id, original_name=video.filename or "video.mp4", status="preparing", planned_for=when)
    session.add(preparing)
    try:
        session.commit()
    except IntegrityError:
        session.rollback()
        return _read(session.get(DesktopReceipt, key), session)
    dest = library.library_dir() / name
    partial = dest.with_name(f".{name}.part")
    own: list[Path] = [partial, dest]  # only this attempt's names, never another request's files
    try:
        with open(partial, "xb") as out:
            writer = _AttemptWriter(out, key, token)
            shutil.copyfileobj(video.file, writer, length=1024 * 1024)
            out.flush()
            os.fsync(out.fileno())
        partial.replace(dest)
        # Hashed while copying: SQLite's write lock is never held while reading the file.
        sha256 = writer.digest.hexdigest()
        stored = options.model_dump()
        stored[SCHEDULE_MODE_OPTION] = "native" if when else "now"
        if when:
            stored[SCHEDULE_OPTION] = when.isoformat()
        # Always due now: a scheduled post is handed to TikTok right away and TikTok publishes it later,
        # so this PC does not need to be on at the scheduled time.
        job = ScheduledUpload(
            account_id=acct.id, source_type="local", source_ref=dest.name,
            title=title, options_json=json.dumps(stored), scheduled_for=now_utc(),
            status=ext.queued_status(acct),  # Chrome jobs never sit in 'pending' (v3.1.0 would claim them)
        )
        session.add(job)
        session.flush()
        won = session.exec(update(DesktopReceipt).where(
            DesktopReceipt.request_id == key, DesktopReceipt.state == "preparing",
            DesktopReceipt.attempt_token == token).values(state="queued", schedule_id=job.id)).rowcount
        if won != 1:
            # Declared stalled meanwhile: that outcome was already reported, so never enqueue now.
            session.rollback()
            _remove_own(own)
            log.warning("desktop %s: late preparation refused; the receipt is no longer preparing", key)
            return _failure(session, key)
        session.delete(preparing)  # atomically replace the preparation placeholder with the durable job outcome
        session.flush()
        entry = history.track_schedule(session, job, request_id=key, sha256=source_sha or sha256,
                                       reel_id=reel_id or history.reel_id_from_name(video.filename or ""),
                                       original_name=video.filename or "video.mp4")
        if when:
            entry.planned_for = when
        session.commit()
    except Exception as exc:
        session.rollback()
        # A handled preparation failure never reached the scheduler: terminal for this key.
        _remove_own(own)
        _mark_failed(session, key, token)
        if not isinstance(exc, _AttemptLost):
            log.exception("desktop %s: preparation failed", key)
        return _failure(session, key)
    return _read(receipt, session)
