#!/usr/bin/env bash
# ============================================================
# 软帮手 OneGZUS — 定时任务安装脚本（在服务器上以 root / sudo 运行）
#
# 把原本由 GitHub Actions 调用的 /internal/cron/* 改为服务器本地 crontab：
#   - wechat-sync    每 6 小时（20 分）同步公众号文章
#   - ecard-reminder 每天 8:00 水电费提醒兜底
#
# 用法：bash /opt/onegzus/deploy/scripts/install_cron.sh
# 可选：CRON_USER=onegzus（默认部署用户）
# ============================================================
set -euo pipefail

CRON_USER="${CRON_USER:-onegzus}"
ENV_FILE="/opt/onegzus/shared/api.env"
LOG_FILE="/var/log/onegzus/cron.log"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "错误：请以 root 运行：sudo bash install_cron.sh" >&2
  exit 1
fi

if [[ ! -f "$ENV_FILE" ]]; then
  echo "错误：$ENV_FILE 不存在，请先完成首个 API release 部署" >&2
  exit 1
fi

API_KEY="$(grep -E '^INTERNAL_API_KEY=' "$ENV_FILE" | head -1 | cut -d= -f2- | tr -d ' \r\n\"')"
if [[ -z "$API_KEY" || "$API_KEY" == CHANGE_ME* ]]; then
  echo "警告：INTERNAL_API_KEY 未配置或仍为占位符，cron 调用将 401。" >&2
  echo "      请先编辑 $ENV_FILE 设置 INTERNAL_API_KEY。" >&2
fi

install -d -o "$CRON_USER" -g "$CRON_USER" /var/log/onegzus

# 幂等：先删除旧的 OneGZUS cron 段再写入
crontab -u "$CRON_USER" -l 2>/dev/null | sed '/^# === OneGZUS cron ===$/,/^# === OneGZUS cron end ===$/d' > /tmp/onegzus-cron.tmp || true
cat >> /tmp/onegzus-cron.tmp <<EOF
# === OneGZUS cron ===
# 公众号文章同步（每 6 小时）
20 */6 * * * curl -fsS -m 120 -H "X-Internal-Key: $API_KEY" http://127.0.0.1:8000/internal/cron/wechat-sync >> $LOG_FILE 2>&1
# 水电费提醒兜底（每天 8:00）
0 8 * * * curl -fsS -m 120 -H "X-Internal-Key: $API_KEY" http://127.0.0.1:8000/internal/cron/ecard-reminder >> $LOG_FILE 2>&1
# === OneGZUS cron end ===
EOF
crontab -u "$CRON_USER" /tmp/onegzus-cron.tmp
rm -f /tmp/onegzus-cron.tmp

echo "==> 已写入 $CRON_USER 的 crontab："
crontab -u "$CRON_USER" -l | sed -n '/OneGZUS cron/,/OneGZUS cron end/p'

echo ""
echo "手动触发验证："
echo "  curl -s -H \"X-Internal-Key: \$API_KEY\" http://127.0.0.1:8000/internal/cron/wechat-sync"
echo "  日志：tail -f $LOG_FILE"
