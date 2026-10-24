"""Pydantic request/response schemas — separate from SQLModel tables so we can
validate input (e.g. reject past scheduled_for, reject non-YouTube URLs) without
polluting the ORM layer. These schemas are what appears in `/docs`.
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone
from typing import Any, Literal, Optional

from pydantic import BaseModel, Field, field_validator, model_validator

from autotok.errors import ValidationError as AutotokValidationError
from autotok.proxy import parse_proxy
from autotok.youtube import is_youtube_url

USERNAME_PATTERN = r"^[A-Za-z0-9_.\-]+$"


def _validate_proxy(v: Optional[str]) -> Optional[str]:
    """Normalise a proxy string to its URL form; '' means "no proxy"."""
    if v is None:
        return None
    if not v.strip():
        return ""
    try:
        return parse_proxy(v).url
    except AutotokValidationError as e:
        raise ValueError(str(e)) from None


# ---------- accounts ---------------------------------------------------------

class AccountRead(BaseModel):
    id: int
    username: str
    display_name: Optional[str]
    cookie_path: str
    has_valid_session: bool
    proxy: Optional[str] = None  # masked: http://user:****@host:port
    created_at: datetime
    updated_at: datetime
    last_used_at: Optional[datetime]

    model_config = {"from_attributes": True}

    @field_validator("created_at", "updated_at", "last_used_at")
    @classmethod
    def _utc_dates(cls, v):
        return v.replace(tzinfo=timezone.utc) if v is not None and v.tzinfo is None else v


class AccountCreate(BaseModel):
    # Register an existing session file (produced by `autotok login` or a
    # previous browser login) against a username. This endpoint does not log in.
    username: str = Field(min_length=1, max_length=128, pattern=USERNAME_PATTERN)
    display_name: Optional[str] = Field(default=None, max_length=128)


class AccountUpdate(BaseModel):
    display_name: Optional[str] = Field(default=None, max_length=128)
    # Full proxy URL to set, "" to clear, omitted to leave unchanged.
    proxy: Optional[str] = None

    @field_validator("proxy")
    @classmethod
    def _check_proxy(cls, v: Optional[str]) -> Optional[str]:
        return _validate_proxy(v)


class SessionCheckResponse(BaseModel):
    valid: bool


# ---------- proxies ----------------------------------------------------------

class ProxyTestRequest(BaseModel):
    proxy: Optional[str] = None  # test this proxy...
    account_id: Optional[int] = None  # ...or this account's saved proxy

    @field_validator("proxy")
    @classmethod
    def _check_proxy(cls, v: Optional[str]) -> Optional[str]:
        return _validate_proxy(v) or None


class ProxyTestResponse(BaseModel):
    ok: bool
    proxy: Optional[str]  # masked
    ip: Optional[str] = None
    error: Optional[str] = None


class ProxyProviderRead(BaseModel):
    key: str
    name: str
    tagline: str
    signup_url: str
    proxy_format: str
    steps: list[str]
    sponsor: bool


# ---------- uploads (immediate) ---------------------------------------------

class UploadOptions(BaseModel):
    """Mirrors the CLI upload flags. All optional with sensible defaults."""
    allow_comment: Literal[0, 1] = 1
    allow_duet: Literal[0, 1] = 0
    allow_stitch: Literal[0, 1] = 0
    visibility_type: Literal[0, 1] = 0  # 0=public, 1=private
    ai_label: Literal[0, 1] = 0
    # Per-upload override; empty means "use the account's saved proxy".
    proxy: str = ""

    @field_validator("proxy")
    @classmethod
    def _check_proxy(cls, v: str) -> str:
        return _validate_proxy(v) or ""


class UploadYouTubeRequest(BaseModel):
    username: str
    title: str = Field(min_length=1, max_length=2200)
    youtube_url: str
    options: UploadOptions = Field(default_factory=UploadOptions)

    @field_validator("youtube_url")
    @classmethod
    def _youtube(cls, v: str) -> str:
        if not is_youtube_url(v):
            raise ValueError("youtube_url must be a valid YouTube URL")
        return v


class UploadLibraryRequest(BaseModel):
    username: str
    title: str = Field(min_length=1, max_length=2200)
    name: str  # file name in the video library
    options: UploadOptions = Field(default_factory=UploadOptions)


class UploadResponse(BaseModel):
    ok: bool
    message: str
    video_id: Optional[str] = None
    uncertain: bool = False
    retryable: bool = False


# ---------- schedules --------------------------------------------------------

# "Hẹn giờ" schedules ON TikTok (the PC may be off at the due time). TikTok needs >= 15 min; 20 min
# leaves room for the upload itself. Some accounts can only schedule 10 days ahead.
NATIVE_MIN_AHEAD = timedelta(minutes=20)
NATIVE_MAX_AHEAD = timedelta(days=10)
NATIVE_SLACK = timedelta(seconds=30)  # request transit: "exactly 20 min" picked by the user still passes
WINDOW_TEXT = "Giờ hẹn phải từ 20 phút đến 10 ngày kể từ bây giờ (TikTok giữ bài và tự đăng)."
PRIVATE_TEXT = "TikTok không cho hẹn giờ video riêng tư (Chỉ mình tôi). Bỏ hẹn giờ hoặc chọn công khai."


def check_native_schedule(when: datetime, visibility_type: int, now: Optional[datetime] = None) -> datetime:
    """Raise ValueError (Vietnamese, shown to the user) unless TikTok can schedule ``when``."""
    if when.tzinfo is None:
        raise ValueError("scheduled_for must include timezone info")
    now = now or datetime.now(timezone.utc)
    if visibility_type == 1:
        raise ValueError(PRIVATE_TEXT)
    if when < now + NATIVE_MIN_AHEAD - NATIVE_SLACK or when > now + NATIVE_MAX_AHEAD:
        raise ValueError(WINDOW_TEXT)
    return when.astimezone(timezone.utc)

class ScheduledUploadCreate(BaseModel):
    username: str
    title: str = Field(min_length=1, max_length=2200)
    source_type: Literal["local", "youtube"]
    source_ref: str  # file name in the video library (local) or YouTube URL
    scheduled_for: datetime  # ISO-8601; must have tzinfo
    options: UploadOptions = Field(default_factory=UploadOptions)

    @model_validator(mode="after")
    def _validate(self) -> "ScheduledUploadCreate":
        check_native_schedule(self.scheduled_for, self.options.visibility_type)
        if self.source_type == "youtube" and not is_youtube_url(self.source_ref):
            raise ValueError("source_ref must be a valid YouTube URL when source_type='youtube'")
        return self


class ScheduledUploadUpdate(BaseModel):
    scheduled_for: Optional[datetime] = None
    title: Optional[str] = Field(default=None, max_length=2200)
    status: Optional[Literal["pending", "cancelled"]] = None  # only safe transitions
    # Retrying a job whose video may already be on TikTok (publish_uncertain) needs this set,
    # after checking the account: otherwise the video could be posted twice.
    confirm_uncertain: bool = False

    @model_validator(mode="after")
    def _validate(self) -> "ScheduledUploadUpdate":
        if self.scheduled_for is not None:
            if self.scheduled_for.tzinfo is None:
                raise ValueError("scheduled_for must include timezone info")
            if self.scheduled_for <= datetime.now(timezone.utc):
                raise ValueError("scheduled_for must be in the future")
        return self


def mask_options_json(raw: str) -> str:
    """Hide the proxy password in stored upload options before returning them."""
    import json

    try:
        data = json.loads(raw or "{}")
    except ValueError:
        return "{}"
    if isinstance(data, dict) and data.get("proxy"):
        try:
            data["proxy"] = parse_proxy(data["proxy"]).masked()
        except AutotokValidationError:
            data["proxy"] = "****"
    return json.dumps(data)


class ScheduledUploadRead(BaseModel):
    id: int
    account_id: int
    source_type: str
    source_ref: str
    title: str
    options_json: str
    scheduled_for: datetime
    status: str
    result_text: Optional[str]
    publish_uncertain: bool = False
    prior_uncertain: bool = False
    attempts: int
    heartbeat_at: Optional[datetime]
    created_at: datetime
    updated_at: datetime
    # From the job's history entry. tiktok_schedule_time: the post is held by TikTok until then.
    tiktok_schedule_time: Optional[datetime] = None
    post_id: Optional[str] = None
    post_url: Optional[str] = None
    link_state: str = ""
    tiktok_response: Optional[Any] = None  # sanitized TikTok answer; failed/uncertain rows only

    model_config = {"from_attributes": True}

    @field_validator("scheduled_for", "heartbeat_at", "created_at", "updated_at", "tiktok_schedule_time")
    @classmethod
    def _utc_dates(cls, v):
        return v.replace(tzinfo=timezone.utc) if v is not None and v.tzinfo is None else v

    @field_validator("options_json")
    @classmethod
    def _mask(cls, v: str) -> str:
        return mask_options_json(v)


# ---------- videos / browse --------------------------------------------------

class VideoFileInfo(BaseModel):
    name: str
    size_bytes: int
    modified_at: datetime


# ---------- login (noVNC) ----------------------------------------------------

class LoginBrowserStartRequest(BaseModel):
    username: str = Field(min_length=1, max_length=128, pattern=USERNAME_PATTERN)
    # Proxy for this account: used by the login browser and saved for uploads.
    proxy: Optional[str] = None

    @field_validator("proxy")
    @classmethod
    def _check_proxy(cls, v: Optional[str]) -> Optional[str]:
        return _validate_proxy(v) or None


class LoginBrowserStartResponse(BaseModel):
    session_id: str
    vnc_url: str


class LoginBrowserCompleteRequest(BaseModel):
    """Payload the noVNC control server POSTs back to the API when it detects
    the session cookies. The API is responsible for saving the account and
    updating the account row — noVNC stays stateless."""
    cookies: list[dict]
    user_agent: Optional[str] = None
    proxy: Optional[str] = None


class LoginSessionRead(BaseModel):
    id: str
    username: str
    status: str
    vnc_url: Optional[str]
    error: Optional[str]
    started_at: datetime
    completed_at: Optional[datetime]

    model_config = {"from_attributes": True}
