"""CRUD on TikTok accounts. An account is a username paired with a saved
session file in the autotok account store. Creating an account here does NOT
log in — it registers a session that already exists (from ``autotok login`` or
a prior browser login). Use /api/login/browser/* for the in-browser login flow.
"""
from __future__ import annotations

from typing import List

from fastapi import APIRouter, Depends, HTTPException, status
from sqlmodel import Session, select

from api.db import get_session, now_utc
from api.models import EXT_TERMINAL, Account, ExtensionClient, ExtensionJob, ScheduledUpload
from api.schemas import AccountCreate, AccountFromChrome, AccountRead, AccountUpdate, SessionCheckResponse
from api.services import account_store, ext
from api.services.history import track_schedule
from autotok import Client
from autotok.errors import AutotokError, NotLoggedInError

router = APIRouter(prefix="/api/accounts", tags=["accounts"])


def to_read(acct: Account, session: Session) -> AccountRead:
    proxy = account_store.get_proxy(acct.username) if acct.cookie_path else None
    data = AccountRead.model_validate(acct).model_dump()
    data["proxy"] = proxy.masked() if proxy else None
    data["ready"], data["ready_reason"] = ext.readiness(session, acct)
    return AccountRead(**data)


QUEUED_EXT = ("pending_ext", "waiting_ext")


def _usable_client(session: Session, client_id: int) -> ExtensionClient:
    """A paired Chrome that reports its TikTok identity right now, alone (no second profile)."""
    client = session.get(ExtensionClient, client_id)
    if client is None or client.revoked_at is not None:
        raise HTTPException(status_code=404, detail="không có Chrome đã ghép nối này")
    if not client.tiktok_user_id or not client.tiktok_username:
        raise HTTPException(status_code=409, detail="Chrome này chưa báo tài khoản TikTok (chưa đăng nhập?)")
    if not ext.online(client):
        raise HTTPException(status_code=409, detail="Chrome này đang không kết nối — mở Chrome rồi thử lại")
    if ext.in_conflict(session, client):
        raise HTTPException(status_code=409, detail="Có hai hồ sơ Chrome cùng tài khoản TikTok này — gỡ bớt một")
    return client


def _check_user_id_free(session: Session, user_id: str, except_id: int | None = None) -> None:
    other = session.exec(select(Account).where(Account.chrome_user_id == user_id)).first()
    if other is not None and other.id != except_id:
        raise HTTPException(status_code=409, detail=f"tài khoản TikTok này đã gắn với '{other.username}'")


def _has_ext_work(session: Session, acct: Account) -> bool:
    if session.exec(select(ScheduledUpload).where(ScheduledUpload.account_id == acct.id,
                                                  ScheduledUpload.status.in_(QUEUED_EXT))).first():
        return True
    return session.exec(select(ExtensionJob).where(ExtensionJob.account_id == acct.id,
                                                   ExtensionJob.state.not_in(EXT_TERMINAL))).first() is not None


def _get(session: Session, account_id: int) -> Account:
    acct = session.get(Account, account_id)
    if not acct:
        raise HTTPException(status_code=404, detail="account not found")
    return acct


@router.get("", response_model=List[AccountRead])
def list_accounts(session: Session = Depends(get_session)):
    return [to_read(a, session) for a in session.exec(select(Account).order_by(Account.username)).all()]


@router.get("/{account_id}", response_model=AccountRead)
def get_account(account_id: int, session: Session = Depends(get_session)):
    return to_read(_get(session, account_id), session)


@router.post("", response_model=AccountRead, status_code=status.HTTP_201_CREATED)
def create_account(payload: AccountCreate, session: Session = Depends(get_session)):
    # Require the session file to already exist. This endpoint is how CLI-
    # created sessions get promoted into the DB; it is NOT how new logins happen.
    if not account_store.exists(payload.username):
        raise HTTPException(
            status_code=400,
            detail=(
                f"No saved session for '{payload.username}'. "
                "Log in first (autotok login, or /api/login/browser/start)."
            ),
        )
    existing = session.exec(select(Account).where(Account.username == payload.username)).first()
    if existing:
        raise HTTPException(status_code=409, detail="account with that username already exists")

    acct = Account(
        username=payload.username,
        display_name=payload.display_name,
        cookie_path=account_store.file_path(payload.username),
        has_valid_session=account_store.has_valid_session(payload.username),
    )
    session.add(acct)
    session.commit()
    session.refresh(acct)
    return to_read(acct, session)


@router.patch("/{account_id}", response_model=AccountRead)
def update_account(
    account_id: int,
    payload: AccountUpdate,
    session: Session = Depends(get_session),
):
    acct = _get(session, account_id)
    if payload.display_name is not None:
        acct.display_name = payload.display_name
    if payload.publisher == "chrome":
        if payload.client_id is None:
            raise HTTPException(status_code=422, detail="client_id is required to post through Chrome")
        client = _usable_client(session, payload.client_id)
        _check_user_id_free(session, client.tiktok_user_id, except_id=acct.id)
        if client.tiktok_username.lower() != acct.username.lower() and not payload.confirm_username_mismatch:
            raise HTTPException(status_code=409, detail=(
                f"Chrome đang đăng nhập TikTok '{client.tiktok_username}', khác tên tài khoản '{acct.username}'. "
                "Xác nhận nếu đúng là cùng một tài khoản."))
        acct.publisher, acct.chrome_user_id = "chrome", client.tiktok_user_id  # cookies are left untouched
    elif payload.publisher == "cookies" and acct.publisher != "cookies":
        if not acct.cookie_path or not account_store.exists(acct.username):
            raise HTTPException(status_code=409, detail="tài khoản này chưa có phiên cookie — đăng nhập trước")
        if _has_ext_work(session, acct):
            raise HTTPException(status_code=409, detail="tài khoản còn việc đang chờ Chrome — đợi xong hoặc hủy trước")
        acct.publisher = "cookies"
    if payload.proxy is not None:
        try:
            account_store.set_proxy(acct.username, payload.proxy or None)
        except AutotokError as e:
            raise HTTPException(status_code=400, detail=str(e))
    acct.updated_at = now_utc()
    session.add(acct)
    session.commit()
    session.refresh(acct)
    return to_read(acct, session)


@router.post("/{account_id}/check", response_model=SessionCheckResponse)
def check_account_session(account_id: int, session: Session = Depends(get_session)):
    """Ask TikTok whether the saved session still works (through the account's proxy).

    Only TikTok rejecting the session marks it invalid; a network or proxy
    failure is reported as 502 and leaves the stored state alone."""
    acct = _get(session, account_id)
    if not acct.cookie_path:  # Chrome-only account: there is no cookie session to check
        raise HTTPException(status_code=409, detail="tài khoản đăng qua Chrome, không có phiên cookie để kiểm tra")
    try:
        valid = Client.from_account(acct.username).check_session()
    except NotLoggedInError:
        valid = False
    except AutotokError as e:
        raise HTTPException(status_code=502, detail=str(e)) from None
    acct.has_valid_session = valid
    acct.updated_at = now_utc()
    session.add(acct)
    session.commit()
    return SessionCheckResponse(valid=valid)


@router.delete("/{account_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_account(account_id: int, session: Session = Depends(get_session)):
    acct = _get(session, account_id)
    rows = session.exec(select(ScheduledUpload).where(ScheduledUpload.account_id == acct.id)).all()
    if any(r.status in ("pending", "running") + QUEUED_EXT for r in rows) or _has_ext_work(session, acct):
        raise HTTPException(
            status_code=409,
            detail="this account has pending or running scheduled uploads; cancel them first",
        )
    # Delete DB rows first — if file deletion fails afterwards the user can
    # still re-import. The reverse is harder to recover from.
    username = acct.username
    for r in rows:  # finished schedule history for this account
        track_schedule(session, r, legacy=True)
        session.delete(r)
    session.flush()  # the rows reference the account, so they must go first
    session.delete(acct)
    session.commit()
    if acct.cookie_path:  # a Chrome-only account owns no session file (never delete another one by name)
        account_store.delete(username)


@router.post("/from-chrome", response_model=AccountRead, status_code=status.HTTP_201_CREATED)
def create_from_chrome(payload: AccountFromChrome, session: Session = Depends(get_session)):
    """Cookie-free account: posts only through the paired Chrome that reports this TikTok user."""
    client = _usable_client(session, payload.client_id)
    _check_user_id_free(session, client.tiktok_user_id)
    if session.exec(select(Account).where(Account.username == client.tiktok_username)).first():
        raise HTTPException(status_code=409, detail=(f"đã có tài khoản '{client.tiktok_username}' — "
                                                     "dùng 'Đăng qua Chrome' trên tài khoản đó"))
    acct = Account(username=client.tiktok_username, cookie_path="", has_valid_session=False,
                   publisher="chrome", chrome_user_id=client.tiktok_user_id)
    session.add(acct)
    session.commit()
    session.refresh(acct)
    return to_read(acct, session)


@router.post("/import-from-disk", response_model=List[AccountRead])
def import_from_disk(session: Session = Depends(get_session)):
    """Register saved sessions that are not in the DB yet. Users who log in
    with `autotok login -n foo` can click one button in the UI to see them."""
    imported: list[Account] = []
    existing = {a.username for a in session.exec(select(Account)).all()}
    for username in account_store.list_usernames_on_disk():
        if username in existing:
            continue
        acct = Account(
            username=username,
            cookie_path=account_store.file_path(username),
            has_valid_session=account_store.has_valid_session(username),
        )
        session.add(acct)
        imported.append(acct)
    session.commit()
    for a in imported:
        session.refresh(a)
    return [to_read(a, session) for a in imported]
