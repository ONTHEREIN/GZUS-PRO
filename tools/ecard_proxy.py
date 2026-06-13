"""
ecard 本地 HTTP 代理 — 让 Web 端也能用宿舍搜索/水电费

启动: python ecard_proxy.py
端口: 8765
然后 Web 端通过 http://localhost:8765/ 调用 ecard API

工作流程:
  浏览器 → http://localhost:8765/rooms → 本机直连 ecarduser.gzus.edu.cn → 返回结果
"""

import hashlib, json, sys, urllib.parse
from http.server import HTTPServer, BaseHTTPRequestHandler
import requests

BASE = "https://ecarduser.gzus.edu.cn"
SECRET = "greatge"
OPENID = "o6gXt5YdtSc-15PgJg0KqAXZytRc"
WX_UA = ("Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) "
         "AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 "
         "MicroMessenger/8.0.38 NetType/WIFI Language/zh_CN")

_token = None
_unionid = None


def md5(s): return hashlib.md5(s.encode()).hexdigest()


def sign(params):
    f = {k: v for k, v in params.items() if k not in ("token", "sign")}
    return md5("&".join(f"{k}={f[k]}" for k in sorted(f)) + "&" + SECRET).upper()


def login():
    global _token, _unionid
    p = {"from": "wxminiprogram", "isWxEnterpriseXcx": "false",
         "wxRequest": "wxRequest", "openid": OPENID}
    p["sign"] = sign(p)
    r = requests.post(f"{BASE}/user/routine/routine-login", data=p,
                      headers={"Content-Type": "application/x-www-form-urlencoded", "User-Agent": WX_UA},
                      timeout=15, verify=False)
    d = r.json()
    if d.get("code") == 200 and d.get("token"):
        _token = str(d["token"])
        _unionid = str(d.get("unionid", ""))
        return True
    return False


def post(path, params=None):
    global _token
    if _token is None:
        login()
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
                      headers={"Content-Type": "application/x-www-form-urlencoded", "User-Agent": WX_UA},
                      timeout=20, verify=False)
    return r.json()


class Handler(BaseHTTPRequestHandler):
    def _cors(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")

    def do_OPTIONS(self):
        self.send_response(204)
        self._cors()
        self.end_headers()

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path.lstrip("/")
        params = dict(urllib.parse.parse_qsl(parsed.query))

        if path == "health":
            self._json({"status": "ok", "token": bool(_token)})
            return

        if path == "rooms":
            result = []
            seen = set()
            for impl in ("CGCOMMON1111", "CGCOMMON2222", "CGCOMMON3333"):
                d = post("powerfee/getRoomInfo", {"implType": impl})
                obj = d.get("obj", [])
                for room in (obj if isinstance(obj, list) else [obj] if isinstance(obj, dict) else []):
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
                    })
            result.sort(key=lambda r: r["displayName"])
            q = params.get("q", "").lower()
            limit = int(params.get("limit", 100))
            if q:
                result = [r for r in result if q in r["displayName"].lower() or q in r["building"].lower() or q in r["room"].lower()]
            self._json(result[:limit])
            return

        if path == "balance":
            room_id = params.get("roomId", "")
            parts = room_id.split("|")
            if len(parts) != 4:
                self._json({"error": "need roomId param like implType|area|building|room"}, 400)
                return
            d = post("powerfee/getBalance", {"implType": parts[0], "schoolAreaNo": parts[1],
                     "buildingNo": parts[2], "roomNum": parts[3]})
            self._json(d.get("obj", d))
            return

        self._json({"error": f"unknown path: {path}"}, 404)

    def _json(self, data, status=200):
        self.send_response(status)
        self._cors()
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.end_headers()
        self.wfile.write(json.dumps(data, ensure_ascii=False).encode())


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
    print(f"ecard proxy 启动: http://localhost:{port}")
    print(f"  GET /health  — 健康检查")
    print(f"  GET /rooms?q=A2&limit=5  — 搜索宿舍")
    print(f"  GET /balance?roomId=CGCOMMON1111|1|J1|123  — 查水电费")
    HTTPServer(("0.0.0.0", port), Handler).serve_forever()
