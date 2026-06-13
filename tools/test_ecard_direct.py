"""
直连学校一卡通 API 查询水电费脚本
用法: python test_ecard_direct.py <OPENID> [房间关键词]

示例:
  python test_ecard_direct.py o6gXt5YdtSc-15PgJg0KqAXZytRc
  python test_ecard_direct.py o6gXt5YdtSc-15PgJg0KqAXZytRc J1

依赖: pip install requests
"""

import sys, json, time, hashlib

ECARD_BASE = "https://ecarduser.gzus.edu.cn"
WX_UA = (
    "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) "
    "AppleWebKit/605.1.15 (KHTML, like Gecko) "
    "Mobile/15E148 MicroMessenger/8.0.38 NetType/WIFI Language/zh_CN"
)
ROOM_IMPL_TYPES = ("CGCOMMON1111", "CGCOMMON2222", "CGCOMMON3333")


def calc_sign(params: dict) -> str:
    """计算 ecard API 签名 MD5(sorted_params + '&')"""
    filtered = {k: v for k, v in params.items() if k not in ("token", "sign")}
    raw = "&".join(f"{k}={filtered[k]}" for k in sorted(filtered)) + "&"
    return hashlib.md5(raw.encode()).hexdigest().upper()


def post_api(path: str, params: dict, openid: str,
             unionid: str = "", token: str = "", timeout: int = 15) -> dict:
    """调用 ecard API"""
    import requests

    payload = dict(params)
    payload.setdefault("from", "wxminiprogram")
    payload.setdefault("isWxEnterpriseXcx", "false")
    payload.setdefault("wxRequest", "wxRequest")
    payload["openid"] = openid
    if unionid:
        payload["unionid"] = unionid
    if token:
        payload["token"] = token
    payload["sign"] = calc_sign(payload)

    url = f"{ECARD_BASE.rstrip('/')}/{path.lstrip('/')}"
    headers = {
        "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8",
        "User-Agent": WX_UA,
    }
    resp = requests.post(url, data=payload, headers=headers, timeout=timeout)
    resp.raise_for_status()
    data = resp.json()
    if not isinstance(data, dict):
        raise RuntimeError(f"API 返回非 JSON: {type(data)}")
    return data


def login(openid: str, unionid: str = "") -> dict:
    """登录 ecard，返回 {token, unionid, ...}"""
    data = post_api("/user/routine/routine-login",
                    {"from": "wxminiprogram"}, openid, unionid)
    token = data.get("token")
    if data.get("code") == 200 and token:
        result = {"token": str(token)}
        if data.get("unionid"):
            result["unionid"] = str(data["unionid"])
        print(f"登录成功 token={token[:16]}...")
        return result
    raise RuntimeError(f"登录失败 code={data.get('code')} msg={data.get('msg', data)}")


def get_rooms(openid: str, token: str, unionid: str = "") -> list[dict]:
    """获取全部宿舍房间列表（3 种 implType 去重）"""
    from concurrent.futures import ThreadPoolExecutor, as_completed

    def fetch(impl_type):
        data = post_api("/powerfee/getRoomInfo",
                        {"implType": impl_type}, openid, unionid, token)
        if data.get("ret") is not True and data.get("code") not in (0, 200):
            return []
        obj = data.get("obj") or []
        return obj if isinstance(obj, list) else [obj]

    all_rooms = []
    with ThreadPoolExecutor(max_workers=3) as pool:
        futures = [pool.submit(fetch, t) for t in ROOM_IMPL_TYPES]
        for f in as_completed(futures):
            try:
                all_rooms.extend(f.result())
            except Exception:
                pass

    seen = set()
    result = []
    for room in all_rooms:
        if not isinstance(room, dict):
            continue
        rid = f"{room.get('implType', '?')}|{room.get('schoolAreaNo', '')}|{room.get('buildingNo', '')}|{room.get('roomNum', '')}"
        if rid in seen or "||" in rid:
            continue
        seen.add(rid)
        result.append({
            "id": rid,
            "implType": room.get("implType", ""),
            "schoolAreaNo": room.get("schoolAreaNo", ""),
            "buildingNo": room.get("buildingNo", ""),
            "roomNum": room.get("roomNum", ""),
            "schoolArea": str(room.get("schoolArea", "")),
            "building": str(room.get("building", "")),
            "room": str(room.get("room", "")).replace("#", "-"),
            "displayName": f"{room.get('schoolArea', '')} {room.get('building', '')} {str(room.get('room', '') or room.get('roomNum', '')).replace('#', '-')}".strip(),
        })
    result.sort(key=lambda r: r["displayName"])
    return result


def get_balance(room: dict, openid: str, token: str, unionid: str = "") -> dict:
    """查询指定宿舍水电费余额"""
    data = post_api("/powerfee/getBalance", {
        "implType": room["implType"],
        "schoolAreaNo": room["schoolAreaNo"],
        "buildingNo": room["buildingNo"],
        "roomNum": room["roomNum"],
    }, openid, unionid, token)

    obj = data.get("obj") or {}
    return {
        "房间": room["displayName"],
        "电费余额": obj.get("powerBalance", "?"),
        "冷水余额": obj.get("waterBalance", "?"),
        "热水余额": obj.get("hotWaterBalance", "?"),
        "电费": obj.get("formatPowerBalanceStr", ""),
        "冷水": obj.get("formatWaterBalanceStr", ""),
        "热水": obj.get("formatHotWaterBalanceStr", ""),
    }


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    openid = sys.argv[1]
    keyword = sys.argv[2] if len(sys.argv) > 2 else ""

    print("=" * 50)
    print("直连 ecard 水电费查询")
    print(f"OPENID: {openid}")
    print("=" * 50)

    # Step 1: 登录
    print("\n[1/4] 登录 ecard API...")
    t0 = time.time()
    try:
        auth = login(openid)
    except Exception as e:
        print(f"失败: {e}")
        sys.exit(1)
    print(f"      耗时 {time.time() - t0:.1f}s")

    # Step 2: 获取房间列表
    print("\n[2/4] 获取宿舍列表（3 路并行）...")
    t0 = time.time()
    try:
        rooms = get_rooms(openid, auth["token"], auth.get("unionid", ""))
    except Exception as e:
        print(f"失败: {e}")
        sys.exit(1)
    print(f"      共 {len(rooms)} 间，耗时 {time.time() - t0:.1f}s")

    # Step 3: 筛选
    if keyword:
        kw = keyword.lower()
        filtered = [r for r in rooms if
                    kw in r["displayName"].lower()
                    or kw in r["building"].lower()
                    or kw in r["room"].lower()
                    or kw in r["schoolArea"].lower()]
        print(f"\n[3/4] 搜索 '{keyword}': {len(filtered)} 间")
        rooms = filtered[:20]
    else:
        print(f"\n[3/4] 显示前 10 间:")
        rooms = rooms[:10]

    for r in rooms:
        print(f"  {r['displayName']}")

    # Step 4: 查询余额（第一间）
    if rooms:
        print(f"\n[4/4] 查询 '{rooms[0]['displayName']}' 水电费...")
        t0 = time.time()
        try:
            balance = get_balance(rooms[0], openid, auth["token"], auth.get("unionid", ""))
            print(f"      耗时 {time.time() - t0:.1f}s\n")
            for k, v in balance.items():
                print(f"  {k}: {v}")
        except Exception as e:
            print(f"      失败: {e}")

    print(f"\n完成！")


if __name__ == "__main__":
    main()
