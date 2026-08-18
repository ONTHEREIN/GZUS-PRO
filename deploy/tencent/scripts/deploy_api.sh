#!/usr/bin/env bash
# ============================================================
# 软帮手 OneGZUS — 后端部署脚本（在服务器上以 root / sudo 运行）
#
# 前置：services/api/ 已 rsync 到 /opt/onegzus/api/（README 第 4.1 节）
# 用法：bash /opt/onegzus/deploy/scripts/deploy_api.sh
#
# 功能：
#   1. 创建 .venv 并安装 requirements.txt
#   2. .env 不存在时从模板复制（之后必须手工编辑！）
#   3. 安装 systemd 单元并启动 onegzus-api
#   4. 健康检查
# ============================================================
set -euo pipefail

API_DIR="/opt/onegzus/api"
SERVICE_NAME="onegzus-api"
DEPLOY_DIR="/opt/onegzus/deploy"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "错误：请以 root 运行：sudo bash deploy_api.sh" >&2
  exit 1
fi

if [[ ! -d "$API_DIR" ]]; then
  echo "错误：$API_DIR 不存在。请先 rsync services/api/ 到服务器（README 第 4.1 节）" >&2
  exit 1
fi

echo "==> [1/4] 创建虚拟环境"
PYTHON_BIN=""
for cand in python3.12 python3.11 python3.10; do
  if command -v "$cand" >/dev/null 2>&1; then PYTHON_BIN="$cand"; break; fi
done
[[ -n "$PYTHON_BIN" ]] || { echo "错误：未找到 Python 3.10+，请先运行 setup_server.sh" >&2; exit 1; }

if [[ ! -x "$API_DIR/.venv/bin/python" ]]; then
  "$PYTHON_BIN" -m venv "$API_DIR/.venv"
fi

echo "==> [2/4] 安装依赖（ddddocr 首次安装较慢，请耐心等待）"
"$API_DIR/.venv/bin/pip" install --upgrade pip wheel setuptools
"$API_DIR/.venv/bin/pip" install -r "$API_DIR/requirements.txt"

echo "==> [3/4] 准备 .env"
if [[ ! -f "$API_DIR/.env" ]]; then
  cp "$DEPLOY_DIR/env/onegzus.env.example" "$API_DIR/.env"
  echo "    已从模板创建 $API_DIR/.env —— 请立即编辑填写真实值！"
  echo "    必改：DATABASE_URL / CREDENTIAL_ENCRYPTION_KEY / INTERNAL_API_KEY /"
  echo "          PUBLIC_API_BASE_URL / FRONTEND_BASE_URL / ADMIN_SEED_OWNER"
else
  echo "    .env 已存在，保留现有配置"
fi
chown -R onegzus:onegzus "$API_DIR"
# 权限收紧：.env 含密钥，仅属主/组可读（nginx 不需要读它）
chmod 750 "$API_DIR"
chmod 640 "$API_DIR/.env"

echo "==> [4/4] 安装 systemd 服务并启动"
cp "$DEPLOY_DIR/systemd/onegzus-api.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl restart "$SERVICE_NAME"

echo "==> 健康检查"
for i in $(seq 1 15); do
  if curl -fsS -m 5 http://127.0.0.1:8000/health 2>/dev/null | grep -q '"status":"ok"'; then
    echo "    ✔ 后端已就绪: $(curl -fsS -m 5 http://127.0.0.1:8000/health)"
    break
  fi
  sleep 2
  [[ $i -eq 15 ]] && { echo "    ✘ 后端未就绪，请查看日志：journalctl -u $SERVICE_NAME -f" >&2; exit 1; }
done

echo ""
echo "完成！后续操作："
echo "  1) 启动日志：journalctl -u $SERVICE_NAME -f"
echo "  2) 前端部署：README 第 5 节"
echo "  3) 定时任务：bash $DEPLOY_DIR/scripts/install_cron.sh"
echo "  4) 若 .env 中仍有 CHANGE_ME 占位符，请务必编辑 $API_DIR/.env 后执行："
echo "     systemctl restart $SERVICE_NAME"
