#!/usr/bin/env bash
# 原子激活 API 或 Web release；失败时恢复上一个已知可用版本。
set -euo pipefail

KIND="${1:?用法: activate_release.sh <api|web> <release-id>}"
RELEASE_ID="${2:?缺少 release id}"
ROOT="/opt/onegzus"
RELEASE="$ROOT/releases/$KIND/$RELEASE_ID"
CURRENT="$ROOT/current/$KIND"
PREVIOUS="$ROOT/current/$KIND.previous"

[[ "$KIND" == "api" || "$KIND" == "web" ]] || { echo "未知 release 类型: $KIND" >&2; exit 1; }
[[ "$RELEASE_ID" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "无效 release id" >&2; exit 1; }
[[ -d "$RELEASE" ]] || { echo "release 不存在: $RELEASE" >&2; exit 1; }
install -d -o onegzus -g onegzus "$ROOT/current" "$ROOT/releases/$KIND" "$ROOT/shared" "$ROOT/backups"

activate_link() {
  local link="$1"
  local target="$2"
  local temporary="$link.next"
  ln -sfn "$target" "$temporary"
  mv -Tf "$temporary" "$link"
}

if [[ "$KIND" == "web" ]]; then
  for asset in index.html main.dart.js flutter_bootstrap.js manifest.json; do
    [[ -f "$RELEASE/$asset" ]] || { echo "Web release 缺少 $asset" >&2; exit 1; }
  done
  local_previous=""
  if [[ -L "$CURRENT" ]]; then
    local_previous="$(readlink -f "$CURRENT")"
    activate_link "$PREVIOUS" "$local_previous"
  fi
  nginx -t
  activate_link "$CURRENT" "$RELEASE"
  if ! systemctl reload nginx; then
    if [[ -n "$local_previous" ]]; then
      activate_link "$CURRENT" "$local_previous"
      systemctl reload nginx
    fi
    exit 1
  fi
else
  ENV_FILE="$ROOT/shared/api.env"
  [[ -f "$ENV_FILE" ]] || { echo "缺少 $ENV_FILE" >&2; exit 1; }
  for required_file in app/main.py pyproject.toml uv.lock; do
    [[ -f "$RELEASE/$required_file" ]] || {
      echo "API release 缺少 $required_file" >&2
      exit 1
    }
  done
  ln -sfn ../../../shared/api.env "$RELEASE/.env"
  [[ -x "$RELEASE/.venv/bin/python" ]] || { echo "API release 未完成 uv sync" >&2; exit 1; }
  "$RELEASE/.venv/bin/python" -c 'from app.main import create_app; create_app()'
  bash "$ROOT/deploy/scripts/backup_db.sh"
  local_previous=""
  if [[ -L "$CURRENT" ]]; then
    local_previous="$(readlink -f "$CURRENT")"
    activate_link "$PREVIOUS" "$local_previous"
  fi
  activate_link "$CURRENT" "$RELEASE"
  ready=false
  if systemctl restart onegzus-api; then
    for _ in {1..10}; do
      if curl -fsS --max-time 2 http://127.0.0.1:8000/health/ready | grep -q '"status":"ready"'; then
        ready=true
        break
      fi
      sleep 1
    done
  fi
  if [[ "$ready" != true ]]; then
    if [[ -n "$local_previous" ]]; then
      activate_link "$CURRENT" "$local_previous"
      systemctl restart onegzus-api
    fi
    journalctl -u onegzus-api -n 80 --no-pager >&2
    exit 1
  fi
fi

chown -R onegzus:onegzus "$RELEASE"
find "$ROOT/releases/$KIND" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' \
  | sort -nr | tail -n +4 | cut -d' ' -f2- | xargs -r rm -rf --
