"""账号级学校会话复用与校方设备数限制处理。"""
from __future__ import annotations

import hashlib
import logging
import threading
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Iterator
from urllib.parse import quote

from sqlalchemy import or_
from sqlalchemy.orm import Session

from app.config import get_settings
from app.database import (
    AppSessionModel,
    BackgroundNotificationProfile,
    CredentialRevocation,
    DeviceAuthorization,
    IosLiveActivityToken,
    IosPushToken,
    SchoolAccountSession,
    WebPushSubscription,
    WechatBinding,
    get_sync_session_factory,
)
from app.ehall_client import EhallClient
from app.sessions import (
    _get_fernet,
    _rebuild_ehall_client,
    _rebuild_school_client,
    decrypt_credentials,
)
from app.school_client import AuthenticationError, SchoolSdkClient

logger = logging.getLogger(__name__)

_SUSPENSION_RETRY_INTERVAL = timedelta(hours=1)
_WECHAT_SCHOOL_SESSION_RETENTION = timedelta(days=30)
_account_locks: dict[str, threading.RLock] = {}
_account_locks_guard = threading.Lock()


class SchoolSessionLimitError(RuntimeError):
    """校方确认拒绝了新的设备/会话，因为已达到账号上限。"""

    def __init__(self, account: str, reason: str) -> None:
        self.account = account
        self.reason = reason
        super().__init__(reason)


class BackgroundAuthorizationRevokedError(RuntimeError):
    """后台授权已被删除或替换，旧轮询不能继续使用学校凭据。"""


class SchoolSessionSuspendedError(RuntimeError):
    """账号目前处于校方设备数限制的自动暂停窗口。"""

    def __init__(self, account: str, next_retry_at: datetime | None, reason: str | None) -> None:
        self.account = account
        self.next_retry_at = next_retry_at
        self.reason = reason or "校方设备或会话数达到上限"
        super().__init__(self.reason)


class SchoolSessionUnavailableError(RuntimeError):
    """账号没有可复用的学校会话。"""


@dataclass(frozen=True)
class SchoolAccountSessionSnapshot:
    student_id: str
    student_name: str | None
    version: int
    last_used_at: datetime
    expires_at: datetime | None
    suspended_at: datetime | None
    suspension_reason: str | None
    next_retry_at: datetime | None
    limit_notified_at: datetime | None


def _utc_now() -> datetime:
    return datetime.now(timezone.utc)


def _account_hash(account: str) -> str:
    return hashlib.sha256(account.encode("utf-8")).hexdigest()[:12]


def _aware(value: datetime | None) -> datetime | None:
    if value is None:
        return None
    return value.replace(tzinfo=timezone.utc) if value.tzinfo is None else value


def _encrypt_secret(value: str | None) -> str | None:
    if not value:
        return None
    key = get_settings().credential_encryption_key
    if not key:
        raise RuntimeError("CREDENTIAL_ENCRYPTION_KEY 未配置，无法保存学校会话")
    return _get_fernet(key).encrypt(value.encode("utf-8")).decode("ascii")


def _decrypt_secret(value: str | None) -> str | None:
    if not value:
        return None
    key = get_settings().credential_encryption_key
    if not key:
        raise RuntimeError("CREDENTIAL_ENCRYPTION_KEY 未配置，无法读取学校会话")
    return _get_fernet(key).decrypt(value.encode("ascii")).decode("utf-8")


def _snapshot(row: SchoolAccountSession) -> SchoolAccountSessionSnapshot:
    return SchoolAccountSessionSnapshot(
        student_id=row.student_id,
        student_name=row.student_name,
        version=int(row.version or 1),
        last_used_at=_aware(row.last_used_at) or _utc_now(),
        expires_at=_aware(row.expires_at),
        suspended_at=_aware(row.suspended_at),
        suspension_reason=row.suspension_reason,
        next_retry_at=_aware(row.next_retry_at),
        limit_notified_at=_aware(row.limit_notified_at),
    )


def get_school_account_session(student_id: str) -> SchoolAccountSessionSnapshot | None:
    account = student_id.strip()
    if not account:
        return None
    with get_sync_session_factory()() as db:
        row = db.query(SchoolAccountSession).filter_by(student_id=account).first()
        return _snapshot(row) if row is not None else None


def record_authenticated_session(
    student_id: str,
    student_name: str | None,
    jwxt_cookies: str,
    ehall_cookies: str | None,
    ehall_auth_token: str | None,
    expires_at: datetime | None,
) -> SchoolAccountSessionSnapshot:
    """写入一次成功的人工/后台登录，并递增账号共享会话版本。"""
    account = student_id.strip()
    if not account or not jwxt_cookies.strip():
        raise ValueError("学校会话缺少学号或 JWXT cookie")
    now = _utc_now()
    # 学校 Cookie 的有效期由校方决定；服务端只在明确失效后标记 expires_at，
    # 不人为设置固定 TTL，避免后台轮询无故制造新的 CAS 会话。
    expires = _aware(expires_at)
    with get_sync_session_factory()() as db:
        row = db.query(SchoolAccountSession).filter_by(student_id=account).first()
        if row is None:
            row = SchoolAccountSession(student_id=account, version=1)
            db.add(row)
        else:
            row.version = int(row.version or 0) + 1
        row.student_name = student_name or row.student_name
        row.jwxt_cookies = _encrypt_secret(jwxt_cookies)
        row.ehall_cookies = _encrypt_secret(ehall_cookies)
        row.ehall_auth_token = _encrypt_secret(ehall_auth_token)
        row.last_used_at = now
        row.authenticated_at = now
        row.expires_at = expires
        row.suspended_at = None
        row.suspension_reason = None
        row.next_retry_at = None
        row.limit_notified_at = None
        row.updated_at = now
        profile = db.query(BackgroundNotificationProfile).filter_by(student_id=account).first()
        if profile is not None:
            profile.suspended_at = None
            profile.suspension_reason = None
            profile.next_retry_at = None
            profile.limit_notified_at = None
            profile.last_error = None
            profile.updated_at = now
        db.commit()
        db.refresh(row)
        logger.info(
            "school_account_session_recorded",
            extra={"account_hash": _account_hash(account), "version": row.version},
        )
        return _snapshot(row)


def _build_clients(snapshot: SchoolAccountSession, student_id: str) -> tuple[SchoolSdkClient, EhallClient | None]:
    try:
        jwxt_cookies = _decrypt_secret(snapshot.jwxt_cookies)
        ehall_cookies = _decrypt_secret(snapshot.ehall_cookies)
        ehall_auth_token = _decrypt_secret(snapshot.ehall_auth_token)
    except Exception as exc:
        raise SchoolSessionUnavailableError("共享学校会话密文无法解密") from exc
    if not jwxt_cookies:
        raise SchoolSessionUnavailableError("共享学校会话没有 JWXT cookie")
    try:
        client = _rebuild_school_client(jwxt_cookies, account=student_id)
    except Exception as exc:
        raise AuthenticationError("共享教务系统会话已失效") from exc
    try:
        ehall_client = (
            _rebuild_ehall_client(ehall_cookies, ehall_auth_token)
            if ehall_cookies or ehall_auth_token
            else None
        )
    except Exception as exc:
        raise SchoolSessionUnavailableError("共享一站式服务会话初始化失败") from exc
    return client, ehall_client


def load_shared_school_clients(
    student_id: str,
) -> tuple[SchoolSdkClient, EhallClient | None, SchoolAccountSessionSnapshot]:
    account = student_id.strip()
    with get_sync_session_factory()() as db:
        row = db.query(SchoolAccountSession).filter_by(student_id=account).first()
        if row is None:
            raise SchoolSessionUnavailableError("尚未建立共享学校会话")
        snapshot = _snapshot(row)
        now = _utc_now()
        if snapshot.expires_at is not None and snapshot.expires_at <= now:
            raise SchoolSessionUnavailableError("共享学校会话已过期")
        if not _within_wechat_retention(row, now) and not _has_school_authorization(db, account, now):
            raise SchoolSessionUnavailableError("学校认证已超过微信恢复保留期，请重新认证")
        client, ehall_client = _build_clients(row, account)
        row.last_used_at = now
        row.updated_at = now
        db.commit()
        return client, ehall_client, snapshot


def mark_school_session_invalid(student_id: str) -> None:
    account = student_id.strip()
    if not account:
        return
    with get_sync_session_factory()() as db:
        row = db.query(SchoolAccountSession).filter_by(student_id=account).first()
        if row is not None:
            row.expires_at = _utc_now()
            row.updated_at = _utc_now()
            db.commit()


def _lock_key(account: str) -> int:
    return int.from_bytes(hashlib.sha256(account.encode("utf-8")).digest()[:8], "big", signed=True)


@contextmanager
def account_school_session_lock(student_id: str) -> Iterator[None]:
    """生产单 worker 内按账号串行；网络调用不占用数据库连接。"""
    account = student_id.strip()
    with _account_locks_guard:
        lock = _account_locks.setdefault(account, threading.RLock())
    with lock:
        yield


def _cas_login(account: str, password: str) -> tuple[str, str, str | None, str | None]:
    from app.cas_auto_login import CasAutoLogin, is_school_session_limit_error

    settings = get_settings()
    cas = CasAutoLogin(
        cas_url=f"{settings.cas_login_url}?service={quote(settings.jwxt_sso_service_url, safe='')}",
        ehall_url=settings.ehall_base_url,
        ehall_service_url=settings.ehall_service_url,
        timeout=settings.cas_login_timeout_seconds,
    )
    result = cas.auto_login(account, password)
    try:
        if result.error:
            if is_school_session_limit_error(result.error, result.error_code):
                raise SchoolSessionLimitError(account, "校方设备或会话数达到上限")
            raise RuntimeError(f"学校登录失败：{result.error}")
        if not result.cookies:
            raise RuntimeError("学校登录未返回教务系统会话")
        return result.account or account, result.cookies, result.ehall_cookies, result.ehall_auth_token
    finally:
        if result.httpx_client is not None:
            result.httpx_client.close()


def ensure_background_clients(
    student_id: str,
    encrypted_credentials: str,
) -> tuple[SchoolSdkClient, EhallClient | None, SchoolAccountSessionSnapshot]:
    """后台优先复用共享会话；失效时按账号锁只刷新一次。"""
    account = student_id.strip()
    with account_school_session_lock(account):
        with get_sync_session_factory()() as db:
            profile = db.query(BackgroundNotificationProfile).filter_by(student_id=account).first()
            if (
                profile is None
                or profile.encrypted_credentials != encrypted_credentials
                or db.get(CredentialRevocation, profile.credential_fingerprint) is not None
            ):
                raise BackgroundAuthorizationRevokedError("后台持续通知授权已撤销")

        current = get_school_account_session(account)
        if (
            current is not None
            and current.suspended_at is not None
            and current.next_retry_at is not None
            and current.next_retry_at > _utc_now()
        ):
            raise SchoolSessionSuspendedError(account, current.next_retry_at, current.suspension_reason)
        if current is not None and current.suspended_at is not None:
            mark_school_session_invalid(account)
        try:
            reused = load_shared_school_clients(account)
            logger.debug(
                "school_account_session_reused_after_lock",
                extra={"account_hash": _account_hash(account), "version": reused[2].version},
            )
            return reused
        except SchoolSessionSuspendedError:
            raise
        except (SchoolSessionUnavailableError, AuthenticationError):
            mark_school_session_invalid(account)
        settings = get_settings()
        login_account, password = decrypt_credentials(
            encrypted_credentials, settings.credential_encryption_key
        )
        resolved_account, cookies, ehall_cookies, ehall_token = _cas_login(login_account, password)
        snapshot = record_authenticated_session(
            resolved_account,
            None,
            cookies,
            ehall_cookies,
            ehall_token,
            None,
        )
        with get_sync_session_factory()() as db:
            row = db.query(SchoolAccountSession).filter_by(student_id=resolved_account).first()
            if row is None:
                raise RuntimeError("共享学校会话写入后无法读取")
            client, ehall_client = _build_clients(row, resolved_account)
            row.last_used_at = _utc_now()
            row.updated_at = _utc_now()
            db.commit()
        logger.info(
            "school_account_session_refreshed",
            extra={"account_hash": _account_hash(account), "version": snapshot.version},
        )
        return client, ehall_client, snapshot


def suspend_school_session(student_id: str, reason: str, next_retry_at: datetime) -> bool:
    """标记共享会话暂停，返回是否首次进入本轮暂停。"""
    account = student_id.strip()
    now = _utc_now()
    with get_sync_session_factory()() as db:
        row = db.query(SchoolAccountSession).filter_by(student_id=account).first()
        if row is None:
            row = SchoolAccountSession(student_id=account, version=1)
            db.add(row)
        first = row.suspended_at is None or (
            row.next_retry_at is not None and row.next_retry_at <= now
        )
        row.suspended_at = now
        row.suspension_reason = reason
        row.next_retry_at = _aware(next_retry_at)
        if first and row.limit_notified_at is None:
            row.limit_notified_at = now
        row.updated_at = now
        db.commit()
        return first


def claim_suspension_notification(student_id: str, notified_at: datetime) -> bool:
    """跨轮询实例幂等领取一次暂停提示。"""
    account = student_id.strip()
    with get_sync_session_factory()() as db:
        claimed = (
            db.query(BackgroundNotificationProfile)
            .filter(
                BackgroundNotificationProfile.student_id == account,
                BackgroundNotificationProfile.limit_notified_at.is_(None),
            )
            .update(
                {
                    "limit_notified_at": _aware(notified_at),
                    "updated_at": _utc_now(),
                },
                synchronize_session=False,
            )
        )
        db.commit()
        return claimed == 1


def clear_school_session_suspension(student_id: str) -> None:
    account = student_id.strip()
    with get_sync_session_factory()() as db:
        row = db.query(SchoolAccountSession).filter_by(student_id=account).first()
        if row is not None:
            row.suspended_at = None
            row.suspension_reason = None
            row.next_retry_at = None
            row.limit_notified_at = None
            row.updated_at = _utc_now()
            db.commit()


def _within_wechat_retention(row: SchoolAccountSession, now: datetime) -> bool:
    """只有学校认证更新保留起点；普通读取、微信恢复和退出均不续期。"""
    authenticated_at = _aware(row.authenticated_at)
    expires_at = _aware(row.expires_at)
    return (
        authenticated_at is not None
        and authenticated_at + _WECHAT_SCHOOL_SESSION_RETENTION > now
        and (expires_at is None or expires_at > now)
    )


def _has_school_authorization(db: Session, account: str, now: datetime) -> bool:
    """前台、设备与后台授权各自独立于微信绑定的保留期限。"""
    cutoff = now - timedelta(seconds=get_settings().session_ttl_seconds)
    has_profile = db.query(BackgroundNotificationProfile.id).filter_by(student_id=account).first()
    has_session = db.query(AppSessionModel.id).filter(
        AppSessionModel.student_account == account,
        AppSessionModel.revoked_at.is_(None),
        AppSessionModel.last_active_at >= cutoff,
    ).first()
    has_device = db.query(DeviceAuthorization.token_digest).filter(
        DeviceAuthorization.student_account == account,
        DeviceAuthorization.revoked_at.is_(None),
    ).first()
    return has_profile is not None or has_session is not None or has_device is not None


def release_if_unused(student_id: str) -> bool:
    """删除无其他有效授权且无认证后 30 天内微信绑定引用的共享学校会话。"""
    account = student_id.strip()
    now = _utc_now()
    with account_school_session_lock(account), get_sync_session_factory()() as db:
        row = db.query(SchoolAccountSession).filter_by(student_id=account).first()
        if row is None or _has_school_authorization(db, account, now):
            return False
        has_binding = db.query(WechatBinding.id).filter_by(student_id=account).first()
        if has_binding is not None and _within_wechat_retention(row, now):
            return False
        db.delete(row)
        db.commit()
        return True


def purge_expired_wechat_school_sessions() -> None:
    """即使前台会话已全部清理，也在现有定时任务中释放到期的微信独占 Cookie。"""
    now = _utc_now()
    with get_sync_session_factory()() as db:
        accounts = [row.student_id for row in db.query(SchoolAccountSession.student_id).filter(or_(
            SchoolAccountSession.authenticated_at.is_(None),
            SchoolAccountSession.authenticated_at <= now - _WECHAT_SCHOOL_SESSION_RETENTION,
            SchoolAccountSession.expires_at <= now,
        )).all()]
    for account in accounts:
        release_if_unused(account)


def revoke_account_school_access(student_id: str) -> None:
    """管理员撤销学校访问时保留微信关联，清理共享会话与所有前台授权。"""
    account = student_id.strip()
    now = _utc_now()
    with account_school_session_lock(account):
        with get_sync_session_factory()() as db:
            fingerprints = {
                row.token_digest for row in db.query(DeviceAuthorization.token_digest).filter_by(
                    student_account=account,
                ).all()
            }
            fingerprints.update(
                row.credential_fingerprint
                for row in db.query(AppSessionModel.credential_fingerprint).filter(
                    AppSessionModel.student_account == account,
                    AppSessionModel.credential_fingerprint.is_not(None),
                ).all()
            )
            fingerprints.update(
                row.credential_fingerprint
                for row in db.query(BackgroundNotificationProfile.credential_fingerprint).filter_by(
                    student_id=account,
                ).all()
            )
            # 所有已发行凭据都要持久撤销，不能在账号重新认证后借旧凭据恢复。
            for fingerprint in fingerprints:
                if db.get(CredentialRevocation, fingerprint) is None:
                    db.add(CredentialRevocation(
                        credential_fingerprint=fingerprint, revoked_at=now, reason="admin_kick",
                    ))
            db.query(DeviceAuthorization).filter_by(student_account=account).update({
                "revoked_at": now, "revoked_reason": "admin_kick", "encrypted_credentials": None,
            }, synchronize_session=False)
            db.query(BackgroundNotificationProfile).filter_by(student_id=account).delete()
            for model in (WebPushSubscription, IosPushToken, IosLiveActivityToken):
                db.query(model).filter(model.student_id == account).delete(synchronize_session=False)
            db.query(SchoolAccountSession).filter_by(student_id=account).delete()
            db.query(AppSessionModel).filter(
                AppSessionModel.student_account == account,
                AppSessionModel.revoked_at.is_(None),
            ).update({"revoked_at": now, "revoked_reason": "admin_kick"}, synchronize_session=False)
            db.commit()


def suspension_retry_interval() -> timedelta:
    return _SUSPENSION_RETRY_INTERVAL
