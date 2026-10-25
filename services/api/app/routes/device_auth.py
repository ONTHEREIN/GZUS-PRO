"""长期设备授权恢复与显式迁移，兼容旧客户端。"""
import logging

import httpx
from requests.exceptions import RequestException
from cryptography.fernet import InvalidToken
from fastapi import APIRouter, HTTPException, Request

from app.config import get_settings
from app.database import get_sync_session_factory
from app.device_authorization import DeviceGrant, decrypt_device_password, issue_device_grant, require_device_grant, update_device_session
from app.schemas import AuthResponse, DeviceMigrateRequest, DeviceRestoreRequest, ReloginRequest
from app.school_client import AuthenticationError
from app.school_session_service import (
    SchoolSessionUnavailableError, account_school_session_lock, load_shared_school_clients,
    mark_school_session_invalid,
)
from app.sessions import AppSession, credential_fingerprint, decrypt_credential_payload, decrypt_sso_session_resume_token

router = APIRouter(prefix="/device", tags=["auth"])
logger = logging.getLogger(__name__)


@router.post('/restore', response_model=AuthResponse)
def restore_device(payload: DeviceRestoreRequest, request: Request) -> dict:
    grant = require_device_grant(payload.device_token, payload.installation_id)
    with account_school_session_lock(grant.account):
        grant = require_device_grant(payload.device_token, payload.installation_id)
        sessions = request.app.state.sessions
        try:
            client, ehall, shared = load_shared_school_clients(grant.account)
            client.validate_session()
        except (AuthenticationError, SchoolSessionUnavailableError):
            mark_school_session_invalid(grant.account)
            if not grant.encrypted_credentials:
                raise HTTPException(428, detail={"code": "school_reauthentication_required",
                    "message": "学校会话失效，请重新完成统一认证"})
            session = _password_session(grant, request)
        except (httpx.HTTPError, RequestException, RuntimeError) as exc:
            raise HTTPException(502, detail="学校会话验证暂时失败，请重试") from exc
        else:
            session = sessions.create(client, shared.student_name, ehall_client=ehall,
                student_account=grant.account, credential_fingerprint=grant.digest,
                school_session_version=shared.version)
        require_device_grant(payload.device_token, payload.installation_id)
        update_device_session(grant, session)
        logger.info('device_restore_completed', extra={'login_method': grant.login_method, 'trace_id': getattr(request.state, 'trace_id', None)})
        return {'status': 'ok', 'sessionId': session.id, 'studentId': grant.account,
                'studentName': session.student_name,
                'ehallError': None if session.ehall_client else '办事大厅暂时不可用，请单独重试'}


@router.post('/migrate', response_model=AuthResponse)
def migrate_device(payload: DeviceMigrateRequest, request: Request) -> dict:
    from app.routes.auth import relogin, session_relogin

    if payload.installation_id is None or payload.store_school_password is None:
        raise HTTPException(422, detail="迁移必须明确提交安装标识和密码保管授权")
    key = get_settings().credential_encryption_key
    try:
        account, credential_id = decrypt_sso_session_resume_token(payload.credential_token, key)
        password = None
        method = 'sso'
    except (ValueError, InvalidToken):
        try:
            account, password, credential_id = decrypt_credential_payload(payload.credential_token, key)
        except (ValueError, InvalidToken) as exc:
            raise HTTPException(401, detail="原凭据无效，不能迁移") from exc
        method = 'password'
    if credential_id is None:
        raise HTTPException(428, detail="旧凭据无法验证撤销状态，请重新登录")
    fingerprint = credential_fingerprint(credential_id)
    with account_school_session_lock(account):
        if request.app.state.sessions.is_credential_revoked(fingerprint):
            raise HTTPException(401, detail="原凭据已撤销，不能迁移")
        legacy = ReloginRequest(credentialToken=payload.credential_token)
        result = relogin(legacy, request) if method == 'password' else session_relogin(legacy, request)
        session = request.app.state.sessions.get(result['sessionId'])
        if session is None:
            raise HTTPException(503, detail="迁移生成的应用会话无法读取")
        token = issue_device_grant(session, payload.installation_id, password,
                                  payload.store_school_password, method, fingerprint)
        return {'status': 'ok', 'sessionId': session.id, 'studentId': account,
                'studentName': session.student_name, 'deviceToken': token}


def _password_session(grant: DeviceGrant, request: Request) -> AppSession:
    from app.routes.auth import _auto_login_impl
    from app.schemas import AutoLoginRequest
    sessions = request.app.state.sessions
    if grant.encrypted_credentials is None:
        raise HTTPException(428, detail="未授权密码保管，请重新完成学校认证")
    account, password = decrypt_device_password(grant.encrypted_credentials)
    try:
        result = _auto_login_impl(AutoLoginRequest(account=account, password=password), request)
    except HTTPException as exc:
        if exc.status_code == 401:
            # 校方否定学校密码不代表设备 bearer token 已撤销。
            raise HTTPException(428, detail={"code": "school_reauthentication_required",
                "message": "学校密码已失效，请重新验证当前设备"}) from exc
        raise
    session = sessions.get(result['sessionId'])
    if session is None:
        raise HTTPException(503, detail="恢复生成的应用会话无法读取")
    # 旧实现仅用于学校连接，不向新客户端返回密码载荷。
    with get_sync_session_factory()() as db:
        from app.database import AppSessionModel
        row = db.get(AppSessionModel, session.id)
        from app.database import DeviceAuthorization, CredentialRevocation
        previous = row.credential_fingerprint
        if previous != grant.digest:
            legacy = db.get(DeviceAuthorization, previous)
            if legacy is not None:
                db.delete(legacy)
            db.add(CredentialRevocation(credential_fingerprint=previous, reason="internal_restore"))
        row.credential_fingerprint = grant.digest
        db.commit()
    session.credential_fingerprint = grant.digest
    return session


@router.post('/ehall-retry', response_model=AuthResponse)
def retry_ehall(payload: DeviceRestoreRequest, request: Request) -> dict:
    grant = require_device_grant(payload.device_token, payload.installation_id)
    with account_school_session_lock(grant.account):
        grant = require_device_grant(payload.device_token, payload.installation_id)
        if not grant.encrypted_credentials:
            raise HTTPException(428, detail="办事大厅需要重新完成统一认证，设备授权仍保留")
        session = _password_session(grant, request)
        require_device_grant(payload.device_token, payload.installation_id)
        update_device_session(grant, session)
        return {'status': 'ok', 'sessionId': session.id, 'studentId': grant.account,
                'studentName': session.student_name,
                'ehallError': None if session.ehall_client else '办事大厅仍不可用，请稍后重试'}
