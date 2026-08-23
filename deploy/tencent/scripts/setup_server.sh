#!/usr/bin/env bash
# ============================================================
# 软帮手 OneGZUS — 腾讯云服务器初始化脚本（在服务器上以 root 运行）
#
# 用法：
#   export PG_PASSWORD='强密码'          # 可选；不设置则自动生成
#   bash setup_server.sh
#
# 功能：
#   1. 安装 Python 3.11+ / uv / nginx / PostgreSQL / rsync / curl
#   2. 创建版本化发布所需目录
#   3. 创建 PostgreSQL 角色 onegzus 与数据库 onegzus
#   4. 把部署脚本复制到 /opt/onegzus/deploy（后续步骤都从这里调用）
# ============================================================
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "错误：请以 root 运行：sudo bash setup_server.sh" >&2
  exit 1
fi

echo "==> [1/5] 安装系统依赖"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y \
  nginx postgresql postgresql-contrib \
  rsync curl ca-certificates gnupg lsb-release \
  python3-venv python3-pip

# ── Python 3.11+（22.04 自带 3.10，走 deadsnakes 装 3.11；24.04 自带 3.12）──
PYTHON_BIN=""
for cand in python3.12 python3.11 python3.10; do
  if command -v "$cand" >/dev/null 2>&1; then PYTHON_BIN="$cand"; break; fi
done

if [[ -z "$PYTHON_BIN" || "$PYTHON_BIN" == "python3.10" ]]; then
  echo "==> 安装 Python 3.11（deadsnakes PPA）"
  install -d /usr/share/keyrings
  curl -fsSL https://keyserver.ubuntu.com/pks/lookup?op=get\&search=0xf23c5a6cf475977595c89f51ba6932366a755776 \
    | gpg --dearmor -o /usr/share/keyrings/deadsnakes.gpg
  echo "deb [signed-by=/usr/share/keyrings/deadsnakes.gpg] https://ppa.launchpadcontent.net/deadsnakes/ppa/ubuntu $(lsb_release -sc) main" \
    > /etc/apt/sources.list.d/deadsnakes.list
  apt-get update -y
  apt-get install -y python3.11 python3.11-venv python3.11-dev
  PYTHON_BIN="python3.11"
fi
echo "    使用 Python: $PYTHON_BIN ($($PYTHON_BIN --version))"

echo "==> [2/5] 创建部署用户与目录"
if ! id onegzus >/dev/null 2>&1; then
  useradd -m -d /opt/onegzus -s /bin/bash onegzus
fi
install -d -o onegzus -g onegzus \
  /opt/onegzus/releases/api /opt/onegzus/releases/web /opt/onegzus/current \
  /opt/onegzus/shared /opt/onegzus/backups /opt/onegzus/deploy

if ! command -v uv >/dev/null 2>&1; then
  echo "==> 安装 uv"
  curl -LsSf https://astral.sh/uv/install.sh | UV_UNMANAGED_INSTALL=/usr/local/bin sh
fi

echo "==> [3/5] 初始化 PostgreSQL"
PG_PASSWORD="${PG_PASSWORD:-$(openssl rand -hex 16)}"
if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='onegzus'" | grep -q 1; then
  sudo -u postgres psql -v ON_ERROR_STOP=1 \
    -c "CREATE ROLE onegzus LOGIN PASSWORD '$PG_PASSWORD';"
fi
if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='onegzus'" | grep -q 1; then
  sudo -u postgres psql -v ON_ERROR_STOP=1 -c "CREATE DATABASE onegzus OWNER onegzus;"
fi

echo "==> [4/5] 复制部署脚本"
if [[ -d /tmp/deploy ]]; then
  cp -a /tmp/deploy/. /opt/onegzus/deploy/
  chown -R onegzus:onegzus /opt/onegzus/deploy
fi
install -m 644 /opt/onegzus/deploy/systemd/onegzus-api.service /etc/systemd/system/onegzus-api.service
systemctl daemon-reload
systemctl enable onegzus-api

echo "==> [5/5] 完成"
echo "------------------------------------------------------------"
echo "  部署用户   : onegzus"
echo "  目录       : /opt/onegzus/{releases,current,shared,backups,deploy}"
echo "  数据库     : postgresql://onegzus:$PG_PASSWORD@127.0.0.1:5432/onegzus"
echo "  Python     : $PYTHON_BIN"
echo "------------------------------------------------------------"
echo " 下一步："
echo "  1) 创建 /opt/onegzus/shared/api.env（见 deploy README）"
echo "  2) 安装 nginx 与 systemd 配置并启用 onegzus-api"
echo "  3) 通过 GitHub Actions 上传首个 API/Web release"
echo "  4) 运行 /opt/onegzus/deploy/scripts/install_cron.sh"
