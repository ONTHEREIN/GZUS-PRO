#!/usr/bin/env bash
# ============================================================
# 软帮手 OneGZUS — 前端部署脚本（在服务器上以 root / sudo 运行）
#
# 前置：本地已执行
#   rsync -avz --delete apps/mobile_web/build/web/ onegzus@SERVER_IP:/tmp/onegzus-web/
# 用法：bash /opt/onegzus/deploy/scripts/deploy_frontend.sh
#
# 功能：把 /tmp/onegzus-web/ 同步到 /opt/onegzus/web/ 并 reload nginx
# ============================================================
set -euo pipefail

SRC="/tmp/onegzus-web"
DST="/opt/onegzus/web"

if [[ ! -d "$SRC" || ! -f "$SRC/index.html" ]]; then
  echo "错误：$SRC 中没有 index.html。请先在本地构建并 rsync（README 第 5 节）" >&2
  exit 1
fi

if [[ "$(id -u)" -ne 0 ]]; then
  echo "错误：请以 root 运行：sudo bash deploy_frontend.sh" >&2
  exit 1
fi

echo "==> 同步静态产物 -> $DST"
rsync -a --delete "$SRC/" "$DST/"
chown -R onegzus:onegzus "$DST"

echo "==> 检查并重载 nginx"
nginx -t
systemctl reload nginx

echo "==> 本机自检"
for path in index.html main.dart.js flutter_bootstrap.js manifest.json canvaskit/canvaskit.js canvaskit/canvaskit.wasm; do
  if [[ -f "$DST/$path" ]]; then
    echo "    ✔ /$path"
  else
    echo "    ✘ /$path 缺失（请检查构建产物）" >&2
  fi
done

echo "完成！外网验证：bash /opt/onegzus/deploy/scripts/verify.sh https://你的域名"
