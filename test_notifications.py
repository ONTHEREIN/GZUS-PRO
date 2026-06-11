#!/usr/bin/env python3
"""通知类型全量测试脚本
用法: python test_notifications.py [--base http://localhost:8001]
"""

import sys, json, time, urllib.request, urllib.error

BASE = "http://localhost:8001"  # 默认本地后端
TOKEN = None  # 有 session 后可填入


def req(method, path, body=None):
    """发送 HTTP 请求"""
    url = f"{BASE}{path}"
    data = json.dumps(body).encode() if body else None
    r = urllib.request.Request(url, data=data, method=method)
    r.add_header("Content-Type", "application/json")
    if TOKEN:
        r.add_header("X-Session-Id", TOKEN)
    try:
        with urllib.request.urlopen(r, timeout=10) as resp:
            return resp.status, json.loads(resp.read())
    except urllib.error.HTTPError as e:
        return e.code, {"error": e.reason, "body": e.read().decode()[:200]}


def step(label):
    print(f"\n{'='*50}")
    print(f"  {label}")
    print(f"{'='*50}")


# ── 1. 获取 session ──
step("1. 创建测试 session")
status, data = req("POST", "/push/test-session")
print(f"  状态: {status}")
print(f"  响应: {json.dumps(data, ensure_ascii=False)}")
if status == 200 and data.get("sessionId"):
    global TOKEN
    TOKEN = data["sessionId"]
    print(f"  ✅ sessionId: {TOKEN[:16]}...")
else:
    print("  ⚠️  test-session 仅在 debug 模式下可用，尝试手动提供 session")
    TOKEN = input("  请输入 sessionId (或回车跳过): ").strip()
    if not TOKEN:
        print("  已跳过，无法继续测试 /push/test")
        sys.exit(1)

# ── 2. 发送各类通知 ──
tests = [
    {
        "name": "普通通知",
        "body": {"title": "🔔 普通通知", "body": "这是一条普通推送通知", "type": "new_notice"},
    },
    {
        "name": "带链接通知",
        "body": {"title": "📎 带链接通知", "body": "点击查看详情", "url": "https://onegzus.pages.dev", "type": "new_notice"},
    },
    {
        "name": "成绩更新通知",
        "body": {"title": "📊 成绩已更新", "body": "高等数学 95分", "type": "grade_update"},
    },
    {
        "name": "Live Update - 倒计时",
        "body": {
            "title": "⏱ 下一节课",
            "body": "大学英语 14:00 开始",
            "type": "course_reminder",
            "liveUpdate": True,
            "style": "timer",
            "endTime": int(time.time() * 1000) + 25 * 60 * 1000,  # 25分钟后
            "shortCriticalText": "25min",
        },
    },
    {
        "name": "Live Update - 进度条",
        "body": {
            "title": "📥 数据同步中",
            "body": "正在同步课表数据...",
            "type": "new_notice",
            "liveUpdate": True,
            "style": "progress",
            "progressMax": 100,
            "progressCurrent": 45,
            "shortCriticalText": "45%",
        },
    },
    {
        "name": "Live Update - 指标",
        "body": {
            "title": "⚡ 电费余额",
            "body": "当前余额较低",
            "type": "ecard_reminder",
            "liveUpdate": True,
            "style": "metric",
            "shortCriticalText": "¥12.5",
        },
    },
    {
        "name": "考试提醒",
        "body": {"title": "📝 考试提醒", "body": "高等数学 明天 9:00-11:00", "type": "exam_reminder"},
    },
]

step("2. 发送各类通知")
for i, t in enumerate(tests):
    print(f"\n  [{i+1}/{len(tests)}] {t['name']}")
    status, resp = req("POST", "/push/test", body=t["body"])
    ok = status == 200 and resp.get("status") == "ok"
    mark = "✅" if ok else "❌"
    print(f"      {mark} HTTP {status} — {json.dumps(resp, ensure_ascii=False)}")
    if i < len(tests) - 1:
        time.sleep(0.3)  # 避免挤在一起

# ── 3. 轮询检查 ──
step("3. 轮询拉取消息")
status, data = req("GET", "/push/poll")
print(f"  状态: {status}")
if status == 200:
    msgs = data.get("messages", [])
    print(f"  待消费消息数: {len(msgs)}")
    for m in msgs[:5]:
        print(f"    - [{m.get('type')}] {m.get('title')}: {m.get('body')[:40]}")
    if len(msgs) > 5:
        print(f"    ... 还有 {len(msgs)-5} 条")

# ── 4. 配置检查 ──
step("4. Web Push 配置检查")
status, data = req("GET", "/push/web/config")
print(f"  状态: {status}")
print(f"  响应: {json.dumps(data, ensure_ascii=False)}")

print(f"\n{'='*50}")
print(f"  测试完成 ✅")
print(f"{'='*50}")
