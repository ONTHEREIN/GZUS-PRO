# 软帮手 OneGZUS — 迁移到腾讯云服务器部署指南

> 目标：把**前端（Flutter Web 静态页）+ 后端（FastAPI）+ PostgreSQL 数据库 + 域名**全部迁移到一台腾讯云 CVM / 轻量应用服务器上，彻底脱离 Cloudflare Pages / Cloudflare Worker / Vercel / Neon。
>
> 部署形态：`nginx`（静态资源 + 反向代理 + HTTPS）→ `uvicorn`（FastAPI，systemd 托管）→ 本机 PostgreSQL。
> 后端在服务器上会**自动启用后台轮询器**（通知/考试提醒/成绩更新/水电费提醒/推送），这是相比 Vercel serverless 的额外收益。

> **系统支持**：Ubuntu（`setup_server.sh`）与 RHEL 系 / OpenCloudOS（`setup_server_rhel.sh`）均已适配。
> OpenCloudOS 注意点：dnf.conf 默认 exclude nginx（脚本用 `--setopt=exclude=` 覆盖）、需 `postgresql-setup --initdb`、pg_hba 默认 ident/trust（脚本改为 scram）。
> 已在 OpenCloudOS 9.6 上实测完成整套部署（本项目 106.55.2.248）。

---

## 0. 迁移前后架构对比

| 组件 | 迁移前 | 迁移后 |
|---|---|---|
| 前端静态资源 | Cloudflare Pages（onegzus-onweb / onegzus） | nginx 静态托管（`/opt/onegzus/web`） |
| CAS 登录 / 验证码 OCR / RSA | Cloudflare Worker（`_worker.js`，边缘） | FastAPI 后端自带实现（`cas_auto_login.py` + `captcha_ocr.py` + `rsa_keys.py`） |
| 学校系统访问（JWXT/一卡通） | 后端经 Worker `/_proxy` 走 Cloudflare 出口 IP | 后端**直连**学校系统（服务器固定公网 IP 成为会话绑定 IP） |
| API 后端 | Vercel serverless | uvicorn + systemd（`127.0.0.1:8000`） |
| 数据库 | Neon PostgreSQL（云） | 服务器本机 PostgreSQL |
| 会话存储 | Worker KV + PostgreSQL | PostgreSQL（唯一） |
| 定时任务 | GitHub Actions 调 `/internal/cron/*` | 服务器 crontab 调本机 `/internal/cron/*` |
| 域名 | `onegzus.cc.cd`（Cloudflare） | 你的新域名（腾讯云） |

**为什么可以直接去掉 Worker？** 教务系统（JWXT）会话按**建立会话时的出口 IP** 绑定。原来 Vercel 出口 IP 不稳定/与用户延迟高，所以让 Worker 用固定边缘 IP 访问学校系统。迁移后，服务器公网 IP 固定，后端从服务器直连学校系统，IP 绑定自然成立，Worker 的代理职责不再需要。后端本身已包含完整的登录/OCR/RSA 实现（Worker 只是把同一套逻辑放到边缘做低延迟优化）。

> ⚠️ **切换后的必然后果**：迁移前由 Cloudflare IP 建立的 JWXT 会话，从服务器 IP 访问会被教务系统拒绝。**所有用户需要重新登录一次**（会话 TTL 本身只有 2 小时，影响很小）。数据（管理员、公众号文章、缓存等）会完整迁移。

### 本次迁移已包含的代码改动（仓库内）

| 文件 | 改动 | 原因 |
|---|---|---|
| `services/api/app/sessions.py` | `SessionStore.create()` 增加 `is_admin` 自动解析：未显式传参时按 `admin_users` 白名单标记管理员 | 原来 `is_admin` 只在 Worker 调用的 `/internal/create-session` 里设置；去掉 Worker 后普通登录路径（`/auth/*`）也需标记管理员，否则管理后台全部 403 |

后端 401 → 前端自动调 `/auth/relogin`（后端自带 CAS 重登，无需 Worker）；会话可从 PostgreSQL 存储的 cookies 重建 —— 这两条链路在无 Worker 模式下均正常，无需改动。

> 后续建议：迁移验证通过后，可把 `apps/mobile_web/lib/api_client.dart` 中 `_defaultApiBaseUrl()` 的默认值（旧 Cloudflare 域名）改为你的新域名，避免漏传 `--dart-define` 的构建指向已废弃域名。

---

## 1. ⚠️ 前置条件：ICP 备案（大陆地域服务器，最重要、最耗时）

腾讯云**大陆地域**服务器绑定域名提供 Web 服务，**必须完成 ICP 备案**；未备案的域名解析到大陆服务器后，80/443 端口会被腾讯云拦截，网站无法访问。

- 备案入口：腾讯云控制台 →「网站备案」（或 https://beian.tencent.com ）。需要：域名已实名、主体信息、服务器已购买、按提示拍照/上传资料。
- 备案周期通常 **1～2 周**（腾讯云初审 + 管局审核）。
- **推荐流程**：备案期间不切换 DNS，旧服务（Cloudflare/Vercel）照常运行；备案通过后按第 8 步切换 DNS 上线。备案通过前，可用「公网 IP + 本机 hosts」方式在服务器上自测（见第 9 步）。
- 若域名注册商不在腾讯云：只需域名已完成实名认证即可备案（域名将解析到腾讯云服务器，备案号与腾讯云接入商绑定）。
- 中国香港/海外地域服务器免备案，但延迟和合规性不同，本指南按大陆地域编写。

---

## 2. 服务器初始化

假设：Ubuntu 22.04 / 24.04 LTS，有 root 或 sudo 权限，公网 IP 记为 `SERVER_IP`，SSH 用户为 `root`（建议后续用 `onegzus` 用户部署）。

### 2.1 上传部署包

在本地（本仓库根目录）：

```bash
scp -r deploy/tencent root@SERVER_IP:/tmp/deploy
```

### 2.2 运行初始化脚本（在服务器上，root）

```bash
cd /tmp/deploy/scripts
# 可选：指定 PostgreSQL 密码（不指定则脚本自动生成并打印）
export PG_PASSWORD='请改成强密码'
bash setup_server.sh
```

脚本会把部署包复制到 `/opt/onegzus/deploy/`，**后续所有步骤都从这里调用**（`/opt/onegzus/deploy/scripts/...`）。

脚本会：
1. 安装 Python 3.11+（22.04 走 deadsnakes PPA 装 3.11；24.04 直接用 3.12）、`python3-venv`、`pip`
2. 安装 nginx、PostgreSQL、rsync、curl
3. 创建部署用户 `onegzus`（home `/opt/onegzus`）与目录 `/opt/onegzus/{api,web,backups}`
4. 创建 PostgreSQL 角色 `onegzus` 与数据库 `onegzus`（密码打印在终端，请记下）

> 若服务器已有其他站点/软件，请先阅读脚本内容再执行。

---

## 3. 数据库迁移（Neon → 服务器 PostgreSQL）

在**本地**执行（需要本机装有 `pg_dump` / `pg_restore`，macOS 可用 `brew install libpq` 后加入 PATH）。

```bash
export NEON_DATABASE_URL='postgresql://<user>:<password>@<neon-host>/<dbname>?sslmode=require'   # Neon 连接串
export SERVER_DB_URL='postgresql://onegzus:<PG_PASSWORD>@127.0.0.1:5432/onegzus'                  # 服务器连接串
export SERVER_SSH='onegzus@SERVER_IP'                                                            # SSH 目标
bash /path/to/deploy/tencent/scripts/migrate_db.sh
```

脚本逻辑：`pg_dump -Fc` 导出 Neon → 经 ssh 管道到服务器 → `pg_restore`（含建表与数据）。迁移的内容包括：会话表、管理员表（`admin_users`/`admin_audit_log`）、公众号文章（`wx_articles`）、各类缓存表等。

> 数据库迁移失败不影响回滚：服务器数据库随时可以清掉重建，旧 Neon 数据库在验证通过前**不要删除**。
>
> **为什么必须保留 `CREDENTIAL_ENCRYPTION_KEY`？** 会话表里保存的用户凭证是用 Fernet（`CREDENTIAL_ENCRYPTION_KEY`）加密的。迁移后该密钥若与 Vercel 生产环境不一致，历史加密凭证将无法解密，所有用户必须重新登录（可接受，但没必要）。请把 Vercel 上的这个值原样复制到服务器 `.env`。

---

## 4. 部署后端 API

### 4.1 上传后端代码（本地执行）

```bash
rsync -avz --delete --exclude '.venv' --exclude '__pycache__' --exclude '.pytest_cache' \
  services/api/ onegzus@SERVER_IP:/opt/onegzus/api/
```

### 4.2 填写环境变量（服务器上）

```bash
cp /opt/onegzus/api/.env.example /opt/onegzus/api/.env
vim /opt/onegzus/api/.env
```

**必填/关键变量清单**（完整模板见 `deploy/tencent/env/onegzus.env.example`）：

| 变量 | 值 | 说明 |
|---|---|---|
| `DEBUG` | `false` | 生产必须 false |
| `DATABASE_URL` | `postgresql://onegzus:<PG_PASSWORD>@127.0.0.1:5432/onegzus` | 本机 PostgreSQL |
| `CREDENTIAL_ENCRYPTION_KEY` | **与 Vercel 生产完全一致** | 见第 3 节警告 |
| `INTERNAL_API_KEY` | 随机串（`python -c "import secrets; print(secrets.token_urlsafe(32))"`） | 供 crontab 调用 `/internal/cron/*`；**保持与 GitHub Actions secret 一致**（旧 cron 停用前） |
| `PUBLIC_API_BASE_URL` | `https://你的域名/api` | LY SSO 回调拼接用；nginx 会剥掉 `/api` 前缀转发到后端 |
| `FRONTEND_BASE_URL` | `https://你的域名` | 自动加入 CORS 白名单 |
| `CORS_ORIGINS` | `https://你的域名,http://localhost:3000,http://localhost:8080,...` | 按需 |
| `CORS_ORIGIN_REGEX` | 默认即可 | 默认已含 localhost / 192.168.* |
| `JWXT_WORKER_PROXY_ORIGIN` | **留空** | 清空 = 后端直连 JWXT（服务器 IP 绑定） |
| `ECARD_WORKER_PROXY_ORIGIN` | **留空** | 清空 = 一卡通直连 |
| `ADMIN_SEED_OWNER` | 你的学号（逗号分隔可多个） | 管理后台 owner |
| `WECHAT_ALBUM_URL` / `WECHAT_RSS_URL` | 沿用现有值 | 公众号文章同步 |
| `WEB_PUSH_VAPID_*` | **沿用现有值** | 推送密钥换掉会导致已订阅的推送失效 |
| `APP_LATEST_VERSION` 等 | 沿用现有值 | 应用更新提示 |
| `JPUSH_APP_KEY` / `JPUSH_MASTER_SECRET` | 有则沿用 | 极光推送 |

> 学校相关 URL（`JW_BASE_URL`/`CAS_LOGIN_URL`/`EHALL_*`/`ECARD_*` 等）保持 `.env.example` 默认值即可，无需改动。

### 4.3 安装依赖并启动（服务器上）

```bash
bash /opt/onegzus/deploy/scripts/deploy_api.sh
```

脚本会：创建 `.venv` → `pip install -r requirements.txt` → 安装 systemd 单元 → 启动并设置开机自启 → 本机健康检查。

启动后确认：

```bash
curl -s http://127.0.0.1:8000/health        # 期望 {"status":"ok"}
sudo journalctl -u onegzus-api -f            # 查看日志
```

> ⚠️ **`--workers 1` 是故意的**：后台轮询器（成绩/考试/水电费/推送）在应用启动时（lifespan）运行。多 worker 会导致多套轮询器重复推送。单 worker 对本项目流量完全够用；如确需扩容，把轮询器拆成独立进程后再加 worker。

---

## 5. 构建并部署前端（Flutter Web）

### 5.1 本地构建（需要 Flutter SDK，版本建议 3.44.x）

```bash
cd apps/mobile_web
flutter pub get
flutter build web --release --base-href "/" \
  --dart-define=API_BASE_URL="https://你的域名/api" \
  --no-web-resources-cdn

# 清理（与 CI 一致：去调试符号/多余 CanvasKit 变体/NOTICES）
cd build/web
find . -name "*.symbols" -delete
rm -rf canvaskit/experimental_webparagraph
rm -f canvaskit/skwasm*.wasm canvaskit/skwasm*.js
rm -f canvaskit/wimp.wasm canvaskit/wimp.js
rm -f assets/NOTICES
```

> `API_BASE_URL` 是编译期注入的，只传新域名即可（逗号列表可用于多后端 fallback，例如 `https://你的域名/api,https://onegzus-onweb.pages.dev/api` 可作过渡期兜底，正式切换后建议只留新域名）。
> `web/` 下的 `_worker.js`、`_redirects`、`edgeone.json`、`edge-functions/` 是 Cloudflare/EdgeOne 专用，nginx 不读，无需处理（它们不会被复制进 `build/web`）。

### 5.2 上传并部署（本地执行上传，服务器执行部署脚本）

```bash
rsync -avz --delete apps/mobile_web/build/web/ onegzus@SERVER_IP:/tmp/onegzus-web/
ssh onegzus@SERVER_IP 'bash /opt/onegzus/deploy/scripts/deploy_frontend.sh'
```

`deploy_frontend.sh` 会把 `/tmp/onegzus-web/` 同步到 `/opt/onegzus/web/` 并 reload nginx。

> Android APK 同样要重新构建才会指向新后端：`flutter build apk --dart-define=API_BASE_URL="https://你的域名/api"`，老 APK 用户需要更新安装包。

---

## 6. nginx + HTTPS

### 6.1 申请 SSL 证书

- 腾讯云控制台 →「SSL 证书」→ 申请**免费 DV 证书**（TrustAsia，有效期 1 年，到期前续期）。
- 下载 **Nginx 版本**，解压得到 `fullchain.crt`（或 `1_你的域名_bundle.crt`）与 `privkey.pem`（或 `2_你的域名.key`）。

### 6.2 放置证书并启用站点（服务器上）

```bash
sudo mkdir -p /etc/nginx/ssl/onegzus
# 上传证书（本地执行）：
#   scp fullchain.crt privkey.pem root@SERVER_IP:/etc/nginx/ssl/onegzus/
# 或服务器上直接编辑粘贴。证书文件命名统一为 fullchain.pem / privkey.pem：
sudo cp /etc/nginx/ssl/onegzus/fullchain.crt /etc/nginx/ssl/onegzus/fullchain.pem  # 按实际文件名调整
sudo cp /etc/nginx/ssl/onegzus/privkey.key  /etc/nginx/ssl/onegzus/privkey.pem      # 按实际文件名调整

# 把配置里的域名替换为你的域名（模板见 /opt/onegzus/deploy/nginx/onegzus.conf）
sudo sed -i 's/onegzus\.example\.com/你的域名/g' /opt/onegzus/deploy/nginx/onegzus.conf
sudo cp /opt/onegzus/deploy/nginx/onegzus.conf /etc/nginx/sites-available/onegzus.conf
sudo ln -sf /etc/nginx/sites-available/onegzus.conf /etc/nginx/sites-enabled/onegzus.conf

# 如果 nginx 默认站点存在，先禁用（避免 80 端口冲突）
sudo rm -f /etc/nginx/sites-enabled/default

sudo nginx -t && sudo systemctl reload nginx
```

### 6.3 放行端口

- 腾讯云控制台 → 该服务器 →「防火墙/安全组」：放行 **80（TCP）**、**443（TCP）**、22（SSH，已有）。
- 服务器内如启用了 ufw：`sudo ufw allow 80/tcp && sudo ufw allow 443/tcp`。

nginx 配置要点（已写入模板）：
- `/api/xxx` → 剥掉 `/api` 前缀代理到 `127.0.0.1:8000/xxx`（与 Worker 行为一致）
- `/api/ws/notifications` 与 `/ws` → WebSocket Upgrade 代理（移动端推送实时通道）
- 旧版非 `/api` 前缀路径（`/auth/*`、`/academic/*` 等）→ 兼容代理（与 Worker 的向后兼容逻辑一致）
- 静态资源长缓存、`index.html` 不缓存、SPA 回退、安全响应头、10MB body 上限

---

## 7. 定时任务迁移（GitHub Actions → 服务器 crontab）

后端在服务器上常驻，但 `/internal/cron/wechat-sync`（公众号文章同步）和 `/internal/cron/ecard-reminder`（水电费提醒兜底）原本由 GitHub Actions 定时调用。迁移后改为服务器本地 crontab（内网调用，无需经过 nginx）：

```bash
bash /opt/onegzus/deploy/scripts/install_cron.sh
```

默认写入（每 6 小时同步公众号文章；每天 8:00 水电费提醒兜底）：

```cron
20 */6 * * * curl -fsS -m 120 -H "X-Internal-Key: <INTERNAL_API_KEY>" http://127.0.0.1:8000/internal/cron/wechat-sync >> /var/log/onegzus/cron.log 2>&1
0 8 * * *   curl -fsS -m 120 -H "X-Internal-Key: <INTERNAL_API_KEY>" http://127.0.0.1:8000/internal/cron/ecard-reminder >> /var/log/onegzus/cron.log 2>&1
```

验证：`curl -s -H "X-Internal-Key: <KEY>" http://127.0.0.1:8000/internal/cron/wechat-sync`。

> 过渡期备选：保留 GitHub Actions 的 `cron-wechat-sync.yml` / `cron-ecard-reminder.yml`，把其中的 URL 改为 `https://你的域名/internal/cron/wechat-sync` 即可（注意 `INTERNAL_API_KEY` secret 与服务器 `.env` 保持一致）。正式切换后二选一，避免重复同步。

---

## 8. DNS 切换上线

备案通过后，到域名注册商（腾讯云 DNS 或 DNSPod）添加解析：

| 记录类型 | 主机记录 | 记录值 |
|---|---|---|
| A | `@` | `SERVER_IP` |
| A | `www` | `SERVER_IP` |

> 旧域名 `onegzus.cc.cd` 在验证完成前保持原样（仍指向 Cloudflare），作为回滚通道。

切换前用第 9 步在服务器上完整自测；切换后从外网验证（第 10 步）。TTL 生效通常几分钟到几小时。

---

## 9. 上线前自测（备案期间即可做）

### 9.1 本机 hosts 方式（不依赖 DNS）

```bash
# /etc/hosts 添加：
SERVER_IP  你的域名
# 然后浏览器访问 https://你的域名  （证书为你的域名签发，可正常校验）
```

### 9.2 运行验证脚本（本地）

```bash
bash /path/to/deploy/tencent/scripts/verify.sh https://你的域名
```

脚本检查：后端 `/api/health`、静态资源（`main.dart.js`、`flutter_bootstrap.js`、`manifest.json`、CanvasKit）、安全响应头、PWA 清单。

### 9.3 功能清单（浏览器手动）

- [ ] 访问首页能加载（无白屏），PWA 可安装
- [ ] 登录流程：账号密码 + 验证码 + CAS 自动登录（`/auth/auto-login`）
- [ ] 课表 / 成绩 / 考勤 / 学分 / 考试 / 通知（JWXT 直连正常）
- [ ] 一卡通余额与水电费（直连正常）
- [ ] 请假、办事大厅
- [ ] 管理后台登录（`ADMIN_SEED_OWNER` 已配）
- [ ] 公众号文章同步（`/internal/cron/wechat-sync`）
- [ ] 推送订阅（VAPID 密钥未变，无需重新订阅）
- [ ] 手机端 WebSocket 连接（`/api/ws/notifications`）
- [ ] 后台轮询器日志无异常（`journalctl -u onegzus-api`）

---

## 10. 回滚方案

- **DNS 回滚**：把 `你的域名` 解析切回 Cloudflare（`onegzus.cc.cd` 全程未动，老 App 仍可用）。
- **服务器故障兜底**：Neon 数据库与 Vercel 后端在验证通过前**不要删除**；GitHub Actions 部署工作流先不删。
- 切换后若发现严重问题：改回 DNS 指向旧域名即可秒级回滚，前端老构建（指向旧域名）无需重新发布。

---

## 11. 收尾清理（确认稳定运行 1～2 周后）

- [ ] 停用/删除 GitHub Actions：`deploy-api.yml`（Vercel）、`deploy-frontend.yml`、`deploy-cloudflare-pages.yml`、`deploy-edgeone-pages.yml`、`cron-wechat-sync.yml`、`cron-ecard-reminder.yml`（在 GitHub 仓库 Settings → Actions 里禁用，或删文件）
- [ ] 删除 Vercel 项目与 Neon 数据库（先做一次完整备份到 `/opt/onegzus/backups/`）
- [ ] 删除 Cloudflare Pages 项目（onegzus-onweb / onegzus / intro-onegzus）与 Worker
- [ ] 旧域名 `onegzus.cc.cd` 按需注销/保留
- [ ] 服务器定时备份：`pg_dump` 每日备份到 `/opt/onegzus/backups/`（建议加 crontab，见下）

```bash
# 每日 3:00 备份数据库（示例，追加到 crontab）
0 3 * * * pg_dump -Fc postgresql://onegzus:<PG_PASSWORD>@127.0.0.1:5432/onegzus | gzip > /opt/onegzus/backups/onegzus-$(date +\%F).dump.gz
```

---

## 12. 常见问题

| 问题 | 处理 |
|---|---|
| 备案未通过时域名访问被拦截 | 属正常；用 hosts + IP 自测（第 9 步），或等备案通过再切 DNS |
| 用户登录后马上又要求重新登录 | 学校会话 IP 绑定：迁移后所有用户需重新登录一次，属预期 |
| `pip install` 装 `ddddocr` 失败 | 确认 Python ≥3.10 且为 x86_64；必要时 `pip install --upgrade pip setuptools wheel` 后重试 |
| 推送失效 | 检查 `WEB_PUSH_VAPID_*` 是否与原来一致 |
| 后台重复推送 | 确认 systemd 里 `--workers 1`（多 worker 会跑多套轮询器） |
| 管理后台无管理员 | 检查 `ADMIN_SEED_OWNER` 是否配置并已启动过服务 |
| 公众号文章不更新 | 检查 `WECHAT_ALBUM_URL` / `WECHAT_RSS_URL` 与 crontab 是否生效 |
| 需要 HTTPS 但腾讯云证书续期 | 免费 DV 证书每年续期一次，续期后替换 `/etc/nginx/ssl/onegzus/` 下文件并 reload nginx |

---

## 13. Git push 自动部署到腾讯云（CI/CD）

仓库已内置两套部署工作流（`.github/workflows/deploy-prod-*.yml`），推送到 `master` 即自动部署到腾讯云生产：

| 工作流 | 触发 | 动作 |
|---|---|---|
| `deploy-prod-frontend.yml` | 任意 push 到 master | Flutter Web 构建 → rsync 到 `/opt/onegzus/web` → nginx reload |
| `deploy-prod-api.yml` | `services/api/**` 变更 | 同步后端代码 → pip 安装依赖 → `systemctl restart onegzus-api` → 健康检查 |

### 13.1 配置 GitHub Secrets（一次性，必须）

仓库 → Settings → Secrets and variables → Actions → New repository secret：

| Secret | 值 |
|---|---|
| `DEPLOY_SSH_KEY` | CI 部署私钥（`deploy/tencent/.ssh/ci_deploy` 的内容，含 `BEGIN OPENSSH PRIVATE KEY` 整块；公钥已加入服务器 root 的 authorized_keys） |
| `DEPLOY_HOST` | `106.55.2.248` |
| `DEPLOY_USER` | `root` |

可选：仓库 Variables 里加 `API_BASE_URL=https://onegzus.onrein.top/api`（不配则用工作流默认值）。

### 13.2 停用旧部署工作流（重要）

旧工作流部署到 Cloudflare/Vercel（已废弃的平台）。确认新流水线跑通后，到 Actions 页面逐个 **Disable**，或删除文件：
`deploy-frontend.yml`、`deploy-api.yml`、`deploy-edgeone-pages.yml`、`cron-wechat-sync.yml`、`cron-ecard-reminder.yml`。

> ⚠️ 在停用之前，每次 push 会同时触发新旧两套部署（新→腾讯云，旧→Cloudflare/Vercel）。这是预期的过渡行为，不影响生产；确认稳定后停用旧的即可。

### 13.3 验证

- 推一次代码 → Actions 里看到 `Deploy Frontend to Tencent Production` / `Deploy API to Tencent Production` 绿色通过
- 检查线上：`https://onegzus.onrein.top` 内容更新、`https://onegzus.onrein.top/api/health` 返回 ok
