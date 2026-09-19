#!/usr/bin/env bash
# 测试环境接口冒烟：演示账号登录 + 六个只读接口 + 凭据字段检查 + 退出后会话失效。
#
# 用法：
#   smoke_test_api.sh                          # 默认打本机 8001（DNS/证书就绪前）
#   smoke_test_api.sh https://test-api.onegzus.onrein.top/api   # 打公网测试域名
#
# 凭据只从环境文件读取，绝不打印密码或会话 ID。
set -euo pipefail

BASE="${1:-http://127.0.0.1:8001}"
ENV_FILE="${ENV_FILE:-/opt/onegzus-test/shared/api.env}"
PY="${PY:-/opt/onegzus-test/current/api/.venv/bin/python}"

[[ -f "$ENV_FILE" ]] || { echo "✖ 找不到 $ENV_FILE" >&2; exit 1; }
[[ -x "$PY" ]] || { echo "✖ 找不到测试环境解释器 $PY" >&2; exit 1; }

DEMO_ACCOUNT="$(sed -nE 's/^DEMO_ACCOUNT=(.*)$/\1/p' "$ENV_FILE")"
DEMO_PASSWORD="$(sed -nE 's/^DEMO_PASSWORD=(.*)$/\1/p' "$ENV_FILE")"
[[ -n "$DEMO_ACCOUNT" && -n "$DEMO_PASSWORD" ]] || { echo "✖ 环境文件缺少演示账号" >&2; exit 1; }

pass=0; fail=0
ok()   { printf '✔ %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '✖ %s\n' "$1"; fail=$((fail+1)); }

# ─── 登录 ───────────────────────────────────────────────────────────
LOGIN_BODY="$(DEMO_ACCOUNT="$DEMO_ACCOUNT" DEMO_PASSWORD="$DEMO_PASSWORD" "$PY" - <<'PYEOF'
import json, os
print(json.dumps({"account": os.environ["DEMO_ACCOUNT"], "password": os.environ["DEMO_PASSWORD"]}))
PYEOF
)"

LOGIN="$(curl -sS --max-time 20 -X POST "$BASE/mini/auth/login" \
  -H 'Content-Type: application/json' -d "$LOGIN_BODY" -w '\n%{http_code}')"
LOGIN_CODE="$(printf '%s' "$LOGIN" | tail -1)"
LOGIN_JSON="$(printf '%s' "$LOGIN" | sed '$d')"

if [[ "$LOGIN_CODE" != "200" ]]; then
  bad "演示账号登录失败（HTTP $LOGIN_CODE）：$(printf '%s' "$LOGIN_JSON" | head -c 200)"
  echo; echo "结果：$pass 通过 / $fail 失败"; exit 1
fi

read -r SESSION SAFE < <(printf '%s' "$LOGIN_JSON" | "$PY" -c '
import json,sys
d=json.load(sys.stdin)
print(d.get("sessionId",""), "yes" if set(d)=={"status","sessionId","studentName","studentId"} else "no")
')

[[ -n "$SESSION" ]] && ok "演示账号登录成功" || bad "登录响应缺少 sessionId"
[[ "$SAFE" == "yes" ]] && ok "登录响应只含四个安全字段" || bad "登录响应字段不符合预期（应为 status/sessionId/studentName/studentId）"

# ─── 六个只读接口 ───────────────────────────────────────────────────
for endpoint in /me /schedule /grades /exams /notices /ecard/summary; do
  code="$(curl -sS -o /tmp/smoke_body.json -w '%{http_code}' --max-time 20 \
    "$BASE$endpoint" -H "X-Session-Id: $SESSION")"
  if [[ "$code" == "200" ]]; then
    ok "GET $endpoint → 200"
  else
    bad "GET $endpoint → $code"
  fi
done

# ─── 响应不得夹带凭据 ───────────────────────────────────────────────
LEAK="$(curl -sS --max-time 20 "$BASE/me" -H "X-Session-Id: $SESSION" \
  | grep -ioE "credentialToken|jwxtCookies|ehallAuthToken|password" || true)"
[[ -z "$LEAK" ]] && ok "响应未夹带凭据字段" || bad "响应出现敏感字段：$LEAK"

# ─── 退出后会话失效 ─────────────────────────────────────────────────
curl -sS -o /dev/null --max-time 20 -X POST "$BASE/auth/logout" -H "X-Session-Id: $SESSION" || true
code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "$BASE/me" -H "X-Session-Id: $SESSION")"
[[ "$code" == "401" ]] && ok "退出登录后会话已失效（401）" || bad "退出登录后仍可访问（$code）"

echo
echo "结果：$pass 通过 / $fail 失败"
[[ "$fail" == "0" ]]
