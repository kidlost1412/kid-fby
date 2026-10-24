"""Uploading and publishing videos through TikTok's web upload API."""
from __future__ import annotations

import json
import logging
import os
import re
import secrets
import shutil
import string
import subprocess
import sys
import time
import uuid
import zlib
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Union
from urllib.parse import quote

import requests
from requests_auth_aws_sigv4 import AWSSigV4

from . import settings
from .accounts import Account, AccountStore
from .captions import build_caption, make_user_resolver
from .errors import (
    AutotokError,
    NotLoggedInError,
    PublishError,
    PublishUncertainError,
    UploadError,
    ValidationError,
)
from .browser_publish import BrowserStartError, publish_in_browser
from .proxy import Proxy, parse_proxy, proxied_session
from .signer import Signer

log = logging.getLogger("autotok")

PROBE_TIMEOUT = 20


def _find_ffprobe() -> str | None:
    return shutil.which("ffprobe") or (os.environ.get("KID_FBY_FFPROBE") or None)


def probe_video(path: Path) -> dict | None:
    """Best-effort ffprobe of a local file: width, height, duration_ms, has_audio.

    Returns None when ffprobe is missing or fails; the caller then omits the fields.
    """
    exe = _find_ffprobe()
    if not exe:
        log.debug("ffprobe not found; skipping video probe")
        return None
    cmd = [exe, "-v", "error", "-print_format", "json",
           "-show_entries", "stream=codec_type,width,height:format=duration", str(path)]
    try:
        out = subprocess.run(cmd, capture_output=True, timeout=PROBE_TIMEOUT, check=True, shell=False).stdout
        data = json.loads(out.decode("utf-8", "replace"))
        streams = data.get("streams") or []
        video = next((s for s in streams if s.get("codec_type") == "video"), None)
        if video is None:
            raise ValueError("no video stream")
        result = {
            "width": int(video["width"]),
            "height": int(video["height"]),
            "duration_ms": int(round(float(data["format"]["duration"]) * 1000)),
            "has_audio": any(s.get("codec_type") == "audio" for s in streams),
        }
    except (OSError, subprocess.SubprocessError, ValueError, KeyError, TypeError) as exc:
        log.warning("ffprobe failed (%s); publishing without size/duration fields", exc)
        return None
    return result

MAX_CAPTION_LENGTH = 2200
MIN_SCHEDULE = timedelta(minutes=15)
MAX_SCHEDULE = timedelta(days=30)
# TikTok gives some accounts 30 days to schedule and others only 10, depending on account and region.
SHORT_SCHEDULE_WINDOW = timedelta(days=10)
CHUNK_SIZE = 5 * 1024 * 1024
DEFAULT_DATACENTER = "useast2a"
AID = 1988

Schedule = Union[int, float, timedelta, datetime, None]


# Windows time zone ids -> IANA names for the tz_name TikTok expects. TIKTOK_TZ_NAME overrides.
_WINDOWS_TZ = {
    "SE Asia Standard Time": "Asia/Bangkok", "China Standard Time": "Asia/Shanghai",
    "Singapore Standard Time": "Asia/Singapore", "Tokyo Standard Time": "Asia/Tokyo",
    "Korea Standard Time": "Asia/Seoul", "Taipei Standard Time": "Asia/Taipei",
    "India Standard Time": "Asia/Kolkata", "UTC": "UTC", "GMT Standard Time": "Europe/London",
    "W. Europe Standard Time": "Europe/Berlin", "Eastern Standard Time": "America/New_York",
    "Central Standard Time": "America/Chicago", "Pacific Standard Time": "America/Los_Angeles",
}


def local_tz_name() -> str:
    env = os.environ.get("TIKTOK_TZ_NAME", "").strip()
    if env:
        return env
    if sys.platform == "win32":
        try:
            import winreg
            with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, r"SYSTEM\CurrentControlSet\Control\TimeZoneInformation") as k:
                win = winreg.QueryValueEx(k, "TimeZoneKeyName")[0].replace(chr(0), '').strip()
            if win in _WINDOWS_TZ:
                return _WINDOWS_TZ[win]
        except OSError:
            pass
    else:
        try:
            link = os.path.realpath("/etc/localtime")
            if "zoneinfo/" in link:
                return link.split("zoneinfo/", 1)[1]
        except OSError:
            pass
    # Etc/GMT names have inverted signs: UTC+7 is Etc/GMT-7.
    offset = datetime.now().astimezone().utcoffset() or timedelta(0)
    hours = int(offset.total_seconds() // 3600)
    return "UTC" if hours == 0 else f"Etc/GMT{-hours:+d}"


@dataclass
class UploadResult:
    """What TikTok returned for a successful post."""

    video_id: str
    creation_id: str
    scheduled_for: datetime | None = None
    response: dict = field(default_factory=dict)
    # Public post (aweme) id, only when the publish response names it under a known key.
    post_id: str | None = None

    def __bool__(self) -> bool:  # truthy, so ``if upload_video(...)`` keeps working
        return True


# item_id / aweme_id / itemId / ItemID ...: compared without underscores, case-insensitively.
_POST_ID_NAMES = {"itemid", "awemeid"}
_SECRET_MARKERS = ("token", "cookie", "session", "sign", "ticket", "auth", "passport", "password", "secret",
                   "csrf", "sid", "ttwid", "odin", "uid_tt", "key")
# Fields the app needs, kept even if a marker above matches part of the name (lower-case).
_KEEP_KEYS = {"item_id", "aweme_id", "itemid", "status_code", "status_msg", "creation_id", "video_id",
              "single_post_resp_list", "data", "log_id", "extra", "message", "description"}
# A string value that looks like a cookie header or a credential, whatever its key is called.
_SECRET_VALUE = re.compile(r"sessionid=|sid_tt=|passport|Bearer ", re.I)
MAX_RESPONSE_JSON = 8 * 1024


def _post_id_value(value) -> str | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        value = str(value)
    if isinstance(value, str) and value.isascii() and value.isdigit() and 17 <= len(value) <= 20:
        return value
    return None


def _id_in(obj) -> str | None:
    """First post id directly under ``obj`` (one of the explicit key names, any case)."""
    if not isinstance(obj, dict):
        return None
    for key, value in obj.items():
        if isinstance(key, str) and key.replace("_", "").lower() in _POST_ID_NAMES:
            found = _post_id_value(value)
            if found:
                return found
    return None


def _extract_post_id(response) -> str | None:
    """The public post id from a publish response, checking only explicit paths:
    top level, ``data``, and ``single_post_resp_list[*]``. Never guesses from other numbers."""
    if not isinstance(response, dict):
        return None
    found = _id_in(response) or _id_in(response.get("data"))
    if found:
        return found
    for key, value in response.items():
        if isinstance(key, str) and key.lower() == "single_post_resp_list" and isinstance(value, list):
            for item in value:
                found = _id_in(item)
                if found:
                    return found
    return None


def _secret_key(key) -> bool:
    if not isinstance(key, str):
        return False
    low = key.lower()
    return low not in _KEEP_KEYS and any(m in low for m in _SECRET_MARKERS)


def sanitize_response(response, limit: int = MAX_RESPONSE_JSON) -> str:
    """JSON text of ``response`` without keys that may carry secrets, cut to ``limit`` characters."""
    def clean(obj):
        if isinstance(obj, dict):
            return {k: clean(v) for k, v in obj.items() if not _secret_key(k)}
        if isinstance(obj, list):
            return [clean(v) for v in obj]
        if isinstance(obj, str) and (_SECRET_VALUE.search(obj) or ("=" in obj and ";" in obj)):
            return "[removed]"
        return obj
    try:
        text = json.dumps(clean(response), ensure_ascii=False, default=str)
    except (TypeError, ValueError):
        return ""
    return text if len(text) <= limit else text[:limit - 14] + "...(truncated)"


def resolve_video_path(video: "str | os.PathLike") -> Path:
    """Find ``video`` as given, or by name in the videos directories."""
    p = Path(video).expanduser()
    if p.is_file():
        return p.resolve()
    if not p.is_absolute():
        for d in settings.video_search_dirs():
            candidate = d / p
            if candidate.is_file():
                return candidate.resolve()
    searched = ", ".join(str(d) for d in settings.video_search_dirs())
    raise ValidationError(f"video not found: {video} (also looked in: {searched})")


def schedule_delay(schedule: Schedule, now: datetime | None = None) -> timedelta | None:
    """Normalise ``schedule`` (seconds, timedelta or aware datetime) to a delay."""
    if schedule is None or schedule == 0:
        return None
    if isinstance(schedule, datetime):
        if schedule.tzinfo is None:
            raise ValidationError("schedule datetime must be timezone-aware")
        delay = schedule - (now or datetime.now(timezone.utc))
    elif isinstance(schedule, timedelta):
        delay = schedule
    elif isinstance(schedule, (int, float)) and not isinstance(schedule, bool):
        delay = timedelta(seconds=schedule)
    else:
        raise ValidationError(f"unsupported schedule value: {schedule!r}")
    if not MIN_SCHEDULE <= delay <= MAX_SCHEDULE:
        raise ValidationError("TikTok only accepts schedules between 15 minutes and 30 days ahead")
    return delay


def _visibility(value) -> int:
    mapping = {"public": 0, "private": 1, 0: 0, 1: 1}
    key = value.lower() if isinstance(value, str) else value
    if key not in mapping or isinstance(value, bool):
        raise ValidationError("visibility must be 0/'public' or 1/'private'")
    return mapping[key]


def _crc32(data: bytes) -> str:
    return format(zlib.crc32(data) & 0xFFFFFFFF, "08x")


def _creation_id() -> str:
    alphabet = string.ascii_letters + string.digits + "_"
    return "".join(secrets.choice(alphabet) for _ in range(21))


MAX_ERROR_BODY = 2048


def _parsed(r: requests.Response):
    """The response body as JSON when it parses (and is an object), else None."""
    try:
        data = r.json()
    except ValueError:
        return None
    return data if isinstance(data, dict) else None


def _json(r: requests.Response, what: str) -> dict:
    try:
        return r.json()
    except ValueError:
        raise UploadError(f"{what}: TikTok returned a non-JSON response (HTTP {r.status_code})",
                          status=r.status_code, body=r.text[:MAX_ERROR_BODY], step=what) from None


class Client:
    """An authenticated TikTok uploader for one account.

    >>> client = Client.from_account("alice")
    >>> client.upload("clip.mp4", "Hello #fyp")
    """

    def __init__(self, account: Account, *, proxy: "str | Proxy | None | bool" = True,
                 timeout: float = 60.0, signer: Signer | None = None):
        if not account.has_session:
            raise NotLoggedInError(
                f"account '{account.name}' has no TikTok session. Run: autotok login -n {account.name}"
            )
        self.account = account
        # proxy=True (default): use the account's saved proxy; None/False: no proxy.
        if proxy is True:
            self.proxy = account.get_proxy()
        elif proxy is False:
            self.proxy = None
        else:
            self.proxy = parse_proxy(proxy)
        self.user_agent = account.user_agent or settings.DEFAULT_USER_AGENT
        self.timeout = timeout
        self._signer = signer

    @classmethod
    def from_account(cls, name: str, *, store: AccountStore | None = None, **kwargs) -> "Client":
        return cls((store or AccountStore()).load(name), **kwargs)

    @classmethod
    def from_session_id(cls, session_id: str, *, datacenter: str | None = None,
                        user_agent: str | None = None, **kwargs) -> "Client":
        account = Account.from_session_id("session", session_id, datacenter=datacenter,
                                          user_agent=user_agent)
        return cls(account, **kwargs)

    # -- helpers ---------------------------------------------------------------

    def _session(self) -> requests.Session:
        s = proxied_session(self.proxy)
        s.cookies.set("sessionid", self.account.session_id, domain=".tiktok.com")
        datacenter = self.account.datacenter
        if not datacenter:
            log.warning("No TikTok datacenter cookie saved for '%s'; assuming %s. "
                        "Log in again if uploads fail.", self.account.name, DEFAULT_DATACENTER)
            datacenter = DEFAULT_DATACENTER
        s.cookies.set("tt-target-idc", datacenter, domain=".tiktok.com")
        s.headers.update({"User-Agent": self.user_agent, "Accept": "application/json, text/plain, */*"})
        return s

    def _request(self, session, method: str, url: str, what: str, *, expect_ok: bool = True,
                 timeout: float | None = None, **kwargs) -> requests.Response:
        try:
            r = session.request(method, url, timeout=timeout or self.timeout, **kwargs)
        except requests.RequestException as exc:
            raise UploadError(f"{what}: network error: {exc}", step=what) from exc
        if expect_ok and r.status_code != 200:
            raise UploadError(f"{what}: HTTP {r.status_code}", status=r.status_code, body=r.text[:MAX_ERROR_BODY],
                              response=_parsed(r), step=what)
        return r

    def check_session(self) -> bool:
        """Return True if TikTok still accepts the saved session for uploads."""
        with self._session() as s:
            r = self._request(s, "GET", f"https://www.tiktok.com/api/v1/video/upload/auth/?aid={AID}",
                              "session check", expect_ok=False)
        try:
            return r.status_code == 200 and "video_token_v5" in r.json()
        except ValueError:
            return False

    # -- upload ----------------------------------------------------------------

    def upload(
        self,
        video: "str | os.PathLike",
        caption: str,
        *,
        schedule: Schedule = None,
        visibility: "int | str" = 0,
        allow_comment: bool = True,
        allow_duet: bool = False,
        allow_stitch: bool = False,
        ai_label: bool = False,
    ) -> UploadResult:
        """Upload ``video`` and publish it with ``caption``.

        ``schedule`` is seconds from now, a ``timedelta`` or an aware
        ``datetime`` between 15 minutes and 30 days ahead (TikTok-side
        scheduling; some accounts only get 10 days). Raises a subclass of
        :class:`AutotokError` on failure.
        """
        if not isinstance(caption, str) or not caption.strip():
            raise ValidationError("caption is required")
        if len(caption) > MAX_CAPTION_LENGTH:
            raise ValidationError(f"caption must be at most {MAX_CAPTION_LENGTH} characters")
        vis = _visibility(visibility)
        delay = schedule_delay(schedule)
        if delay is not None and vis == 1:
            raise ValidationError("TikTok does not allow scheduling private videos")
        # Fix the publish time now, so a slow upload doesn't push it back.
        publish_at = None
        if delay is not None:
            publish_at = schedule if isinstance(schedule, datetime) else datetime.now(timezone.utc) + delay
        path = resolve_video_path(video)

        log.info("Uploading %s as '%s'%s", path.name, self.account.name,
                 f" via proxy {self.proxy.masked()}" if self.proxy else "")
        with self._session() as session:
            creation_id = _creation_id()
            url = f"https://www.tiktok.com/api/v1/web/project/create/?creation_id={creation_id}&type=1&aid={AID}"
            data = _json(self._request(session, "POST", url, "create project"), "create project")
            if "project" not in data:
                raise UploadError(
                    "create project: TikTok did not return a project. The session may have expired "
                    "or the datacenter cookie is wrong; log in again.", status=200,
                    body=json.dumps(data)[:MAX_ERROR_BODY], response=data, step="create project"
                )

            video_id = self._transfer(session, path)

            caption_markup, text_extra = build_caption(
                caption, make_user_resolver(session, self.user_agent, timeout=self.timeout)
            )
            scheduled_for = None
            payload = self._payload(creation_id, video_id, caption, caption_markup, text_extra,
                                    vis, allow_comment, allow_duet, allow_stitch, ai_label,
                                    probe=probe_video(path))
            if publish_at is not None:
                ts = int(publish_at.timestamp())
                earliest = int(time.time() + MIN_SCHEDULE.total_seconds())
                if ts < earliest:
                    log.warning("The upload took long enough that the scheduled time is now less than "
                                "15 minutes away; publishing 15 minutes from now instead.")
                    ts = earliest
                payload["feature_common_info_list"][0]["schedule_time"] = ts
                scheduled_for = datetime.fromtimestamp(ts, tz=timezone.utc)

            try:
                if publish_at is not None:
                    # requests-sent schedules always get "Invalid parameters"; a real page succeeds.
                    response = self._publish_in_browser(payload)
                else:
                    response = self._publish(session, payload)
            except PublishError as exc:
                if delay is not None and delay > SHORT_SCHEDULE_WINDOW:
                    raise PublishError(
                        f"{exc}. This post was scheduled more than 10 days ahead, and some accounts "
                        "can only schedule up to 10 days; try an earlier time.",
                        status_code=exc.status_code, status_msg=exc.status_msg, response=exc.response,
                        http_status=exc.http_status,
                    ) from exc
                raise

        log.debug("Published%s", f", scheduled for {scheduled_for.isoformat()}" if scheduled_for else "")
        return UploadResult(video_id=video_id, creation_id=creation_id,
                            scheduled_for=scheduled_for, response=response,
                            post_id=_extract_post_id(response))

    def _transfer(self, session: requests.Session, path: Path) -> str:
        """Send the file to TikTok's storage. Returns TikTok's video id."""
        auth = _json(self._request(session, "GET", f"https://www.tiktok.com/api/v1/video/upload/auth/?aid={AID}",
                                   "upload auth"), "upload auth")
        try:
            token = auth["video_token_v5"]
            aws_auth = AWSSigV4(
                "vod",
                region="ap-singapore-1",
                aws_access_key_id=token["access_key_id"],
                aws_secret_access_key=token["secret_acess_key"],  # sic: TikTok's spelling
                aws_session_token=token["session_token"],
            )
        except (KeyError, TypeError):
            raise NotLoggedInError(
                f"TikTok rejected the session for '{self.account.name}'. Log in again: "
                f"autotok login -n {self.account.name} --force"
            ) from None

        file_size = path.stat().st_size
        url = ("https://www.tiktok.com/top/v1?Action=ApplyUploadInner&Version=2020-11-19"
               f"&SpaceName=tiktok&FileType=video&IsInner=1&FileSize={file_size}&s=g158iqx8434")
        apply = _json(self._request(session, "GET", url, "apply upload", auth=aws_auth), "apply upload")
        try:
            node = apply["Result"]["InnerUploadAddress"]["UploadNodes"][0]
            video_id = node["Vid"]
            store = node["StoreInfos"][0]
            store_uri, store_auth = store["StoreUri"], store["Auth"]
            upload_host, session_key = node["UploadHost"], node["SessionKey"]
        except (KeyError, IndexError, TypeError):
            raise UploadError("apply upload: unexpected response from TikTok", status=200,
                              body=json.dumps(apply)[:MAX_ERROR_BODY],
                              response=apply if isinstance(apply, dict) else None,
                              step="apply upload") from None

        upload_id = str(uuid.uuid4())
        crcs: list[str] = []
        with open(path, "rb") as f:
            part = 0
            while True:
                chunk = f.read(CHUNK_SIZE)
                if not chunk:
                    break
                part += 1
                crc = _crc32(chunk)
                crcs.append(crc)
                self._request(
                    session, "POST",
                    f"https://{upload_host}/{store_uri}?partNumber={part}&uploadID={upload_id}&phase=transfer",
                    f"upload part {part}",
                    headers={
                        "Authorization": store_auth,
                        "Content-Type": "application/octet-stream",
                        "Content-Disposition": 'attachment; filename="undefined"',
                        "Content-Crc32": crc,
                    },
                    data=chunk,
                    timeout=max(self.timeout, 120),
                )
                log.debug("uploaded part %d (%d bytes)", part, len(chunk))
        if not crcs:
            raise ValidationError(f"video file is empty: {path}")

        # Finishing the multipart upload goes straight to the storage host
        # without TikTok's cookies, like the web client does.
        with proxied_session(self.proxy) as bare:
            self._request(
                bare, "POST",
                f"https://{upload_host}/{store_uri}?uploadID={upload_id}&phase=finish&uploadmode=part",
                "finish upload",
                headers={"Authorization": store_auth, "Content-Type": "text/plain;charset=UTF-8"},
                data=",".join(f"{i + 1}:{c}" for i, c in enumerate(crcs)),
            )

        self._request(
            session, "POST",
            "https://www.tiktok.com/top/v1?Action=CommitUploadInner&Version=2020-11-19&SpaceName=tiktok",
            "commit upload",
            auth=aws_auth,
            data=json.dumps({"SessionKey": session_key, "Functions": [{"name": "GetMeta"}]}),
        )
        self._request(session, "HEAD", "https://www.tiktok.com", "tiktok.com", expect_ok=False,
                      headers={"user-agent": self.user_agent})
        return video_id

    @staticmethod
    def _payload(creation_id, video_id, caption, markup, text_extra, visibility,
                 allow_comment, allow_duet, allow_stitch, ai_label, probe=None) -> dict:
        feature = {
            "geofencing_regions": [],
            "playlist_name": "",
            "playlist_id": "",
            "tcm_params": '{"commerce_toggle_info":{}}',
            "sound_exemption": 0,
            "music_copyright": {"result": 1},
            "anchors": [],
            "vedit_common_info": {"draft": "", "video_id": video_id},
            "privacy_setting_info": {
                "visibility_type": visibility,
                "allow_duet": int(bool(allow_duet)),
                "allow_stitch": int(bool(allow_stitch)),
                "allow_comment": int(bool(allow_comment)),
                # Defaults TikTok Studio sends today; scheduled posts fail with
                # "Invalid parameters" without them.
                "allow_content_reuse": 1,
                "allow_ai_remix": 2,
            },
            "content_check_id": "",
        }
        if ai_label:
            feature["aigc_info"] = {"aigc_label_type": 1}
        info = {
            "text": caption,
            "text_extra": text_extra,
            "markup_text": markup,
            "music_info": {"origin_volume": "100"},
            "poster_delay": 0,
            "cloud_edit_is_use_video_canvas": False,
            "is_upload_audio_track": False,
            "mature_theme_type": 0,
        }
        if probe:
            # Only what ffprobe really reported; never guessed.
            if probe.get("width") and probe.get("height"):
                info["cloud_edit_video_width"] = probe["width"]
                info["cloud_edit_video_height"] = probe["height"]
            if probe.get("duration_ms"):
                info["video_track_time_range_list"] = [
                    {"start_time_in_ms": 0, "end_time_in_ms": probe["duration_ms"]}]
            if "has_audio" in probe:
                info["has_original_audio"] = 1 if probe["has_audio"] else 0
        return {
            "post_common_info": {"creation_id": creation_id, "enter_post_page_from": 8, "post_type": 3},
            "feature_common_info_list": [feature],
            "single_post_req_list": [{
                "batch_index": 0,
                "video_id": video_id,
                "is_long_video": 0,
                "single_post_feature_info": info,
            }],
        }

    def _publish(self, session: requests.Session, payload: dict) -> dict:
        ms_token = session.cookies.get("msToken") or ""
        base = "https://www.tiktok.com/api/v1/web/project/post/"
        tz = local_tz_name()
        # TikTok Studio sends tz_name; scheduled posts are rejected ("Invalid parameters") without it.
        query = (f"app_name=tiktok_web&channel=tiktok_web&device_platform=web&tz_name={quote(tz, safe='')}"
                 f"&aid={AID}&msToken={ms_token}")
        if self._signer is not None:
            sig = self._signer.sign(f"{base}?{query}")
        else:
            with Signer(self.user_agent, proxy=self.proxy, timeout=self.timeout) as signer:
                sig = signer.sign(f"{base}?{query}")

        params = {
            "app_name": "tiktok_web",
            "channel": "tiktok_web",
            "device_platform": "web",
            "tz_name": tz,
            "aid": AID,
            "msToken": ms_token,
            "X-Bogus": sig.x_bogus,
            "_signature": sig.signature,
        }
        headers = {
            "content-type": "application/json",
            "user-agent": self.user_agent,
            "origin": "https://www.tiktok.com",
            "referer": "https://www.tiktok.com/",
        }
        url = "https://www.tiktok.com/tiktok/web/project/post/v1/"
        try:
            r = session.post(url, params=params, data=json.dumps(payload), headers=headers, timeout=self.timeout)
        except requests.RequestException as exc:
            raise PublishUncertainError(
                f"publish request failed ({exc}); the video may or may not have been posted. "
                "Check the account on TikTok before retrying."
            ) from exc
        return _check_publish(r.status_code, r.text)

    def _publish_in_browser(self, payload: dict) -> dict:
        try:
            result = publish_in_browser(json.dumps(payload), local_tz_name(), cookies=self.account.cookies,
                                        user_agent=self.user_agent, proxy=self.proxy, timeout=self.timeout)
        except BrowserStartError as exc:
            log.warning("Scheduling browser could not start: %s", exc)
            raise PublishError("không mở được trình duyệt để hẹn giờ", status_msg=str(exc)[:300]) from exc
        except Exception as exc:
            raise PublishUncertainError(
                f"publish request from the browser failed ({exc}); the video may or may not have been "
                "posted. Check the account on TikTok before retrying."
            ) from exc
        status = result.get("status") if isinstance(result, dict) else None
        if not isinstance(status, int) or status <= 0:
            error = result.get("error") if isinstance(result, dict) else None
            raise PublishUncertainError(
                f"publish request from the browser failed ({error or 'no response'}); the video may or may "
                "not have been posted. Check the account on TikTok before retrying."
            )
        return _check_publish(status, result.get("text") or "")


def _check_publish(status: int, text: str) -> dict:
    """Map the publish HTTP status and body to the response dict or a publish error."""
    try:
        data = json.loads(text)
        parsed_ok = True
    except ValueError:
        data, parsed_ok = None, False
    parsed = data if isinstance(data, dict) else None
    if status != 200:
        if status >= 500 or status in (408, 429):
            raise PublishUncertainError(
                f"publish: HTTP {status}; check the account before retrying.",
                response=parsed, body=text[:MAX_ERROR_BODY], http_status=status,
            )
        raise PublishError(f"publish: HTTP {status}", status_code=None, status_msg=text[:300],
                           response=parsed or {"body": text[:MAX_ERROR_BODY]},
                           http_status=status)
    if not parsed_ok:
        raise PublishUncertainError(
            "publish: TikTok returned a non-JSON response; check the account before retrying.",
            body=text[:MAX_ERROR_BODY], http_status=status,
        )
    code = data.get("status_code") if isinstance(data, dict) else None
    if type(code) is not int:
        # Missing, null, "0", 0.0 or true: not TikTok's documented answer, so the outcome is unknown.
        raise PublishUncertainError(
            f"publish: TikTok returned no usable status_code ({code!r}); check the account before retrying.",
            response=data if isinstance(data, dict) else {"body": data}, http_status=status,
        )
    if code != 0:
        msg = data.get("status_msg") or ""
        raise PublishError(f"TikTok rejected the post: {msg or 'unknown error'} (status_code={code})",
                           status_code=code, status_msg=msg, response=data, http_status=status)
    return data


def upload_video(
    account: "str | Account",
    video: "str | os.PathLike",
    caption: str,
    *,
    schedule: Schedule = None,
    visibility: "int | str" = 0,
    allow_comment: bool = True,
    allow_duet: bool = False,
    allow_stitch: bool = False,
    ai_label: bool = False,
    proxy: "str | Proxy | None | bool" = True,
    store: AccountStore | None = None,
) -> UploadResult:
    """One-call upload: ``upload_video("alice", "clip.mp4", "Hello #fyp")``."""
    acct = account if isinstance(account, Account) else (store or AccountStore()).load(account)
    return Client(acct, proxy=proxy).upload(
        video, caption, schedule=schedule, visibility=visibility, allow_comment=allow_comment,
        allow_duet=allow_duet, allow_stitch=allow_stitch, ai_label=ai_label,
    )


__all__ = ["Client", "UploadResult", "upload_video", "resolve_video_path", "schedule_delay", "AutotokError"]
