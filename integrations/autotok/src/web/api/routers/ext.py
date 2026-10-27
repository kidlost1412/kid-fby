"""/api/ext/*: the Chrome extension publisher. Contract: integrations/autotok-extension/PROTOCOL.md.

Handlers are plain ``def`` (threadpool): /next long-polls with time.sleep.
"""
from __future__ import annotations

import re
import time

from fastapi import APIRouter, Depends, Request
from fastapi.responses import JSONResponse, Response, StreamingResponse
from sqlmodel import Session, select

from api.db import get_session, now_utc
from api.models import ExtensionClient, ExtensionJob
from api.services import ext
from api.services import videos as library

router = APIRouter(prefix="/api/ext", tags=["chrome-extension"])

GUI_ONLY = ("/api/ext/pair-code", "/api/ext/clients")
NEXT_MAX_WAIT = 25.0


class ExtError(Exception):
    def __init__(self, status: int, code: str, message: str = "", **extra):
        self.status, self.code, self.message, self.extra = status, code, message, extra


def ext_error_response(_request: Request, exc: ExtError) -> JSONResponse:
    return JSONResponse({"ok": False, "error": exc.code, "message": exc.message, **exc.extra},
                        status_code=exc.status)


def _protocol(request: Request) -> int:
    try:
        return int(request.headers.get("x-autotok-protocol", "0"))
    except ValueError:
        return 0


def current_client(request: Request, session: Session = Depends(get_session)) -> ExtensionClient:
    auth = request.headers.get("authorization", "")
    client = ext.client_for_token(session, auth[7:] if auth.startswith("Bearer ") else "")
    if client is None:
        raise ExtError(401, "unauthorized", "Cần ghép nối lại tiện ích với ứng dụng")
    ext.touch(session, client, _protocol(request))
    return client


def gui_only(request: Request) -> None:
    if request.headers.get("origin"):
        raise ExtError(403, "gui_only", "chỉ ứng dụng trên máy này được gọi")


def _body(raw) -> dict:
    if not isinstance(raw, dict):
        raise ExtError(400, "bad_request", "body must be a JSON object")
    return raw


async def _json(request: Request) -> dict:
    try:
        return _body(await request.json())
    except ValueError:
        raise ExtError(400, "bad_request", "invalid JSON") from None


def _need_reload(request: Request) -> None:
    if not ext.protocol_ok(_protocol(request)):
        raise ExtError(409, "need_reload", ext.RELOAD_TEXT, need_reload=True)


def _job(session: Session, job_id) -> ExtensionJob:
    job = session.get(ExtensionJob, str(job_id or ""))
    if job is None:
        raise ExtError(404, "unknown_job", "máy chủ không còn việc này")
    return job


def _owned(session: Session, body: dict) -> ExtensionJob:
    job = _job(session, body.get("id"))
    if not (isinstance(body.get("nonce"), str) and body["nonce"] == job.nonce
            and isinstance(body.get("claim_token"), str) and job.claim_token and body["claim_token"] == job.claim_token):
        raise ExtError(403, "bad_nonce", "nonce/claim_token không khớp")
    return job


# ---------- extension endpoints ----------

@router.post("/pair")
async def pair(request: Request, session: Session = Depends(get_session)):
    body = await _json(request)
    try:
        protocol = int(body.get("protocol", 0))
    except (TypeError, ValueError):
        protocol = 0
    if not ext.protocol_ok(protocol):
        raise ExtError(409, "need_reload", ext.RELOAD_TEXT, need_reload=True)
    ok, code, left = ext.use_pair_code(str(body.get("code", "")))
    if not ok:
        if code == "bad_code":
            raise ExtError(403, "bad_code", "Mã ghép nối sai", tries_left=left)
        raise ExtError(410, "no_code", "Không có mã ghép nối đang hiệu lực — bấm tạo mã mới trong ứng dụng")
    client, token = ext.create_client(session, str(body.get("label") or "Chrome"), str(body.get("ext_version") or ""),
                                      protocol)
    return {"ok": True, "client_id": client.id, "token": token}


@router.post("/hello")
async def hello(request: Request, client: ExtensionClient = Depends(current_client),
                session: Session = Depends(get_session)):
    body = await _json(request)
    identity = body.get("identity")
    username = user_id = None
    if isinstance(identity, dict) and identity.get("user_id") and identity.get("username"):
        username, user_id = str(identity["username"])[:128], str(identity["user_id"])[:32]
        if not re.fullmatch(r"[0-9]{1,32}", user_id) or not re.fullmatch(r"[A-Za-z0-9_.\-]{1,128}", username):
            raise ExtError(400, "bad_request", "identity must be {username: TikTok handle, user_id: digits}")
    try:
        protocol = int(body.get("protocol", _protocol(request)))
    except (TypeError, ValueError):
        protocol = 0
    client = session.get(ExtensionClient, client.id)
    ext.touch(session, client, protocol, tiktok_username=username, tiktok_user_id=user_id,
              ext_version=str(body.get("ext_version") or client.ext_version)[:32])
    if not user_id:
        ext.log.warning("ext: client %s hello without TikTok identity (not logged in?); no work is dispatched to it",
                        client.id)
    acct = ext.bound_account(session, user_id)
    need = not ext.protocol_ok(protocol)
    return {"ok": True, "client_id": client.id, "protocol_min": ext.PROTOCOL_MIN, "protocol_max": ext.PROTOCOL_MAX,
            "need_reload": need, "message": ext.RELOAD_TEXT if need else "", "server_time": ext.iso(now_utc()),
            "account": {"id": acct.id, "username": acct.username, "publisher": acct.publisher} if acct else None,
            "conflict": bool(user_id) and ext.in_conflict(session, client)}


@router.get("/next")
def next_job(request: Request, wait: float = 0.0, client: ExtensionClient = Depends(current_client),
             session: Session = Depends(get_session)):
    _need_reload(request)
    if not client.tiktok_user_id:
        raise ExtError(409, "no_identity", "Chrome chưa đăng nhập TikTok (gửi hello sau khi đăng nhập)")
    if ext.in_conflict(session, client):
        raise ExtError(409, "identity_conflict", "Có hai hồ sơ Chrome cùng một tài khoản TikTok — gỡ bớt một trong ứng dụng")
    end = time.monotonic() + min(max(wait, 0.0), NEXT_MAX_WAIT)
    while True:
        ext.reconcile_ext()
        job = ext.claim_next(client)
        if job is not None:
            return ext.job_payload(job, client)
        if time.monotonic() >= end:
            return Response(status_code=204)
        time.sleep(1.0)


def _video_job(session: Session, client: ExtensionClient, job_id) -> ExtensionJob:
    job = _job(session, job_id)
    if job.claim_client != client.id or job.state not in ext.RUNNING:
        raise ExtError(403, "bad_nonce", "việc này không thuộc Chrome này hoặc đã xong")
    return job


@router.get("/video/meta")
def video_meta(id: str, client: ExtensionClient = Depends(current_client), session: Session = Depends(get_session)):
    job = _video_job(session, client, id)
    try:
        path = library.resolve(job.video_name)
    except ValueError as exc:
        raise ExtError(404, "unknown_job", str(exc)) from None
    return {"name": job.video_name, "size": path.stat().st_size, "type": ext.library_type(job.video_name)}


@router.get("/video")
def video(id: str, request: Request, client: ExtensionClient = Depends(current_client),
          session: Session = Depends(get_session)):
    job = _video_job(session, client, id)
    try:
        path = library.resolve(job.video_name)
    except ValueError as exc:
        raise ExtError(404, "unknown_job", str(exc)) from None
    size = path.stat().st_size
    start, end, code = 0, size - 1, 200
    rng = request.headers.get("range")
    if rng:
        m = re.fullmatch(r"bytes=(\d*)-(\d*)", rng.strip())
        if not m or (not m.group(1) and not m.group(2)):
            return Response(status_code=416, headers={"Content-Range": f"bytes */{size}"})
        if m.group(1):
            start = int(m.group(1))
            end = min(int(m.group(2)), size - 1) if m.group(2) else size - 1
        else:
            start = max(size - int(m.group(2)), 0)
        if start >= size or start > end:
            return Response(status_code=416, headers={"Content-Range": f"bytes */{size}"})
        code = 206

    def chunks(begin=start, left=end - start + 1):
        with open(path, "rb") as fh:
            fh.seek(begin)
            while left > 0:
                buf = fh.read(min(1 << 20, left))
                if not buf:
                    break
                left -= len(buf)
                yield buf

    headers = {"Accept-Ranges": "bytes", "Content-Length": str(end - start + 1)}
    if code == 206:
        headers["Content-Range"] = f"bytes {start}-{end}/{size}"
    return StreamingResponse(chunks(), status_code=code, media_type=ext.library_type(job.video_name), headers=headers)


@router.post("/progress")
async def progress(request: Request, client: ExtensionClient = Depends(current_client),
                   session: Session = Depends(get_session)):
    body = await _json(request)
    job = _owned(session, body)
    state = ext.heartbeat(job, ready=body.get("phase") == "ready")
    if state == "revoked":
        return {"ok": False, "state": state, "cancelled": True}
    return {"ok": state in ext.RUNNING + ("authorized",), "state": state}


@router.post("/authorize")
async def authorize(request: Request, client: ExtensionClient = Depends(current_client),
                    session: Session = Depends(get_session)):
    body = await _json(request)
    job = _owned(session, body)
    reason = ext.authorize_refusal(session, job, client, body, _protocol(request))
    if reason is None:
        try:
            granted = ext.authorize(job, body["body_sha256"], body["creation_id"])
        except Exception:
            ext.log.exception("ext: authorize of job %s not persisted", job.id)
            raise ExtError(500, "persist_failed", "không ghi được quyền đăng — không đăng") from None
        if granted:
            return {"ok": True}
        session.refresh(job)
        reason = ext.state_refusal(session, job) or "not-ready"
    ext.log.info("ext: authorize refused job=%s client=%s reason=%s", job.id, client.id, reason)
    return {"ok": False, "reason": reason}


@router.post("/result")
async def result(request: Request, client: ExtensionClient = Depends(current_client),
                 session: Session = Depends(get_session)):
    body = await _json(request)
    job = _owned(session, body)
    duplicate, state = ext.ingest_result(job.id, body)
    ext.log.info("ext: result job=%s client=%s outcome=%s duplicate=%s", job.id, client.id, body.get("outcome"), duplicate)
    ext.reconcile_ext()
    return {"ok": True, "duplicate": duplicate, "state": state}


@router.post("/cancel")
async def cancel(request: Request, client: ExtensionClient = Depends(current_client),
                 session: Session = Depends(get_session)):
    body = await _json(request)
    job = _owned(session, body)
    if ext.revoke(job.id, ext.CANCEL_TEXT + (f" ({str(body.get('reason'))[:120]})" if body.get("reason") else "")):
        ext.reconcile_ext()
        return {"ok": True, "state": "revoked", "cancel_recorded": False}
    session.refresh(job)
    if job.state == "authorized" and not job.cancel_requested:
        job.cancel_requested = True  # recorded only: an authorization is never undone
        session.add(job)
        session.commit()
    return {"ok": True, "state": job.state, "cancel_recorded": job.state == "authorized"}


@router.get("/job_state")
def job_state(id: str, client: ExtensionClient = Depends(current_client), session: Session = Depends(get_session)):
    job = _job(session, id)
    return {"ok": True, "state": job.state, "authorized": job.authorized_at is not None}


# ---------- GUI-only ----------

@router.post("/pair-code", dependencies=[Depends(gui_only)])
def pair_code():
    return ext.new_pair_code()


@router.get("/clients", dependencies=[Depends(gui_only)])
def list_clients(session: Session = Depends(get_session)):
    rows = session.exec(select(ExtensionClient).where(ExtensionClient.revoked_at.is_(None))
                        .order_by(ExtensionClient.id)).all()
    return [{"id": c.id, "label": c.label, "tiktok_username": c.tiktok_username, "tiktok_user_id": c.tiktok_user_id,
             "ext_version": c.ext_version, "protocol": c.protocol, "need_reload": not ext.protocol_ok(c.protocol),
             "last_seen_at": ext.iso(c.last_seen_at), "online": ext.online(c),
             "has_identity": bool(c.tiktok_user_id),
             "status": ("need_reload" if not ext.protocol_ok(c.protocol) else "offline" if not ext.online(c)
                        else "no_identity" if not c.tiktok_user_id
                        else "conflict" if ext.in_conflict(session, c) else "ok"),
             "conflict": bool(c.tiktok_user_id) and ext.online(c) and ext.in_conflict(session, c),
             "created_at": ext.iso(c.created_at)} for c in rows]


@router.delete("/clients/{client_id}", status_code=204, dependencies=[Depends(gui_only)])
def delete_client(client_id: int, session: Session = Depends(get_session)):
    client = session.get(ExtensionClient, client_id)
    if client is None or client.revoked_at is not None:
        raise ExtError(404, "unknown_client", "không có Chrome này")
    client.revoked_at = now_utc()
    session.add(client)
    session.commit()
    return Response(status_code=204)


def install_cors(app) -> None:
    """CORS only for the fixed extension origin and only on the extension endpoints (not GUI_ONLY)."""
    allow = {"Access-Control-Allow-Origin": ext.EXT_ORIGIN, "Vary": "Origin",
             "Access-Control-Expose-Headers": "Content-Range, Content-Length, Accept-Ranges"}

    @app.middleware("http")
    async def _ext_cors(request: Request, call_next):
        path = request.url.path
        if (request.headers.get("origin") != ext.EXT_ORIGIN or not path.startswith("/api/ext/")
                or path.startswith(GUI_ONLY)):
            return await call_next(request)
        if request.method == "OPTIONS" and request.headers.get("access-control-request-method"):
            return Response(status_code=204, headers={
                **allow, "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
                "Access-Control-Allow-Headers": "Authorization, Content-Type, X-Requested-With, X-Autotok-Protocol, Range",
                "Access-Control-Max-Age": "600"})
        response = await call_next(request)
        response.headers.update(allow)
        return response
