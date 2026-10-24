"""Late lookup of the public post link when TikTok's publish answer did not name the post id.

State per history row (``link_state``): '' (nothing to do) -> pending | scheduled_on_tiktok ->
found | gave_up. One row is claimed per idle scheduler tick with a conditional UPDATE (like
``claim_next_due``); the claim bumps ``link_attempts`` and leases the row, and the result is only
written if ``link_attempts`` is still the claimed value. This module only READS the account's own
posts (``autotok.posts.find_post``); it never uploads or publishes.
"""
from __future__ import annotations

import logging
from datetime import timedelta
from typing import Optional

from sqlalchemy import update
from sqlmodel import Session, select

import api.db as _api_db
from api.db import now_utc
from api.models import UploadHistory
from api.services.history import _POST_ID, build_post_url

log = logging.getLogger("api.links")

CLAIMABLE = ("pending", "scheduled_on_tiktok")
BACKOFF = (timedelta(minutes=1), timedelta(minutes=2), timedelta(minutes=5), timedelta(minutes=10))
MAX_ATTEMPTS = 10
LEASE = timedelta(minutes=10)  # a lookup that crashed is tried again after this


def _find_post(username: str, caption: str, near_time) -> Optional[str]:
    from autotok import posts  # imported lazily: tests patch it

    return posts.find_post(username, caption, near_time)


def next_delay(attempts: int) -> timedelta:
    """Wait after the ``attempts``-th miss: 2, 5, 10, 10... minutes (the first try waits 1)."""
    return BACKOFF[min(attempts, len(BACKOFF) - 1)]


def claim_next(session: Session) -> Optional[UploadHistory]:
    now = now_utc()
    row = session.exec(select(UploadHistory)
                       .where(UploadHistory.link_state.in_(CLAIMABLE), UploadHistory.link_next_at <= now)
                       .order_by(UploadHistory.link_next_at).limit(1)).first()
    if row is None:
        return None
    won = session.exec(update(UploadHistory)
                       .where(UploadHistory.key == row.key, UploadHistory.link_state == row.link_state,
                              UploadHistory.link_attempts == row.link_attempts)
                       .values(link_attempts=UploadHistory.link_attempts + 1, link_next_at=now + LEASE)).rowcount
    if won != 1:
        session.rollback()
        return None  # someone else claimed or changed it
    session.commit()
    session.refresh(row)
    return row


def finish(session: Session, key: str, attempts: int, post_id: Optional[str]) -> bool:
    """Record the lookup result of claim ``attempts``. False when a newer claim/reset owns the row."""
    entry = session.get(UploadHistory, key)
    if entry is None:
        return False
    url = build_post_url(entry.username, post_id)
    if url:
        values = dict(link_state="found", post_id=post_id, post_url=url, link_next_at=None)
    elif attempts >= MAX_ATTEMPTS:
        values = dict(link_state="gave_up", link_next_at=None)
    else:
        values = dict(link_state="pending", link_next_at=now_utc() + next_delay(attempts))
    won = session.exec(update(UploadHistory)
                       .where(UploadHistory.key == key, UploadHistory.link_attempts == attempts,
                              UploadHistory.link_state.in_(CLAIMABLE))
                       .values(**values)).rowcount
    if won != 1:
        session.rollback()
        return False
    session.commit()
    return True


def tick() -> bool:
    """Look up at most one due link. True if a row was processed."""
    with Session(_api_db.engine) as s:
        row = claim_next(s)
        if row is None:
            return False
        key, attempts, username = row.key, row.link_attempts, row.username
        caption = row.caption or ""
        near = row.tiktok_schedule_time or row.accepted_at
    post_id = None
    if caption and near is not None:
        try:
            post_id = _find_post(username, caption, near)
        except Exception as exc:  # read-only lookup: a failure is just a miss
            log.warning("post link lookup for %s failed: %s", key, exc)
    with Session(_api_db.engine) as s:
        finish(s, key, attempts, post_id)
    return True


def reset(session: Session, key: str) -> Optional[UploadHistory]:
    """'Thử lấy lại link': a succeeded row without a link goes back to pending, due now."""
    entry = session.get(UploadHistory, key)
    if entry is None:
        return None
    if entry.status != "succeeded" or entry.link_state == "found":
        return entry
    session.exec(update(UploadHistory).where(UploadHistory.key == key, UploadHistory.status == "succeeded",
                                             UploadHistory.link_state != "found")
                 .values(link_state="pending", link_attempts=0, link_next_at=now_utc()))
    session.commit()
    session.refresh(entry)
    return entry
