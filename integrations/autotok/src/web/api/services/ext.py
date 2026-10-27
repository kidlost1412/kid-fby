"""Chrome extension publisher: pairing, readiness, child jobs and their reconciliation.

Protocol and state machine: integrations/autotok-extension/PROTOCOL.md. Rules that matter most:
  * a child (extension_jobs row) is created in the same transaction that moves its parent
    scheduled_uploads row pending_ext -> waiting_ext for that attempt; UNIQUE(schedule_id, attempt);
  * authorize and revoke are single conditional UPDATEs, so only one of them can win;
  * the parent is finalized from durable child state by reconcile_ext(), never by a waiting process;
  * nothing here ever falls back to the cookie publisher.
"""
from __future__ import annotations

import hashlib
import hmac
import json
import logging
import re
import secrets
import threading
from datetime import datetime, timedelta, timezone
from typing import Optional

from sqlalchemy import func, select as sa_select, update
from sqlalchemy.exc import IntegrityError, OperationalError
from sqlmodel import Session, select

import api.db as _api_db
from api.db import now_utc
from api.models import EXT_TERMINAL, Account, ExtensionClient, ExtensionJob, ScheduledUpload, UploadHistory
from api.schemas import NATIVE_MAX_AHEAD, NATIVE_SLACK, PRIVATE_TEXT, WINDOW_TEXT
from api.services import videos as library
from api.services.history import record_failure, record_success, schedule_key, track_schedule
from api.services.tiktok_adapter import UploadOutcome, native_schedule
from autotok.uploader import MAX_SCHEDULE_SHIFT, MIN_SCHEDULE, SCHEDULE_EXPIRED_TEXT, sanitize_response

log = logging.getLogger("api.ext")

PROTOCOL_MIN = 1
PROTOCOL_MAX = 1
EXT_ORIGIN = "chrome-extension://pomofdinonmfmpnpjdneihgklgdkidmc"
RELOAD_TEXT = "Cần tải lại tiện ích (chrome://extensions → ⟳)"

ONLINE_WINDOW = timedelta(seconds=90)
CLAIM_WITHIN = timedelta(seconds=120)
STALE_AFTER = timedelta(seconds=120)
UPLOAD_WITHIN = timedelta(minutes=15)
RESULT_WITHIN = timedelta(seconds=180)
PAIR_VALID = timedelta(minutes=5)
PAIR_MAX_TRIES = 5

PRE_AUTH = ("queued", "claimed", "uploading", "ready")
RUNNING = ("claimed", "uploading", "ready")

NOT_READY_TEXT = "Chrome chưa sẵn sàng (không nhận việc trong 2 phút) — chưa đăng"
STALLED_TEXT = "Chrome ngừng giữa chừng (không có tín hiệu 2 phút) — chưa đăng"
TOO_LONG_TEXT = "Chrome tải quá 15 phút — đã dừng, chưa đăng"
CANCEL_TEXT = "Chrome đã hủy việc trước khi đăng — chưa đăng"
NO_RESULT_TEXT = ("Chrome đã được phép đăng nhưng không báo kết quả trong 3 phút — có thể đã đăng hoặc chưa; "
                  "kiểm tra TikTok trước khi thử lại")
NOT_CHROME_TEXT = "Tài khoản không còn đăng qua Chrome — chưa đăng; hãy thử lại"
FRIENDS_TEXT = "Chế độ hiển thị này chưa hỗ trợ khi đăng qua Chrome (chỉ công khai hoặc riêng tư) — chưa đăng"
YOUTUBE_TEXT = "Đăng qua Chrome chưa hỗ trợ nguồn YouTube — chưa đăng"


def _utc(value: Optional[datetime]) -> Optional[datetime]:
    if value is None:
        return None
    return value.replace(tzinfo=timezone.utc) if value.tzinfo is None else value.astimezone(timezone.utc)


def iso(value: Optional[datetime]) -> Optional[str]:
    value = _utc(value)
    return value.strftime("%Y-%m-%dT%H:%M:%SZ") if value else None


def protocol_ok(protocol: int) -> bool:
    return PROTOCOL_MIN <= protocol <= PROTOCOL_MAX


def _log_transition(job: ExtensionJob, old: str, new: str, client: Optional[int] = None) -> None:
    log.info("ext-transition receipt=%s job=%s schedule=%s attempt=%s client=%s %s->%s",
             job.request_id or job.schedule_key, job.id, job.schedule_id, job.attempt,
             client if client is not None else job.claim_client, old, new)


# ---------- pairing ----------------------------------------------------------

_pair_lock = threading.Lock()
_pair: dict = {}


def new_pair_code(now: Optional[datetime] = None) -> dict:
    now = now or now_utc()
    code = f"{secrets.randbelow(10 ** 6):06d}"
    with _pair_lock:
        _pair.clear()
        _pair.update(code=code, expires=now + PAIR_VALID, tries=0)
    return {"code": code, "expires_at": iso(now + PAIR_VALID), "valid_s": int(PAIR_VALID.total_seconds())}


def use_pair_code(code: str, now: Optional[datetime] = None) -> tuple[bool, str, int]:
    """(ok, error code, tries left). A right code is consumed; 5 wrong tries burn it."""
    now = now or now_utc()
    with _pair_lock:
        if not _pair or now >= _pair["expires"]:
            _pair.clear()
            return False, "no_code", 0
        if hmac.compare_digest(str(code), _pair["code"]):
            _pair.clear()
            return True, "", 0
        _pair["tries"] += 1
        left = PAIR_MAX_TRIES - _pair["tries"]
        if left <= 0:
            _pair.clear()
            return False, "no_code", 0
        return False, "bad_code", left


def token_hash(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def create_client(session: Session, label: str, ext_version: str, protocol: int) -> tuple[ExtensionClient, str]:
    token = secrets.token_urlsafe(32)
    client = ExtensionClient(token_hash=token_hash(token), label=label[:128], ext_version=ext_version[:32],
                             protocol=protocol, last_seen_at=now_utc())
    session.add(client)
    session.commit()
    session.refresh(client)
    log.info("ext: paired client %s (%s, extension %s)", client.id, client.label, client.ext_version)
    return client, token


def client_for_token(session: Session, token: str) -> Optional[ExtensionClient]:
    if not token:
        return None
    client = session.exec(select(ExtensionClient).where(ExtensionClient.token_hash == token_hash(token))).first()
    return client if client and client.revoked_at is None else None


def touch(session: Session, client: ExtensionClient, protocol: int, **fields) -> None:
    client.last_seen_at = now_utc()
    client.protocol = protocol
    for k, v in fields.items():
        setattr(client, k, v)
    session.add(client)
    session.commit()


def online(client: ExtensionClient, now: Optional[datetime] = None) -> bool:
    seen = _utc(client.last_seen_at)
    return bool(seen and (now or now_utc()) - seen < ONLINE_WINDOW)


def online_clients_for(session: Session, user_id: Optional[str]) -> list[ExtensionClient]:
    if not user_id:
        return []
    rows = session.exec(select(ExtensionClient).where(ExtensionClient.tiktok_user_id == user_id,
                                                      ExtensionClient.revoked_at.is_(None))).all()
    now = now_utc()
    return [c for c in rows if online(c, now)]


def in_conflict(session: Session, client: ExtensionClient) -> bool:
    return any(c.id != client.id for c in online_clients_for(session, client.tiktok_user_id))


def bound_account(session: Session, user_id: Optional[str]) -> Optional[Account]:
    if not user_id:
        return None
    return session.exec(select(Account).where(Account.publisher == "chrome",
                                              Account.chrome_user_id == user_id)).first()


def readiness(session: Session, acct: Account) -> tuple[bool, str]:
    if acct.publisher != "chrome":
        return (True, "ok") if acct.has_valid_session else (False, "no_session")
    if not acct.chrome_user_id:
        return False, "chrome_unbound"
    clients = online_clients_for(session, acct.chrome_user_id)
    if not clients:
        return False, "chrome_offline"
    if len(clients) > 1:
        return False, "chrome_conflict"
    if not protocol_ok(clients[0].protocol):
        return False, "chrome_need_reload"
    return True, "ok"


# ---------- options / validation --------------------------------------------

def wire_options(row: ScheduledUpload, now: Optional[datetime] = None) -> tuple[Optional[dict], Optional[str]]:
    """(options for the extension, None) or (None, Vietnamese reason). Refusals are definite: nothing sent."""
    now = now or now_utc()
    if row.source_type != "local":
        return None, YOUTUBE_TEXT
    try:
        options = json.loads(row.options_json or "{}")
        if not isinstance(options, dict):
            raise ValueError
    except ValueError:
        return None, "invalid options_json"
    try:
        visibility = int(options.get("visibility_type", 0))
        flags = {k: int(bool(int(options.get(k, d))))
                 for k, d in (("allow_comment", 1), ("allow_duet", 0), ("allow_stitch", 0), ("ai_label", 0))}
    except (TypeError, ValueError):
        return None, "invalid options_json"
    if visibility not in (0, 1):
        return None, FRIENDS_TEXT
    try:
        when = native_schedule(options)
    except ValueError:
        return None, "invalid tiktok_schedule_time in job options"
    if when is not None:
        if visibility == 1:
            return None, PRIVATE_TEXT
        when = when.astimezone(timezone.utc)
        # Same limits as autotok.uploader: at publish time the extension may push it back <= 10 min.
        if when < now + MIN_SCHEDULE - MAX_SCHEDULE_SHIFT:
            return None, SCHEDULE_EXPIRED_TEXT
        if when > now + NATIVE_MAX_AHEAD + NATIVE_SLACK:
            return None, WINDOW_TEXT
    return {"visibility_type": visibility, **flags, "schedule_time": iso(when)}, None


def job_payload(job: ExtensionJob, client: ExtensionClient) -> dict:
    opts = json.loads(job.options_json or "{}")
    when = opts.get("schedule_time")
    size = None
    try:
        size = library.resolve(job.video_name).stat().st_size
    except (ValueError, OSError):
        pass
    return {
        "id": job.id, "nonce": job.nonce, "claim_token": job.claim_token, "mode": "post", "attempt": job.attempt,
        "caption": job.caption, "visibility": "private" if opts.get("visibility_type") == 1 else "public",
        "visibility_type": opts.get("visibility_type", 0), "schedule_time": when,
        "schedule_unix": int(datetime.fromisoformat(when.replace("Z", "+00:00")).timestamp()) if when else None,
        "options": {k: opts.get(k, d) for k, d in (("allow_comment", 1), ("allow_duet", 0),
                                                   ("allow_stitch", 0), ("ai_label", 0))},
        "expect_account": client.tiktok_username, "expect_user_id": job.expect_user_id,
        "video": {"name": job.video_name, "size": size, "type": library_type(job.video_name)},
        "limits": {"claim_within_s": int(CLAIM_WITHIN.total_seconds()), "heartbeat_every_s": 60,
                   "stale_after_s": int(STALE_AFTER.total_seconds()),
                   "upload_within_s": int(UPLOAD_WITHIN.total_seconds()),
                   "result_within_s": int(RESULT_WITHIN.total_seconds()),
                   "schedule_min_ahead_s": int(MIN_SCHEDULE.total_seconds()),
                   "schedule_max_shift_s": int(MAX_SCHEDULE_SHIFT.total_seconds())},
    }


def library_type(name: str) -> str:
    return {".webm": "video/webm", ".mov": "video/quicktime"}.get(name[name.rfind("."):].lower(), "video/mp4")


# ---------- parent outcome ---------------------------------------------------

def _apply(s: Session, parent: ScheduledUpload, expected_status: str, outcome: UploadOutcome) -> bool:
    """Conditional parent update + history in the caller's transaction (not committed). False if it changed."""
    now = now_utc()
    if outcome.ok:
        changes = dict(status="succeeded", publish_uncertain=False,
                       result_text=f"{outcome.message} (video id {outcome.video_id})" if outcome.video_id
                       else outcome.message)
    else:
        changes = dict(status="failed", publish_uncertain=outcome.uncertain, result_text=outcome.message)
    won = s.exec(update(ScheduledUpload).where(
        ScheduledUpload.id == parent.id, ScheduledUpload.attempts == parent.attempts,
        ScheduledUpload.status == expected_status).values(updated_at=now, **changes)).rowcount
    if won != 1:
        return False
    s.refresh(parent)
    if outcome.ok:
        acct = s.get(Account, parent.account_id)
        if acct:
            acct.last_used_at = now
            s.add(acct)
    entry = track_schedule(s, parent)
    if outcome.ok:
        record_success(entry, outcome, parent.title)
    else:
        record_failure(entry, outcome)
    s.add(entry)
    return True


def fail_parent(parent_id: int, attempts: int, expected_status: str, message: str) -> bool:
    """Definite failure (nothing sent) for a parent still in ``expected_status``."""
    with Session(_api_db.engine) as s:
        parent = s.get(ScheduledUpload, parent_id)
        if not parent or parent.attempts != attempts:
            return False
        if not _apply(s, parent, expected_status, UploadOutcome(ok=False, message=message)):
            s.rollback()
            return False
        s.commit()
        log.info("ext: schedule %s attempt %s %s->failed: %s", parent_id, attempts, expected_status, message)
        return True


def _result(job: ExtensionJob) -> dict:
    try:
        data = json.loads(job.result_json) if job.result_json else {}
    except ValueError:
        data = {}
    return data if isinstance(data, dict) else {}


def _when(raw) -> Optional[datetime]:
    if raw in (None, ""):
        return None
    try:
        if isinstance(raw, (int, float)) and not isinstance(raw, bool):
            return datetime.fromtimestamp(int(raw), tz=timezone.utc)
        return _utc(datetime.fromisoformat(str(raw).replace("Z", "+00:00")))
    except (ValueError, OverflowError, OSError):
        return None


def outcome_of(job: ExtensionJob) -> UploadOutcome:
    r = _result(job)
    response_json = str(r.get("response_json") or "")
    reason = str(r.get("reason") or "")[:200]
    detail = str(r.get("detail") or "")[:300]
    if job.state == "posted":
        scheduled_opt = json.loads(job.options_json or "{}").get("schedule_time")
        when = (_when(r.get("schedule_time")) or _when(scheduled_opt)) if scheduled_opt else None
        item = r.get("item_id")
        return UploadOutcome(ok=True, message="scheduled on TikTok" if when else "published",
                             video_id=str(r["video_id"]) if r.get("video_id") else None,
                             post_id=str(item) if item not in (None, "") else None,
                             creation_id=job.auth_creation_id or (str(r["creation_id"]) if r.get("creation_id") else None),
                             tiktok_schedule_time=when, response_json=response_json)
    if job.state == "rejected":
        code, msg = r.get("status_code"), str(r.get("status_msg") or "")[:200]
        text = (f"TikTok từ chối bài đăng (status_code {code}{': ' + msg if msg else ''})" if code is not None
                else f"TikTok từ chối bài đăng ({reason or 'http ' + str(r.get('http'))})")
        return UploadOutcome(ok=False, message=text, response_json=response_json)
    if job.state == "uncertain":
        if not job.result_json:
            return UploadOutcome(ok=False, message=NO_RESULT_TEXT, uncertain=True)
        return UploadOutcome(ok=False, uncertain=True, response_json=response_json,
                             message=f"Không rõ đã đăng hay chưa (Chrome: {reason or 'uncertain'}) — "
                                     "kiểm tra TikTok trước khi thử lại")
    if job.state == "revoked":
        return UploadOutcome(ok=False, message=job.note or CANCEL_TEXT)
    return UploadOutcome(ok=False, response_json=response_json,
                         message=f"Chrome báo lỗi, chưa đăng: {reason or 'failed'}{': ' + detail if detail else ''}")


def _note_history(s: Session, job: ExtensionJob, outcome: UploadOutcome, why: str) -> None:
    """A success that cannot change its parent (superseded, deleted, anomaly) is still kept in the history."""
    log.warning("ext: job %s (schedule %s attempt %s) %s; parent left unchanged", job.id, job.schedule_id,
                job.attempt, why)
    if not outcome.ok:
        return
    entry = s.get(UploadHistory, job.schedule_key)
    if entry is None:
        log.error("ext: late success of job %s (post id %s) has no history entry", job.id, outcome.post_id)
        return
    note = (f"late success of attempt {job.attempt} via Chrome"
            + (f" (post id {outcome.post_id})" if outcome.post_id else "")
            + f": {why}; check the account before reposting")
    if not entry.post_id and outcome.post_id:
        from api.services.history import build_post_url
        entry.post_id, entry.post_url = outcome.post_id, build_post_url(entry.username, outcome.post_id)
        if entry.post_url:
            entry.link_state, entry.link_next_at = "found", None
    entry.prior_uncertain = True
    entry.result_text = f"{entry.result_text} | {note}" if entry.result_text else note
    s.add(entry)


def finalize_child(job_id: str) -> bool:
    """Apply a terminal child's state to its parent + history once (idempotent). True if something changed."""
    for _ in range(3):
        with Session(_api_db.engine) as s:
            job = s.get(ExtensionJob, job_id)
            if not job or job.state not in EXT_TERMINAL or job.finalized_state == job.state:
                return False
            outcome = outcome_of(job)
            parent = s.get(ScheduledUpload, job.schedule_id)
            owned = bool(parent and schedule_key(parent) == job.schedule_key and parent.attempts == job.attempt)
            late = job.finalized_state == "uncertain"
            applied = True
            if owned and parent.status == "waiting_ext":
                applied = _apply(s, parent, "waiting_ext", outcome)
            elif owned and late and parent.status == "failed" and job.state in ("posted", "rejected", "failed"):
                applied = _apply(s, parent, "failed", outcome)  # the real outcome of an uncertain attempt
            elif owned and late and parent.status == "pending" and outcome.ok:
                applied = _apply(s, parent, "pending", outcome)  # the manual retry must not post again
            elif not owned:
                _note_history(s, job, outcome, "a newer attempt owns the job, or it was deleted")
            elif job.state != "revoked" and outcome.ok:
                _note_history(s, job, outcome, f"parent is {parent.status}")
            if not applied:
                s.rollback()
                continue
            won = s.exec(update(ExtensionJob).where(ExtensionJob.id == job.id, ExtensionJob.state == job.state)
                         .values(finalized_state=job.state, updated_at=now_utc())).rowcount
            if won != 1:
                s.rollback()
                continue
            s.commit()
            log.info("ext-finalized job=%s schedule=%s attempt=%s state=%s parent=%s", job.id, job.schedule_id,
                     job.attempt, job.state, parent.status if parent else "(deleted)")
            return True
    log.error("ext: job %s not finalized after repeated concurrent changes", job_id)
    return False


# ---------- child transitions -----------------------------------------------

def revoke(job_id: str, note: str) -> bool:
    """Pre-authorization only. True when this call won against authorize (C1)."""
    with Session(_api_db.engine) as s:
        job = s.get(ExtensionJob, job_id)
        won = s.exec(update(ExtensionJob).where(ExtensionJob.id == job_id, ExtensionJob.state.in_(PRE_AUTH))
                     .values(state="revoked", note=note, updated_at=now_utc())).rowcount
        s.commit()
        if won and job:
            _log_transition(job, job.state, "revoked")
        return won == 1


def authorize(job: ExtensionJob, sha: str, creation_id: str) -> bool:
    """The one conditional UPDATE that grants the publish (C1). Commits before returning."""
    current = (sa_select(ScheduledUpload.attempts)
               .where(ScheduledUpload.id == ExtensionJob.schedule_id, ScheduledUpload.status == "waiting_ext")
               .scalar_subquery())
    with Session(_api_db.engine) as s:
        now = now_utc()
        won = s.exec(update(ExtensionJob).where(
            ExtensionJob.id == job.id, ExtensionJob.state == "ready", ExtensionJob.claim_token == job.claim_token,
            ExtensionJob.nonce == job.nonce, ExtensionJob.attempt == current,
        ).values(state="authorized", authorized_at=now, auth_sha=sha, auth_creation_id=creation_id,
                 updated_at=now)).rowcount
        s.commit()
    if won == 1:
        _log_transition(job, "ready", "authorized")
    return won == 1


def ingest_result(job_id: str, body: dict) -> tuple[bool, str]:
    """Store the first result durably. Returns (duplicate, state after)."""
    outcome = str(body.get("outcome") or "")
    not_sent = body.get("not_sent") is True or body.get("notSent") is True
    keep = {k: body[k] for k in ("outcome", "definite", "reason", "detail", "http", "status_code", "status_msg",
                                 "item_id", "creation_id", "video_id", "schedule_time", "elapsed_ms", "authorized")
            if k in body}
    keep["not_sent"] = not_sent
    if body.get("response") is not None:
        keep["response_json"] = sanitize_response(body["response"])  # same filter and size cap as the cookie path
    for _ in range(3):
        with Session(_api_db.engine) as s:
            job = s.get(ExtensionJob, job_id)
            if job.result_json is not None:
                s.exec(update(ExtensionJob).where(ExtensionJob.id == job_id)
                       .values(duplicate_results=ExtensionJob.duplicate_results + 1))
                s.commit()
                log.info("ext: duplicate result for job %s (%s), ignored", job_id, outcome)
                return True, job.state
            old = job.state
            if old in ("authorized", "uncertain"):
                new = {"posted": "posted", "rejected": "rejected", "uncertain": "uncertain"}.get(
                    outcome, "failed" if outcome == "failed" and not_sent else "uncertain")
            elif old in PRE_AUTH:
                new = {"posted": "posted", "uncertain": "uncertain"}.get(outcome, "failed")
                if new != "failed":
                    log.error("ext: job %s reported %s without authorization (gate bypassed?)", job_id, outcome)
            else:
                new = old  # revoked / already final: keep, record the result
                if outcome == "posted":
                    log.error("ext: job %s reported posted while %s", job_id, old)
            won = s.exec(update(ExtensionJob).where(ExtensionJob.id == job_id, ExtensionJob.state == old,
                                                    ExtensionJob.result_json.is_(None))
                         .values(state=new, result_json=json.dumps(keep, ensure_ascii=False), result_at=now_utc(),
                                 updated_at=now_utc())).rowcount
            if won != 1:
                s.rollback()
                continue
            if new == old and outcome == "posted":
                s.refresh(job)
                _note_history(s, job, UploadOutcome(ok=True, message="published", post_id=str(body.get("item_id") or "") or None),
                              f"Chrome reported a post while the job was {old}")
            s.commit()
            if new != old:
                _log_transition(job, old, new)
            return False, new
    raise RuntimeError(f"ext: result for job {job_id} not stored after repeated concurrent changes")


# ---------- reconciliation --------------------------------------------------

def _expire(now: datetime) -> None:
    with Session(_api_db.engine) as s:
        queued = s.exec(select(ExtensionJob.id).where(ExtensionJob.state == "queued",
                                                      ExtensionJob.created_at < now - CLAIM_WITHIN)).all()
        running = s.exec(select(ExtensionJob).where(ExtensionJob.state.in_(RUNNING))).all()
        authorized = s.exec(select(ExtensionJob).where(ExtensionJob.state == "authorized",
                                                       ExtensionJob.authorized_at < now - RESULT_WITHIN)).all()
    for jid in queued:
        revoke(jid, NOT_READY_TEXT)
    for job in running:
        if _utc(job.claimed_at) and now - _utc(job.claimed_at) > UPLOAD_WITHIN:
            revoke(job.id, TOO_LONG_TEXT)
        elif now - (_utc(job.heartbeat_at) or _utc(job.claimed_at) or _utc(job.created_at)) > STALE_AFTER:
            revoke(job.id, STALLED_TEXT)
    for job in authorized:  # a post may have been sent: never definite, never re-run
        with Session(_api_db.engine) as s:
            won = s.exec(update(ExtensionJob).where(ExtensionJob.id == job.id, ExtensionJob.state == "authorized",
                                                    ExtensionJob.result_json.is_(None))
                         .values(state="uncertain", note=NO_RESULT_TEXT, updated_at=now_utc())).rowcount
            s.commit()
        if won:
            _log_transition(job, "authorized", "uncertain")


def _promote(now: datetime) -> None:
    with Session(_api_db.engine) as s:
        busy = set(s.exec(select(ExtensionJob.account_id).where(ExtensionJob.state.not_in(EXT_TERMINAL))).all())
        waiting = s.exec(select(ScheduledUpload).where(ScheduledUpload.status == "pending_ext")
                         .order_by(ScheduledUpload.scheduled_for, ScheduledUpload.id)).all()
    seen: set[int] = set()
    for row in waiting:
        if row.account_id in busy or row.account_id in seen:
            continue
        seen.add(row.account_id)
        with Session(_api_db.engine) as s:
            acct = s.get(Account, row.account_id)
        if not acct or acct.publisher != "chrome" or not acct.chrome_user_id:
            fail_parent(row.id, row.attempts, "pending_ext", NOT_CHROME_TEXT)
            seen.discard(row.account_id)
            continue
        options, error = wire_options(row, now)
        if error is None:
            try:
                name = library.resolve(row.source_ref).name
            except ValueError as exc:
                error = str(exc)
        if error:
            fail_parent(row.id, row.attempts, "pending_ext", error)
            seen.discard(row.account_id)  # the next job of this account may go
            continue
        _create_child(row, acct, name, options)


def _create_child(row: ScheduledUpload, acct: Account, name: str, options: dict) -> Optional[str]:
    """Child + parent pending_ext -> waiting_ext in ONE transaction, fenced on the attempt."""
    with Session(_api_db.engine) as s:
        entry = s.get(UploadHistory, schedule_key(row))
        job = ExtensionJob(id="ej_" + secrets.token_hex(12), schedule_id=row.id, attempt=row.attempts,
                           schedule_key=schedule_key(row), request_id=entry.request_id if entry else None,
                           account_id=acct.id, expect_user_id=acct.chrome_user_id, video_name=name,
                           caption=row.title, options_json=json.dumps(options), nonce=secrets.token_hex(16))
        try:
            s.add(job)
            s.flush()
            won = s.exec(update(ScheduledUpload).where(
                ScheduledUpload.id == row.id, ScheduledUpload.attempts == row.attempts,
                ScheduledUpload.status == "pending_ext").values(status="waiting_ext", updated_at=now_utc())).rowcount
            if won != 1:
                s.rollback()
                return None
            parent = s.get(ScheduledUpload, row.id)
            s.refresh(parent)
            track_schedule(s, parent)
            s.commit()
        except IntegrityError:  # the account got a child meanwhile, or this attempt already has one
            s.rollback()
            return None
        _log_transition(job, "-", "queued")
        return job.id


def reconcile_ext() -> None:
    """Idempotent; safe from several threads and processes. Deadlines, results, promotion."""
    now = now_utc()
    for step in (_expire, _finalize_all, _promote):
        try:
            step(now)
        except OperationalError:
            log.warning("ext: reconcile step %s skipped (database busy); next tick retries", step.__name__)


def _finalize_all(_now: datetime) -> None:
    with Session(_api_db.engine) as s:
        ids = s.exec(select(ExtensionJob.id).where(
            ExtensionJob.state.in_(EXT_TERMINAL),
            (ExtensionJob.finalized_state.is_(None)) | (ExtensionJob.finalized_state != ExtensionJob.state))).all()
    for jid in ids:
        finalize_child(jid)


def active_children(session: Session) -> int:
    """Children Chrome may be working on right now (claimed..authorized): the installer drains these."""
    return session.exec(select(func.count()).select_from(ExtensionJob)
                        .where(ExtensionJob.state.in_(RUNNING + ("authorized",)))).one()


# ---------- extension calls -------------------------------------------------

def claim_next(client: ExtensionClient) -> Optional[ExtensionJob]:
    """Oldest queued child of the account bound to this client's identity; claimed at most once."""
    with Session(_api_db.engine) as s:
        acct = bound_account(s, client.tiktok_user_id)
        if acct is None:
            return None
        job = s.exec(select(ExtensionJob).where(ExtensionJob.account_id == acct.id, ExtensionJob.state == "queued",
                                                ExtensionJob.expect_user_id == client.tiktok_user_id)
                     .order_by(ExtensionJob.created_at)).first()
        if job is None:
            return None
        now = now_utc()
        won = s.exec(update(ExtensionJob).where(ExtensionJob.id == job.id, ExtensionJob.state == "queued")
                     .values(state="claimed", claim_client=client.id, claim_token=secrets.token_hex(16),
                             claimed_at=now, heartbeat_at=now, updated_at=now)).rowcount
        s.commit()
        if won != 1:
            return None
        s.refresh(job)
        _log_transition(job, "queued", "claimed", client.id)
        return job


def release_claim(job: ExtensionJob) -> bool:
    """Undo a claim whose reply could not be delivered. Only while still 'claimed' by that very claim
    (no progress, nothing uploaded, never authorized); the claim deadline keeps counting from creation."""
    with Session(_api_db.engine) as s:
        won = s.exec(update(ExtensionJob).where(
            ExtensionJob.id == job.id, ExtensionJob.state == "claimed", ExtensionJob.claim_token == job.claim_token)
            .values(state="queued", claim_client=None, claim_token=None, claimed_at=None, heartbeat_at=None,
                    updated_at=now_utc())).rowcount
        s.commit()
    if won:
        _log_transition(job, "claimed", "queued")
    return won == 1


def heartbeat(job: ExtensionJob, ready: bool = False) -> str:
    with Session(_api_db.engine) as s:
        now = now_utc()
        s.exec(update(ExtensionJob).where(ExtensionJob.id == job.id, ExtensionJob.state.in_(RUNNING))
               .values(heartbeat_at=now, updated_at=now))
        new = "ready" if ready else "uploading"
        moved = s.exec(update(ExtensionJob).where(
            ExtensionJob.id == job.id,
            ExtensionJob.state.in_(("claimed", "uploading") if ready else ("claimed",))).values(state=new)).rowcount
        s.commit()
        fresh = s.get(ExtensionJob, job.id)
        if moved:
            _log_transition(fresh, job.state, new)
        return fresh.state


def state_refusal(session: Session, job: ExtensionJob) -> Optional[str]:
    if job.state == "authorized":
        return "already-authorized"
    if job.state == "revoked":
        return "revoked"
    if job.state in EXT_TERMINAL:
        return "terminal"
    parent = session.get(ScheduledUpload, job.schedule_id)
    if not parent or parent.attempts != job.attempt or parent.status != "waiting_ext":
        return "superseded"
    if job.state != "ready":
        return "not-ready"
    return None


def authorize_refusal(session: Session, job: ExtensionJob, client: ExtensionClient, body: dict,
                      protocol: int) -> Optional[str]:
    """Checks before the conditional UPDATE. None = may try to authorize."""
    if not protocol_ok(protocol):
        return "need-reload"
    refusal = state_refusal(session, job)
    if refusal:
        return refusal
    sha, cid = body.get("body_sha256"), body.get("creation_id")
    if not (isinstance(sha, str) and re.fullmatch(r"[0-9a-f]{64}", sha)) or not (isinstance(cid, str) and cid):
        return "bad-binding"
    identity = body.get("identity") if isinstance(body.get("identity"), dict) else {}
    if str(identity.get("user_id") or "") != job.expect_user_id or client.tiktok_user_id != job.expect_user_id:
        return "identity-mismatch"
    if in_conflict(session, client):
        return "identity-conflict"
    opts = json.loads(job.options_json or "{}")
    if body.get("visibility_type") != opts.get("visibility_type"):
        return "visibility-mismatch"
    sent = body.get("schedule_time")
    wanted = opts.get("schedule_time")
    if wanted is None:
        if sent is not None:
            return "schedule-mismatch"
    else:
        target = int(datetime.fromisoformat(wanted.replace("Z", "+00:00")).timestamp())
        if not (isinstance(sent, int) and not isinstance(sent, bool)):
            return "schedule-mismatch"
        earliest = now_utc().timestamp() + MIN_SCHEDULE.total_seconds() - 60
        if not (target <= sent <= target + MAX_SCHEDULE_SHIFT.total_seconds()) or sent < earliest:
            return "schedule-mismatch"
    return None
