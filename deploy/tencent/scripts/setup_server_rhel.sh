#!/usr/bin/env bash
# ============================================================
# 软帮手 OneGZUS — 腾讯云服务器初始化脚本（RHEL 系 / OpenCloudOS 9）
# 在服务器上以 root 运行（dnf 包管理）
#
# 用法：
#   export PG_PASSWORD='强密码'          # 可选；不设置则自动生成
#   bash setup_server_rhel.sh
#
# 功能：
#   1. 安装 Python 3.11 / nginx / PostgreSQL / rsync / curl
#   2. 初始化 PostgreSQL 并允许本机密码登录（onegzus 用户）
#   3. 创建部署用户 onegzus 与版本化发布目录
#   4. 放行防火墙 80/443；SELinux 放行 nginx 反代
#   5. 把部署脚本复制到 /opt/onegzus/deploy
# ============================================================
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "错误：请以 root 运行：sudo bash setup_server_rhel.sh" >&2
  exit 1
fi

echo "==> [1/6] 安装系统依赖"
# OpenCloudOS 默认在 dnf.conf 排除 nginx/httpd/php/mysql，用 --setopt=exclude= 覆盖
export DNF_OPTS="-y --allowerasing --setopt=exclude="
dnf install $DNF_OPTS \
  nginx postgresql-server postgresql \
  python3.11 python3.11-pip \
  rsync curl openssl unzip xz git \
  firewalld || {
    echo "某些包安装失败，请手动排查后重试" >&2
    exit 1
  }

PYTHON_BIN="$(command -v python3.11 || command -v python3 || true)"
[[ -n "$PYTHON_BIN" ]] || { echo "错误：未找到 Python" >&2; exit 1; }
echo "    使用 Python: $PYTHON_BIN ($($PYTHON_BIN --version))"

echo "==> [2/6] 创建部署用户与目录"
if ! id onegzus >/dev/null 2>&1; then
  useradd -m -d /opt/onegzus -s /bin/bash onegzus
fi
# /opt/onegzus 需 755（nginx 要能穿越到 current/web）。
chmod 755 /opt/onegzus
install -d -m 750 -o onegzus -g onegzus \
  /opt/onegzus/releases/api /opt/onegzus/releases/web /opt/onegzus/current \
  /opt/onegzus/shared /opt/onegzus/backups /opt/onegzus/deploy

if ! command -v uv >/dev/null 2>&1; then
  echo "==> 安装 uv"
  curl -LsSf https://astral.sh/uv/install.sh | UV_UNMANAGED_INSTALL=/usr/local/bin sh
fi

echo "==> [3/6] 初始化 PostgreSQL（RHEL 系需手动 initdb）"
if [[ ! -d /var/lib/pgsql/data/base ]]; then
  postgresql-setup --initdb || true
fi
systemctl enable --now postgresql

PG_PASSWORD="${PG_PASSWORD:-$(openssl rand -hex 16)}"
if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='onegzus'" | grep -q 1; then
  sudo -u postgres psql -v ON_ERROR_STOP=1 \
    -c "CREATE ROLE onegzus LOGIN PASSWORD '$PG_PASSWORD';"
fi
if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='onegzus'" | grep -q 1; then
  sudo -u postgres psql -v ON_ERROR_STOP=1 -c "CREATE DATABASE onegzus OWNER onegzus;"
fi

# pg_hba：允许 127.0.0.1 密码登录（RHEL 默认 ident/trust）
PGHBA="$(sudo -u postgres psql -tAc 'SHOW hba_file')"
if ! grep -qE "^host[[:space:]]+all[[:space:]]+all[[:space:]]+127\.0\.0\.1/32[[:space:]]+scram-sha-256" "$PGHBA"; then
  cp "$PGHBA" "${PGHBA}.bak"
  sed -i -E 's/^(host[[:space:]]+all[[:space:]]+all[[:space:]]+127\.0\.0\.1\/32[[:space:]]+)(ident|trust|peer)/\1scram-sha-256/; s/^(host[[:space:]]+all[[:space:]]+all[[:space:]]+::1\/128[[:space:]]+)(ident|trust|peer)/\1scram-sha-256/' "$PGHBA"
  systemctl restart postgresql
  echo "    已修改 pg_hba.conf：127.0.0.1 使用密码认证"
fi

echo "==> [4/6] nginx + 防火墙 + SELinux"
systemctl enable --now nginx 2>/dev/null || systemctl enable nginx
# 移除默认欢迎页配置
rm -f /etc/nginx/conf.d/default.conf
if systemctl is-active --quiet firewalld; then
  firewall-cmd --permanent --add-service=http --add-service=https 2>/dev/null || true
  firewall-cmd --reload 2>/dev/null || true
fi
# SELinux：允许 nginx 反代后端 + 读当前 Web release
if command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce)" == "Enforcing" ]]; then
  setsebool -P httpd_can_network_connect 1
  semanage fcontext -a -t httpd_sys_content_t "/opt/onegzus/current/web(/.*)?" 2>/dev/null || true
  restorecon -Rv /opt/onegzus/current/web 2>/dev/null || true
  echo "    SELinux 已放行 nginx 反代与静态目录"
fi

echo "==> [5/6] 复制部署脚本"
if [[ -d /tmp/deploy ]]; then
  cp -a /tmp/deploy/. /opt/onegzus/deploy/
  chown -R onegzus:onegzus /opt/onegzus/deploy
fi
install -m 644 /opt/onegzus/deploy/systemd/onegzus-api.service /etc/systemd/system/onegzus-api.service
systemctl daemon-reload
systemctl enable onegzus-api

echo "==> [6/6] 完成"
echo "------------------------------------------------------------"
echo "  部署用户   : onegzus"
echo "  目录       : /opt/onegzus/{releases,current,shared,backups,deploy}"
echo "  数据库     : postgresql://onegzus:$PG_PASSWORD@127.0.0.1:5432/onegzus"
echo "  Python     : $PYTHON_BIN"
echo "------------------------------------------------------------"
echo " 下一步："
echo "  1) 创建 /opt/onegzus/shared/api.env（见 deploy README）"
echo "  2) nginx 站点：/opt/onegzus/deploy/nginx/onegzus.conf → /etc/nginx/conf.d/"
echo "  3) 通过 GitHub Actions 上传首个 API/Web release"
echo "  4) 运行 /opt/onegzus/deploy/scripts/install_cron.sh"
