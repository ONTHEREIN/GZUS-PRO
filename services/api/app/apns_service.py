from __future__ import annotations

import base64
import json
import logging
import time
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Final

import httpx
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric.ec import EllipticCurvePrivateKey, ECDSA
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature

from app.config import Settings, get_settings
from app.database import IosPushToken, get_sync_session_factory

logger = logging.getLogger(__name__)

_APNS_PRODUCTION_URL: Final = "https://api.push.apple.com"
_APNS_SANDBOX_URL: Final = "https://api.sandbox.push.apple.com"
_APNS_MAX_PAYLOAD_BYTES: Final = 4096
_APNS_TOKEN_TTL_SECONDS: Final = 50 * 60
_APNS_RETRY_COUNT: Final = 3
_APNS_TIMEOUT_SECONDS: Final = 10.0
_token_cache: tuple[str, int] | None = None


class ApnsConfigurationError(RuntimeError):
    pass


class ApnsDeliveryError(RuntimeError):
    pass


class ApnsUnregisteredError(ApnsDeliveryError):
    pass


@dataclass(frozen=True)
class _ApnsCredentials:
    key_id: str
    team_id: str
    bundle_id: str
    private_key: EllipticCurvePrivateKey


def is_apns_enabled() -> bool:
    settings = get_settings()
    values = (
        settings.apns_key_id.strip(),
        settings.apns_team_id.strip(),
        settings.apns_key_p8_base64.strip(),
    )
    return any(values)


def _base64url(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).rstrip(b"=").decode("ascii")


def _decode_private_key(value: str) -> EllipticCurvePrivateKey:
    try:
        pem = base64.b64decode(value, validate=True)
    except ValueError as exc:
        raise ApnsConfigurationError("APNS_KEY_P8_BASE64 不是有效的 Base64 编码") from exc
    key = serialization.load_pem_private_key(pem, password=None)
    if not isinstance(key, EllipticCurvePrivateKey):
        raise ApnsConfigurationError("APNS Auth Key 必须是 EC 私钥")
    return key


def _credentials(settings: Settings) -> _ApnsCredentials:
    values = {
        "APNS_KEY_ID": settings.apns_key_id.strip(),
        "APNS_TEAM_ID": settings.apns_team_id.strip(),
        "APNS_KEY_P8_BASE64": settings.apns_key_p8_base64.strip(),
        "APNS_BUNDLE_ID": settings.apns_bundle_id.strip(),
    }
    configured = {name: bool(value) for name, value in values.items()}
    if not any(configured.values()):
        raise ApnsConfigurationError("APNs 未配置")
    missing = [name for name, present in configured.items() if not present]
    if missing:
        raise ApnsConfigurationError(f"APNs 配置不完整，缺少: {', '.join(missing)}")
    return _ApnsCredentials(
        key_id=values["APNS_KEY_ID"],
        team_id=values["APNS_TEAM_ID"],
        bundle_id=values["APNS_BUNDLE_ID"],
        private_key=_decode_private_key(values["APNS_KEY_P8_BASE64"]),
    )


def _authorization_token(credentials: _ApnsCredentials, now: int) -> str:
    global _token_cache
    if _token_cache is not None and now - _token_cache[1] < _APNS_TOKEN_TTL_SECONDS:
        return _token_cache[0]

    header = _base64url(
        json.dumps({"alg": "ES256", "kid": credentials.key_id}, separators=(",", ":")).encode()
    )
    claims = _base64url(
        json.dumps({"iss": credentials.team_id, "iat": now}, separators=(",", ":")).encode()
    )
    signing_input = f"{header}.{claims}".encode("ascii")
    signature_der = credentials.private_key.sign(signing_input, ECDSA(hashes.SHA256()))
    r, s = decode_dss_signature(signature_der)
    signature = r.to_bytes(32, "big") + s.to_bytes(32, "big")
    token = f"{header}.{claims}.{_base64url(signature)}"
    _token_cache = (token, now)
    return token


def _safe_metadata(extras: dict | None) -> dict[str, str | int | float | bool]:
    if extras is None:
        return {}
    metadata: dict[str, str | int | float | bool] = {}
    for key in ("id", "type", "url", "courseName"):
        value = extras.get(key)
        if isinstance(value, str):
            metadata[key] = value[:128]
        elif isinstance(value, (int, float, bool)):
            metadata[key] = value
    return metadata


def build_apns_payload(title: str, body: str, extras: dict | None) -> bytes:
    payload = {
        "aps": {
            "alert": {
                "title": title[:256],
                "body": body[:512],
            },
            "sound": "default",
        },
        "extras": _safe_metadata(extras),
    }
    encoded = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    if len(encoded) > _APNS_MAX_PAYLOAD_BYTES:
        raise ApnsDeliveryError("APNs payload 超过 4 KB 限制")
    return encoded


def _endpoint(environment: str, device_token: str) -> str:
    base = _APNS_SANDBOX_URL if environment == "sandbox" else _APNS_PRODUCTION_URL
    return f"{base}/3/device/{device_token}"


def _response_reason(response: httpx.Response) -> str:
    try:
        payload = response.json()
    except ValueError:
        return response.text[:200]
    if isinstance(payload, dict) and isinstance(payload.get("reason"), str):
        return payload["reason"]
    return response.text[:200]


def _send_once(
    credentials: _ApnsCredentials,
    device_token: str,
    environment: str,
    payload: bytes,
) -> None:
    headers = {
        "authorization": f"bearer {_authorization_token(credentials, int(time.time()))}",
        "apns-topic": credentials.bundle_id,
        "apns-push-type": "alert",
        "apns-priority": "10",
        "apns-expiration": str(int((datetime.now(timezone.utc) + timedelta(days=1)).timestamp())),
        "content-type": "application/json",
    }
    with httpx.Client(http2=True, timeout=_APNS_TIMEOUT_SECONDS) as client:
        response = client.post(
            _endpoint(environment, device_token), content=payload, headers=headers
        )
    if response.status_code == 200:
        return
    reason = _response_reason(response)
    if response.status_code == 410 or reason == "BadDeviceToken":
        raise ApnsUnregisteredError(
            f"APNs 设备令牌已失效: status={response.status_code}, reason={reason}"
        )
    raise ApnsDeliveryError(f"APNs 请求失败: status={response.status_code}, reason={reason}")


def _send_with_retry(
    credentials: _ApnsCredentials,
    device_token: str,
    environment: str,
    payload: bytes,
) -> None:
    last_error: ApnsDeliveryError | None = None
    for attempt in range(1, _APNS_RETRY_COUNT + 1):
        try:
            _send_once(credentials, device_token, environment, payload)
            return
        except ApnsUnregisteredError:
            raise
        except (ApnsDeliveryError, httpx.HTTPError) as exc:
            last_error = exc if isinstance(exc, ApnsDeliveryError) else ApnsDeliveryError(str(exc))
            if attempt < _APNS_RETRY_COUNT:
                logger.warning(
                    "apns_delivery_retry",
                    extra={"attempt": attempt, "environment": environment},
                )
    if last_error is None:
        raise ApnsDeliveryError("APNs 投递未执行")
    raise last_error


def send_apns_to_student(student_id: str, title: str, body: str, extras: dict | None) -> None:
    if not is_apns_enabled():
        return
    credentials = _credentials(get_settings())
    payload = build_apns_payload(title, body, extras)
    factory = get_sync_session_factory()
    with factory() as db:
        subscriptions = db.query(IosPushToken).filter(IosPushToken.student_id == student_id).all()
        for subscription in subscriptions:
            try:
                _send_with_retry(
                    credentials,
                    subscription.device_token,
                    subscription.environment,
                    payload,
                )
            except ApnsUnregisteredError:
                db.delete(subscription)
                db.commit()
                logger.info("apns_token_removed", extra={"student_id": student_id})
            except (ApnsConfigurationError, ApnsDeliveryError) as exc:
                logger.error(
                    "apns_delivery_failed",
                    extra={
                        "student_id": student_id,
                        "environment": subscription.environment,
                        "error": str(exc),
                    },
                )
