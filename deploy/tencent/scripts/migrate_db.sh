#!/usr/bin/env bash
# ============================================================
# 软帮手 OneGZUS — 数据库迁移脚本（Neon → 服务器 PostgreSQL）
# 在【本地电脑】执行（需要本机有 pg_dump / psql，macOS: brew install libpq）
#
# 用法：
#   export NEON_DATABASE_URL='postgresql://user:pass@<neon-host>/<db>?sslmode=require'
#   export SERVER_DB_URL='postgresql://onegzus:<PG_PASSWORD>@127.0.0.1:5432/onegzus'
#   export SERVER_SSH='onegzus@SERVER_IP'
#   bash migrate_db.sh
#
# 说明：
#   - 使用 --clean --if-exists：可重复执行（先删后建）
#   - 迁移内容：admin_users / admin_audit_log / wx_articles / 会话 / 缓存等全部表
#   - 迁移前请确认服务器数据库已由 setup_server.sh 创建
#   - 迁移后旧会话（JWXT cookies 绑定 Cloudflare IP）会失效，用户需重新登录，属预期
# ============================================================
set -euo pipefail

: "${NEON_DATABASE_URL:?请先 export NEON_DATABASE_URL（Neon 连接串）}"
: "${SERVER_DB_URL:?请先 export SERVER_DB_URL（服务器连接串）}"
: "${SERVER_SSH:?请先 export SERVER_SSH（如 onegzus@1.2.3.4）}"

echo "==> 检查本机工具"
command -v pg_dump >/dev/null || { echo "缺少 pg_dump（macOS: brew install libpq 并加入 PATH）" >&2; exit 1; }
command -v ssh >/dev/null || { echo "缺少 ssh" >&2; exit 1; }

echo "==> 测试 SSH 连接: $SERVER_SSH"
ssh "$SERVER_SSH" "command -v psql >/dev/null && echo OK || (echo '服务器缺少 psql' >&2; exit 1)"

echo "==> 开始迁移 Neon → 服务器（管道直传，可能需要几分钟）"
pg_dump --clean --if-exists --no-owner --no-privileges "$NEON_DATABASE_URL" \
  | ssh "$SERVER_SSH" "psql -v ON_ERROR_STOP=1 '$SERVER_DB_URL'"

echo "==> 迁移完成。验证（服务器上执行）："
echo "    ssh $SERVER_SSH \"psql '$SERVER_DB_URL' -c '\\dt'\""
echo ""
echo "备选方案（数据量大时，先落盘再传输）："
echo "    pg_dump -Fc --no-owner --no-privileges \$NEON_DATABASE_URL | gzip > neon.dump.gz"
echo "    scp neon.dump.gz $SERVER_SSH:/tmp/"
echo "    ssh $SERVER_SSH 'gunzip -c /tmp/neon.dump.gz | pg_restore --no-owner --no-privileges -d \"\$SERVER_DB_URL\"'"
