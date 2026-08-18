#!/usr/bin/env bash
# ============================================================
# 软帮手 OneGZUS — ICP 备案通过后的上线脚本（在服务器上以 root 运行）
#
# 前置：
#   1. 域名 onegzus.onrein.top 已完成 ICP 备案
#   2. 已申请腾讯云免费 SSL 证书（Nginx 格式）并上传到服务器
#   3. 证书文件就位：
#      /etc/nginx/ssl/onegzus/fullchain.pem
#      /etc/nginx/ssl/onegzus/privkey.pem
#
# 功能：
#   1. 校验证书文件与域名
#   2. 替换自签证书为正式证书（先备份）
#   3. reload nginx
#   4. 校验 DNS 是否已解析到本机
#   5. 从公网验证 https://onegzus.onrein.top 完整链路
# ============================================================
set -euo pipefail

DOMAIN="${1:-onegzus.onrein.top}"
CERT_DIR="/etc/nginx/ssl/onegzus"
FULLCHAIN="$CERT_DIR/fullchain.pem"
PRIVKEY="$CERT_DIR/privkey.pem"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "错误：请以 root 运行：sudo bash go_live.sh [域名]" >&2
  exit 1
fi

echo "==> [1/5] 校验证书"
[[ -s "$FULLCHAIN" ]] || { echo "缺少 $FULLCHAIN（请先上传正式证书）" >&2; exit 1; }
[[ -s "$PRIVKEY" ]] || { echo "缺少 $PRIVKEY（请先上传正式证书）" >&2; exit 1; }
if ! openssl x509 -in "$FULLCHAIN" -noout -subject 2>/dev/null | grep -qi "$DOMAIN"; then
  echo "警告：证书 subject 未包含 $DOMAIN（openssl 输出如下，请人工确认）" >&2
  openssl x509 -in "$FULLCHAIN" -noout -subject 2>&1 || true
fi
# 证书与私钥是否匹配
CERT_MOD="$(openssl x509 -in "$FULLCHAIN" -noout -modulus | openssl md5)"
KEY_MOD="$(openssl rsa -in "$PRIVKEY" -noout -modulus 2>/dev/null | openssl md5)"
if [[ "$CERT_MOD" != "$KEY_MOD" ]]; then
  echo "错误：证书与私钥不匹配（modulus 不一致）" >&2
  exit 1
fi
echo "    证书有效，与私钥匹配"

echo "==> [2/5] 备份自签证书并替换"
BACKUP="$CERT_DIR/selfsigned-backup-$(date +%F)"
mkdir -p "$BACKUP"
cp "$FULLCHAIN" "$PRIVKEY" "$BACKUP/"
# 腾讯云下载的 Nginx 证书文件名可能是 fullchain.crt / xxx.key，此处假设已命名为 fullchain.pem / privkey.pem
echo "    已备份到 $BACKUP"

echo "==> [3/5] 重载 nginx"
nginx -t && systemctl reload nginx
echo "    nginx 已重载"

echo "==> [4/5] DNS 校验"
MY_IP="$(curl -s --max-time 10 https://api.ipify.org || echo "")"
DOMAIN_IP="$(dig +short "$DOMAIN" A 2>/dev/null | tail -1 || true)"
if [[ -z "$DOMAIN_IP" ]]; then
  echo "错误：$DOMAIN 未解析。请先添加 A 记录 $DOMAIN -> $MY_IP（腾讯云 DNS/DNSPod）" >&2
  exit 1
fi
echo "    本机公网 IP: $MY_IP"
echo "    域名解析到 : $DOMAIN_IP"
if [[ "$DOMAIN_IP" != "$MY_IP" ]]; then
  echo "警告：解析 IP 与本机不一致，请检查 A 记录（若有多条/CDN 请人工确认）" >&2
fi

echo "==> [5/5] 公网验证"
check() {
  local url="$1" expect="$2"
  local ct code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$url")"
  ct="$(curl -sI --max-time 15 "$url" | grep -i '^content-type:' | tail -1 | tr -d '\r' | cut -d: -f2- | xargs)"
  if [[ "$code" == "200" ]] && echo "$ct" | grep -qi "$expect"; then
    echo "  ✔ $url"
  else
    echo "  ✘ $url -> HTTP $code, $ct" >&2
  fi
}
check "https://$DOMAIN/" "html"
check "https://$DOMAIN/api/health" "json"
check "https://$DOMAIN/main.dart.js" "javascript"

echo ""
echo "完成！如全部 ✔，域名已正式上线。"
echo "后续清理：Cloudflare/Vercel/Neon 资源停用见 deploy/tencent/README.md 第 11 节"
