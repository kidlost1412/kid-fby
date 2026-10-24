"""Regression tests for the v3 QA fixes (post link without a clean handle, sanitizer, fresh-DB defaults, retry)."""
import json
from datetime import timedelta
from types import SimpleNamespace

import sqlalchemy
from sqlmodel import Session, select

import api.db as db
from api.models import UploadHistory
from api.services import history
from autotok.uploader import sanitize_response

PID = "7429183650274961408"


def test_build_post_url_handle_bounds():
    assert history.build_post_url("demo.user_1", PID) == f"https://www.tiktok.com/@demo.user_1/video/{PID}"
    assert history.build_post_url("kid-main", PID) is None  # '-' is not allowed in a handle: never invent one
    assert history.build_post_url("a" * 24, PID) is not None and history.build_post_url("a" * 25, PID) is None
    assert history.build_post_url("demo", "123") is None  # id malformed
    assert history.build_post_url("a", PID) is None  # handle too short


def test_record_success_with_unusable_label_still_found_without_url():
    entry = UploadHistory(key="k", username="(tài khoản đã xóa)")
    history.record_success(entry, SimpleNamespace(video_id="v", post_id=PID, creation_id="c", response_json=""))
    assert (entry.link_state, entry.post_id, entry.post_url) == ("found", PID, None)


def test_sanitize_keeps_ids_and_drops_credentials():
    resp = {"status_code": 0, "status_msg": "", "single_post_resp_list": [{"item_id": PID, "creation_id": "c"}],
            "data": {"video_id": "v", "x_sid": "S", "api_key": "K", "note": "a=b; c=d"}}
    out = json.loads(sanitize_response(resp))
    assert out["single_post_resp_list"][0]["item_id"] == PID and out["status_code"] == 0
    assert "x_sid" not in out["data"] and "api_key" not in out["data"] and out["data"]["video_id"] == "v"
    assert out["data"]["note"] != "a=b; c=d"


def test_fresh_v3_db_accepts_a_row_written_by_v2_code(tmp_path):
    engine = db.make_engine(f"sqlite:///{tmp_path / 'fresh.db'}")
    db.override_engine(engine)
    db.init_db()
    with engine.begin() as conn:  # v2 knows neither link_state nor link_attempts
        conn.execute(sqlalchemy.text(
            "INSERT INTO upload_history (key, username, reel_id, sha256, original_name, status, "
            "publish_uncertain, prior_uncertain, time_source, created_at) VALUES ('k','u','','','x','pending',0,0,'acknowledgement','2026-01-01')"))
    with Session(engine) as s:
        row = s.get(UploadHistory, "k")
        assert row.link_state == "" and row.link_attempts == 0
    engine.dispose()
