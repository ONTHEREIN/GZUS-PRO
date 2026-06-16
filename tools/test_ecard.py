"""
软帮手（OneGZUS）一卡通冒烟测试脚本

用法:
  python tools/test_ecard.py [关键词] [数量]
  python tools/test_ecard.py J1 10 --account 学号 --password 密码

环境变量:
  ONEGZUS_ACCOUNT / GZUS_TEST_ACCOUNT
  ONEGZUS_PASSWORD / GZUS_TEST_PASSWORD
  ONEGZUS_API_BASE_URL / API_BASE_URL

默认 API: https://onegzus.cc.cd/api
依赖: pip install requests cryptography
"""

from __future__ import annotations

import argparse
import base64
import os
import sys
import time
from typing import Any

import requests
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import padding

DEFAULT_API_BASE = "https://onegzus.cc.cd/api"
USER_AGENT = "OneGZUS/1.0 smoke-test"


def env_first(*names: str) -> str:
    for name in names:
        value = os.getenv(name)
        if value:
            return value
    return ""


def normalize_api_base(value: str) -> str:
    first = value.split(",", 1)[0].strip() if value else DEFAULT_API_BASE
    return first.rstrip("/")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="软帮手登录、宿舍搜索、余额查询冒烟测试")
    parser.add_argument("keyword", nargs="?", default="A2", help="宿舍搜索关键词，空字符串表示不筛选")
    parser.add_argument("limit", nargs="?", type=int, default=5, help="宿舍搜索返回数量")
    parser.add_argument(
        "--api-base",
        default=env_first("ONEGZUS_API_BASE_URL", "API_BASE_URL") or DEFAULT_API_BASE,
        help="API 根地址，默认使用当前主域 https://onegzus.cc.cd/api",
    )
    parser.add_argument(
        "--account",
        default=env_first("ONEGZUS_ACCOUNT", "GZUS_TEST_ACCOUNT"),
        help="登录学号；也可用 ONEGZUS_ACCOUNT 或 GZUS_TEST_ACCOUNT",
    )
    parser.add_argument(
        "--password",
        default=env_first("ONEGZUS_PASSWORD", "GZUS_TEST_PASSWORD"),
        help="登录密码；也可用 ONEGZUS_PASSWORD 或 GZUS_TEST_PASSWORD",
    )
    parser.add_argument("--room-id", default="", help="指定宿舍 roomId；不传则使用搜索结果第一项")
    parser.add_argument("--room-display", default="", help="指定宿舍显示名；配合 --room-id 使用")
    parser.add_argument(
        "--no-bind",
        action="store_true",
        help="不自动绑定搜索到的宿舍，只读取当前已绑定宿舍的余额",
    )
    return parser.parse_args()


def request_json(method: str, url: str, **kwargs: Any) -> Any:
    headers = kwargs.pop("headers", {})
    headers.setdefault("User-Agent", USER_AGENT)
    resp = requests.request(method, url, headers=headers, **kwargs)
    try:
        data = resp.json()
    except ValueError:
        data = {"detail": resp.text[:300] or "empty response"}

    if resp.status_code >= 400:
        detail = data.get("detail") if isinstance(data, dict) else data
        raise RuntimeError(f"HTTP {resp.status_code}: {detail}")
    return data


def login(api_base: str, account: str, password: str) -> str:
    pk = request_json("GET", f"{api_base}/auth/public-key", timeout=15)
    public_key = serialization.load_pem_public_key(pk["publicKey"].encode())
    encrypted = public_key.encrypt(password.encode("utf-8"), padding.PKCS1v15())

    data = request_json(
        "POST",
        f"{api_base}/auth/auto-login",
        json={
            "account": account,
            "encryptedPassword": base64.b64encode(encrypted).decode(),
            "keyId": pk["keyId"],
        },
        headers={"Content-Type": "application/json"},
        timeout=120,
    )
    sid = data.get("sessionId", "")
    if not sid:
        raise RuntimeError(f"登录失败: {data.get('detail', '未返回 sessionId')}")
    return sid


def auth_headers(session_id: str) -> dict[str, str]:
    return {"X-Session-Id": session_id, "User-Agent": USER_AGENT}


def search_rooms(api_base: str, session_id: str, keyword: str, limit: int) -> list[dict[str, Any]]:
    t0 = time.time()
    params: dict[str, Any] = {"limit": limit}
    if keyword:
        params["q"] = keyword

    rooms = request_json(
        "GET",
        f"{api_base}/ecard/rooms",
        params=params,
        headers=auth_headers(session_id),
        timeout=90,
    )
    elapsed = time.time() - t0

    print(f"找到 {len(rooms)} 间宿舍 ({elapsed:.1f}s)")
    for room in rooms:
        print(f"  {room['displayName']}")
        print(f"    id={room['id']}")
    return rooms


def bind_room(api_base: str, session_id: str, room_id: str, room_display: str) -> dict[str, Any]:
    print(f"\n绑定宿舍并查询余额: {room_display or room_id}")
    return request_json(
        "POST",
        f"{api_base}/ecard/binding",
        json={"roomId": room_id, "roomDisplay": room_display or room_id},
        headers=auth_headers(session_id),
        timeout=90,
    )


def refresh_summary(api_base: str, session_id: str) -> dict[str, Any]:
    print("\n刷新当前绑定宿舍余额...")
    return request_json(
        "POST",
        f"{api_base}/ecard/refresh",
        json={},
        headers=auth_headers(session_id),
        timeout=90,
    )


def print_summary(summary: dict[str, Any]) -> None:
    if summary.get("status") == "not_bound":
        print("余额: 未绑定宿舍")
        return

    print(f"余额宿舍: {summary.get('roomDisplay') or summary.get('roomId') or '?'}")
    print(f"  电费: {summary.get('powerText') or '-'}")
    print(f"  冷水: {summary.get('coldWaterText') or '-'}")
    print(f"  热水: {summary.get('hotWaterText') or '-'}")
    print(f"  更新时间: {summary.get('updatedAt') or '-'}")


def main() -> int:
    args = parse_args()
    api_base = normalize_api_base(args.api_base)

    if not args.account or not args.password:
        print(
            "缺少登录凭据：请传 --account/--password，或设置 "
            "ONEGZUS_ACCOUNT/ONEGZUS_PASSWORD（兼容 GZUS_TEST_ACCOUNT/GZUS_TEST_PASSWORD）。",
            file=sys.stderr,
        )
        return 2

    print("=" * 50)
    print("软帮手一卡通冒烟测试")
    print("=" * 50)
    print(f"API: {api_base}")

    print("\n登录中...")
    sid = login(api_base, args.account, args.password)
    print(f"登录成功 (sessionId={sid[:16]}...)")

    print(f"\n搜索宿舍 (q={args.keyword!r}, limit={args.limit}):")
    rooms = search_rooms(api_base, sid, args.keyword, args.limit)

    if args.no_bind:
        summary = refresh_summary(api_base, sid)
    else:
        selected = None
        if args.room_id:
            selected = {"id": args.room_id, "displayName": args.room_display or args.room_id}
        elif rooms:
            selected = rooms[0]

        if selected is None:
            print("\n未找到可用于余额查询的宿舍；可用 --room-id 指定。", file=sys.stderr)
            return 1
        summary = bind_room(api_base, sid, selected["id"], selected.get("displayName", ""))

    print_summary(summary)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except requests.RequestException as exc:
        print(f"请求失败: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
    except RuntimeError as exc:
        print(str(exc), file=sys.stderr)
        raise SystemExit(1) from exc
