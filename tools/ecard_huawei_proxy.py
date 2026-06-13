"""
ecard 华为云 FunctionGraph 代理 — 免费额度充足，中国 IP 直达
部署: 华为云控制台 → 函数工作流 FunctionGraph → 创建函数
  运行时: Python 3.9+
  函数入口: ecard_huawei_proxy.handler
  触发器: API 网关 (APIG) → 开启 CORS
  内存: 128 MB (免费额度最优)
"""

import hashlib, json, urllib.parse

BASE = "https://ecarduser.gzus.edu.cn"
SECRET = "greatge"
OPENID = "o6gXt5YdtSc-15PgJg0KqAXZytRc"
UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148 MicroMessenger/8.0.38"

_token = None
_unionid = None


def md5(s):
    return hashlib.md5(s.encode()).hexdigest()


def sign(params):
    f = {k: v for k, v in params.items() if k not in ("token", "sign")}
    return md5("&".join(f"{k}={f[k]}" for k in sorted(f)) + "&" + SECRET).upper()


def login():
    global _token, _unionid
    import requests
    p = {"from": "wxminiprogram", "isWxEnterpriseXcx": "false",
         "wxRequest": "wxRequest", "openid": OPENID}
    p["sign"] = sign(p)
    r = requests.post(BASE + "/user/routine/routine-login", data=p,
                      headers={"Content-Type": "application/x-www-form-urlencoded", "User-Agent": UA},
                      timeout=10, verify=False)
    d = r.json()
    if d.get("code") == 200 and d.get("token"):
        _token = d["token"]
        _unionid = d.get("unionid", "")
        return True
    return False


def post(path, params=None):
    global _token
    if not _token:
        login()
    import requests
    p = dict(params or {})
    p.setdefault("from", "wxminiprogram")
    p.setdefault("isWxEnterpriseXcx", "false")
    p.setdefault("wxRequest", "wxRequest")
    p["openid"] = OPENID
    if _unionid:
        p["unionid"] = _unionid
    if _token:
        p["token"] = _token
    p["sign"] = sign(p)
    r = requests.post(f"{BASE}/{path}", data=p,
                      headers={"Content-Type": "application/x-www-form-urlencoded", "User-Agent": UA},
                      timeout=15, verify=False)
    return r.json()


def rooms(query="", limit=100):
    result, seen = [], set()
    for impl in ("CGCOMMON1111", "CGCOMMON2222", "CGCOMMON3333"):
        d = post("powerfee/getRoomInfo", {"implType": impl})
        for room in (d.get("obj") or []):
            if not isinstance(room, dict):
                continue
            rid = f"{room.get('implType') or impl}|{room.get('schoolAreaNo','')}|{room.get('buildingNo','')}|{room.get('roomNum','')}"
            if rid in seen or "||" in rid:
                continue
            seen.add(rid)
            result.append({
                "id": rid,
                "displayName": f"{room.get('schoolArea','')} {room.get('building','')} {(room.get('room','') or room.get('roomNum','')).replace('#','-')}".strip(),
                "schoolArea": str(room.get("schoolArea", "")),
                "building": str(room.get("building", "")),
                "room": str(room.get("room", "")).replace("#", "-"),
                "implType": room.get("implType") or impl,
                "schoolAreaNo": room.get("schoolAreaNo", ""),
                "buildingNo": room.get("buildingNo", ""),
                "roomNum": room.get("roomNum", ""),
            })
    result.sort(key=lambda r: r["displayName"])
    q = query.lower()
    if q:
        result = [r for r in result if q in r["displayName"].lower()
                   or q in r["building"].lower() or q in r["room"].lower()]
    return result[:limit]


def balance(room_id):
    parts = room_id.split("|")
    if len(parts) != 4:
        return {"error": "need roomId=implType|areaNo|buildingNo|roomNum"}
    d = post("powerfee/getBalance",
             {"implType": parts[0], "schoolAreaNo": parts[1],
              "buildingNo": parts[2], "roomNum": parts[3]})
    obj = d.get("obj", {})
    return {
        "powerBalance": obj.get("powerBalance"),
        "waterBalance": obj.get("waterBalance"),
        "hotWaterBalance": obj.get("hotWaterBalance"),
        "powerText": obj.get("formatPowerBalanceStr", ""),
        "waterText": obj.get("formatWaterBalanceStr", ""),
        "hotWaterText": obj.get("formatHotWaterBalanceStr", ""),
    }


# ─── 华为云 FunctionGraph HTTP 函数入口 ───
def handler(event, context):
    """HTTP 触发器入口 (APIG)"""
    # 华为云 APIG 传入的 event 结构
    query = event.get("queryStringParameters", {}) or {}
    path = (event.get("path") or "").strip("/")
    action = query.get("action", path or "rooms")

    cors_headers = {
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
        "Access-Control-Allow-Headers": "Content-Type",
        "Content-Type": "application/json; charset=utf-8",
    }

    if event.get("httpMethod") == "OPTIONS":
        return {"statusCode": 204, "headers": cors_headers, "body": ""}

    try:
        if action in ("rooms", ""):
            data = rooms(query.get("q", ""), int(query.get("limit", 100)))
        elif action == "balance":
            data = balance(query.get("roomId", ""))
        elif action == "health":
            data = {"status": "ok", "service": "华为云 FunctionGraph"}
        else:
            data = {"error": f"unknown: {action}"}
    except Exception as e:
        data = {"error": str(e)}

    return {
        "statusCode": 200 if "error" not in data else 500,
        "headers": cors_headers,
        "body": json.dumps(data, ensure_ascii=False),
    }
