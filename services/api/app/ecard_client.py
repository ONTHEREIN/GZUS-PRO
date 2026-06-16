from __future__ import annotations

import concurrent.futures
import hashlib
import logging
from dataclasses import dataclass
from typing import Any
from urllib.parse import urlencode

import httpx

from app.config import get_settings

logger = logging.getLogger(__name__)


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


def public_room(room: dict[str, Any]) -> dict[str, str]:
    ref = EcardRoomRef(
        str(room.get("implType") or "CGCOMMON1111"),
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


class EcardClient:
    def __init__(self, worker_proxy_origin: str | None = None) -> None:
        self.settings = get_settings()
        self._worker_proxy_origin = (
            worker_proxy_origin
            if worker_proxy_origin is not None
            else self.settings.ecard_worker_proxy_origin
        )
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
    ) -> dict[str, Any]:
        payload = dict(params or {})
        payload.setdefault("from", "wxminiprogram")
        payload.setdefault("isWxEnterpriseXcx", "false")
        payload.setdefault("wxRequest", "wxRequest")
        payload["openid"] = self._openid
        # unionid 仅在已认证请求（带 token）中发送。登录请求若带上
        # unionid，学校服务端会判定为"已登录态"并返回 code=203 未登录，
        # 拒绝签发新 token。与 Cloudflare 透明代理路径保持一致：
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

        # If Worker proxy is configured, route through Cloudflare to reach
        # the ecard API from serverless regions where direct access is flaky.
        if self._worker_proxy_origin:
            return self._post_via_proxy(url, payload, headers)

        try:
            client = self._get_http_client()
            response = client.post(url, data=payload, headers=headers)
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

    def _post_via_proxy(
        self, url: str, payload: dict[str, Any], headers: dict[str, str],
    ) -> dict[str, Any]:
        """Send the already-signed ecard request through Cloudflare Worker."""
        proxy_origin = self._worker_proxy_origin.rstrip("/")
        proxy_url = f"{proxy_origin}/_proxy"
        proxy_body = {
            "url": url,
            "method": "POST",
            "headers": headers,
            "body": urlencode(payload),
        }
        try:
            client = self._get_http_client()
            response = client.post(
                proxy_url,
                json=proxy_body,
                timeout=self.settings.request_timeout_seconds + 15,
            )
            response.raise_for_status()
            upstream_status = int(response.headers.get("X-Proxy-Status", response.status_code))
            if upstream_status >= 400:
                raise EcardApiError(f"一卡通服务请求失败: HTTP {upstream_status}")
            data = response.json()
        except httpx.TimeoutException as exc:
            logger.error("ecard_client: Cloudflare proxy timeout for %s: %s", proxy_url, exc)
            raise EcardApiError("一卡通服务请求超时") from exc
        except EcardApiError:
            raise
        except Exception as exc:
            logger.error("ecard_client: Cloudflare proxy request failed: %s", exc, exc_info=True)
            raise EcardApiError("一卡通服务请求失败") from exc
        if not isinstance(data, dict):
            raise EcardApiError("一卡通服务响应异常")
        return data

    def login(self) -> str:
        if self._token:
            return self._token
        data = self.post_api("/user/routine/routine-login", {"from": "wxminiprogram"})
        token = data.get("token")
        if data.get("code") == 200 and token:
            self._token = str(token)
            if data.get("unionid"):
                self._unionid = str(data["unionid"])
            logger.info("ecard_client: login success")
            return self._token
        logger.error("ecard_client: login failed, code=%s msg=%s", data.get("code"), data.get("msg"))
        raise EcardApiError(str(data.get("msg") or "一卡通登录失败"))

    def current_user(self) -> dict[str, Any]:
        data = self.post_api("/user/routine/getCurrentUser", token=self.login())
        if not is_ok(data):
            raise EcardApiError(str(data.get("msg") or "获取一卡通用户失败"))
        return data.get("obj") or {}

    def rooms(self) -> list[dict[str, str]]:
        token = self.login()
        all_rooms: list[dict[str, Any]] = []

        # Fetch from all 3 impl types in parallel (each call is ~0.8s →
        # ~0.8s total instead of ~2.5s sequential)
        def _fetch_one(impl_type: str) -> list[dict[str, Any]]:
            data = self.post_api("/powerfee/getRoomInfo", {"implType": impl_type}, token=token)
            if not is_ok(data):
                return []
            obj = data.get("obj") or []
            return obj if isinstance(obj, list) else [obj]

        errors: list[BaseException] = []
        with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
            futures = [pool.submit(_fetch_one, t) for t in ROOM_IMPL_TYPES]
            for future in concurrent.futures.as_completed(futures):
                try:
                    all_rooms.extend(future.result())
                except Exception as exc:
                    errors.append(exc)

        seen: set[str] = set()
        result: list[dict[str, str]] = []
        for room in all_rooms:
            if not isinstance(room, dict):
                continue
            item = public_room({k: v for k, v in room.items() if k not in SENSITIVE_ROOM_KEYS})
            if item["id"] in seen or "||" in item["id"]:
                continue
            seen.add(item["id"])
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
            token=self.login(),
        )
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
