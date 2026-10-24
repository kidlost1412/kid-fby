"""Look up local posting outcomes by content hash, source Reel ID or receipt."""
from collections import defaultdict
from fastapi import APIRouter, Depends, HTTPException
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field
from sqlmodel import Session, select
from api.db import get_session
from api.models import DesktopReceipt, UploadHistory
from api.routers.desktop import expire_stale
from api.services import links
from api.services.history import LIGHT, chunks, entries_by_request
from datetime import datetime, timezone

router = APIRouter(prefix="/api/history", tags=["history"])


class VideoIdentity(BaseModel):
    reel_id: str = Field(default="", max_length=128)
    sha256: str = Field(default="", max_length=64)
    request_ids: list[str] = Field(default_factory=list, max_length=1000)


class HistoryLookup(BaseModel):
    videos: list[VideoIdentity] = Field(max_length=2000)


def _dump(entry, exclude=None):
    data = entry.model_dump(exclude=exclude)
    for key, value in data.items():
        if isinstance(value, datetime):
            data[key] = value.replace(tzinfo=timezone.utc).isoformat() if value.tzinfo is None else value.isoformat()
    return data


@router.get("/entry/{key}")
def get_entry(key: str, session: Session = Depends(get_session)):
    """One full history row, including the sanitized publish response TikTok returned."""
    entry = session.get(UploadHistory, key)
    if entry is None:
        raise HTTPException(404, "history entry not found")
    return _dump(entry)


@router.post("/{key}/refresh-link")
def refresh_link(key: str, session: Session = Depends(get_session)):
    """Look for the public post link again (read-only lookup by the scheduler; never reposts)."""
    entry = links.reset(session, key)
    if entry is None:
        raise HTTPException(404, "history entry not found")
    if entry.status != "succeeded":
        raise HTTPException(409, "Chỉ lấy link cho bài TikTok đã nhận.")
    return _dump(entry, exclude={"publish_response_json", "caption"})


@router.post("/lookup")
def lookup(payload: HistoryLookup, session: Session = Depends(get_session)):
    # Legacy jobs are backfilled once at startup; a lookup never writes history rows.
    expire_stale(session)
    by_column = {}
    for column, values in ((UploadHistory.sha256, {v.sha256 for v in payload.videos if v.sha256}),
                           (UploadHistory.reel_id, {v.reel_id for v in payload.videos if v.reel_id})):
        index = by_column[column.key] = defaultdict(list)
        for chunk in chunks(sorted(values)):
            for entry in session.exec(select(UploadHistory).options(*LIGHT).where(column.in_(chunk))).all():
                index[getattr(entry, column.key)].append(entry)
    request_ids = {r for v in payload.videos for r in v.request_ids if r}
    by_request = entries_by_request(session, request_ids)
    receipts = {}
    for chunk in chunks(sorted(request_ids - by_request.keys())):
        for receipt in session.exec(select(DesktopReceipt).where(DesktopReceipt.request_id.in_(chunk))).all():
            receipts[receipt.request_id] = receipt

    def read(entry):
        return _dump(entry, exclude={"publish_response_json", "caption"})  # kept small; see GET /entry/{key}
    result = []
    for video in payload.videos:
        matched = {}
        for entry in [*by_column["sha256"].get(video.sha256, ()), *by_column["reel_id"].get(video.reel_id, ()),
                      *(by_request[r] for r in video.request_ids if r in by_request)]:
            matched[entry.key] = entry
        row = {"reel_id": video.reel_id, "entries": [
            read(entry) for entry in sorted(matched.values(), key=lambda e: e.created_at, reverse=True)]}
        present = {entry.get("request_id") for entry in row["entries"]}
        for request_id in video.request_ids:
            if request_id in present:
                continue
            receipt = receipts.get(request_id)
            if receipt and receipt.schedule_id is None:
                row["entries"].append({"key": f"receipt:{request_id}", "request_id": request_id,
                    "username": "", "status": receipt.state, "accepted_at": None,
                    "planned_for": None, "created_at": receipt.created_at.replace(tzinfo=timezone.utc).isoformat(),
                    "publish_uncertain": False, "prior_uncertain": False, "sha256": "", "reel_id": "",
                    "time_source": "legacy_receipt"})
        result.append(row)
    # Already plain JSON values: skip FastAPI's per-field encoder (it dominates a 2000-video lookup).
    return JSONResponse(result)
