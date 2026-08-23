#!/usr/bin/env bash
# 安装 release 所需的 systemd 与 Nginx 配置；不重启 API，也不 reload Nginx。
set -euo pipefail

DEPLOY_ROOT="/opt/onegzus/deploy"
NGINX_SOURCE="$DEPLOY_ROOT/nginx/onegzus.conf"
NGINX_TARGET="/etc/nginx/conf.d/onegzus.conf"
UNIT_SOURCE="$DEPLOY_ROOT/systemd/onegzus-api.service"
UNIT_TARGET="/etc/systemd/system/onegzus-api.service"
DOMAIN="onegzus.onrein.top"

[[ "$(id -u)" -eq 0 ]] || { echo "必须以 root 运行" >&2; exit 1; }
[[ -f "$NGINX_SOURCE" ]] || { echo "缺少 Nginx 配置：$NGINX_SOURCE" >&2; exit 1; }
[[ -f "$UNIT_SOURCE" ]] || { echo "缺少 systemd unit：$UNIT_SOURCE" >&2; exit 1; }

temporary_config="$(mktemp /etc/nginx/conf.d/onegzus.conf.XXXXXX)"
backup_config="${NGINX_TARGET}.previous"
trap 'rm -f "$temporary_config"' EXIT

sed "s/onegzus\\.example\\.com/$DOMAIN/g" "$NGINX_SOURCE" > "$temporary_config"
if [[ -f "$NGINX_TARGET" ]]; then
  cp -p "$NGINX_TARGET" "$backup_config"
fi
install -m 644 "$temporary_config" "$NGINX_TARGET"
if ! nginx -t; then
  if [[ -f "$backup_config" ]]; then
    mv -f "$backup_config" "$NGINX_TARGET"
  else
    rm -f "$NGINX_TARGET"
  fi
  exit 1
fi
rm -f "$backup_config"

install -m 644 "$UNIT_SOURCE" "$UNIT_TARGET"
systemctl daemon-reload
