"""SQLModel ORM tables. Also serve as the source of truth for the DB schema
that is exposed through OpenAPI (via response_model in the routers).
"""
from __future__ import annotations

from datetime import datetime
from typing import Optional

from sqlmodel import Field, SQLModel

from api.db import now_utc


# ---------- accounts ---------------------------------------------------------

class Account(SQLModel, table=True):
    __tablename__ = "accounts"

    id: Optional[int] = Field(default=None, primary_key=True)
    username: str = Field(index=True, unique=True, max_length=128)
    display_name: Optional[str] = Field(default=None, max_length=128)
    cookie_path: str  # absolute path to tiktok_session-{username}.cookie
    has_valid_session: bool = Field(default=True)
    created_at: datetime = Field(default_factory=now_utc)
    updated_at: datetime = Field(default_factory=now_utc)
    last_used_at: Optional[datetime] = Field(default=None)


# ---------- scheduled uploads -----------------------------------------------

class ScheduledUpload(SQLModel, table=True):
    __tablename__ = "scheduled_uploads"

    id: Optional[int] = Field(default=None, primary_key=True)
    account_id: int = Field(foreign_key="accounts.id", index=True)

    # 'local' = source_ref is an absolute file path on the shared volume.
    # 'youtube' = source_ref is a YouTube URL that the worker will resolve
    # via yt-dlp at run time.
    source_type: str = Field(max_length=16)
    source_ref: str
    title: str = Field(max_length=2200)

    # Mirror of CLI upload flags so the worker can call upload_video with the
    # same signature. Stored as a JSON string for schema simplicity.
    options_json: str = Field(default="{}")

    scheduled_for: datetime = Field(index=True)

    # pending → running → succeeded|failed|cancelled
    status: str = Field(default="pending", index=True, max_length=16)

    result_text: Optional[str] = Field(default=None)
    # Set when a failed job may still have been posted (the publish request was cut off, or the
    # scheduler stopped mid-upload). Retrying it needs an explicit confirmation.
    publish_uncertain: bool = Field(default=False)
    attempts: int = Field(default=0)
    heartbeat_at: Optional[datetime] = Field(default=None)

    created_at: datetime = Field(default_factory=now_utc)
    updated_at: datetime = Field(default_factory=now_utc)


# ---------- noVNC login sessions --------------------------------------------

class DesktopReceipt(SQLModel, table=True):
    """Idempotency receipt for the Kid FB.Y bridge. No local source paths/cookies."""
    __tablename__ = "desktop_receipts"
    request_id: str = Field(primary_key=True, max_length=32)
    schedule_id: Optional[int] = None  # retain receipt if a dashboard job is deleted
    state: str = "preparing"
    # Owner of the in-flight preparation; only this attempt may enqueue or delete its files.
    attempt_token: str = ""
    heartbeat_at: Optional[datetime] = None  # bumped while copying; stale -> preparation_failed
    created_at: datetime = Field(default_factory=now_utc)


class UploadHistory(SQLModel, table=True):
    """Independent outcome journal: deleting a schedule/account never erases it."""
    __tablename__ = "upload_history"
    key: str = Field(primary_key=True)
    schedule_id: Optional[int] = Field(default=None, index=True)
    request_id: Optional[str] = Field(default=None, index=True)
    username: str = Field(index=True)
    reel_id: str = Field(default="", index=True)
    sha256: str = Field(default="", index=True)
    original_name: str = ""
    status: str = "pending"
    planned_for: Optional[datetime] = None
    accepted_at: Optional[datetime] = None  # API acknowledgement, NOT public profile verification
    finished_at: Optional[datetime] = None
    time_source: str = "acknowledgement"
    media_video_id: Optional[str] = None  # upstream storage ID; not an aweme/public post ID
    publish_uncertain: bool = False
    # Monotonic: set once any attempt ended uncertain (or succeeded late); a retry never clears it.
    prior_uncertain: bool = False
    result_text: Optional[str] = None
    created_at: datetime = Field(default_factory=now_utc)
    # v3: public post link. post_url is only ever built by the backend from username + post_id.
    post_id: Optional[str] = None
    post_url: Optional[str] = None
    creation_id: Optional[str] = None
    # '' (nothing to fetch), pending, found, gave_up, scheduled_on_tiktok (TikTok holds the post until
    # tiktok_schedule_time). A natively scheduled post keeps status 'succeeded': TikTok accepted it.
    link_state: str = Field(default="", index=True, sa_column_kwargs={"server_default": ""})
    link_attempts: int = Field(default=0, sa_column_kwargs={"server_default": "0"})
    link_next_at: Optional[datetime] = None
    tiktok_schedule_time: Optional[datetime] = None  # UTC; set only when TikTok holds the post
    publish_response_json: Optional[str] = None  # sanitized, at most ~8 KB
    caption: Optional[str] = None  # what was posted; the late link lookup matches on it


class LoginSession(SQLModel, table=True):
    __tablename__ = "login_sessions"

    id: str = Field(primary_key=True, max_length=64)  # uuid
    username: str = Field(index=True, max_length=128)
    # pending → active → completed|failed|expired
    status: str = Field(default="pending", max_length=16)
    vnc_url: Optional[str] = Field(default=None)
    error: Optional[str] = Field(default=None)

    started_at: datetime = Field(default_factory=now_utc)
    completed_at: Optional[datetime] = Field(default=None)
