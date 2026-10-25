"""Send the publish request from a real, logged-in TikTok page.

TikTok rejects scheduled posts sent by ``requests`` ("Invalid parameters") even
with a body identical to TikTok Studio's, while the same body sent by the
Studio page's own ``XMLHttpRequest`` is accepted: the page's SDK adds the
signing parameters and headers. So for scheduled posts a headless browser
(with the account's cookies, user agent and proxy) opens TikTok Studio and
sends the request from there.

Unlike :class:`~autotok.signer.Signer`, this browser is online: it must load
TikTok's own scripts.
"""
from __future__ import annotations

import logging
import re
from urllib.parse import quote

from .browsers import open_browser, sync_playwright
from .proxy import Proxy

log = logging.getLogger("autotok")

STUDIO_URL = "https://www.tiktok.com/tiktokstudio/upload"
POST_URL = "https://www.tiktok.com/tiktok/web/project/post/v1/"
AID = 1988
_COOKIE_KEYS = ("name", "value", "domain", "path", "expires", "httpOnly", "secure", "sameSite")
_SAMESITE = {"strict": "Strict", "lax": "Lax", "none": "None"}
# Signed-request parameters; "%3D" covers a URL nested (encoded) inside another one. The value also stops at
# whitespace/quotes, so redacting a whole error message keeps the text after the URL.
_SECRET_PARAMS = re.compile(r"((?:msToken|X-Bogus|X-Gnarly|_signature|verifyFp)(?:=|%3D))[^&\s'\"<>]*", re.I)

# True once TikTok's SDK has hooked XMLHttpRequest (it signs requests sent through it).
_SDK_READY = (
    "() => document.readyState === 'complete' && ("
    "!/\\[native code\\]/.test(XMLHttpRequest.prototype.open.toString()) || "
    "!/\\[native code\\]/.test(XMLHttpRequest.prototype.send.toString()))"
)

_SEND_JS = """
([url, body, timeoutMs]) => new Promise((resolve) => {
  const xhr = new XMLHttpRequest();
  xhr.open('POST', url, true);
  xhr.withCredentials = true;
  xhr.timeout = timeoutMs;
  xhr.setRequestHeader('content-type', 'application/json');
  xhr.onload = () => resolve({status: xhr.status, text: xhr.responseText, error: null});
  xhr.onerror = () => resolve({status: 0, text: '', error: 'network error'});
  xhr.ontimeout = () => resolve({status: 0, text: '', error: 'timeout'});
  xhr.onabort = () => resolve({status: 0, text: '', error: 'aborted'});
  xhr.send(body);
})
"""


class BrowserStartError(Exception):
    """The browser could not be made ready; nothing was sent to TikTok."""


def redact_url(url: str) -> str:
    """Hide signing tokens in a URL or in any text that may hold one (exception messages, response
    bodies). The one helper to apply before such text is logged, stored or returned."""
    return _SECRET_PARAMS.sub(r"\1<redacted>", str(url))


def post_url(tz_name: str) -> str:
    return (f"{POST_URL}?app_name=tiktok_web&channel=tiktok_web&device_platform=web"
            f"&tz_name={quote(tz_name, safe='')}&aid={AID}")


def _playwright_cookies(cookies: list[dict]) -> list[dict]:
    out = []
    for c in cookies or []:
        if not isinstance(c, dict) or not c.get("name") or c.get("value") is None:
            continue
        item = {k: c[k] for k in _COOKIE_KEYS if k in c and c[k] is not None}
        item.setdefault("domain", ".tiktok.com")
        item.setdefault("path", "/")
        same = _SAMESITE.get(str(item.get("sameSite", "")).lower())
        if same:
            item["sameSite"] = same
        else:
            item.pop("sameSite", None)
        if "expires" in item and not isinstance(item["expires"], (int, float)):
            item.pop("expires")
        out.append(item)
    return out


def publish_in_browser(body: str, tz_name: str, *, cookies: list[dict], user_agent: str,
                       proxy: Proxy | None, timeout: float = 60.0) -> dict:
    """POST ``body`` from a TikTok Studio page. Returns ``{"status", "text", "error"}``.

    Raises :class:`BrowserStartError` if the page could not be prepared (nothing
    sent). Any other exception means the request may have been sent.
    """
    ms = timeout * 1000
    pw = handle = None
    try:
        try:
            pw = sync_playwright().start()
            handle = open_browser(pw, headless=True, proxy=proxy, timeout=max(300, timeout * 4))
            if handle.is_remote:
                context = handle.context()
                page = handle.page(context)
            else:
                context = handle.context(user_agent=user_agent, locale="en-US")
                page = context.new_page()
            context.add_cookies(_playwright_cookies(cookies))
            page.goto(STUDIO_URL, wait_until="load", timeout=ms)
            if "/login" in (page.url or ""):
                raise BrowserStartError("TikTok sent the browser to the login page; log in again")
            page.wait_for_function(_SDK_READY, timeout=ms)
        except BrowserStartError:
            raise
        except Exception as exc:
            raise BrowserStartError(str(exc)) from exc

        def on_request(request):
            if request.url.startswith(POST_URL):
                log.debug("browser publish request: %s", redact_url(request.url))

        page.on("request", on_request)
        # From here on the request may reach TikTok: errors are uncertain, never retried.
        return page.evaluate(_SEND_JS, [post_url(tz_name), body, int(ms)])
    finally:
        for obj, method in ((handle, "close"), (pw, "stop")):
            if obj is not None:
                try:
                    getattr(obj, method)()
                except Exception:  # pragma: no cover - best effort cleanup
                    pass
