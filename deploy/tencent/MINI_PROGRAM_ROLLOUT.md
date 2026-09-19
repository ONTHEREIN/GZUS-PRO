# 小程序后端上线清单（生产）

> 结论先行：**小程序 MVP 的后端支持目前只存在于工作区未提交的改动里，从未上线。**
> 正式版小程序调用 `/mini/auth/login` 会 404。本文给出安全上线的步骤、验证与回滚。
>
> 本文只描述步骤，**不代表已经执行**。

## 1. 现状证据（2026-09-19 实测）

生产当前 release：`/opt/onegzus/releases/api/multi-album-20260919-1212`
（上一版 `24ad1494ab2a019a3691afa81fec5632a7b81cd8` ＝ 仓库 HEAD）

在生产 release 里查不到：

```
$ ls /opt/onegzus/current/api/app/routes/mini_program.py   → 不存在
$ ls /opt/onegzus/current/api/app/demo_data.py             → 不存在
$ grep demo /opt/onegzus/current/api/app/config.py         → 无 demo 字段
```

把生产 `app/` 拉下来与工作区 `services/api/app/` 做 `diff -rq`，真实差异是：

| 类型 | 文件 |
| --- | --- |
| 仅工作区有 | `app/demo_data.py`、`app/routes/mini_program.py`、`app/shiply_export_jobs.py` |
| 两边不同 | `app/config.py`、`app/database.py`、`app/main.py`、`app/routes/__init__.py`、`app/routes/admin.py`、`app/routes/auth.py`、`app/routes/deps.py`、`app/routes/ecard.py`、`app/schemas.py`、`app/sessions.py`、`app/shiply_content.py` |

**这不是「只加一个小程序接口」**：同一批改动还包含 shiply 导出任务、管理后台、会话与数据库相关改动。
上线前必须按一次完整 release 对待。

## 2. 一个关键安全性质

`DEMO_ACCOUNT_ENABLED` **在生产必须保持关闭**，这不是建议而是硬约束：

```python
# app/config.py
if settings.demo_account_enabled:
    if not settings.debug:
        raise RuntimeError("DEMO_ACCOUNT_ENABLED requires DEBUG=true")
```

生产 `DEBUG=false`，一旦把 `DEMO_ACCOUNT_ENABLED` 设为 `true`，**服务会直接启动失败**（这是一个好性质：
演示账号不可能误开到生产）。因此：

- 生产环境文件里不要新增任何 `DEMO_ACCOUNT*`；
- 生产小程序使用**真实学生账号**走 CAS 登录，演示账号只在测试环境使用；
- `app/demo_data.py` 仍然必须一起部署——`app/routes/auth.py` 在模块顶层无条件 import 它，
  缺文件会导致**整个应用启动失败**（`ModuleNotFoundError`），即使演示账号从未被使用。

## 3. 上线前检查

- [ ] 工作区改动已提交到 `master`（CI 只对提交内容构建 release）
- [ ] 本地全绿：`npm run typecheck`、逻辑单测、页面回归 10/10
- [ ] 后端全绿：`PYTHONPATH=. uv run pytest`（当前 356 例）、`uv run ruff check .`
- [ ] 在**测试环境**用工作区代码完成一次演示账号验收（已完成：`smoke_test_api.sh` 10/10）
- [ ] 确认生产 `api.env` **没有** `DEMO_ACCOUNT_ENABLED` / `DEBUG=true`
- [ ] 确认 `services/api/.env.example` 里的新键已按生产需要补齐（模板不参与运行，但便于维护）
- [ ] 确认 `CREDENTIAL_ENCRYPTION_KEY` 不变（改动会导致所有用户需重新登录）
- [ ] 数据库备份可用：`bash deploy/tencent/scripts/backup_db.sh`

## 4. 部署步骤

CI 已把流程自动化（`.github/workflows/deploy-prod-api.yml`，`master` 上 `services/api/**` 变更即触发）：
测试 → `uv sync --frozen --no-dev` → 数据库备份 → 原子切换 → `/health/ready` 检查 → 失败自动回滚。

推送到 `master` 后：

```bash
# 1. 观察 workflow
gh run watch            # 或网页查看 deploy-prod-api 运行

# 2. 确认新 release 已激活
ssh root@106.55.2.248 'readlink -f /opt/onegzus/current/api'

# 3. 就绪探针
curl -s https://onegzus.onrein.top/api/health/ready     # {"status":"ready"}

# 4. 新接口存在性（不带会话应为 401/422，而不是 404）
curl -s -o /dev/null -w '%{http_code}\n' -X POST https://onegzus.onrein.top/api/mini/auth/login \
  -H 'Content-Type: application/json' -d '{}'           # 期望 422，不是 404
```

> 第 4 步是本次上线的核心验收点：**404 说明 `mini_program` 路由没被注册**。

手动部署（CI 不可用时）：

```bash
# 在服务器上按 release 流程构建，再原子激活
ssh root@106.55.2.248
sudo -u onegzus -H bash -lc 'cd /opt/onegzus/releases/api/<tag> && uv sync --frozen --no-dev'
bash /opt/onegzus/deploy/scripts/activate_release.sh api <tag>
```

## 5. 上线后回归

- [ ] `curl https://onegzus.onrein.top/api/health/ready` → `{"status":"ready"}`
- [ ] 小程序登录接口返回 422（存在）而非 404
- [ ] Web 端（Flutter）登录与首页、课表、成绩、考试、通知、生活缴费全部正常
- [ ] `journalctl -u onegzus-api -n 100` 无 `unhandled_exception`
- [ ] 观察 15 分钟：4xx/5xx 比例、登录失败率、接口耗时
- [ ] 确认日志中不出现密码、Cookie、会话 ID

## 6. 微信公众平台

- [ ] 正式版 `request 合法域名` 已包含 `https://onegzus.onrein.top`
- [ ] 上传小程序代码（`npm run auto-preview` 只用于真机调试；正式发布需在开发者工具上传并提交审核）
- [ ] 提审前确认：小程序只保存 `sessionId`，未采集多余个人信息，隐私协议已配置

## 7. 回滚

CI 在 `/health/ready` 失败时会自动切回上一版。手动回滚：

```bash
ssh root@106.55.2.248
ls -l /opt/onegzus/current/api.previous          # 确认目标版本
bash /opt/onegzus/deploy/scripts/activate_release.sh api <previous-tag>
curl -s https://onegzus.onrein.top/api/health/ready
```

回滚**不需要**改数据库：`database.py` 的 `_ensure_columns()` 只做 `ALTER TABLE ADD COLUMN`，是加列不改列的轻量迁移，旧版本代码可以正常忽略新列。

## 8. 风险提示

| 风险 | 说明 | 缓解 |
| --- | --- | --- |
| 爆炸半径大于预期 | 同批改动含 shiply 导出、admin、sessions、database | 按完整 release 评审，而非「加个接口」 |
| 缺 `demo_data.py` 导致启动失败 | `routes/auth.py` 顶层无条件 import | 部署时确认三处新文件都在 release 内 |
| 误开演示账号 | 生产 `DEBUG=false` 会直接拒绝启动 | 保持生产不含 `DEMO_ACCOUNT*`；靠启动校验兜底 |
| 会话/凭据不兼容 | `sessions.py`、`config.py` 有改动 | 不改 `CREDENTIAL_ENCRYPTION_KEY`；上线后验证老会话仍可恢复 |
| 前端与后端不同步 | Flutter Web 与小程序共用后端 | 后端先上、验证通过后再上传小程序正式版 |

## 9. 与测试环境的关系

测试环境（`test-api.onrein.top`，端口 8001，独立库 `onegzus_test`）**已经用工作区代码**跑通，
因此本次上线的代码变更在测试环境是经过验证的。测试环境与生产只有两点差异需要留意：

- 测试环境 `DEBUG=true` + 演示账号；生产 `DEBUG=false` + 真实学生账号；
- 测试环境库为空、无真实数据，因此**数据库迁移类改动在测试环境不会被真正压测**。
  上线前建议用生产库的备份在测试库上先跑一次启动，确认 `_ensure_columns()` 不报错。
