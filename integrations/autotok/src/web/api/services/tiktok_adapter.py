"""The one place the API and the scheduler call into autotok to upload.

Never raises for upload problems: everything comes back as an
:class:`UploadOutcome`, with ``retryable`` set only when nothing reached
TikTok's publish endpoint (so retrying cannot create a duplicate post), and
``uncertain`` set when the video may have been posted despite the failure.
Tests patch ``upload_from_options``.
"""
from __future__ import annotations

import logging
import traceback
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any, Optional

from autotok import Client
from autotok.errors import AutotokError, PublishUncertainError
from autotok.browser_publish import redact_url
from autotok.uploader import sanitize_response
from autotok.proxy import parse_proxy

log = logging.getLogger("api.upload")


@dataclass
class UploadOutcome:
    ok: bool
    message: str
    retryable: bool = False
    video_id: Optional[str] = None
    uncertain: bool = False  # the post may exist: check TikTok before retrying
    post_id: Optional[str] = None  # public post id, when TikTok's answer named it
    creation_id: Optional[str] = None
    tiktok_schedule_time: Optional[datetime] = None  # set when TikTok itself holds the post until then
    response_json: str = ""  # sanitized publish response (no token/cookie/session/sign/ticket keys)

# Key in a job's options_json: the job is scheduled ON TikTok for this UTC ISO time.
SCHEDULE_OPTION = "tiktok_schedule_time"
# Key in options_json of every job created by this version: "native" (TikTok holds the post) or "now".
# Jobs without it are legacy jobs that waited on this PC until their due time.
SCHEDULE_MODE_OPTION = "schedule_mode"


def native_schedule(options: dict[str, Any]) -> Optional[datetime]:
    raw = options.get(SCHEDULE_OPTION) if isinstance(options, dict) else None
    if not raw:
        return None
    when = datetime.fromisoformat(str(raw).replace("Z", "+00:00"))
    return when if when.tzinfo else when.replace(tzinfo=timezone.utc)


def error_response_json(exc: Exception) -> str:
    """Sanitized {"step", "http_status", "response"|"body"} for a failed attempt, "" if TikTok never answered."""
    step = getattr(exc, "step", None)
    if not step:
        return ""
    response = getattr(exc, "response", None)
    wrapper: dict[str, Any] = {
        "step": step if step in ("create project", "publish") else "transfer",
        "http_status": getattr(exc, "http_status", None) or getattr(exc, "status", None),
    }
    if step not in ("create project", "publish"):
        wrapper["detail"] = step
    if response:
        wrapper["response"] = response
    elif getattr(exc, "body", None):
        wrapper["body"] = exc.body[:2048]
    return sanitize_response(wrapper)


def upload_from_options(username: str, video_path: str, title: str, options: dict[str, Any]) -> UploadOutcome:
    try:
        schedule = native_schedule(options)
    except ValueError:  # nothing was sent: a definite failure, never "maybe posted"
        return UploadOutcome(ok=False, message=f"invalid {SCHEDULE_OPTION} in job options")
    try:
        override = parse_proxy(options.get("proxy") or None)
        client = Client.from_account(username, proxy=override if override else True)
        result = client.upload(
            video_path,
            title,
            schedule=schedule,
            visibility=int(options.get("visibility_type", 0)),
            allow_comment=bool(int(options.get("allow_comment", 1))),
            allow_duet=bool(int(options.get("allow_duet", 0))),
            allow_stitch=bool(int(options.get("allow_stitch", 0))),
            ai_label=bool(int(options.get("ai_label", 0))),
        )
    except AutotokError as exc:
        return UploadOutcome(ok=False, message=redact_url(exc), retryable=exc.retryable,
                             uncertain=isinstance(exc, PublishUncertainError),
                             response_json=error_response_json(exc))
    except Exception as exc:  # a bug: never retry automatically, it may have posted
        # Traceback text may quote a signed URL: log it redacted, never raw.
        log.error("unexpected upload failure\n%s", redact_url(traceback.format_exc()))
        return UploadOutcome(ok=False, message=f"unexpected error: {redact_url(exc)}", retryable=False, uncertain=True)
    return UploadOutcome(ok=True, message="scheduled on TikTok" if result.scheduled_for else "published",
                         video_id=result.video_id, post_id=result.post_id, creation_id=result.creation_id,
                         tiktok_schedule_time=result.scheduled_for,
                         response_json=sanitize_response(result.response))
