"""设备持久授权：随机 bearer token、摘要校验和服务端密码加密。"""
from dataclasses import dataclass
from datetime import datetime, timezone
from secrets import token_urlsafe

from cryptography.fernet import InvalidToken
from fastapi import HTTPException
from sqlalchemy.orm import Session as DbSession

from app.config import get_settings
from app.database import (
    AppSessionModel, BackgroundNotificationProfile, CredentialRevocation,
    DeviceAuthorization, IosLiveActivityToken, IosPushToken, WebPushSubscription,
    get_sync_session_factory,
)
from app.sessions import (
    AppSession, SessionStore, credential_fingerprint, decrypt_credentials, encrypt_credentials,
    remove_push_registrations_for_credential,
)


@dataclass(frozen=True)
class DeviceGrant:
    digest: str
    account: str
    installation_id: str
    login_method: str
    encrypted_credentials: str | None
    session_id: str | None


def require_device_grant(token: str, installation_id: str) -> DeviceGrant:
    digest = credential_fingerprint(token)
    with get_sync_session_factory()() as db:
        row = db.get(DeviceAuthorization, digest)
        if (row is None or row.revoked_at is not None
                or row.installation_id != installation_id
                or db.get(CredentialRevocation, digest) is not None):
            raise HTTPException(401, detail={"code": "device_authorization_invalid",
                                             "message": "设备登录授权无效或已撤销，请重新登录"})
        return DeviceGrant(digest, row.student_account, row.installation_id,
                           row.login_method, row.encrypted_credentials, row.session_id)


def decrypt_device_password(ciphertext: str) -> tuple[str, str]:
    try:
        return decrypt_credentials(ciphertext, get_settings().credential_encryption_key)
    except (InvalidToken, ValueError, UnicodeError) as exc:
        raise HTTPException(503, detail={"code": "device_credential_unreadable",
            "message": "设备授权密文无法读取，请联系管理员检查服务端加密密钥"}) from exc


def _revoke_row(db: DbSession, row: DeviceAuthorization, reason: str) -> None:
    now = datetime.now(timezone.utc)
    row.revoked_at = now
    row.revoked_reason = reason
    row.encrypted_credentials = None
    if db.get(CredentialRevocation, row.token_digest) is None:
        db.add(CredentialRevocation(credential_fingerprint=row.token_digest, reason=reason))
    db.query(AppSessionModel).filter(
        AppSessionModel.credential_fingerprint == row.token_digest,
    ).update({"revoked_at": now, "revoked_reason": reason}, synchronize_session=False)
    db.query(BackgroundNotificationProfile).filter(
        BackgroundNotificationProfile.credential_fingerprint == row.token_digest,
    ).delete(synchronize_session=False)
    remove_push_registrations_for_credential(db, row.token_digest)


def issue_device_grant(
    session: AppSession, installation_id: str, password: str | None,
    store_school_password: bool, login_method: str, old_fingerprint: str | None,
) -> str:
    """认证成功后绑定授权；迁移与旧授权撤销在同一事务中提交。"""
    source_fingerprint = old_fingerprint or session.credential_fingerprint
    account = session.student_account
    if not account:
        raise ValueError("设备授权缺少已验证账号")
    token = token_urlsafe(48)
    digest = credential_fingerprint(token)
    now = datetime.now(timezone.utc)
    key = get_settings().credential_encryption_key
    encrypted = encrypt_credentials(account, password, key) if password and store_school_password else None
    with get_sync_session_factory()() as db:
        if source_fingerprint and db.get(CredentialRevocation, source_fingerprint) is not None:
            raise HTTPException(401, detail="原设备凭据已撤销，不能迁移")
        existing = db.query(DeviceAuthorization).filter(
            DeviceAuthorization.student_account == account,
            DeviceAuthorization.revoked_at.is_(None),
        ).all()
        password_changed = password is not None and any(
            row.encrypted_credentials and
            decrypt_device_password(row.encrypted_credentials)[1] != password
            for row in existing
        )
        for row in existing:
            if row.token_digest == source_fingerprint:
                continue
            if row.installation_id == installation_id:
                _revoke_row(db, row, "device_reauthorized")
            elif password_changed:
                _revoke_row(db, row, "school_password_changed")
        db.add(DeviceAuthorization(
            token_digest=digest, student_account=account, installation_id=installation_id,
            login_method=login_method, store_school_password=store_school_password,
            encrypted_credentials=encrypted, session_id=session.id,
            created_at=now, last_used_at=now,
        ))
        row = db.get(AppSessionModel, session.id)
        if row is None or row.revoked_at is not None:
            raise HTTPException(401, detail="待绑定会话已失效")
        row.credential_fingerprint = digest
        if source_fingerprint:
            legacy_row = db.get(DeviceAuthorization, source_fingerprint)
            if legacy_row is not None:
                legacy_row.revoked_at = now
                legacy_row.revoked_reason = "device_migrated"
                legacy_row.encrypted_credentials = None
            for model in (WebPushSubscription, IosPushToken, IosLiveActivityToken):
                db.query(model).filter(model.credential_fingerprint == source_fingerprint).update(
                    {"credential_fingerprint": digest, "session_id": session.id},
                    synchronize_session=False,
                )
            db.query(BackgroundNotificationProfile).filter(
                BackgroundNotificationProfile.credential_fingerprint == source_fingerprint,
            ).update({"credential_fingerprint": digest}, synchronize_session=False)
            db.query(AppSessionModel).filter(
                AppSessionModel.credential_fingerprint == source_fingerprint,
                AppSessionModel.id != session.id,
            ).update({"revoked_at": now, "revoked_reason": "device_migrated"}, synchronize_session=False)
            db.add(CredentialRevocation(credential_fingerprint=source_fingerprint, reason="device_migrated"))
        db.commit()
    session.credential_fingerprint = digest
    return token


def update_device_session(grant: DeviceGrant, session: AppSession) -> None:
    with get_sync_session_factory()() as db:
        row = db.get(DeviceAuthorization, grant.digest)
        if row is None or row.revoked_at is not None or db.get(CredentialRevocation, grant.digest):
            raise HTTPException(401, detail="设备授权在恢复期间已撤销")
        row.session_id = session.id
        row.last_used_at = datetime.now(timezone.utc)
        for model in (WebPushSubscription, IosPushToken, IosLiveActivityToken):
            db.query(model).filter(model.credential_fingerprint == grant.digest).update(
                {"session_id": session.id}, synchronize_session=False,
            )
        db.commit()


def revoke_device_grant(token: str, sessions: SessionStore, session_id: str) -> tuple[str, str]:
    digest = credential_fingerprint(token)
    with get_sync_session_factory()() as db:
        row = db.get(DeviceAuthorization, digest)
        if row is None:
            raise HTTPException(401, detail="设备授权不存在")
        account = row.student_account
        current = db.get(AppSessionModel, session_id) if session_id else None
        if current is not None and current.credential_fingerprint != digest:
            raise HTTPException(403, detail="退出凭据与当前会话不属于同一设备")
        _revoke_row(db, row, "logout")
        db.commit()
    sessions.remove(session_id, digest, account)
    return digest, account
