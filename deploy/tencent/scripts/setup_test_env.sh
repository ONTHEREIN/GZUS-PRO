#!/usr/bin/env bash
# 在小程序测试环境主机上初始化**隔离**的 API 测试实例。
#
# 幂等：可重复执行；已存在的密钥与环境文件不会被覆盖。
# 安全边界：绝不修改生产目录 /opt/onegzus、生产服务 onegzus-api.service
#           或生产站点 /etc/nginx/conf.d/onegzus.conf。
#
# 用法（在测试环境主机上以 root 执行）：
#   bash setup_test_env.sh
# 可用环境变量覆盖：
#   TEST_DOMAIN / DEMO_ACCOUNT / TEST_RELEASE_TAG
set -euo pipefail

PROD_ROOT="/opt/onegzus"
ROOT="/opt/onegzus-test"
SERVICE="onegzus-test-api"
PORT=8001
DB_NAME="onegzus_test"
DB_ROLE="onegzus_test"
DOMAIN="${TEST_DOMAIN:-test-api.onrein.top}"
DEMO_ACCOUNT="${DEMO_ACCOUNT:-demo_mini_2026}"
RELEASE_TAG="${TEST_RELEASE_TAG:-test-mvp-$(date +%Y%m%d-%H%M)}"
# 代码来源。默认复用生产 release，但生产 release 可能**尚未包含**小程序后端支持
# （/mini/auth/login、demo_data.py、DEMO_ACCOUNT_* 配置）。此时请把工作区源码上传到
# 服务器后用 TEST_CODE_SRC 指定，例如 TEST_CODE_SRC=/tmp/onegzus-test-src。
CODE_SRC="${TEST_CODE_SRC:-$PROD_ROOT/current/api}"

ENV_FILE="$ROOT/shared/api.env"
RELEASE="$ROOT/releases/api/$RELEASE_TAG"

log() { printf '%s\n' "▸ $*"; }
die() { printf '%s\n' "✖ $*" >&2; exit 1; }

[[ "$(id -u)" == "0" ]] || die "请以 root 执行"
[[ -d "$PROD_ROOT/current/api/app" ]] || die "找不到生产 release：$PROD_ROOT/current/api/app"
[[ -f "$CODE_SRC/app/main.py" ]] || die "代码来源缺少 app/main.py：$CODE_SRC"
[[ -f "$CODE_SRC/pyproject.toml" && -f "$CODE_SRC/uv.lock" ]] || die "代码来源缺少 pyproject.toml / uv.lock：$CODE_SRC"
command -v uv >/dev/null || die "缺少 uv"
command -v psql >/dev/null || die "缺少 psql"
# 切到中立目录，避免 sudo -u postgres 打印 "could not change directory" 警告
cd /tmp

# ─── 1. 目录 ────────────────────────────────────────────────────────
log "创建测试环境目录 $ROOT"
install -d -o onegzus -g onegzus "$ROOT"/{shared,releases/api,current,backups}

# ─── 2. 环境文件（先于数据库，因为数据库口令存在其中）──────────────
if [[ -f "$ENV_FILE" ]]; then
  log "复用已有环境文件 $ENV_FILE（不覆盖密钥）"
  DB_PASSWORD="$(sed -nE 's#^DATABASE_URL=postgresql://[^:]+:([^@]+)@.*#\1#p' "$ENV_FILE")"
  [[ -n "$DB_PASSWORD" ]] || die "无法从已有 DATABASE_URL 解析数据库口令"
else
  log "生成测试环境专用密钥（与生产不同）"
  # 用十六进制：无需 URL 编码，可直接放进 DATABASE_URL 与 shell 变量。
  DB_PASSWORD="$(openssl rand -hex 16)"
  CRED_KEY="$(/opt/onegzus/current/api/.venv/bin/python -c 'import secrets;print(secrets.token_urlsafe(32))')"
  INTERNAL_KEY="$(openssl rand -hex 32)"
  DEMO_PASSWORD="Demo-$(openssl rand -hex 6)!"

  umask 077
  cat > "$ENV_FILE" <<EOF
# 软帮手 OneGZUS — 小程序测试环境（$DOMAIN）
# 由 setup_test_env.sh 生成；权限 600，绝不提交仓库。
# 演示账号密码只存在于本文件：
#   DEMO_ACCOUNT=$DEMO_ACCOUNT
#   DEMO_PASSWORD=$DEMO_PASSWORD
DEBUG=true

DATABASE_URL=postgresql://$DB_ROLE:$DB_PASSWORD@127.0.0.1:5432/$DB_NAME
DB_POOL_SIZE=5
DB_MAX_OVERFLOW=10
DB_POOL_TIMEOUT=10
DB_POOL_RECYCLE=300

CREDENTIAL_ENCRYPTION_KEY=$CRED_KEY
INTERNAL_API_KEY=$INTERNAL_KEY

PUBLIC_API_BASE_URL=https://$DOMAIN/api
FRONTEND_BASE_URL=https://$DOMAIN
CORS_ORIGINS=https://$DOMAIN
CORS_ORIGIN_REGEX=^https?://(localhost|127\\.0\\.0\\.1)(:\\d+)?$

DEMO_ACCOUNT_ENABLED=true
DEMO_ACCOUNT=$DEMO_ACCOUNT
DEMO_PASSWORD=$DEMO_PASSWORD
DEMO_STUDENT_ID=DEMO-2026-001

JW_BASE_URL=https://jwxt.gzus.edu.cn/jwglxt
EHALL_BASE_URL=https://ehall.gzus.edu.cn
CAS_LOGIN_URL=https://cas.gzus.edu.cn/lyuapServer/login
CAS_PASSWORD_CHANGE_URL=https://cas.gzus.edu.cn/aqzx/#/password/passwordModify
EHALL_SERVICE_URL=http://ehall.gzus.edu.cn/shiro-cas
JWXT_SSO_SERVICE_URL=https://jwxt.gzus.edu.cn/sso/lyiotlogin
ECARD_BASE_URL=https://ecarduser.gzus.edu.cn
ECARD_OPENID=
ECARD_UNIONID=
ECARD_SECRET=
ECARD_VERIFY_TLS=true
EHALL_CSRF_KEY=

SESSION_TTL_SECONDS=3600
SSO_TTL_SECONDS=300
REQUEST_TIMEOUT_SECONDS=15

WEB_PUSH_VAPID_PUBLIC_KEY=
WEB_PUSH_VAPID_PRIVATE_KEY=
WEB_PUSH_VAPID_SUBJECT=
APNS_KEY_ID=
APNS_TEAM_ID=
APNS_KEY_P8_BASE64=
APNS_BUNDLE_ID=
PUSH_POLL_INTERVAL_SECONDS=3600

ADMIN_SEED_OWNER=

WECHAT_ALBUM_URL=
WECHAT_ALBUM_URLS=
WECHAT_RSS_URL=
WECHAT_SYNC_INTERVAL_HOURS=24
EOF
  chown onegzus:onegzus "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  log "已写入 $ENV_FILE"
fi

# ─── 3. 独立数据库角色与库（与生产库、生产角色均隔离）────────────────
log "确保数据库角色与库存在"
sudo -u postgres psql -v ON_ERROR_STOP=1 -q <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '$DB_ROLE') THEN
    CREATE ROLE $DB_ROLE LOGIN PASSWORD '$DB_PASSWORD';
  ELSE
    ALTER ROLE $DB_ROLE WITH LOGIN PASSWORD '$DB_PASSWORD';
  END IF;
END
\$\$;
SQL

if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'" | grep -q 1; then
  sudo -u postgres createdb -O "$DB_ROLE" "$DB_NAME"
  log "已创建数据库 $DB_NAME"
else
  log "数据库 $DB_NAME 已存在"
fi

# ─── 4. 构建 release（复用生产代码，但使用独立 venv）─────────────────
if [[ -x "$RELEASE/.venv/bin/python" ]]; then
  log "release $RELEASE_TAG 已构建，跳过"
else
  log "从 $CODE_SRC 复制代码到 $RELEASE"
  install -d -o onegzus -g onegzus "$RELEASE"
  cp -a "$CODE_SRC/app" "$RELEASE/"
  cp -a "$CODE_SRC/pyproject.toml" "$CODE_SRC/uv.lock" "$RELEASE/"
  chown -R onegzus:onegzus "$RELEASE"

  log "uv sync --frozen --no-dev（首次较慢）"
  # UV_CACHE_DIR 指向测试环境目录：onegzus 的家目录就是生产目录 /opt/onegzus，
  # 不隔离的话 uv 会把缓存写进生产树。
  install -d -o onegzus -g onegzus "$ROOT/shared/uv-cache"
  sudo -u onegzus -H bash -c \
    "cd '$RELEASE' && UV_CACHE_DIR='$ROOT/shared/uv-cache' uv sync --frozen --no-dev"
fi

ln -sfn ../../../shared/api.env "$RELEASE/.env"
chown -h onegzus:onegzus "$RELEASE/.env"

# ─── 5. 原子切换 current ────────────────────────────────────────────
log "切换 current/api → $RELEASE_TAG"
ln -sfn "$RELEASE" "$ROOT/current/api.next"
mv -Tf "$ROOT/current/api.next" "$ROOT/current/api"

# ─── 6. systemd 单元 ────────────────────────────────────────────────
log "安装 systemd 单元 $SERVICE"
cat > "/etc/systemd/system/$SERVICE.service" <<EOF
[Unit]
Description=OneGZUS Test API (软帮手小程序测试环境)
After=network.target postgresql.service
Wants=postgresql.service

[Service]
Type=simple
User=onegzus
Group=onegzus
WorkingDirectory=$ROOT/current/api
EnvironmentFile=$ENV_FILE
ExecStart=$ROOT/current/api/.venv/bin/uvicorn app.main:app --host 127.0.0.1 --port $PORT --workers 1
Restart=always
RestartSec=5
TimeoutStopSec=30

NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ReadWritePaths=$ROOT/current/api $ROOT/releases $ROOT/shared $ROOT/backups

StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now "$SERVICE" >/dev/null
systemctl restart "$SERVICE"

# ─── 7. 就绪检查 ────────────────────────────────────────────────────
log "等待 /health/ready"
ready=false
for _ in $(seq 1 20); do
  if curl -fsS --max-time 2 "http://127.0.0.1:$PORT/health/ready" | grep -q '"status":"ready"'; then
    ready=true
    break
  fi
  sleep 1
done

if [[ "$ready" != true ]]; then
  journalctl -u "$SERVICE" -n 60 --no-pager >&2
  die "$SERVICE 未就绪"
fi

log "就绪：http://127.0.0.1:$PORT/health/ready"
log "演示账号：$DEMO_ACCOUNT（密码见 $ENV_FILE）"
log "完成。"
