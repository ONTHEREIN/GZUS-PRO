"""
天气代理端点 — 将 wttr.in API 封装到后端，提供统一的天气数据接口。
"""

import time
from datetime import datetime
from typing import Any

import httpx
from fastapi import APIRouter, Query
from fastapi.responses import JSONResponse

router = APIRouter(prefix="/weather", tags=["weather"])

WTTR_BASE = "https://wttr.in"
WTTR_TIMEOUT = 15.0

# ---------- 内存缓存 ----------
_cache: dict[str, tuple[dict[str, Any], float]] = {}
_CACHE_TTL = 30 * 60  # 30 分钟


def _cache_key(lat: float | None, lon: float | None) -> str:
    if lat is not None and lon is not None:
        return f"{lat:.1f},{lon:.1f}"
    return "default"


def _build_wttr_url(lat: float | None, lon: float | None) -> str:
    if lat is not None and lon is not None:
        location = f"{lat:.2f},{lon:.2f}"
    else:
        location = "Guangzhou"
    return f"{WTTR_BASE}/{location}?format=j1"


_WEATHER_CODE_CN: dict[str, str] = {
    "113": "晴", "116": "多云", "119": "阴",
    "122": "阴", "143": "雾", "176": "小雨",
    "179": "雪", "182": "雨夹雪", "185": "冻雨",
    "200": "雷阵雨", "227": "暴风雪", "230": "暴风雪",
    "248": "雾", "260": "冻雾", "263": "毛毛雨",
    "266": "小雨", "281": "冻雨", "284": "冻雨",
    "293": "小雨", "296": "小雨", "299": "中雨",
    "302": "中雨", "305": "大雨", "308": "暴雨",
    "311": "冻雨", "314": "冻雨", "317": "雨夹雪",
    "320": "雪", "323": "中雪", "326": "中雪",
    "329": "大雪", "332": "大雪", "335": "暴雪",
    "338": "暴雪", "350": "冰雹", "353": "小雨",
    "356": "中雨", "359": "暴雨", "362": "雨夹雪",
    "365": "雨夹雪", "368": "雪", "371": "大雪",
    "374": "冻雨", "377": "雨夹雪", "386": "雷阵雨",
    "389": "雷暴", "392": "雷阵雨", "395": "大雪",
}

_WIND_DIR_CN: dict[str, str] = {
    "N": "北风", "NNE": "东北偏北风", "NE": "东北风", "ENE": "东北偏东风",
    "E": "东风", "ESE": "东南偏东风", "SE": "东南风", "SSE": "东南偏南风",
    "S": "南风", "SSW": "西南偏南风", "SW": "西南风", "WSW": "西南偏西风",
    "W": "西风", "WNW": "西北偏西风", "NW": "西北风", "NNW": "西北偏北风",
}


def _wind_power(speed_kmh: float) -> str:
    if speed_kmh < 6:
        return "1级"
    if speed_kmh < 12:
        return "2级"
    if speed_kmh < 20:
        return "3级"
    if speed_kmh < 29:
        return "4级"
    if speed_kmh < 39:
        return "5级"
    if speed_kmh < 50:
        return "6级"
    if speed_kmh < 62:
        return "7级"
    return "8级+"


def _transform_wttr(data: dict[str, Any]) -> dict[str, Any]:
    """将 wttr.in 的原始响应转换为前端 WeatherData 格式。"""
    current_list = data.get("current_condition", [])
    nearest_list = data.get("nearest_area", [])
    weather_list = data.get("weather", [])

    current = current_list[0] if current_list else {}
    nearest = nearest_list[0] if nearest_list else {}

    # ---- 天气描述 ----
    weather_code = str(current.get("weatherCode", "116"))
    weather_cn = _WEATHER_CODE_CN.get(weather_code, "多云")

    # ---- 温度 ----
    temp_c = _safe_float(current.get("temp_C"))
    humidity_val = _safe_int(current.get("humidity"))

    # ---- 风向 / 风力 ----
    wind_dir_raw = str(current.get("winddir16Point", ""))
    wind_dir = _WIND_DIR_CN.get(wind_dir_raw, wind_dir_raw)
    wind_speed = _safe_float(current.get("windspeedKmph"))
    wind_power_str = _wind_power(wind_speed)

    # ---- 位置 ----
    def _first_value(items: list[dict[str, Any]], key: str) -> str:
        if items and isinstance(items, list):
            first = items[0]
            if isinstance(first, dict):
                inner = first.get(key, "value")
                if isinstance(inner, list) and inner:
                    return str(inner[0].get("value", ""))
                return str(inner)
        return ""

    area_name = _first_value(nearest.get("areaName", []), "value")
    region = _first_value(nearest.get("region", []), "value")
    province = region or "广东"
    city = area_name or "广州"
    district = area_name if area_name else "广州"

    # ---- 今日最高/最低温 ----
    today = weather_list[0] if weather_list else {}
    temp_max = _safe_float(today.get("maxtempC"))
    temp_min = _safe_float(today.get("mintempC"))

    # ---- 未来预报 ----
    forecast: list[dict[str, Any]] = []
    for day in weather_list:
        hourly = day.get("hourly", [])
        if hourly and isinstance(hourly, list):
            mid_point = hourly[len(hourly) // 2]
            if isinstance(mid_point, dict):
                fc_code = str(mid_point.get("weatherCode", "116"))
                date_str = day.get("date", "")
                forecast.append({
                    "date": date_str,
                    "week": _weekday_cn(date_str),
                    "temp_max": _safe_float(day.get("maxtempC"), 0),
                    "temp_min": _safe_float(day.get("mintempC"), 0),
                    "weather_day": _WEATHER_CODE_CN.get(fc_code, "多云"),
                })

    return {
        "province": province,
        "city": city,
        "district": district,
        "weather": weather_cn,
        "weather_icon": weather_code,
        "temperature": temp_c,
        "wind_direction": wind_dir,
        "wind_power": wind_power_str,
        "humidity": humidity_val,
        "temp_max": temp_max,
        "temp_min": temp_min,
        "forecast": forecast,
    }


_WEEKDAY_CN = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]


def _weekday_cn(date_str: str) -> str:
    try:
        dt = datetime.strptime(date_str, "%Y-%m-%d")
        return _WEEKDAY_CN[dt.weekday()]
    except (ValueError, IndexError):
        return ""


def _safe_float(value: Any, default: float = 0.0) -> float:
    if value is None:
        return default
    try:
        return float(value)
    except (ValueError, TypeError):
        return default


def _safe_int(value: Any, default: int = 0) -> int:
    if value is None:
        return default
    try:
        return int(value)
    except (ValueError, TypeError):
        return default


@router.get("")
async def get_weather(
    lat: float | None = Query(default=None, ge=-90, le=90),
    lon: float | None = Query(default=None, ge=-180, le=180),
) -> JSONResponse:
    """获取天气数据，优先使用 lat/lon 定位，fallback 到广州。

    结果按坐标缓存 30 分钟（内存级，不含永久存储）。
    公开端点，无需认证。
    """
    key = _cache_key(lat, lon)

    # 检查缓存
    cached = _cache.get(key)
    if cached is not None:
        cached_data, cached_at = cached
        if time.time() - cached_at < _CACHE_TTL:
            return JSONResponse(content=cached_data)

    # 请求 wttr.in
    url = _build_wttr_url(lat, lon)
    try:
        async with httpx.AsyncClient(timeout=WTTR_TIMEOUT) as client:
            resp = await client.get(url, headers={
                "Accept": "application/json",
                "User-Agent": "OneGZUS/1.0",
            })
            resp.raise_for_status()
            raw = resp.json()
    except httpx.TimeoutException:
        stale = _cache.get(key)
        if stale is not None:
            # wttr.in 超时但缓存仍在，返回过期缓存
            return JSONResponse(content=stale[0])
        raise
    except httpx.HTTPStatusError:
        # wttr.in 服务端错误
        stale = _cache.get(key)
        if stale is not None:
            return JSONResponse(content=stale[0])
        raise
    except Exception:
        stale = _cache.get(key)
        if stale is not None:
            return JSONResponse(content=stale[0])
        raise

    try:
        result = _transform_wttr(raw)
    except Exception:
        stale = _cache.get(key)
        if stale is not None:
            return JSONResponse(content=stale[0])
        raise

    # 缓存结果
    _cache[key] = (result, time.time())
    return JSONResponse(content=result)
