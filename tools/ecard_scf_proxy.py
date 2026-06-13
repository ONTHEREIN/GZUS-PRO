"""
ecard 腾讯云函数代理 — 一键部署，Web 端可用
免费额度: 每月100万次调用，完全够用

部署步骤:
1. 打开 https://console.cloud.tencent.com/scf/list
2. 创建函数 → 从头开始 → Python 3.9 → 粘贴此文件
3. 触发器: API 网关触发器 → 路径 /ecard → 启用 CORS
4. 获得公网 URL: https://service-xxx.gz.apigw.tencentcs.com/release/ecard
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
            rid = f"{room.get('implType','')}|{room.get('schoolAreaNo','')}|{room.get('buildingNo','')}|{room.get('roomNum','')}"
            if rid in seen or "||" in rid:
                continue
            seen.add(rid)
            result.append({
                "id": rid,
                "displayName": f"{room.get('schoolArea','')} {room.get('building','')} {(room.get('room','') or room.get('roomNum','')).replace('#','-')}".strip(),
                "schoolArea": str(room.get("schoolArea", "")),
                "building": str(room.get("building", "")),
                "room": str(room.get("room", "")).replace("#", "-"),
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
        return {"error": "need roomId=implType|area|building|room"}
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


# ─── 腾讯云函数入口 ───
def main_handler(event, context):
    params = event.get("queryString", event.get("queryStringParameters", {}))
    path = event.get("path", "").rstrip("/")
    action = params.get("action", path.strip("/") or "rooms")
    query = params.get("q", "")
    limit = int(params.get("limit", 100))
    room_id = params.get("roomId", "")

    try:
        if action in ("rooms", ""):
            data = rooms(query, limit)
        elif action == "balance":
            data = balance(room_id)
        elif action == "health":
            data = {"status": "ok"}
        else:
            data = {"error": f"unknown action: {action}"}
    except Exception as e:
        data = {"error": str(e)}

    return {
        "isBase64Encoded": False,
        "statusCode": 200,
        "headers": {
            "Content-Type": "application/json",
            "Access-Control-Allow-Origin": "*",
        },
        "body": json.dumps(data, ensure_ascii=False),
    }
