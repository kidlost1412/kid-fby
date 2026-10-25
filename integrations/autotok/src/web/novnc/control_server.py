"""noVNC control server.

The API does NOT drive the browser directly — it POSTs here, we start Chromium
(via Playwright) on the Xvfb display through the account's proxy, wait for the
TikTok session cookies, then POST cookies + user agent + proxy back to the
API's callback_url. The API is the only service that writes account files,
keeping this container stateless.

Single-slot queue: only one browser session at a time. A second start call
while one is active returns 409. This matches the realistic workload (a
single human logging in).

Playwright's sync API is bound to the thread that created it, so the worker
thread owns the browser for its whole life; other requests only flip a cancel
flag that the worker checks while it waits.
"""
from __future__ import annotations

import logging
import os
import re
import threading
from typing import Optional
from urllib.parse import urlsplit

import httpx
from fastapi import FastAPI, HTTPException, Request, status
from fastapi.responses import JSONResponse
from pydantic import BaseModel

from autotok.errors import AutotokError
from autotok.auth import open_login_session

log = logging.getLogger("novnc.control")
app = FastAPI(title="noVNC control server")

_POLL_TIMEOUT_SECONDS = 600  # 10-min human login window
_ACTIVE = ("starting", "active", "completing")

# Same rules as the API (api.main / api.security), kept local so this container needs no api package.
# "novnc" is the compose service name the API container uses to reach this server.
CSRF_HEADER = "X-Requested-With"
CSRF_VALUE = "autotok"
_SAFE_METHODS = ("GET", "HEAD", "OPTIONS")
_DEFAULT_ALLOWED_HOSTS = ("localhost", "127.0.0.1", "::1", "novnc")
_TOKEN = re.compile(r"token=[0-9a-f]{64}")


def _allowed_hosts() -> set[str]:
    extra = os.getenv("AUTOTOK_ALLOWED_HOSTS", "")
    return set(_DEFAULT_ALLOWED_HOSTS) | {h.strip().lower() for h in extra.split(",") if h.strip()}


def _hostname(host_header: str) -> str:
    value = host_header.strip().lower()
    if value.startswith("["):  # [::1]:17900
        host, _, rest = value[1:].partition("]")
        return host if re.fullmatch(r"(:\d+)?", rest) else value
    return value.rsplit(":", 1)[0] if value.count(":") == 1 else value


@app.middleware("http")
async def _require_known_host_and_csrf(request: Request, call_next):
    # A web page (DNS rebinding, or any page posting to 127.0.0.1) must not start a login browser
    # or cancel one: unknown Host names and state changes without the custom header are refused.
    if _hostname(request.headers.get("host", "")) not in _allowed_hosts():
        return JSONResponse({"detail": "unknown Host header"}, status_code=403)
    if request.method not in _SAFE_METHODS and request.headers.get(CSRF_HEADER) != CSRF_VALUE:
        return JSONResponse({"detail": f"missing header {CSRF_HEADER}: {CSRF_VALUE}"}, status_code=403)
    return await call_next(request)


def expected_callback(session_id: str) -> str:
    """The only callback this server posts cookies to: the API's completion endpoint for this
    session. API_PUBLIC_URL is set by the host (same default as api.routers.login)."""
    base = os.getenv("API_PUBLIC_URL", "http://api:8000").rstrip("/")
    return f"{base}/api/login/browser/{session_id}/complete"


def callback_allowed(session_id: str, callback_url: str) -> bool:
    """True only for <API_PUBLIC_URL>/api/login/browser/<session_id>/complete?token=<64 hex>."""
    try:
        parts = urlsplit(callback_url)
        expected = urlsplit(expected_callback(session_id))
    except ValueError:
        return False
    return ((parts.scheme, parts.netloc, parts.path) == (expected.scheme, expected.netloc, expected.path)
            and not parts.fragment and bool(_TOKEN.fullmatch(parts.query)))


class _BrowserState:
    """The current login attempt. At most one at a time; guarded by ``lock``."""

    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.session_id: Optional[str] = None
        self.status: str = "idle"  # idle|starting|active|completing|completed|failed
        self.error: Optional[str] = None
        self.cancel = threading.Event()

    def update(self, sid: str, status_: str, error: Optional[str] = None) -> None:
        """Only the worker for the current session may change the state."""
        with self.lock:
            if self.session_id == sid:
                self.status = status_
                self.error = error


_state = _BrowserState()


class StartRequest(BaseModel):
    session_id: str
    username: str
    callback_url: str
    proxy: Optional[str] = None


def _launch_and_watch(sid: str, callback_url: str, proxy: Optional[str], cancel: threading.Event) -> None:
    """Worker thread: open Chromium, wait for login, POST the result to the API."""
    _state.update(sid, "active")
    try:
        cookies, user_agent = open_login_session(
            proxy=proxy, timeout=_POLL_TIMEOUT_SECONDS, should_stop=cancel.is_set
        )
    except AutotokError as e:
        if not cancel.is_set():
            log.warning("login %s failed: %s", sid, e)
        _state.update(sid, "failed", str(e))
        return
    except Exception as e:
        log.exception("login %s crashed", sid)
        _state.update(sid, "failed", f"browser error: {e}")
        return

    _state.update(sid, "completing")
    try:
        with httpx.Client(timeout=30.0) as client:
            client.post(
                callback_url,
                json={"cookies": cookies, "user_agent": user_agent, "proxy": proxy},
                headers={"X-Requested-With": "autotok"},
            ).raise_for_status()
        _state.update(sid, "completed")
    except httpx.HTTPError as e:
        log.exception("callback POST failed")
        _state.update(sid, "failed", f"callback failed: {e}")


@app.post("/browser/start", status_code=status.HTTP_202_ACCEPTED)
def browser_start(req: StartRequest):
    if not callback_allowed(req.session_id, req.callback_url):
        # Cookies, user agent and proxy credentials go to this URL: never to anything else.
        raise HTTPException(status_code=400, detail="callback_url is not this API's login completion endpoint")
    with _state.lock:
        if _state.status in _ACTIVE:
            raise HTTPException(
                status_code=409,
                detail=f"another login in progress (session {_state.session_id})",
            )
        _state.cancel.set()  # stop any previous worker that is still winding down
        _state.cancel = threading.Event()
        _state.session_id = req.session_id
        _state.status = "starting"
        _state.error = None
        threading.Thread(
            target=_launch_and_watch,
            args=(req.session_id, req.callback_url, req.proxy, _state.cancel),
            daemon=True,
        ).start()
    return {"session_id": req.session_id, "status": "starting"}


@app.get("/browser/status/{session_id}")
def browser_status(session_id: str):
    with _state.lock:
        if _state.session_id != session_id:
            raise HTTPException(status_code=404, detail="unknown session")
        return {"session_id": session_id, "status": _state.status, "error": _state.error}


@app.delete("/browser/{session_id}", status_code=status.HTTP_204_NO_CONTENT)
def browser_stop(session_id: str):
    with _state.lock:
        if _state.session_id != session_id:
            return  # already gone, idempotent
        _state.cancel.set()
        _state.session_id = None
        _state.status = "idle"
        _state.error = None


@app.get("/health")
def health():
    return {"status": "ok", "browser_status": _state.status}
