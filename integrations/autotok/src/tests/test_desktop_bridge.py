"""Offline integration tests: no cookies, media or TikTok requests from the real app."""
import json
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient
from sqlmodel import Session, select

import api.db as db
from api.main import create_app
from api.models import Account, DesktopReceipt, ScheduledUpload
from api.services.tiktok_adapter import UploadOutcome
from autotok import settings
from scheduler import worker


@pytest.fixture
def client(tmp_path):
    old = db.engine
    engine = db.make_engine(f"sqlite:///{tmp_path / 'bridge.db'}")
    db.override_engine(engine)
    db.init_db()
    with Session(engine) as s:
        s.add(Account(username="demo", cookie_path=str(tmp_path / 'absent.cookie'), has_valid_session=True))
        s.commit()
    with TestClient(create_app(), base_url="http://localhost", headers={"X-Requested-With": "autotok"}) as c:
        yield c
    db.override_engine(old)
    engine.dispose()


def post(client, key=None, **fields):
    return client.post('/api/desktop/jobs', data={
        'request_id': key or uuid4().hex, 'username': 'demo', 'title': 'Mô tả tiếng Việt 🌸', **fields,
    }, files={'video': ('clip.mp4', b'fixture-video-bytes', 'video/mp4')})


def test_once_only_across_duplicate_and_concurrent_requests(client):
    key = uuid4().hex
    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(lambda _: post(client, key), range(2)))
    assert all(r.status_code == 200 for r in results)
    final = client.get(f'/api/desktop/jobs/{key}').json()
    assert final['status'] == 'pending'
    assert post(client, key).json()['schedule_id'] == final['schedule_id']
    with Session(db.engine) as s:
        assert len(s.exec(select(ScheduledUpload)).all()) == 1
        row = s.get(ScheduledUpload, final['schedule_id'])
        assert row.title == 'Mô tả tiếng Việt 🌸'
    assert len(list(settings.videos_dir().glob('*.mp4'))) == 1


def test_original_scheduler_success_and_uncertain_failure(client, monkeypatch):
    calls = []
    def fake(*args):
        calls.append(args)
        return UploadOutcome(ok=True, message='published', video_id='fixture')
    monkeypatch.setattr('api.services.tiktok_adapter.upload_from_options', fake)
    first = post(client).json()
    with Session(db.engine) as s:
        job = s.get(ScheduledUpload, first['schedule_id'])
        job.scheduled_for = db.now_utc() - timedelta(seconds=1)
        s.add(job); s.commit()
    assert worker.tick()
    assert client.get(f"/api/desktop/jobs/{first['request_id']}").json()['status'] == 'succeeded'
    assert len(calls) == 1
    second = post(client).json()
    monkeypatch.setattr('api.services.tiktok_adapter.upload_from_options', lambda *a: UploadOutcome(ok=False, message='ambiguous', uncertain=True))
    with Session(db.engine) as s:
        job = s.get(ScheduledUpload, second['schedule_id'])
        job.scheduled_for = db.now_utc() - timedelta(seconds=1)
        s.add(job); s.commit()
    assert worker.tick()
    result = client.get(f"/api/desktop/jobs/{second['request_id']}").json()
    assert result['status'] == 'failed' and result['publish_uncertain']
    assert not worker.tick()
    assert client.patch(f"/api/schedules/{second['schedule_id']}", json={'status': 'pending'}).status_code == 409


def test_schedule_options_cancel_and_deleted_receipt(client):
    when = db.now_utc() + timedelta(days=1)
    result = post(client, scheduled_for=when.isoformat(), options_json=json.dumps({'allow_comment': 0, 'ai_label': 1})).json()
    with Session(db.engine) as s:
        job = s.get(ScheduledUpload, result['schedule_id'])
        assert json.loads(job.options_json)['ai_label'] == 1
        # TikTok-side scheduling: the time travels in the options; the job itself is due now.
        assert abs((datetime.fromisoformat(json.loads(job.options_json)['tiktok_schedule_time']) - when).total_seconds()) < 0.001
    with Session(db.engine) as s:
        source_ref = s.get(ScheduledUpload, result['schedule_id']).source_ref
    assert client.delete(f'/api/videos/{source_ref}').status_code == 409
    assert client.patch(f"/api/schedules/{result['schedule_id']}", json={'status': 'cancelled'}).status_code == 200
    assert client.delete(f"/api/schedules/{result['schedule_id']}").status_code == 204
    repeated = post(client, result['request_id']).json()
    assert repeated['status'] == 'cancelled'  # durable outcome survives deletion; never recreate job


@pytest.mark.parametrize('fields', [
    {'username': 'missing'}, {'title': ''}, {'request_id': '../oops'},
    {'scheduled_for': '2020-01-01T00:00:00Z'}, {'options_json': '{broken'},
    {'scheduled_for': (db.now_utc()+timedelta(days=1)).isoformat(), 'options_json': '{"visibility_type":1}'},
])
def test_validation_does_not_create_job(client, fields):
    assert post(client, **fields).status_code in (404, 422)
    with Session(db.engine) as s:
        assert not s.exec(select(ScheduledUpload)).all()
        assert not s.exec(select(DesktopReceipt)).all()


def test_interrupted_reservation_never_requeues(client, monkeypatch):
    key = uuid4().hex
    def broken(*a, **kw):
        raise OSError('fixture disk failure')
    monkeypatch.setattr('api.routers.desktop.shutil.copyfileobj', broken)
    assert post(client, key).status_code == 500
    assert post(client, key).json()['status'] == 'preparation_failed'
    with Session(db.engine) as s:
        assert not s.exec(select(ScheduledUpload)).all()


def test_stream_ranges_and_private_file_denial(client, tmp_path):
    library = settings.videos_dir()
    (library/'sample.mp4').write_bytes(b'0123456789')
    (library/'.secret.mp4').write_bytes(b'private')
    (library/'settings.json').write_bytes(b'private')
    outside = tmp_path/'outside.mp4'; outside.write_bytes(b'private')
    (library/'escape.mp4').symlink_to(outside) if __import__('os').name != 'nt' else None
    r = client.get('/api/videos/sample.mp4/stream', headers={'Range': 'bytes=2-5'})
    assert r.status_code == 206 and r.content == b'2345'
    assert client.get('/api/videos/.secret.mp4/stream').status_code == 404
    assert client.get('/api/videos/settings.json/stream').status_code == 404
    assert client.get('/api/videos/%2e%2e%5coutside.mp4/stream').status_code == 404
    assert client.get('/api/videos/sample.mp4/stream', headers={'Range':'bytes=50-60'}).status_code == 416
