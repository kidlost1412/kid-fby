"""Read-only lookup of an account's own recent posts, to find the public id of a post.

STUB: ``find_post`` returns None. Listing an account's posts needs TikTok's web
``/api/post/item_list/`` endpoint with the account's ``secUid`` and request signing,
and the local account name is not necessarily the TikTok @handle; this could not be
built and checked without a live account, so it is left unimplemented on purpose.
The matching rule is implemented and tested (``match_post``) so a real lister can be
plugged in. Nothing here may upload or publish.
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone
from typing import Iterable, Optional

MATCH_WINDOW = timedelta(minutes=15)


def _norm(text: str) -> str:
    return " ".join((text or "").split())


def match_post(items: Iterable[dict], caption: str, near_time: datetime) -> Optional[str]:
    """The id of the single post whose caption equals ``caption`` (whitespace-normalized) and whose
    ``createTime`` (unix seconds) is within MATCH_WINDOW of ``near_time``. None when 0 or >1 match."""
    if near_time.tzinfo is None:
        near_time = near_time.replace(tzinfo=timezone.utc)
    want = _norm(caption)
    if not want:
        return None
    hits = []
    for item in items or ():
        try:
            created = datetime.fromtimestamp(int(item.get("createTime")), tz=timezone.utc)
        except (TypeError, ValueError, OverflowError, OSError):
            continue
        post_id = str(item.get("id") or "")
        if (post_id.isdigit() and _norm(item.get("desc") or "") == want
                and abs(created - near_time) <= MATCH_WINDOW):
            hits.append(post_id)
    return hits[0] if len(set(hits)) == 1 else None


def find_post(username: str, caption: str, near_time: datetime) -> Optional[str]:
    """STUB (see module docstring): always None, so the link state machine ends in gave_up."""
    return None
