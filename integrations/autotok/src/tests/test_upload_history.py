"""History is independent of UI marks, deleted jobs and process restarts."""
import hashlib
from datetime import timedelta, timezone
from uuid import uuid4
import pytest
from fastapi.testclient import TestClient
from sqlmodel import Session, select
import api.db as db
from api.main import create_app
from api.models import Account, ScheduledUpload, UploadHistory
from api.services.tiktok_adapter import UploadOutcome
from scheduler import worker
from api.services.history import track_schedule


@pytest.fixture
def client(tmp_path, monkeypatch):
    old=db.engine
    engine=db.make_engine(f"sqlite:///{tmp_path/'history.db'}")
    db.override_engine(engine);db.init_db()
    with Session(engine) as s:
        s.add(Account(username='demo',cookie_path=str(tmp_path/'absent'),has_valid_session=True));s.commit()
    monkeypatch.setattr('api.services.tiktok_adapter.upload_from_options',lambda *a:UploadOutcome(ok=True,message='fixture',video_id='storage-fixture'))
    with TestClient(create_app(),base_url='http://localhost',headers={'X-Requested-With':'autotok'}) as c:yield c
    db.override_engine(old);engine.dispose()


def submit(client, data=b'fixture-content', key=None, reel_id='123456', scheduled_for=''):
    return client.post('/api/desktop/jobs',data={'username':'demo','title':'Mô tả Unicode 🌸','request_id':key or uuid4().hex,'reel_id':reel_id,'scheduled_for':scheduled_for},files={'video':('video.mp4',data,'video/mp4')}).json()


def due(job_id):
    with Session(db.engine) as s:
        row=s.get(ScheduledUpload,job_id);row.scheduled_for=db.now_utc()-timedelta(seconds=1);s.add(row);s.commit()


def lookup(client, **identity):
    r=client.post('/api/history/lookup',json={'videos':[identity]});assert r.status_code==200,r.text
    return r.json()[0]['entries']


def test_success_has_real_ack_time_and_survives_deletion_and_id_reuse(client):
    first=submit(client);due(first['schedule_id']);before=db.now_utc();assert worker.tick();after=db.now_utc()
    entries=lookup(client,reel_id='123456');assert len(entries)==1
    entry=entries[0]
    from datetime import datetime
    accepted=datetime.fromisoformat(entry['accepted_at'])
    assert before <= accepted <= after
    assert entry['username']=='demo' and entry['time_source']=='acknowledgement'
    assert entry['media_video_id']=='storage-fixture'
    assert client.delete(f"/api/schedules/{first['schedule_id']}").status_code==204
    second=submit(client,b'new-content',reel_id='999999')
    # SQLite may reuse ID=1. An old receipt must still refer to its own successful post.
    old=client.get('/api/desktop/jobs/'+first['request_id']).json()
    assert old['status']=='succeeded' and datetime.fromisoformat(old['accepted_at'])==accepted
    assert lookup(client,reel_id='123456')[0]['accepted_at']==entry['accepted_at']
    assert len(lookup(client,reel_id='999999'))==1
    assert second['request_id'] != first['request_id']


def test_content_hash_finds_renamed_video_and_web_direct_upload(client):
    blob=b'identical video bytes'
    r=client.post('/api/uploads/file',data={'username':'demo','title':'test'},files={'video':('old-name.mp4',blob,'video/mp4')})
    assert r.status_code==200 and r.json()['ok']
    entries=lookup(client,reel_id='different-source-id',sha256=hashlib.sha256(blob).hexdigest())
    assert len(entries)==1 and entries[0]['status']=='succeeded'
    assert not lookup(client,sha256=hashlib.sha256(b'different').hexdigest())


def test_request_mapping_recovers_legacy_native_receipt(client):
    result=submit(client,reel_id='')
    entries=lookup(client,reel_id='old-reel-id',request_ids=[result['request_id']])
    assert len(entries)==1 and entries[0]['request_id']==result['request_id']


def test_schedule_retains_original_plan_across_retry_and_cancel(client, monkeypatch):
    plan=db.now_utc()+timedelta(days=1)
    result=submit(client,scheduled_for=plan.isoformat());due(result['schedule_id'])
    monkeypatch.setattr('api.services.tiktok_adapter.upload_from_options',lambda *a:UploadOutcome(ok=False,message='fixture before publish',retryable=True))
    assert worker.tick()
    entries=lookup(client,reel_id='123456')
    from datetime import datetime
    assert datetime.fromisoformat(entries[0]['planned_for'])==plan
    assert entries[0]['accepted_at'] is None and entries[0]['status']=='pending'
    assert client.patch(f"/api/schedules/{result['schedule_id']}",json={'status':'cancelled'}).status_code==200
    assert client.delete(f"/api/schedules/{result['schedule_id']}").status_code==204
    assert lookup(client,reel_id='123456')[0]['status']=='cancelled'


def test_failed_uncertain_never_marks_success(client, monkeypatch):
    result=submit(client);due(result['schedule_id'])
    monkeypatch.setattr('api.services.tiktok_adapter.upload_from_options',lambda *a:UploadOutcome(ok=False,message='unknown',uncertain=True))
    assert worker.tick()
    entry=lookup(client,reel_id='123456')[0]
    assert entry['publish_uncertain'] and entry['accepted_at'] is None and entry['status']=='failed'


def test_api_datetimes_always_have_utc_offset(client):
    result=submit(client)
    job=client.get(f"/api/schedules/{result['schedule_id']}").json()
    assert job['scheduled_for'].endswith(('Z','+00:00'))
    assert job['created_at'].endswith(('Z','+00:00'))


def test_account_deletion_does_not_delete_post_history(client, monkeypatch):
    result=submit(client);due(result['schedule_id']);assert worker.tick()
    monkeypatch.setattr('api.services.account_store.delete',lambda *a:None)
    with Session(db.engine) as s:account=s.exec(select(Account)).one()
    assert client.delete('/api/accounts/'+str(account.id)).status_code==204
    entry=lookup(client,reel_id='123456')[0]
    assert entry['status']=='succeeded' and entry['username']=='demo'


def test_preparing_submission_is_visible_before_scheduler_job_exists(client, monkeypatch):
    from concurrent.futures import ThreadPoolExecutor
    from threading import Event
    import shutil
    started,release=Event(),Event()
    original=shutil.copyfileobj
    def slow_copy(*args,**kwargs):
        started.set()
        assert release.wait(5)
        return original(*args,**kwargs)
    monkeypatch.setattr('api.routers.desktop.shutil.copyfileobj',slow_copy)
    with ThreadPoolExecutor(max_workers=1) as pool:
        future=pool.submit(submit,client)
        try:
            assert started.wait(5)
            entries=lookup(client,reel_id='123456')
            assert len(entries)==1 and entries[0]['status']=='preparing'
            assert entries[0]['username']=='demo' and entries[0]['accepted_at'] is None
        finally:release.set()
        result=future.result()
    entries=lookup(client,reel_id='123456')
    assert len(entries)==1 and entries[0]['status']=='pending'
    assert entries[0]['request_id']==result['request_id']


def test_schedules_api_exposes_prior_uncertain_from_history(client, monkeypatch):
    clean = submit(client)['schedule_id']
    flagged = submit(client)['schedule_id']
    with Session(db.engine) as s:
        job = s.get(ScheduledUpload, flagged)
        entry = s.get(UploadHistory, f"schedule:{flagged}:{job.created_at.replace(tzinfo=None).isoformat(timespec='microseconds')}")
        entry.prior_uncertain = True
        s.add(entry);s.commit()
    listed = {r['id']: r['prior_uncertain'] for r in client.get('/api/schedules').json()}
    assert listed == {clean: False, flagged: True}
    assert client.get(f'/api/schedules/{flagged}').json()['prior_uncertain'] is True
    assert client.get(f'/api/schedules/{clean}').json()['prior_uncertain'] is False


def test_patch_after_confirmed_retry_reports_prior_uncertain(client):
    sid = submit(client)['schedule_id']
    with Session(db.engine) as s:
        row = s.get(ScheduledUpload, sid)
        row.status = 'failed';row.publish_uncertain = True;s.add(row)
        track_schedule(s, row);s.commit()  # as the worker does when it records an uncertain failure
    r = client.patch(f'/api/schedules/{sid}', json={'status': 'pending', 'confirm_uncertain': True})
    assert r.status_code == 200, r.text
    body = r.json()
    assert body['publish_uncertain'] is False and body['prior_uncertain'] is True
    assert client.get(f'/api/schedules/{sid}').json()['prior_uncertain'] is True
