# 第7章：部署与运维架构

> 软帮手（OneGZUS）软件设计文档  
> 版本：1.0  
> 最后更新：2026-06-17

---

## 7.1 部署架构概述

### 7.1.1 整体部署架构图

软帮手采用免费/低成本的全 Serverless 部署方案，前端托管于 Cloudflare Pages，后端部署在 Vercel Serverless Functions，数据库使用 Neon PostgreSQL。Cloudflare Worker 作为边缘层，在靠近中国大陆的节点处理 CAS SSO 登录和请求代理。

```mermaid
graph TB
    subgraph 用户端
        APP[Flutter Web / Android App]
        BROWSER[浏览器]
    end

    subgraph Cloudflare 边缘层
        CF_PAGES[Cloudflare Pages<br/>onegzus-onweb / onegzus]
        CF_WORKER[Cloudflare Worker<br/>_worker.js]
        CF_KV[Cloudflare KV<br/>SESSIONS_KV]
        CF_CUSTOM[自定义域名<br/>onegzus.cc.cd]
        CF_INTRO[Cloudflare Pages<br/>intro-onegzus]
    end

    subgraph Vercel 后端
        VERCEL[Vercel Serverless<br/>FastAPI App]
        VERCEL_ENV[Vercel 环境变量]
    end

    subgraph 数据库
        NEON[(Neon PostgreSQL<br/>Serverless)]
    end

    subgraph CI/CD
        GHA[GitHub Actions]
    end

    subgraph 代码仓库
        REPO[GitHub 仓库<br/>GZUS-PRO]
    end

    APP -->|HTTPS| CF_CUSTOM
    BROWSER -->|HTTPS| CF_CUSTOM
    CF_CUSTOM --> CF_WORKER
    CF_WORKER -->|CAS SSO / health| CF_WORKER
    CF_WORKER -->|代理其余请求| VERCEL
    CF_WORKER <-->|会话存取| CF_KV
    CF_PAGES -->|静态资源| APP
    CF_INTRO -->|介绍页| BROWSER

    VERCEL -->|SQL| NEON
    VERCEL_ENV --> VERCEL

    REPO -->|push to master| GHA
    GHA -->|Flutter build + deploy| CF_PAGES
    GHA -->|Vercel deploy| VERCEL
    GHA -->|wrangler deploy| CF_INTRO

    CF_WORKER -->|/internal/ocr<br/>/internal/decrypt-password<br/>/internal/create-session| VERCEL
```

### 7.1.2 三大部署目标

| 部署目标 | 技术栈 | 托管平台 | 域名/项目名 | 说明 |
|----------|--------|----------|-------------|------|
| Flutter Web 应用 | Flutter 3.x → 静态资源 | Cloudflare Pages | `onegzus-onweb`、`onegzus` | 主应用前端，含 Worker 边缘逻辑 |
| FastAPI 后端 | Python 3.11+ / FastAPI | Vercel Serverless | Vercel 项目 | API 服务，处理业务逻辑 |
| 静态介绍页 | HTML/CSS | Cloudflare Pages | `intro-onegzus` | 项目介绍网站，`website/` 目录 |

### 7.1.3 Cloudflare Worker 边缘层

Cloudflare Worker（`apps/mobile_web/web/_worker.js`，约 1780 行）是整个系统的关键中间层，承担以下职责：

- **CAS SSO 登录处理**：在边缘节点直接完成 CAS 认证流程（含验证码 OCR、RSA 加密），减少到中国高校 CAS 服务器的延迟
- **请求代理**：将非登录请求代理至 Vercel 后端，并注入 `X-Worker-Auth`、`Cookie`、`X-Student-Account` 等头部
- **会话管理**：使用 Cloudflare KV（`SESSIONS_KV`）在边缘侧持久化会话 Cookie，实现跨实例会话恢复
- **重试机制**：对 Vercel 后端的 5xx 响应执行最多 2 次指数退避重试
- **内部 API 调用**：调用 Vercel 后端的 `/internal/*` 端点（OCR、密码解密、会话创建），通过 `INTERNAL_API_KEY` 认证

---

## 7.2 前端部署

### 7.2.1 Flutter Web 构建

#### 构建命令

```bash
cd apps/mobile_web
flutter build web --release --base-href "/" \
  --dart-define=API_BASE_URL=<URL> \
  --no-web-resources-cdn
```

#### API_BASE_URL 配置

`API_BASE_URL` 是编译时注入的配置项，支持逗号分隔的多 URL fallback 机制：

| 参数 | 说明 |
|------|------|
| 默认值 | `https://onegzus.cc.cd/api,https://onegzus-onweb.pages.dev/api` |
| Fallback 机制 | 逗号分隔列表，前端按顺序尝试；Vercel URL 会被自动过滤 |
| 本地开发 | `http://127.0.0.1:8000`（Android 模拟器自动重写为 `10.0.2.2`） |

Fallback 列表的工作原理：

1. 前端解析逗号分隔的 URL 列表
2. 过滤掉 Vercel 域名（`*.vercel.app`）的 URL（避免直连后端绕过 Worker）
3. 按顺序尝试第一个可用 URL
4. 若请求失败，自动切换到下一个 URL

### 7.2.2 Cloudflare Pages 部署

Flutter Web 构建产物部署到两个 Cloudflare Pages 项目：

| 项目名 | 用途 | 说明 |
|--------|------|------|
| `onegzus-onweb` | 主部署目标 | 绑定 Worker，处理 API 请求 |
| `onegzus` | 备用/镜像部署 | 与 onegzus-onweb 相同内容 |

部署命令（CI 中执行）：

```bash
npx wrangler@latest pages deploy apps/mobile_web/build/web \
  --project-name=onegzus-onweb \
  --branch=master \
  --commit-dirty=true

npx wrangler@latest pages deploy apps/mobile_web/build/web \
  --project-name=onegzus \
  --branch=master \
  --commit-dirty=true
```

### 7.2.3 构建产物优化

CI 流水线在部署前对 Flutter 构建产物执行以下清理操作，显著减小部署体积：

```bash
cd apps/mobile_web/build/web

# 移除调试符号文件
find . -name "*.symbols" -delete

# 移除不需要的 CanvasKit 变体
rm -rf canvaskit/chromium
rm -rf canvaskit/experimental_webparagraph
rm -f canvaskit/skwasm*.wasm canvaskit/skwasm*.js
rm -f canvaskit/wimp.wasm canvaskit/wimp.js

# 移除 NOTICE 文件
rm -f assets/NOTICES
```

| 优化项 | 说明 | 预估节省 |
|--------|------|----------|
| `.symbols` 文件 | 调试符号，生产环境不需要 | 数 MB |
| CanvasKit 变体 | Chromium 专用、实验性 Web Paragraph、skwasm/wimp | 10-20 MB |
| `NOTICES` 文件 | 开源许可声明，生产环境可移除 | 数百 KB |

### 7.2.4 Android APK 构建

#### 手动构建

```bash
cd apps/mobile_web
flutter build apk --dart-define=API_BASE_URL=<URL>
```

#### 自动化脚本：build_deploy.ps1

`build_deploy.ps1` 是一键构建并安装 APK 到 Android 设备的自动化脚本，位于项目根目录。

**功能特性：**

- 自动递增 `pubspec.yaml` 中的构建号（`version: x.y.z+N` 中的 N）
- 支持 `-Cloud`（默认）和 `-Local` 两种模式
- 自动检测 LAN IP 或回退到 `10.0.2.2`（模拟器）
- 通过 ADB 自动安装到连接的设备

**使用方式：**

```powershell
# 云端模式（默认）
.\build_deploy.ps1

# 局域网模式
.\build_deploy.ps1 -Local

# 自定义 API URL
.\build_deploy.ps1 -ApiUrl=https://onegzus.cc.cd/api
```

**执行流程：**

```
1. 解析 pubspec.yaml 版本号，自动 +1
2. 根据 -Cloud/-Local 确定 API_BASE_URL
3. 执行 flutter build apk
4. 检测 ADB 连接设备（优先 Wi-Fi 设备）
5. adb install -r 安装 APK
```

---

## 7.3 后端部署

### 7.3.1 Vercel 部署

#### 部署命令

```bash
cd services/api
npx vercel --prod --yes --token <VERCEL_TOKEN>
```

#### vercel.json 配置

```json
{
  "version": 2,
  "installCommand": "pip install -r requirements.txt",
  "builds": [
    {
      "src": "app/main.py",
      "use": "@vercel/python"
    }
  ],
  "routes": [
    {
      "src": "/(.*)",
      "dest": "app/main.py"
    }
  ],
  "headers": [
    {
      "source": "/(.*)",
      "headers": [
        { "key": "X-Content-Type-Options", "value": "nosniff" },
        { "key": "X-Frame-Options", "value": "DENY" },
        { "key": "Strict-Transport-Security", "value": "max-age=63072000; includeSubDomains; preload" }
      ]
    }
  ],
  "env": {
    "DEBUG": "false",
    "DB_POOL_SIZE": "3",
    "DB_MAX_OVERFLOW": "5",
    "DB_POOL_TIMEOUT": "10",
    "DB_POOL_RECYCLE": "300",
    "JWXT_WORKER_PROXY_ORIGIN": "https://onegzus.cc.cd",
    "ECARD_WORKER_PROXY_ORIGIN": "https://onegzus.cc.cd"
  }
}
```

| 配置项 | 说明 |
|--------|------|
| `builds` | 入口文件 `app/main.py`，使用 `@vercel/python` 运行时 |
| `routes` | 所有请求路由到 `app/main.py` |
| `headers` | 安全响应头（nosniff、DENY、HSTS） |
| `env` | Vercel 平台级环境变量（可被 Vercel Dashboard 中的变量覆盖） |

> **注意**：`vercel.json` 中的 `env` 字段设置的连接池参数（`DB_POOL_SIZE=3`、`DB_MAX_OVERFLOW=5`）比 `.env.example` 中的默认值（`1`/`2`）更大，这是 Vercel 生产环境的优化配置。Vercel Dashboard 中设置的环境变量优先级高于 `vercel.json`。

### 7.3.2 生产环境变量

| 变量名 | 必填 | 说明 | 示例值 |
|--------|------|------|--------|
| `DEBUG` | 是 | 生产环境必须为 `false` | `false` |
| `JWXT_WORKER_PROXY_ORIGIN` | 是 | JWXT API 调用通过 Worker 代理的源地址 | `https://onegzus.cc.cd` |
| `ECARD_WORKER_PROXY_ORIGIN` | 是 | 一卡通 API 调用通过 Worker 代理的源地址 | `https://onegzus.cc.cd` |
| `DATABASE_URL` | 是 | PostgreSQL 连接字符串 | `postgresql://user:pass@host/db?sslmode=require` |
| `CREDENTIAL_ENCRYPTION_KEY` | 是 | 凭证加密密钥（32 字节随机串） | `secrets.token_urlsafe(32)` 生成 |
| `INTERNAL_API_KEY` | 是 | Worker 调用内部端点的认证密钥 | 自定义随机字符串 |
| `RSA_PRIVATE_KEY_PEM` | 推荐 | RSA 私钥，避免冷启动时密钥轮换 | PEM 格式 |

### 7.3.3 Vercel Serverless 特性与限制

| 特性 | 说明 | 应对策略 |
|------|------|----------|
| 冷启动 | 函数无流量时实例回收，首次请求延迟较高 | 会话从 DB 恢复；Worker 侧缓存 Cookie |
| 函数超时 | 免费版 10s，Pro 版 60s | 慢操作（如 CAS 登录）在 Worker 边缘处理 |
| 执行时长 | 免费版每月 100 GB-Hrs | 缓存策略减少后端调用 |
| 无长连接 | 不支持 WebSocket 长驻 | WebSocket 仅在非 Vercel 环境启用 |
| 后台任务 | `IS_VERCEL=1` 时不启动 poller | 通知轮询等在本地部署时运行 |

> **关键设计**：`main.py` 中通过 `IS_VERCEL = os.environ.get("VERCEL") == "1"` 检测运行环境。在 Vercel 上，后台轮询任务（通知、考试提醒、成绩更新、水电提醒）不会启动，因为这些任务需要长驻进程。

---

## 7.4 数据库部署

### 7.4.1 Neon PostgreSQL

生产环境使用 Neon 提供的 Serverless PostgreSQL，具备以下特性：

- **自动扩缩容**：根据负载自动调整计算资源
- **连接池**：提供 Pooled Connection String，适合 Serverless 场景
- **自动休眠**：空闲时自动休眠，节省资源
- **Branching**：支持数据库分支，便于开发测试

#### 连接字符串格式

```
# 直连（管理用）
postgresql://user:password@ep-xxx.region.aws.neon.tech/dbname?sslmode=require

# Pooled（应用用，推荐）
postgresql://user:password@ep-xxx-region.pooler.region.aws.neon.tech/dbname?sslmode=require
```

> **重要**：生产环境必须使用 **Pooled Connection String**（带 `-pooler-` 的 URL），以避免 Serverless 函数耗尽数据库连接数。

### 7.4.2 连接池配置

| 参数 | 默认值 | Vercel 生产值 | 说明 |
|------|--------|---------------|------|
| `DB_POOL_SIZE` | 1 | 3 | 连接池常驻连接数 |
| `DB_MAX_OVERFLOW` | 2 | 5 | 超出 pool_size 后允许的临时连接数 |
| `DB_POOL_TIMEOUT` | 10 | 10 | 获取连接的超时时间（秒） |
| `DB_POOL_RECYCLE` | 300 | 300 | 连接回收周期（秒） |

> **免费方案优化**：`.env.example` 中推荐 `DB_POOL_SIZE=1`、`DB_MAX_OVERFLOW=2`，这是为 Neon 免费版（最多 5 个并发连接）设计的保守配置。Vercel 生产环境通过 `vercel.json` 覆盖为 `3`/`5`。

### 7.4.3 数据库初始化与迁移

#### 自动初始化

应用启动时，`database.py:init_db()` 自动执行：

1. `Base.metadata.create_all(engine)` — 创建所有表
2. `_ensure_columns()` — 轻量级列迁移，添加模型中存在但数据库中可能缺失的列

```python
# _ensure_columns 示例：幂等迁移
_ensure_columns(engine, "app_sessions", {
    "student_account": "VARCHAR(100)",
    "revoked_at": "TIMESTAMP",
    "revoked_reason": "VARCHAR(100)",
})
```

> **设计决策**：项目不使用 Alembic 等迁移框架，而是采用轻量级的 `_ensure_columns()` 方案。每次冷启动时执行，`ALTER TABLE ADD COLUMN` 在列已存在时安全忽略。适合 Serverless 场景下快速迭代。

#### SQLite → PostgreSQL 迁移

`migrate_to_postgres.py` 是一次性数据迁移脚本，将 SQLite 数据导入 PostgreSQL：

```bash
cd services/api
python migrate_to_postgres.py \
  --sqlite-path ./gzus_pro.db \
  --database-url postgresql://user:pass@host:5432/dbname?sslmode=require
```

**迁移表清单：**

| 表名 | 说明 | 主键类型 |
|------|------|----------|
| `staff_members` | 教职工信息 | 字符串 PK |
| `ehall_sessions` | ehall 会话 | 自增 ID |
| `ecard_bindings` | 一卡通绑定 | 自增 ID |
| `push_registrations` | 推送注册 | 自增 ID |
| `data_cache` | 数据缓存 | 自增 ID |
| `web_push_subscriptions` | Web 推送订阅 | 自增 ID |

**安全机制：**

- 默认不覆盖目标库已有数据
- `--truncate-target --yes` 需双重确认才会清空目标表
- 批量写入（`BATCH_SIZE=100`），自动重置序列

---

## 7.5 Cloudflare Worker 部署

### 7.5.1 Worker 代码

Worker 代码位于 `apps/mobile_web/web/_worker.js`，约 1780 行，作为 Cloudflare Pages 的 Functions 部署。

**Worker 路由规则：**

| 路由 | 处理方式 | 说明 |
|------|----------|------|
| `POST /auth/auto-login` | 边缘处理 | 完整 CAS 登录流程（含验证码 OCR、RSA 加密） |
| `POST /auth/relogin` | 边缘处理 | 使用存储凭证重新登录 |
| `GET /health` | 边缘处理 | 健康检查 |
| 其他所有请求 | 代理至 Vercel | 注入 Worker 认证头部和 Cookie |

### 7.5.2 KV 命名空间

Worker 使用 Cloudflare KV 存储会话 Cookie，实现边缘侧会话持久化。

**wrangler.toml 配置：**

```toml
name = "onegzus-onweb"
pages_build_output_dir = ""
compatibility_date = "2026-06-09"

[[env.production.kv_namespaces]]
id = "09627cf70d7a493f87d8a95f20e682a0"
binding = "SESSIONS_KV"
```

| 配置项 | 说明 |
|--------|------|
| `name` | Pages 项目名称 |
| `SESSIONS_KV` | KV 命名空间绑定名，Worker 代码中通过 `env.SESSIONS_KV` 访问 |
| `id` | KV 命名空间 ID |

**KV 存储结构：**

```
Key:   session:{sessionId}:jwxt_cookies     → JWXT Cookie 字符串
Key:   session:{sessionId}:ehall_cookies    → ehall Cookie 字符串
Key:   session:{sessionId}:account          → 学号
Key:   session:{sessionId}:credential_token → 加密凭证
```

### 7.5.3 自定义域名

Worker 通过自定义域名 `onegzus.cc.cd` 对外提供服务：

- 用户访问 `https://onegzus.cc.cd/api/*` 时，请求到达 Cloudflare Worker
- Worker 根据路由规则决定边缘处理或代理至 Vercel
- Vercel 后端通过 `JWXT_WORKER_PROXY_ORIGIN=https://onegzus.cc.cd` 将 JWXT API 调用路由回 Worker，保持 IP 绑定一致性

### 7.5.4 Worker → Vercel 内部 API 桥接

Worker 调用 Vercel 后端的内部端点时，通过 `X-Internal-Key` 头传递 `INTERNAL_API_KEY` 进行认证：

| 端点 | 方法 | 说明 |
|------|------|------|
| `/internal/ocr` | POST | 验证码 OCR 识别（ddddocr） |
| `/internal/decrypt-password` | POST | RSA 密码解密 |
| `/internal/create-session` | POST | 创建服务端会话 |

> **安全要求**：`INTERNAL_API_KEY` 必须在 Worker 和 Vercel 两端保持一致。如果密钥不匹配，Worker 调用内部端点将返回 403。

---

## 7.6 CI/CD 流水线

### 7.6.1 流水线总览

项目使用 GitHub Actions 实现自动化构建和部署，所有工作流在 `push to master` 时触发，同时支持 `workflow_dispatch` 手动触发。

```mermaid
graph LR
    subgraph 触发条件
        PUSH[push to master]
        MANUAL[workflow_dispatch]
    end

    subgraph 工作流
        FE[deploy-frontend.yml<br/>Flutter → Cloudflare Pages]
        API[deploy-api.yml<br/>Vercel 部署]
        CF[deploy-cloudflare-pages.yml<br/>website → intro-onegzus]
        EO[deploy-edgeone-pages.yml<br/>海外部署]
    end

    PUSH --> FE
    PUSH --> API
    PUSH --> CF
    MANUAL --> FE
    MANUAL --> API
    MANUAL --> CF
    MANUAL --> EO

    API -.->|仅 services/api/** 变更时| API
```

### 7.6.2 deploy-frontend.yml

**触发条件：** 任意 push 到 `master` 分支 + `workflow_dispatch`

**执行步骤：**

| 步骤 | 操作 | 说明 |
|------|------|------|
| 1 | Checkout | 检出代码 |
| 2 | Setup Flutter | 安装 Flutter 3.44.0 |
| 3 | Install dependencies | `flutter pub get` |
| 4 | Build Web | `flutter build web --release --dart-define=API_BASE_URL=...` |
| 5 | Clean build output | 移除 `.symbols`、CanvasKit 变体、`NOTICES` |
| 6 | Deploy to onegzus-onweb | `wrangler pages deploy` |
| 7 | Deploy to onegzus | `wrangler pages deploy`（镜像部署） |

**所需 Secrets：**

- `CLOUDFLARE_API_TOKEN`
- `CLOUDFLARE_ACCOUNT_ID`
- `API_BASE_URL`（可选，默认 `https://onegzus-onweb.pages.dev/api`）

### 7.6.3 deploy-api.yml

**触发条件：** `services/api/**` 路径下的变更 + `workflow_dispatch`

**执行步骤：**

| 步骤 | 操作 | 说明 |
|------|------|------|
| 1 | Checkout | 检出代码 |
| 2 | Deploy to Vercel | `npx vercel --prod --yes --token $VERCEL_TOKEN` |

**所需 Secrets：**

- `VERCEL_TOKEN`

> **路径过滤**：仅当 `services/api/` 目录下有变更时才触发部署，避免前端修改导致后端无意义重部署。

### 7.6.4 deploy-cloudflare-pages.yml

**触发条件：** 任意 push 到 `master` 分支 + `workflow_dispatch`

**执行步骤：**

| 步骤 | 操作 | 说明 |
|------|------|------|
| 1 | Checkout | 检出代码 |
| 2 | Deploy | `wrangler pages deploy website --project-name=intro-onegzus` |

**所需 Secrets：**

- `CLOUDFLARE_API_TOKEN`
- `CLOUDFLARE_ACCOUNT_ID`

### 7.6.5 deploy-edgeone-pages.yml（海外部署）

**触发条件：** 仅 `workflow_dispatch` 手动触发

**执行步骤：**

| 步骤 | 操作 | 说明 |
|------|------|------|
| 1 | Checkout | 检出代码 |
| 2 | Deploy to EdgeOne | 部署到 EdgeOne Pages（海外加速） |

**所需 Secrets：**

- `EDGEONE_API_TOKEN`

> **说明**：此工作流仅用于海外部署，需要手动触发，不在常规 CI 流程中。

### 7.6.6 CI/CD 所需 Secrets 汇总

| Secret 名称 | 用于工作流 | 说明 |
|--------------|------------|------|
| `CLOUDFLARE_API_TOKEN` | deploy-frontend, deploy-cloudflare-pages | Cloudflare API 令牌 |
| `CLOUDFLARE_ACCOUNT_ID` | deploy-frontend, deploy-cloudflare-pages | Cloudflare 账户 ID |
| `VERCEL_TOKEN` | deploy-api | Vercel 部署令牌 |
| `EDGEONE_API_TOKEN` | deploy-edgeone-pages | EdgeOne API 令牌 |
| `API_BASE_URL` | deploy-frontend（可选） | 前端 API 地址 |

---

## 7.7 环境配置管理

### 7.7.1 .env 文件结构

后端使用 `pydantic-settings` 管理配置，从 `services/api/.env` 文件读取环境变量。参考 `.env.example` 模板：

```bash
# ─── 学校系统 URL ───
JW_BASE_URL=https://jwxt.seig.edu.cn/jwglxt
EHALL_BASE_URL=https://ehall.gzus.edu.cn
CAS_LOGIN_URL=https://cas.gzus.edu.cn/lyuapServer/login
EHALL_SERVICE_URL=http://ehall.gzus.edu.cn/shiro-cas
JWXT_SSO_SERVICE_URL=https://jwxt.seig.edu.cn/sso/lyiotlogin

# ─── 应用 URL ───
PUBLIC_API_BASE_URL=https://your-app.vercel.app
FRONTEND_BASE_URL=https://onegzus.pages.dev

# ─── CORS ───
CORS_ORIGINS=http://localhost:3000,http://localhost:5173,http://localhost:8080
CORS_ORIGIN_REGEX=^https?://(localhost|127\.0\.0\.1|192\.168\.\d{1,3}\.\d{1,3})(:\d+)?$

# ─── 会话 ───
SESSION_TTL_SECONDS=7200
SSO_TTL_SECONDS=300
REQUEST_TIMEOUT_SECONDS=15

# ─── 推送 ───
JPUSH_APP_KEY=
JPUSH_MASTER_SECRET=
PUSH_POLL_INTERVAL_SECONDS=1800
WS_HEARTBEAT_SECONDS=30

# ─── 数据库 ───
DATABASE_URL=postgresql://user:password@host:5432/dbname?sslmode=require
DB_POOL_SIZE=1
DB_MAX_OVERFLOW=2
DB_POOL_TIMEOUT=10
DB_POOL_RECYCLE=300

# ─── 一卡通 ───
ECARD_BASE_URL=https://ecarduser.gzus.edu.cn
ECARD_OPENID=
ECARD_UNIONID=
ECARD_SECRET=
ECARD_VERIFY_TLS=true
ECARD_DAILY_REMINDER_HOUR=8
ECARD_DAILY_REMINDER_MINUTE=0

# ─── 安全 ───
CREDENTIAL_ENCRYPTION_KEY=change-this-to-a-random-32-byte-string
EHALL_CSRF_KEY=

# ─── 应用版本 ───
APP_LATEST_VERSION=0.1.1-Dev
APP_LATEST_BUILD=4
APP_MIN_SUPPORTED_VERSION=0.0.1
APP_MIN_SUPPORTED_BUILD=1
APP_DOWNLOAD_URL=
APP_RELEASE_NOTES=Dev
```

### 7.7.2 关键环境变量清单

#### 核心必填变量

| 变量名 | 说明 | 生成方式 |
|--------|------|----------|
| `DATABASE_URL` | PostgreSQL 连接字符串 | Neon 控制台获取，使用 Pooled URL |
| `CREDENTIAL_ENCRYPTION_KEY` | 凭证加密密钥 | `python -c "import secrets; print(secrets.token_urlsafe(32))"` |
| `INTERNAL_API_KEY` | Worker→API 内部认证密钥 | 自定义随机字符串，需与 Worker 端一致 |

#### 安全相关变量

| 变量名 | 说明 | 备注 |
|--------|------|------|
| `RSA_PRIVATE_KEY_PEM` | RSA 私钥（PEM 格式） | 避免 Vercel 冷启动时密钥轮换导致前端解密失败 |
| `EHALL_CSRF_KEY` | ehall CSRF 令牌 | ehall 接口访问所需 |

#### 推送相关变量

| 变量名 | 说明 | 备注 |
|--------|------|------|
| `JPUSH_APP_KEY` | 极光推送 AppKey | 留空则关闭 Android 推送 |
| `JPUSH_MASTER_SECRET` | 极光推送 Master Secret | 留空则关闭 Android 推送 |
| `WEB_PUSH_VAPID_PUBLIC_KEY` | Web Push VAPID 公钥 | 浏览器推送所需 |
| `WEB_PUSH_VAPID_PRIVATE_KEY` | Web Push VAPID 私钥 | 浏览器推送所需 |

#### 一卡通相关变量

| 变量名 | 说明 | 备注 |
|--------|------|------|
| `ECARD_OPENID` | 一卡通 OpenID | 一卡通接口认证 |
| `ECARD_UNIONID` | 一卡通 UnionID | 一卡通接口认证 |
| `ECARD_SECRET` | 一卡通密钥 | 一卡通接口签名 |

### 7.7.3 各平台环境变量配置方式

| 平台 | 配置方式 | 优先级 |
|------|----------|--------|
| 本地开发 | `services/api/.env` 文件 | 最高 |
| Vercel | Dashboard → Settings → Environment Variables | 覆盖 `vercel.json` 中的 `env` |
| GitHub Actions | Repository → Settings → Secrets and variables | CI 构建时使用 |
| Cloudflare Worker | Worker 代码中硬编码或环境变量 | 需与 Vercel 端一致 |

> **安全原则**：`.env` 文件已在 `.gitignore` 中排除，绝不提交到仓库。敏感密钥（`CREDENTIAL_ENCRYPTION_KEY`、`INTERNAL_API_KEY`、`RSA_PRIVATE_KEY_PEM` 等）仅通过平台环境变量或 Secrets 管理。

### 7.7.4 生产环境启动校验

`config.py:get_settings()` 在生产环境（`DEBUG=false`）下执行以下强制校验：

1. **`CREDENTIAL_ENCRYPTION_KEY` 必须设置** — 否则抛出 `RuntimeError`
2. **`PUBLIC_API_BASE_URL` 必须使用 HTTPS** — 否则抛出 `RuntimeError`
3. **`FRONTEND_BASE_URL` 必须使用 HTTPS** — 否则抛出 `RuntimeError`
4. **`DATABASE_URL` 必须是 PostgreSQL** — `database.py` 启动时校验，拒绝文件型 SQLite

---

## 7.8 本地开发环境

### 7.8.1 restart.ps1 一键启动

`restart.ps1` 位于项目根目录，一键启动后端和前端开发环境：

```powershell
.\restart.ps1
```

**执行流程：**

| 步骤 | 操作 | 说明 |
|------|------|------|
| 1 | 停止现有进程 | 终止端口 8000 上的进程和所有 Dart 进程 |
| 2 | 启动后端 | 新窗口运行 `uvicorn app.main:app --reload` |
| 3 | 启动前端 | 新窗口运行 `flutter run -d chrome --dart-define=API_BASE_URL=http://127.0.0.1:8000` |
| 4 | 完成 | 后端 `http://0.0.0.0:8000`，前端 Chrome 调试模式 |

### 7.8.2 后端开发

```bash
cd services/api
python -m venv .venv
.venv\Scripts\activate        # Windows
pip install -r requirements.txt
uvicorn app.main:app --reload --reload-dir app --reload-exclude .venv --host 0.0.0.0
```

| 配置 | 说明 |
|------|------|
| 端口 | `8000` |
| 热重载 | `--reload`，监听 `app/` 目录变更 |
| 数据库 | 本地 `.env` 配置，或 SQLite 内存库（测试） |
| 后台任务 | 本地环境启动通知轮询等 poller |

### 7.8.3 前端开发

```bash
cd apps/mobile_web
flutter pub get
flutter run -d chrome --dart-define=API_BASE_URL=http://127.0.0.1:8000
```

| 配置 | 说明 |
|------|------|
| 设备 | Chrome 浏览器 |
| API 地址 | `http://127.0.0.1:8000` |
| 热重载 | Flutter 默认支持 |

### 7.8.4 测试环境

```bash
cd services/api
pytest
```

**测试环境自动配置（`conftest.py`）：**

| 配置项 | 值 | 说明 |
|--------|-----|------|
| `DEBUG` | `true` | 跳过生产环境校验 |
| `DATABASE_URL` | `sqlite:///:memory:` | 内存数据库，测试后自动销毁 |
| `CREDENTIAL_ENCRYPTION_KEY` | 测试用密钥 | 通过 monkeypatch 注入 |

> **注意**：`test_api.py` 和 `test_login.py` 是手动集成测试，需要 `GZUS_TEST_ACCOUNT` 和 `GZUS_TEST_PASSWORD` 环境变量，不在默认 `pytest` 中运行。

---

## 7.9 监控与运维

### 7.9.1 健康检查

**端点：** `GET /health`

**响应：**

```json
{
  "status": "ok"
}
```

**处理位置：**

- **边缘层**：Cloudflare Worker 直接响应，不代理至 Vercel
- **后端**：`app/main.py` 中定义，用于 Vercel 健康检查

### 7.9.2 日志策略

| 组件 | 日志方式 | 说明 |
|------|----------|------|
| Vercel 后端 | `logging` 标准库 | Vercel 自动收集函数日志 |
| Cloudflare Worker | `console.log` / `console.error` | Cloudflare Dashboard → Workers → Logs 实时查看 |
| Flutter 前端 | `print()` / `debugPrint()` | 浏览器控制台输出 |

**关键日志点：**

- 会话创建/恢复/过期（`sessions.py`）
- Worker Cookie 注入/恢复（`deps.py`）
- RSA 密钥不匹配警告（`internal.py`）
- Vercel 代理重试/失败（`_worker.js`）

### 7.9.3 错误追踪

| 层级 | 错误处理方式 | 说明 |
|------|-------------|------|
| FastAPI 全局异常 | `global_exception_handler` | 捕获所有未处理异常，返回 500 + 日志 |
| Worker 代理失败 | 重试 2 次后返回 401/502 | 有本地会话返回 502，无本地会话返回 401 |
| 数据库操作 | SQLAlchemy 异常 + 事务回滚 | `_ensure_columns` 安全忽略已存在列 |
| RSA 密钥不匹配 | 返回 400 + 详细信息 | 提示前端刷新页面获取新公钥 |

### 7.9.4 成本监控要点

免费部署方案下，需重点关注以下指标：

| 监控项 | 平台 | 免费额度 | 告警阈值 |
|--------|------|----------|----------|
| Neon 连接数 | Neon Dashboard | 5 个并发连接 | > 4 个 |
| Vercel 函数执行时间 | Vercel Dashboard | 100 GB-Hrs/月 | > 80% |
| Vercel 函数调用次数 | Vercel Dashboard | 免费版无硬限制 | 异常增长 |
| Cloudflare Worker 请求数 | Cloudflare Dashboard | 100,000 次/天 | > 80,000 次/天 |
| Cloudflare KV 读写 | Cloudflare Dashboard | 100,000 读/天，1,000 写/天 | 接近限额 |
| Cloudflare Pages 带宽 | Cloudflare Dashboard | 免费版无硬限制 | 异常增长 |

---

## 7.10 成本优化策略

### 7.10.1 免费部署默认策略

软帮手以零成本运行为目标，所有核心服务均使用免费方案：

| 服务 | 免费方案 | 限制 |
|------|----------|------|
| Cloudflare Pages | 无限静态站点 | 每次构建 500 次上限 |
| Cloudflare Workers | 100,000 请求/天 | 10ms CPU 时间/请求 |
| Cloudflare KV | 100,000 读/天 | 1,000 写/天 |
| Vercel | 100 GB-Hrs/月 | 10s 函数超时 |
| Neon PostgreSQL | 0.5 GB 存储 | 5 个并发连接 |

### 7.10.2 连接池最小化

Serverless 环境下数据库连接是稀缺资源，采用以下策略：

- **Pooled Connection String**：使用 Neon 的连接池代理，减少直连数
- **小连接池**：`DB_POOL_SIZE=1`、`DB_MAX_OVERFLOW=2`（免费方案默认）
- **连接回收**：`DB_POOL_RECYCLE=300`，5 分钟回收空闲连接
- **连接前检测**：`pool_pre_ping=True`，避免使用已断开的连接

### 7.10.3 JPush 可选关闭

推送服务为可选功能，不配置即可关闭：

- `JPUSH_APP_KEY` 和 `JPUSH_MASTER_SECRET` 留空 → 不发送 Android 推送
- `WEB_PUSH_VAPID_PUBLIC_KEY` 和 `WEB_PUSH_VAPID_PRIVATE_KEY` 留空 → 不发送 Web 推送
- 关闭推送后，相关后台轮询任务仍可运行（仅不发送推送通知）

### 7.10.4 缓存策略减少后端调用

| 缓存层 | 实现 | 说明 |
|--------|------|------|
| Worker 边缘缓存 | Cloudflare KV | 会话 Cookie 在边缘侧缓存，减少 DB 查询 |
| 后端内存缓存 | `cache_service.py` | 通知、考试提醒、成绩更新等数据的内存缓存 |
| 前端缓存 | Flutter 本地存储 | 课表、成绩等数据本地缓存，离线可用 |
| 请求去重 | Worker 侧 | 同一会话的并发请求合并 |

### 7.10.5 上线后优先观察

| 观察项 | 关注点 | 应对措施 |
|--------|--------|----------|
| Neon 连接数 | 是否接近 5 个上限 | 优化查询、增加缓存 |
| Vercel 函数超时 | 慢接口是否频繁超时 | 将耗时操作移至 Worker 边缘 |
| Worker 请求量 | 是否接近 10 万/天 | 前端缓存兜底、减少轮询频率 |
| 登录成功率 | CAS 验证码识别准确率 | 调整 OCR 参数、增加重试次数 |

---

## 附录：部署检查清单

### 首次部署

- [ ] Neon PostgreSQL 实例已创建，获取 Pooled Connection String
- [ ] Vercel 项目已创建，`DATABASE_URL` 等环境变量已配置
- [ ] `CREDENTIAL_ENCRYPTION_KEY` 已生成并配置到 Vercel
- [ ] `INTERNAL_API_KEY` 已在 Worker 和 Vercel 两端配置一致
- [ ] Cloudflare Pages 项目 `onegzus-onweb` 和 `onegzus` 已创建
- [ ] Cloudflare KV 命名空间 `SESSIONS_KV` 已创建并绑定
- [ ] 自定义域名 `onegzus.cc.cd` 已配置 CNAME 指向 Cloudflare Pages
- [ ] GitHub Secrets 已配置（`CLOUDFLARE_API_TOKEN`、`VERCEL_TOKEN` 等）
- [ ] `RSA_PRIVATE_KEY_PEM` 已配置（避免冷启动密钥轮换）

### 日常运维

- [ ] 检查 Neon 连接数是否正常
- [ ] 检查 Vercel 函数执行时长和错误率
- [ ] 检查 Cloudflare Worker 请求量和 KV 读写量
- [ ] 检查 `/health` 端点响应正常
- [ ] 检查 CI/CD 流水线运行状态