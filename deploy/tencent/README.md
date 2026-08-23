# OneGZUS 腾讯云部署

生产链路固定为：腾讯云 CVM 上的 Nginx、systemd 托管的 FastAPI、PostgreSQL 和 Flutter Web。唯一公开业务入口为 `https://onegzus.onrein.top/api`；Nginx 不公开转发 `/api/internal/*`。

## 首次初始化

以 root 执行：

```bash
cd /opt/onegzus/deploy/scripts
bash setup_server.sh
```

初始化会创建：

```text
/opt/onegzus/releases/{api,web}/  # 不可变 release
/opt/onegzus/current/{api,web}    # 当前 release 软链接
/opt/onegzus/shared/api.env       # 仅服务器保存的环境变量
/opt/onegzus/backups/postgres/    # PostgreSQL 备份
```

将 `deploy/tencent/nginx/onegzus.conf` 安装为 Nginx 站点，替换其中示例域名并配置证书。部署账户为 `onegzus`；不要在仓库或服务器工作目录保存部署私钥。

`/opt/onegzus/shared/api.env` 至少需要设置：

```dotenv
DEBUG=false
DATABASE_URL=postgresql://onegzus:<password>@127.0.0.1:5432/onegzus
CREDENTIAL_ENCRYPTION_KEY=<随机 32 字节密钥>
RSA_PRIVATE_KEY_PEM=<PEM 私钥>
INTERNAL_API_KEY=<随机维护密钥>
PUBLIC_API_BASE_URL=https://onegzus.onrein.top/api
FRONTEND_BASE_URL=https://onegzus.onrein.top
```

## 自动发布

推送到 `master` 后，`deploy-prod-api.yml` 和 `deploy-prod-frontend.yml` 分别构建并上传对应 release。发布任务排队执行，不会中断正在进行的发布。

GitHub Actions 必须配置以下 Secrets：

| Secret | 用途 |
| --- | --- |
| `DEPLOY_SSH_KEY` | 仅 CI 使用的部署私钥 |
| `DEPLOY_KNOWN_HOSTS` | 已在可信环境采集、固定的 SSH 主机指纹 |
| `DEPLOY_HOST` | 服务器地址 |
| `DEPLOY_USER` | 部署用户 |

每个 release 先做完整性检查。API 在切换前执行数据库备份、导入预检并重启候选版本；`/health/ready` 不通过会自动恢复前一个 API 软链接。Web 发布失败不会切换 `current/web`。每类 release 保留当前版本和两个历史版本。

手动激活已上传的候选版本：

```bash
bash /opt/onegzus/deploy/scripts/activate_release.sh api <commit-sha>
bash /opt/onegzus/deploy/scripts/activate_release.sh web <commit-sha>
```

## 备份、恢复与演练

每日执行一次数据库备份（仅 `onegzus` 可读）：

```cron
0 3 * * * /opt/onegzus/deploy/scripts/backup_db.sh >> /var/log/onegzus/backup.log 2>&1
```

发布 API 也会自动调用同一备份脚本。保留 14 个最新备份。恢复演练在隔离数据库进行：

```bash
createdb onegzus_restore_check
pg_restore --clean --if-exists --no-owner -d onegzus_restore_check /opt/onegzus/backups/postgres/<backup>.dump
dropdb onegzus_restore_check
```

不要对生产数据库执行 `--clean` 恢复；先创建隔离库确认备份可用。

## 定时任务与监控

安装唯一的服务器本机 cron：

```bash
sudo bash /opt/onegzus/deploy/scripts/install_cron.sh
```

它只调用 `127.0.0.1:8000/internal/cron/*`，使用 `X-Internal-Key` 鉴权。每次运行的成功时间、耗时与失败原因存入 `maintenance_job_status`，可在管理后台系统状态读取。

Uptime Kuma 的本机 Compose 配置位于 `deploy/tencent/uptime-kuma/`，仅绑定 `127.0.0.1:3001`。创建以下监控：

- `https://onegzus.onrein.top/api/health/ready`（HTTP 200，内容含 `ready`）
- HTTPS 证书有效期
- cron 状态：读取管理后台的 `maintenanceJobs`，超过计划周期未成功或 `lastError` 非空即告警

## 验收

```bash
bash /opt/onegzus/deploy/scripts/verify.sh https://onegzus.onrein.top
curl -fsS http://127.0.0.1:8000/health/ready
curl -I https://onegzus.onrein.top/api/internal/cron/wechat-sync  # 必须 404
```

确认候选 API 失败不会改变 `current/api`，健康检查成功后再人工验证登录、课表、一卡通、推送和管理后台。
