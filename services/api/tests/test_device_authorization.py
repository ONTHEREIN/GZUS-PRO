"""设备授权通过真实本地 HTTP 验证恢复、闲置清理和撤销。"""
import threading
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest
from fastapi import HTTPException
from fastapi.testclient import TestClient

from app.config import get_settings
from app.database import AppSessionModel, DeviceAuthorization, get_sync_session_factory
from app.device_authorization import issue_device_grant, require_device_grant
from app.main import create_app
from app.school_client import SchoolSdkClient
from app.school_session_service import record_authenticated_session
from app.sessions import SessionStore, credential_fingerprint, encrypt_sso_session_resume_token


@pytest.fixture
def school(monkeypatch):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, format, *args):
            pass

        def do_GET(self):
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b'<html><input id="col_xh" value="test-account"></html>')

    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    base = f'http://127.0.0.1:{server.server_port}/jwglxt'
    monkeypatch.setenv('JW_BASE_URL', base)
    get_settings.cache_clear()
    yield base
    server.shutdown()
    server.server_close()
    thread.join()


def setup_grant(base, account, installation, password):
    store = SessionStore(ttl_seconds=7200)
    client = SchoolSdkClient(base, timeout_seconds=2)
    client.login_with_cookies('JSESSIONID=local', account, validate=False)
    shared = record_authenticated_session(account, '测试', 'JSESSIONID=local', None, None, None)
    session = store.create(client, '测试', student_account=account, school_session_version=shared.version)
    token = issue_device_grant(session, installation, password, password is not None, 'password' if password else 'sso', None)
    return store, session, token


def test_idle_cleanup_keeps_device_and_shared_session_then_restores(school):
    store, session, token = setup_grant(school, 'test-account', 'installation-one-0001', None)
    with get_sync_session_factory()() as db:
        db.get(AppSessionModel, session.id).last_active_at = datetime.now(timezone.utc) - timedelta(hours=3)
        db.commit()
    store._purge_expired()
    assert store.get(session.id) is None
    app = create_app()
    app.state.sessions = store
    client = TestClient(app)
    response = client.post('/auth/device/restore', json={'deviceToken': token, 'installationId': 'installation-one-0001'})
    assert response.status_code == 200, response.text
    assert response.json()['studentId'] == 'test-account'
    assert response.json().get('credentialToken') is None
    assert response.json()['sessionId'] != session.id
    with get_sync_session_factory()() as db:
        row = db.get(DeviceAuthorization, credential_fingerprint(token))
        assert row is not None and row.token_digest != token


def test_device_logout_revokes_only_current_device(school):
    store, session, token = setup_grant(school, 'test-account', 'installation-one-0001', 'test-password')
    _, other_session, other = setup_grant(school, 'test-account', 'installation-two-0002', 'test-password')
    app = create_app()
    app.state.sessions = store
    client = TestClient(app)
    response = client.post('/auth/logout', json={'deviceToken': token}, headers={'X-Session-Id': session.id})
    assert response.status_code == 200, response.text
    assert client.post('/auth/device/restore', json={'deviceToken': token, 'installationId': 'installation-one-0001'}).status_code == 401
    assert require_device_grant(other, 'installation-two-0002').account == 'test-account'
    with get_sync_session_factory()() as db:
        assert db.get(DeviceAuthorization, credential_fingerprint(token)).encrypted_credentials is None
        assert db.get(AppSessionModel, other_session.id).revoked_at is None


def test_password_change_requires_other_devices_to_verify(school):
    _, _, old = setup_grant(school, 'test-account', 'installation-one-0001', 'old-password')
    _, _, current = setup_grant(school, 'test-account', 'installation-two-0002', 'new-password')
    with pytest.raises(HTTPException) as error:
        require_device_grant(old, 'installation-one-0001')
    assert error.value.status_code == 401
    assert require_device_grant(current, 'installation-two-0002').account == 'test-account'


def test_device_token_cannot_be_used_by_another_installation(school):
    _, _, token = setup_grant(school, 'test-account', 'installation-one-0001', None)
    with pytest.raises(HTTPException) as error:
        require_device_grant(token, 'installation-two-0002')
    assert error.value.status_code == 401


def test_migration_revokes_legacy_token_and_cannot_revive_it(school):
    store, session, _ = setup_grant(school, 'test-account', 'installation-one-0001', None)
    legacy_id = 'legacy-test-id'
    digest = credential_fingerprint(legacy_id)
    with get_sync_session_factory()() as db:
        db.get(AppSessionModel, session.id).credential_fingerprint = digest
        db.commit()
    legacy = encrypt_sso_session_resume_token('test-account', legacy_id, get_settings().credential_encryption_key)
    app = create_app()
    app.state.sessions = store
    client = TestClient(app)
    payload = {'credentialToken': legacy, 'installationId': 'installation-migrate-01', 'storeSchoolPassword': False}
    response = client.post('/auth/device/migrate', json=payload)
    assert response.status_code == 200, response.text
    assert require_device_grant(response.json()['deviceToken'], payload['installationId']).account == 'test-account'
    assert store.is_credential_revoked(digest)
    assert client.post('/auth/device/migrate', json=payload).status_code == 401


def test_sso_school_reauthentication_preserves_device_grant(school):
    from app.school_session_service import mark_school_session_invalid
    store, _, token = setup_grant(school, 'test-account', 'installation-one-0001', None)
    mark_school_session_invalid('test-account')
    app = create_app()
    app.state.sessions = store
    response = TestClient(app).post('/auth/device/restore', json={
        'deviceToken': token, 'installationId': 'installation-one-0001',
    })
    assert response.status_code == 428
    assert require_device_grant(token, 'installation-one-0001').account == 'test-account'


def test_concurrent_restores_remain_on_same_account(school):
    from concurrent.futures import ThreadPoolExecutor
    store, _, token = setup_grant(school, 'test-account', 'installation-one-0001', None)
    app = create_app()
    app.state.sessions = store
    client = TestClient(app)

    def restore():
        return client.post('/auth/device/restore', json={
            'deviceToken': token, 'installationId': 'installation-one-0001',
        })

    with ThreadPoolExecutor(max_workers=4) as executor:
        responses = list(executor.map(lambda _: restore(), range(4)))
    assert all(response.status_code == 200 for response in responses)
    assert {response.json()['studentId'] for response in responses} == {'test-account'}
    with get_sync_session_factory()() as db:
        row = db.get(DeviceAuthorization, credential_fingerprint(token))
        assert row.session_id in {response.json()['sessionId'] for response in responses}


def test_changed_password_login_does_not_revoke_newly_created_session(school):
    _, _, old = setup_grant(school, 'test-account', 'installation-old-0001', 'old-password')
    store = SessionStore(ttl_seconds=7200)
    client = SchoolSdkClient(school, timeout_seconds=2)
    client.login_with_cookies('JSESSIONID=local', 'test-account', validate=False)
    fingerprint = credential_fingerprint('new-login-credential')
    session = store.create(client, '测试', student_account='test-account', credential_fingerprint=fingerprint)
    token = issue_device_grant(session, 'installation-new-0002', 'new-password', True, 'password', None)
    assert require_device_grant(token, 'installation-new-0002').account == 'test-account'
    with get_sync_session_factory()() as db:
        assert db.get(AppSessionModel, session.id).revoked_at is None
    with pytest.raises(HTTPException):
        require_device_grant(old, 'installation-old-0001')


@pytest.mark.asyncio
async def test_logout_waiting_for_account_lock_does_not_block_health(school):
    import asyncio
    import httpx
    from app.school_session_service import account_school_session_lock

    store, session, token = setup_grant(school, 'test-account', 'installation-one-0001', None)
    app = create_app()
    app.state.sessions = store
    locked = threading.Event()
    release = threading.Event()

    def hold_account_lock():
        with account_school_session_lock('test-account'):
            locked.set()
            assert release.wait(5)

    thread = threading.Thread(target=hold_account_lock)
    thread.start()
    assert locked.wait(1)
    try:
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url='http://test') as client:
            logout = asyncio.create_task(client.post('/auth/logout',
                json={'deviceToken': token}, headers={'X-Session-Id': session.id}))
            await asyncio.sleep(0.05)
            response = await asyncio.wait_for(client.get('/health'), timeout=1)
            assert response.status_code == 200
            assert not logout.done()
            release.set()
            assert (await logout).status_code == 200
    finally:
        release.set()
        thread.join()
