"""
OneGZUS 宿舍搜索测试脚本
用法: python test_ecard.py [关键词] [数量]

示例:
  python test_ecard.py           # 搜索 A2，显示前 5 条
  python test_ecard.py J1 10     # 搜索 J1，显示前 10 条
  python test_ecard.py "" 20     # 无关键词，显示前 20 条

依赖: pip install requests cryptography
"""

import sys, json, time, base64
import requests
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import padding

ACCOUNT = "2540232101"
PASSWORD = "Limuliseig423."
API_BASE = "https://onegzus-onweb.pages.dev/api"


def login():
    """通过 RSA 加密密码自动登录，返回 sessionId"""
    pk = requests.get(
        f"{API_BASE}/auth/public-key",
        headers={"User-Agent": "OneGZUS/1.0"},
        timeout=15,
    ).json()

    public_key = serialization.load_pem_public_key(pk["publicKey"].encode())
    encrypted = public_key.encrypt(PASSWORD.encode("utf-8"), padding.PKCS1v15())

    resp = requests.post(
        f"{API_BASE}/auth/auto-login",
        json={
            "account": ACCOUNT,
            "encryptedPassword": base64.b64encode(encrypted).decode(),
            "keyId": pk["keyId"],
        },
        headers={"Content-Type": "application/json", "User-Agent": "OneGZUS/1.0"},
        timeout=120,
    )
    data = resp.json()
    sid = data.get("sessionId", "")
    if not sid:
        print(f"登录失败: {data.get('detail', '未知错误')}")
        sys.exit(1)
    return sid


def search_rooms(session_id, keyword="A2", limit=5):
    """搜索宿舍"""
    t0 = time.time()
    params = {"limit": limit}
    if keyword:
        params["q"] = keyword

    resp = requests.get(
        f"{API_BASE}/ecard/rooms",
        params=params,
        headers={"X-Session-Id": session_id, "User-Agent": "OneGZUS/1.0"},
        timeout=90,
    )
    elapsed = time.time() - t0

    if resp.status_code != 200:
        data = resp.json() if resp.text else {"detail": "empty response"}
        print(f"请求失败 HTTP {resp.status_code} ({elapsed:.1f}s): {data.get('detail', '?')}")
        return False

    rooms = resp.json()
    print(f"找到 {len(rooms)} 间宿舍 ({elapsed:.1f}s)")
    for r in rooms:
        print(f"  {r['displayName']}")
        print(f"    id={r['id']}")
    return True


def test_me(session_id):
    """测试个人信息接口"""
    resp = requests.get(
        f"{API_BASE}/me",
        headers={"X-Session-Id": session_id, "User-Agent": "OneGZUS/1.0"},
        timeout=30,
    )
    me = resp.json()
    print(f"\n个人信息: {me.get('name', '?')} / {me.get('studentId', '?')}")
    photo = me.get("photoDataUrl", "")
    if photo and photo.startswith("data:image/"):
        print(f"照片: {photo.split(';')[0].split(':')[1]} base64 {len(photo.split(',')[1])}B")
    elif photo:
        print(f"照片: 非 base64 格式 ({photo[:60]}...)")
    else:
        print("照片: NULL")


def test_weather():
    """测试天气接口"""
    resp = requests.get(f"{API_BASE}/weather", timeout=15)
    w = resp.json()
    weeks = [f["week"] for f in w.get("forecast", [])]
    print(f"\n天气: {w['weather']} {w['temperature']}°C {w['district']}")
    print(f"预报: {', '.join(weeks)}")


if __name__ == "__main__":
    keyword = sys.argv[1] if len(sys.argv) > 1 else "A2"
    limit = int(sys.argv[2]) if len(sys.argv) > 2 else 5

    print("=" * 50)
    print("OneGZUS 宿舍搜索测试")
    print("=" * 50)

    print("\n登录中...")
    sid = login()
    print(f"登录成功 (sessionId={sid[:16]}...)")

    print(f"\n搜索宿舍 (q={keyword!r}, limit={limit}):")
    ok = search_rooms(sid, keyword, limit)

    if ok:
        test_me(sid)
        test_weather()
