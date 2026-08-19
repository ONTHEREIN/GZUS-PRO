#!/usr/bin/env bash
# 软帮手 OneGZUS — 为域名签发 Let's Encrypt 证书（HTTP-01 webroot 校验）并配置 nginx 使用
#
# 用法（在服务器上以 root 运行）：
#   bash issue_letsencrypt.sh <你的域名> [邮箱] [--register-unsafely-without-email]
#
# 前提：
#   1) ICP 备案必须已完成（未备案时腾讯云会拦截，HTTP-01 校验和 HTTPS 都不可用，见 README §6）
#   2) /etc/nginx/conf.d/onegzus.conf 的 80 server 块已含
#      `location /.well-known/acme-challenge/ { root /var/www/certbot; }`（模板已默认带）
#   3) 已安装 certbot：`dnf install -y certbot python3-certbot-nginx`
#   4) 已启用自动续期定时器：`systemctl enable --now certbot-renew.timer`
#
# 幂等：--keep-until-expiring 保证已有有效证书时不会重复签发。
set -euo pipefail

DOMAIN="${1:?用法: issue_letsencrypt.sh <域名> [邮箱]}"
EMAIL="${2:-}"
UNSAFE=""
[ -n "$EMAIL" ] || UNSAFE="--register-unsafely-without-email"
[ -z "$EMAIL" ] && echo "⚠️  未提供邮箱，使用 --register-unsafely-without-email（收不到到期提醒，可稍后补：certbot update_account --email 你@邮箱.com）" >&2

WEBROOT=/var/www/certbot
mkdir -p "$WEBROOT"

echo "==> 确认 ACME 校验路径可直达（应非 301/302）..."
if curl -s -o /dev/null -w '%{http_code}\n' -H "Host: $DOMAIN" "http://127.0.0.1/.well-known/acme-challenge/probe" | grep -qE '^(404|403|400)$'; then
    echo "    OK：/.well-known/acme-challenge/ 由 nginx 本地直答。"
else
    echo "    ⚠️  /.well-known/acme-challenge/ 未能直答（返回的是跳转？）。请先修正 nginx 80 server 块（用 location 包住 return 301）。" >&2
    exit 1
fi

echo "==> certbot 签发（HTTP-01 webroot）..."
certbot certonly --webroot -w "$WEBROOT" -d "$DOMAIN" \
  --non-interactive --agree-tos $UNSAFE \
  ${EMAIL:+--email "$EMAIL"} \
  --keep-until-expiring

CERT_DIR="/etc/letsencrypt/live/$DOMAIN"
LECRT="$CERT_DIR/fullchain.pem"
LEKEY="$CERT_DIR/privkey.pem"
[ -f "$LECRT" ] && [ -f "$LEKEY" ] || { echo "证书签发结果异常：$CERT_DIR 缺失" >&2; exit 1; }

echo "==> 配置 nginx 使用 certbot 证书..."
NGINX_CONF="${NGINX_CONF:-/etc/nginx/conf.d/onegzus.conf}"
if [ -f "$NGINX_CONF" ]; then
    sed -i "s|ssl_certificate[[:space:]].*;|ssl_certificate     $LECRT;|" "$NGINX_CONF"
    sed -i "s|ssl_certificate_key[[:space:]].*;|ssl_certificate_key $LEKEY;|" "$NGINX_CONF"
    nginx -t
    systemctl reload nginx
    echo "==> nginx 已重载并启用新证书。"
else
    echo "==> 未找到 $NGINX_CONF，请手动把下面两行写入 nginx 站点配置后 reload：" >&2
    echo "    ssl_certificate     $LECRT;"
    echo "    ssl_certificate_key $LEKEY;" >&2
fi

echo "==> 验证（本机）: https://$DOMAIN/"
curl -fsS -o /dev/null -w '    HTTP %{http_code}\n' "https://$DOMAIN/" || echo "    （本机直连失败，外部仍可能被腾讯云拦截，详见 README §6）" >&2

echo "==> 完成。证书信息："
certbot certificates | grep -A3 "Domains: $DOMAIN" || true
