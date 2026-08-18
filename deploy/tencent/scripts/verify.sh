#!/usr/bin/env bash
# ============================================================
# 软帮手 OneGZUS — 上线前验证脚本（在【本地】执行）
#
# 用法：bash verify.sh https://你的域名
# 说明：域名解析未切换时，可先用 hosts 文件指向服务器 IP 再运行
# ============================================================
set -uo pipefail

BASE_URL="${1:?用法: bash verify.sh https://你的域名}"
BASE_URL="${BASE_URL%/}"

FAIL=0
check() {
  local desc="$1" url="$2" expect="$3"
  local code content_type
  code="$(curl -sS -m 15 -o /tmp/onegzus-verify -w '%{http_code}' "$url" 2>/dev/null || echo 000)"
  content_type="$(curl -sSI -m 15 "$url" 2>/dev/null | grep -i '^content-type:' | tail -1 | tr -d '\r' | cut -d: -f2- | xargs)"
  if [[ "$code" == "200" ]] && echo "$content_type" | grep -qi "$expect"; then
    echo "  ✔ $desc ($url -> $content_type)"
  else
    echo "  ✘ $desc ($url -> HTTP $code, Content-Type: $content_type)" >&2
    FAIL=1
  fi
}

echo "==> 验证 $BASE_URL"

echo "---- 后端 ----"
check "API 健康检查"            "$BASE_URL/api/health"              "json"

echo "---- 静态资源 ----"
check "Flutter 主入口"          "$BASE_URL/main.dart.js"             "javascript"
check "Flutter 引导"            "$BASE_URL/flutter_bootstrap.js"     "javascript"
check "PWA 脚本"                "$BASE_URL/gzus_pwa.js"             "javascript"
check "PWA Service Worker"      "$BASE_URL/gzus_pwa_sw.js"           "javascript"
check "Manifest"                "$BASE_URL/manifest.json"            "json"
check "CanvasKit JS"            "$BASE_URL/canvaskit/canvaskit.js"   "javascript"
check "CanvasKit WASM"          "$BASE_URL/canvaskit/canvaskit.wasm" "wasm"
check "应用图标"                "$BASE_URL/icons/icon-192x192.png"   "png"

echo "---- 安全响应头 ----"
for h in "strict-transport-security" "x-content-type-options" "x-frame-options" "referrer-policy"; do
  if curl -sSI -m 15 "$BASE_URL/" | grep -qi "^$h:"; then
    echo "  ✔ $h"
  else
    echo "  ✘ 缺少 $h" >&2
    FAIL=1
  fi
done

echo "---- SPA 回退 ----"
code="$(curl -sS -m 15 -o /dev/null -w '%{http_code}' "$BASE_URL/some/spa/route" 2>/dev/null || echo 000)"
if [[ "$code" == "200" ]]; then echo "  ✔ SPA 回退返回 200"; else echo "  ✘ SPA 回退 HTTP $code" >&2; FAIL=1; fi

echo ""
if [[ "$FAIL" -eq 0 ]]; then
  echo "全部通过 ✔"
else
  echo "存在失败项，请排查（nginx 日志：journalctl -u nginx / tail /var/log/nginx/error.log）" >&2
  exit 1
fi
