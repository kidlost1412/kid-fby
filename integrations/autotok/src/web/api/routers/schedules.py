"""CRUD over scheduled_uploads.

Create inserts a 'pending' row; the scheduler container picks it up when its
scheduled_for is due. Update only allows safe transitions (cancel, reschedule
forward). Delete is soft via status=cancelled, except for terminal rows where
it hard-deletes.
"""
from __future__ import annotations

import json
from datetime import timezone
from typing import List, Optional

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import delete, update
from sqlmodel import Session, select

from api.db import get_session, now_utc
from api.models import Account, ScheduledUpload, UploadHistory
from api.schemas import (
    ScheduledUploadCreate,
    ScheduledUploadRead,
    ScheduledUploadUpdate,
)
from api.services import videos as library
from api.services.history import chunks, local_identity, schedule_key, track_schedule
from api.services.tiktok_adapter import SCHEDULE_MODE_OPTION, SCHEDULE_OPTION, native_schedule

NATIVE_LOCKED = "Đã hẹn trên TikTok — sửa/hủy trong TikTok Studio"


def _native_time(row: ScheduledUpload):
    try:
        return native_schedule(json.loads(row.options_json or "{}"))
    except ValueError:
        return None

def _legacy_options(row: ScheduledUpload):
    """Parsed options of a job made before native scheduling (no schedule_mode), else None."""
    try:
        options = json.loads(row.options_json or "{}")
    except ValueError:
        options = {}
    if not isinstance(options, dict) or options.get(SCHEDULE_MODE_OPTION):
        return None
    return options


router = APIRouter(prefix="/api/schedules", tags=["schedules"])


def _with_prior_uncertain(session: Session, rows) -> List[ScheduledUploadRead]:
    """Attach history fields (prior_uncertain, link, TikTok schedule): one query per chunk, not one per row."""
    keys = {schedule_key(row): row.id for row in rows}
    entries: dict = {}
    for chunk in chunks(keys):
        for entry in session.exec(select(UploadHistory).where(UploadHistory.key.in_(chunk))).all():
            entries[entry.key] = entry
    out = []
    for row in rows:
        item = ScheduledUploadRead.model_validate(row)
        entry = entries.get(schedule_key(row))
        item.prior_uncertain = bool(entry and entry.prior_uncertain)
        item.tiktok_schedule_time = (entry.tiktok_schedule_time if entry and entry.tiktok_schedule_time
                                     else _native_time(row))
        if item.tiktok_schedule_time is not None and item.tiktok_schedule_time.tzinfo is None:
            item.tiktok_schedule_time = item.tiktok_schedule_time.replace(tzinfo=timezone.utc)
        if entry:
            item.post_id, item.post_url, item.link_state = entry.post_id, entry.post_url, entry.link_state or ""
        out.append(item)
    return out


@router.get("", response_model=List[ScheduledUploadRead])
def list_schedules(
    status_filter: Optional[str] = Query(default=None, alias="status"),
    session: Session = Depends(get_session),
):
    q = select(ScheduledUpload).order_by(ScheduledUpload.scheduled_for)
    if status_filter:
        q = q.where(ScheduledUpload.status == status_filter)
    return _with_prior_uncertain(session, session.exec(q).all())


@router.get("/{schedule_id}", response_model=ScheduledUploadRead)
def get_schedule(schedule_id: int, session: Session = Depends(get_session)):
    row = session.get(ScheduledUpload, schedule_id)
    if not row:
        raise HTTPException(status_code=404, detail="schedule not found")
    return _with_prior_uncertain(session, [row])[0]


@router.post("", response_model=ScheduledUploadRead, status_code=status.HTTP_201_CREATED)
def create_schedule(
    payload: ScheduledUploadCreate,
    session: Session = Depends(get_session),
):
    acct = session.exec(select(Account).where(Account.username == payload.username)).first()
    if not acct:
        raise HTTPException(status_code=404, detail=f"account '{payload.username}' not found")

    source_ref = payload.source_ref
    sha256 = reel_id = ""
    if payload.source_type == "local":
        # Only files in the video library can be scheduled; store the name so
        # the row stays valid if the volume is mounted somewhere else.
        try:
            source_ref = library.resolve(payload.source_ref).name
        except ValueError as e:
            raise HTTPException(status_code=400, detail=str(e))
        sha256, reel_id = local_identity(source_ref)  # before the write transaction, not under its lock

    # Scheduled ON TikTok: the job runs now and TikTok holds the post until scheduled_for.
    when = payload.scheduled_for.astimezone(timezone.utc)
    options = payload.options.model_dump()
    options.update({SCHEDULE_MODE_OPTION: "native", SCHEDULE_OPTION: when.isoformat()})
    row = ScheduledUpload(
        account_id=acct.id,
        source_type=payload.source_type,
        source_ref=source_ref,
        title=payload.title,
        options_json=json.dumps(options),
        scheduled_for=now_utc(),
        status="pending",
    )
    session.add(row)
    session.flush()
    entry = track_schedule(session, row, sha256=sha256, reel_id=reel_id)
    entry.planned_for = when
    session.commit()
    session.refresh(row)
    return _with_prior_uncertain(session, [row])[0]


@router.patch("/{schedule_id}", response_model=ScheduledUploadRead)
def update_schedule(
    schedule_id: int,
    payload: ScheduledUploadUpdate,
    session: Session = Depends(get_session),
):
    row = session.get(ScheduledUpload, schedule_id)
    if not row:
        raise HTTPException(status_code=404, detail="schedule not found")
    if payload.scheduled_for is not None and _native_time(row) is not None:
        raise HTTPException(status_code=409, detail=NATIVE_LOCKED)
    if row.status not in ("pending", "failed"):
        # Running, succeeded, cancelled rows are terminal from a CRUD perspective.
        raise HTTPException(status_code=409, detail=f"cannot modify row in status '{row.status}'")

    changes: dict = {"updated_at": now_utc()}
    if payload.scheduled_for is not None:
        changes["scheduled_for"] = payload.scheduled_for
    if payload.title is not None:
        changes["title"] = payload.title
    if payload.status is not None:
        # Only two safe transitions: pending→cancelled, failed→pending (retry)
        if payload.status == "cancelled" and row.status in ("pending", "failed"):
            changes["status"] = "cancelled"
        elif payload.status == "pending" and row.status == "failed":
            if row.publish_uncertain and not payload.confirm_uncertain:
                raise HTTPException(
                    status_code=409,
                    detail="This video may already be on TikTok: the last attempt was cut off while "
                           "publishing. Check the account first, then retry with confirm_uncertain=true "
                           "if it isn't there.",
                )
            changes.update(status="pending", result_text=None, publish_uncertain=False)
            legacy_options = _legacy_options(row)
            if legacy_options is not None:
                # Old PC-side job: the owner asked for it now, so it must not be re-expired as late.
                legacy_options[SCHEDULE_MODE_OPTION] = "now"
                changes.update(options_json=json.dumps(legacy_options), scheduled_for=now_utc())
        else:
            raise HTTPException(
                status_code=409,
                detail=f"invalid transition {row.status}→{payload.status}",
            )
    # Only write if the row is still in the state we checked: the scheduler may have claimed it
    # in the meantime, and a cancelled or edited job must not run with stale data.
    result = session.exec(
        update(ScheduledUpload)
        .where(ScheduledUpload.id == schedule_id)
        .where(ScheduledUpload.status == row.status)
        .values(**changes)
    )
    if result.rowcount != 1:
        session.rollback()
        raise HTTPException(status_code=409, detail="the job changed while you were editing it; refresh and try again")
    session.refresh(row)
    entry = track_schedule(session, row)
    if payload.scheduled_for is not None:
        entry.planned_for = row.scheduled_for  # a user reschedule moves the plan; retry backoff never does
    session.commit()
    return _with_prior_uncertain(session, [row])[0]


@router.delete("/{schedule_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_schedule(schedule_id: int, session: Session = Depends(get_session)):
    row = session.get(ScheduledUpload, schedule_id)
    if not row:
        raise HTTPException(status_code=404, detail="schedule not found")
    if row.status == "running":
        raise HTTPException(status_code=409, detail="cannot delete a running job; wait for it to finish")
    entry = track_schedule(session, row, legacy=True)
    if row.status == "pending":
        entry.status = "cancelled"
        entry.finished_at = now_utc()
        session.add(entry)
    # Conditional, like update_schedule: never delete a job the scheduler has just claimed.
    result = session.exec(
        delete(ScheduledUpload)
        .where(ScheduledUpload.id == schedule_id)
        .where(ScheduledUpload.status != "running")
    )
    if result.rowcount != 1:
        session.rollback()
        raise HTTPException(status_code=409, detail="cannot delete a running job; wait for it to finish")
    session.commit()  # only our record: a post TikTok is holding is NOT cancelled (the UIs say so)
