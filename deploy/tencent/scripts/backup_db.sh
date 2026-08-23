#!/usr/bin/env bash
# 备份本机 PostgreSQL；只保留 14 个最近备份，文件只允许部署账户读取。
set -euo pipefail

ENV_FILE="/opt/onegzus/shared/api.env"
BACKUP_DIR="/opt/onegzus/backups/postgres"

[[ -f "$ENV_FILE" ]] || { echo "缺少 $ENV_FILE" >&2; exit 1; }
DATABASE_URL="$(grep -E '^DATABASE_URL=' "$ENV_FILE" | tail -n 1 | cut -d= -f2- | tr -d '\r')"
case "$DATABASE_URL" in
  \"*\") DATABASE_URL="${DATABASE_URL#\"}"; DATABASE_URL="${DATABASE_URL%\"}" ;;
  \'*\') DATABASE_URL="${DATABASE_URL#\'}"; DATABASE_URL="${DATABASE_URL%\'}" ;;
esac
[[ -n "$DATABASE_URL" ]] || { echo "DATABASE_URL 未配置" >&2; exit 1; }

install -d -m 700 -o onegzus -g onegzus "$BACKUP_DIR"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
TARGET="$BACKUP_DIR/onegzus-$STAMP.dump"
umask 077
pg_dump --format=custom --file "$TARGET" "$DATABASE_URL"
chown onegzus:onegzus "$TARGET"
find "$BACKUP_DIR" -type f -name 'onegzus-*.dump' -printf '%T@ %p\n' \
  | sort -nr | tail -n +15 | cut -d' ' -f2- | xargs -r rm -f --
printf '%s\n' "$TARGET"
