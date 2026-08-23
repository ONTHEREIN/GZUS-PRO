from __future__ import annotations

import hashlib
import json
import logging
import threading
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any

import httpx

from app.config import get_settings

logger = logging.getLogger(__name__)

# ─── Global token cache (all users share one ECARD_OPENID/SECRET) ───
_TOKEN_CACHE_LOCK = threading.Lock()
_GLOBAL_TOKEN: dict[str, Any] = {"token": None, "unionid": None, "cached_at": 0.0}
_TOKEN_TTL = 3000  # 50 minutes


class EcardConfigurationError(RuntimeError):
    pass


class EcardApiError(RuntimeError):
    pass


WX_UA = (
    "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) "
    "AppleWebKit/605.1.15 (KHTML, like Gecko) "
    "Mobile/15E148 MicroMessenger/8.0.38 NetType/WIFI Language/zh_CN"
)
ROOM_IMPL_TYPES = ("CGCOMMON1111", "CGCOMMON2222", "CGCOMMON3333")
SENSITIVE_ROOM_KEYS = {
    "powerBalance",
    "waterBalance",
    "formatPowerBalanceStr",
    "formatWaterBalanceStr",
    "formatHotWaterBalanceStr",
}


def calc_sign(params: dict[str, Any], secret: str | None = None) -> str:
    settings = get_settings()
    secret_value = secret if secret is not None else settings.ecard_secret
    filtered = {k: v for k, v in params.items() if k not in ("token", "sign")}
    raw = "&".join(f"{key}={filtered[key]}" for key in sorted(filtered)) + f"&{secret_value}"
    return hashlib.md5(raw.encode()).hexdigest().upper()


def is_ok(data: dict[str, Any]) -> bool:
    return data.get("ret") is True or data.get("code") in (0, 200) or data.get("resCode") in (
        0,
        "0",
    )


def safe_float(value: Any) -> float | None:
    if value is None or str(value) in ("", "null"):
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


@dataclass(frozen=True)
class EcardRoomRef:
    impl_type: str
    school_area_no: str
    building_no: str
    room_num: str

    @property
    def id(self) -> str:
        return "|".join((self.impl_type, self.school_area_no, self.building_no, self.room_num))

    @classmethod
    def from_id(cls, value: str) -> "EcardRoomRef":
        parts = value.split("|")
        if len(parts) != 4 or any(part == "" for part in parts):
            raise ValueError("无效宿舍标识")
        return cls(parts[0], parts[1], parts[2], parts[3])


def room_display_name(room: dict[str, Any]) -> str:
    room_name = str(room.get("room") or "").replace("#", "-")
    parts = [
        str(room.get("schoolArea") or ""),
        str(room.get("building") or ""),
        room_name or str(room.get("roomNum") or ""),
    ]
    return " ".join(part for part in parts if part)


def public_room(room: dict[str, Any], fallback_impl_type: str = "") -> dict[str, str]:
    ref = EcardRoomRef(
        str(room.get("implType") or fallback_impl_type),
        str(room.get("schoolAreaNo") or ""),
        str(room.get("buildingNo") or ""),
        str(room.get("roomNum") or ""),
    )
    return {
        "id": ref.id,
        "schoolArea": str(room.get("schoolArea") or ""),
        "building": str(room.get("building") or ""),
        "room": str(room.get("room") or "").replace("#", "-") or str(room.get("roomNum") or ""),
        "displayName": room_display_name(room),
    }


def _load_token_from_db() -> None:
    """Load global ecard token from DataCache on cold start."""
    try:
        from app.database import DataCache, get_sync_session_factory
        factory = get_sync_session_factory()
        with factory() as db:
            row = db.query(DataCache).filter(
                DataCache.cache_key == "ecard_global_token"
            ).first()
            if row and row.response_json:
                data = json.loads(row.response_json)
                ts = row.cached_at.timestamp() if row.cached_at else 0.0
                _GLOBAL_TOKEN.update(token=data.get("token"), unionid=data.get("unionid"), cached_at=ts)
    except Exception as exc:
        logger.warning("ecard_client: load token from DB failed: %s", exc)


def _save_token_to_db(token: str, unionid: str | None) -> None:
    """Persist global ecard token to DataCache for cold-start recovery."""
    try:
        from app.database import DataCache, get_sync_session_factory
        factory = get_sync_session_factory()
        with factory() as db:
            row = db.query(DataCache).filter(
                DataCache.cache_key == "ecard_global_token"
            ).first()
            payload = json.dumps({"token": token, "unionid": unionid or ""})
            if row is None:
                db.add(DataCache(
                    cache_key="ecard_global_token", student_id="",
                    resource="ecard", response_json=payload,
                ))
            else:
                row.response_json = payload
                # UPDATE 不触发 column default，须显式刷新缓存时间戳
                row.cached_at = datetime.now(timezone.utc)
            db.commit()
    except Exception as exc:
        logger.warning("ecard_client: save token to DB failed: %s", exc)


def _delete_token_from_db() -> None:
    """Delete global ecard token from DataCache (on invalidation)."""
    try:
        from app.database import DataCache, get_sync_session_factory
        factory = get_sync_session_factory()
        with factory() as db:
            db.query(DataCache).filter(DataCache.cache_key == "ecard_global_token").delete()
            db.commit()
    except Exception:
        pass


class EcardClient:
    def __init__(self) -> None:
        self.settings = get_settings()
        if not self.settings.ecard_openid:
            raise EcardConfigurationError("未配置 ECARD_OPENID")
        self._token: str | None = None
        self._openid = self.settings.ecard_openid
        self._unionid = self.settings.ecard_unionid
        self._http_client: httpx.Client | None = None

    def _get_http_client(self) -> httpx.Client:
        if self._http_client is None or self._http_client.is_closed:
            self._http_client = httpx.Client(
                timeout=self.settings.request_timeout_seconds,
                verify=self.settings.ecard_verify_tls,
                limits=httpx.Limits(max_connections=4, max_keepalive_connections=2),
            )
        return self._http_client

    def close(self) -> None:
        if self._http_client is not None and not self._http_client.is_closed:
            self._http_client.close()
            self._http_client = None

    def post_api(
        self,
        path: str,
        params: dict[str, Any] | None = None,
        *,
        token: str | None = None,
        timeout: float | None = None,
    ) -> dict[str, Any]:
        payload = dict(params or {})
        payload.setdefault("from", "wxminiprogram")
        payload.setdefault("isWxEnterpriseXcx", "false")
        payload.setdefault("wxRequest", "wxRequest")
        payload["openid"] = self._openid
        # unionid 仅在已认证请求（带 token）中发送。登录请求若带上
        # unionid，学校服务端会判定为"已登录态"并返回 code=203 未登录，
        # 拒绝签发新 token，登录响应成功后才记录 unionid：
        # 登录响应成功后才记录 unionid，再用于后续业务请求。
        if self._unionid and token:
            payload["unionid"] = self._unionid
        if token:
            payload["token"] = token
        payload["sign"] = calc_sign(payload)
        headers = {
            "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8",
            "User-Agent": WX_UA,
        }
        url = f"{self.settings.ecard_base_url.rstrip('/')}/{path.lstrip('/')}"

        try:
            client = self._get_http_client()
            request_kwargs: dict[str, Any] = {}
            if timeout is not None:
                request_kwargs["timeout"] = timeout
            response = client.post(url, data=payload, headers=headers, **request_kwargs)
            response.raise_for_status()
            data = response.json()
        except httpx.TimeoutException as exc:
            logger.error("ecard_client: request timeout for %s: %s", path, exc)
            raise EcardApiError("一卡通服务请求超时") from exc
        except httpx.HTTPStatusError as exc:
            logger.error("ecard_client: HTTP %s for %s: %s", exc.response.status_code, path, exc)
            raise EcardApiError("一卡通服务请求失败") from exc
        except Exception as exc:
            logger.error("ecard_client: request failed for %s: %s", path, exc, exc_info=True)
            raise EcardApiError("一卡通服务请求失败") from exc
        if not isinstance(data, dict):
            raise EcardApiError("一卡通服务响应异常")
        return data

    def login(self) -> str:
        if self._token:
            return self._token
        # 1. Check module-level cache (hot path, no DB I/O)
        with _TOKEN_CACHE_LOCK:
            if _GLOBAL_TOKEN["token"] and (time.time() - _GLOBAL_TOKEN["cached_at"] < _TOKEN_TTL):
                self._token = _GLOBAL_TOKEN["token"]
                self._unionid = _GLOBAL_TOKEN["unionid"] or self._unionid
                return self._token
        # 2. Cold start: load from DB
        if not _GLOBAL_TOKEN["token"]:
            _load_token_from_db()
            with _TOKEN_CACHE_LOCK:
                if _GLOBAL_TOKEN["token"] and (time.time() - _GLOBAL_TOKEN["cached_at"] < _TOKEN_TTL):
                    self._token = _GLOBAL_TOKEN["token"]
                    self._unionid = _GLOBAL_TOKEN["unionid"] or self._unionid
                    return self._token
        # 3. Cache miss: do actual login
        data = self.post_api("/user/routine/routine-login", {"from": "wxminiprogram"})
        token = data.get("token")
        if data.get("code") == 200 and token:
            self._token = str(token)
            if data.get("unionid"):
                self._unionid = str(data["unionid"])
            # Update global cache + persist to DB
            with _TOKEN_CACHE_LOCK:
                _GLOBAL_TOKEN.update(
                    token=self._token, unionid=self._unionid, cached_at=time.time(),
                )
            _save_token_to_db(self._token, self._unionid)
            logger.info("ecard_client: login success, token cached globally")
            return self._token
        logger.error("ecard_client: login failed, code=%s msg=%s", data.get("code"), data.get("msg"))
        raise EcardApiError(str(data.get("msg") or "一卡通登录失败"))

    def _invalidate_token(self) -> None:
        """Clear cached token (module-level + DB) on auth failure."""
        with _TOKEN_CACHE_LOCK:
            _GLOBAL_TOKEN.update(token=None, unionid=None, cached_at=0.0)
        self._token = None
        _delete_token_from_db()
        logger.info("ecard_client: token invalidated due to auth failure")

    def rooms(self) -> list[dict[str, str]]:
        token = self.login()
        rooms_by_impl: dict[str, list[dict[str, Any]]] = {}

        # 上游对同一 token 的并发请求敏感，宿舍类型按顺序查询。
        def _fetch_one(impl_type: str) -> list[dict[str, Any]]:
            settings = getattr(self, "settings", None)
            base_timeout = getattr(settings, "request_timeout_seconds", 6)
            room_timeout = max(base_timeout, 15)
            data = self.post_api(
                "/powerfee/getRoomInfo",
                {"implType": impl_type},
                token=token,
                timeout=room_timeout,
            )
            if not is_ok(data):
                # Retry on auth failure
                if data.get("code") == 203 or "未登录" in str(data.get("msg", "")):
                    self._invalidate_token()
                    token_fresh = self.login()
                    data = self.post_api(
                        "/powerfee/getRoomInfo",
                        {"implType": impl_type},
                        token=token_fresh,
                        timeout=room_timeout,
                    )
                if not is_ok(data):
                    message = data.get("msg") or data.get("message") or "获取宿舍列表失败"
                    raise EcardApiError(str(message))
            obj = data.get("obj") or []
            return obj if isinstance(obj, list) else [obj]

        errors: list[BaseException] = []
        for impl_type in ROOM_IMPL_TYPES:
            try:
                rooms_by_impl[impl_type] = _fetch_one(impl_type)
            except Exception as exc:
                logger.warning("ecard_client: getRoomInfo failed for implType=%s: %s", impl_type, exc)
                errors.append(exc)

        seen: set[str] = set()
        seen_physical: set[tuple[str, str, str]] = set()
        result: list[dict[str, str]] = []
        for impl_type in ROOM_IMPL_TYPES:
            for room in rooms_by_impl.get(impl_type, []):
                if not isinstance(room, dict):
                    continue
                public_source = {k: v for k, v in room.items() if k not in SENSITIVE_ROOM_KEYS}
                item = public_room(public_source, fallback_impl_type=impl_type)
                if item["id"] in seen or "||" in item["id"]:
                    continue
                physical_key = (
                    str(room.get("schoolAreaNo") or ""),
                    str(room.get("buildingNo") or ""),
                    str(room.get("roomNum") or ""),
                )
                if all(physical_key) and physical_key in seen_physical:
                    continue
                seen.add(item["id"])
                if all(physical_key):
                    seen_physical.add(physical_key)
                result.append(item)
        if not result and errors:
            raise EcardApiError("获取宿舍列表失败") from errors[0]
        result.sort(key=lambda item: (item["displayName"], item["id"]))
        return result

    def balance(self, room_ref: EcardRoomRef, student_id: str) -> dict[str, Any]:
        token = self.login()
        power_data = self.post_api(
            "/powerfee/getBalance",
            {
                "implType": room_ref.impl_type,
                "schoolAreaNo": room_ref.school_area_no,
                "buildingNo": room_ref.building_no,
                "roomNum": room_ref.room_num,
                "studentId": student_id,
            },
            token=token,
        )
        # 注意:这里不做 203 重试。重试链 login+getBalance 会叠加到 10s+
        # 避免余额查询叠加多个耗时请求，token 有
        # 50min 全局缓存,203 属低频;遇到时置为无效并抛错,由上层走 stale
        # 兜底,下一次请求会自动重新登录。
        if power_data.get("code") == 203 or "未登录" in str(power_data.get("msg", "")):
            logger.warning(
                "ecard_client: getBalance token expired (code=%s), invalidating; no immediate retry",
                power_data.get("code"),
            )
            self._invalidate_token()
        if not is_ok(power_data):
            logger.error("ecard_client: getBalance failed, code=%s msg=%s", power_data.get("code") or power_data.get("resCode"), power_data.get("msg"))
            raise EcardApiError(str(power_data.get("msg") or "获取水电费失败"))
        obj = power_data.get("obj") or {}
        hot_balance = obj.get("hotWaterBalance")
        try:
            if hot_balance is None:
                hot_data = self.post_api(
                    "/waterfee/memberInfo",
                    {"sno": student_id, "implType": "MINGHANBLUETOOTH"},
                    token=token,
                )
                if is_ok(hot_data):
                    hot_balance = (hot_data.get("obj") or {}).get("balance")
        except EcardApiError:
            hot_balance = None
        cold_balance = obj.get("coldWaterBalance", obj.get("waterBalance"))
        return {
            "powerBalance": obj.get("powerBalance"),
            "powerUnit": obj.get("du", "度"),
            "powerText": obj.get("formatPowerBalanceStr") or _format_value(obj.get("powerBalance"), obj.get("du", "度")),
            "coldWaterBalance": cold_balance,
            "coldWaterUnit": obj.get("dun", "吨"),
            "coldWaterText": obj.get("coldWaterText") or obj.get("formatWaterBalanceStr") or _format_value(cold_balance, obj.get("dun", "吨")),
            "hotWaterBalance": hot_balance,
            "hotWaterUnit": "元",
            "hotWaterText": obj.get("hotWaterText") or _format_value(hot_balance, "元"),
        }

    def consumption(self, room_ref: EcardRoomRef, month: str) -> dict[str, Any]:
        # 单次请求,不做 203 重试:与 balance() 同理,避免 login+业务请求
        # 叠加超时。token 全局缓存 50min，203 属低频。
        token = self.login()
        data = self.post_api(
            "/powerfee/getDailyDetails",
            {
                "roomNum": room_ref.room_num,
                "lastDate": month,
                "type": "",
                "implType": room_ref.impl_type,
                "schoolAreaNo": room_ref.school_area_no,
                "pageNum": "1",
                "pageSize": "31",
            },
            token=token,
            timeout=3,
        )
        if data.get("code") == 203 or "未登录" in str(data.get("msg", "")):
            logger.warning(
                "ecard_client: getDailyDetails token expired (code=%s), invalidating; no retry",
                data.get("code"),
            )
            self._invalidate_token()
        if data.get("status") == "ok" and isinstance(data.get("items"), list):
            return data
        if is_ok(data):
            obj = data.get("obj") or {}
            items = obj.get("dailyDetailsInfos") if isinstance(obj, dict) else None
            if isinstance(items, list):
                unit = str(obj.get("dailyUsedUnit") or "度")
                return {
                    "status": "ok",
                    "items": [_public_power_daily_item(item, unit) for item in items],
                }
        logger.error("ecard_client: getDailyDetails failed, code=%s msg=%s", data.get("code") or data.get("resCode"), data.get("msg"))
        raise EcardApiError(str(data.get("msg") or "电费消费记录查询失败"))


def _format_value(value: Any, unit: str) -> str | None:
    if value is None or str(value) in ("", "null"):
        return None
    return f"{value} {unit}".strip()


def _public_power_daily_item(item: Any, unit: str) -> dict[str, str]:
    if not isinstance(item, dict):
        return {"title": str(item), "amount": "", "time": ""}
    daily_used = str(item.get("dailyUsed") or "")
    left_used = str(item.get("leftUsed") or "")
    left_free = str(item.get("leftFree") or "")
    details = [f"剩余 {left_used} {unit}".strip()] if left_used else []
    if left_free:
        details.append(f"免费额 {left_free} {unit}".strip())
    return {
        "title": " · ".join(details) or "电费日用",
        "amount": f"{daily_used} {unit}".strip() if daily_used else "",
        "time": str(item.get("dateTime") or ""),
    }
