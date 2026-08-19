# 第2章 后端模块设计

## 2.1 后端整体架构

### 2.1.1 技术栈概览

后端位于 `services/api/app/`，基于 **FastAPI**（Python 3.11+）构建，部署到 **Vercel Serverless**。整体采用分层架构，自上而下分为：

| 层级 | 目录/文件 | 职责 |
|------|-----------|------|
| 入口层 | `main.py` | 应用创建、中间件注册、路由挂载、生命周期管理 |
| 路由层 | `routes/` | HTTP 端点定义、请求校验、响应序列化 |
| 客户端层 | `*_client.py` | 封装外部系统（教务系统、ehall、一卡通）的 API 调用 |
| 服务层 | `*_service.py`, `sessions.py` | 业务逻辑、会话管理、缓存、通知处理 |
| 后台任务 | `jobs.py` | 定时轮询器（通知、考试提醒、成绩更新、水电费） |
| 推送层 | `push.py` | JPush / Web Push 消息推送 |
| 辅助模块 | `config.py`, `database.py`, `schemas.py` 等 | 配置、数据库、数据模型、加解密等基础设施 |
| Vendored | `vendor/school_sdk/` | 打过补丁的学校 SDK |

### 2.1.2 应用入口 — `main.py`

`main.py` 是整个后端的入口，核心职责如下：

#### 应用创建（`create_app()`）

```python
def create_app() -> FastAPI:
    settings = get_settings()
    app = FastAPI(title="软帮手 API", version="0.1.1", lifespan=lifespan)
```

- 读取配置（`get_settings()`）
- 创建 FastAPI 实例，绑定生命周期管理器
- 初始化应用状态（`app.state`）
- 注册中间件、异常处理器、路由

#### 应用状态管理（`app.state`）

| 属性 | 类型 | 用途 |
|------|------|------|
| `sessions` | `SessionStore` | 会话存储（PostgreSQL 持久化 + 内存缓存） |
| `pending_captcha` | `dict` | 等待验证码的登录会话（token → (client, account)） |
| `ly_sso_states` | `dict` | SSO 登录流程的 state 映射（防 CSRF） |
| `ws_manager` | `ConnectionManager` | WebSocket 连接管理器 |
| `notice_cache` | `NoticeCache` | 通知轮询缓存（按 session 记录已推送标题） |
| `exam_reminder_cache` | `ExamReminderCache` | 考试提醒缓存（按 session 记录已提醒考试） |
| `grade_update_cache` | `GradeUpdateCache` | 成绩更新缓存（按 student 记录成绩快照） |
| `rsa_key_manager` | `RsaKeyManager` | RSA 密钥管理器 |
| `limiter` | `Limiter` | slowapi 速率限制器 |

#### 生命周期管理（`lifespan`）

```python
@asynccontextmanager
async def lifespan(app: FastAPI):
    if not IS_VERCEL:
        init_db()
        poller_task = asyncio.create_task(run_notice_poller(app))
        ecard_task = asyncio.create_task(run_ecard_reminder_poller(app))
        exam_task = asyncio.create_task(run_exam_reminder_poller(app))
        grade_task = asyncio.create_task(run_grade_update_poller(app))
    await app.state.sessions.start_cleanup_task()
    yield
    # 清理...
```

- **启动阶段**：
  - 非 Vercel 环境：初始化数据库、启动四个后台轮询器
  - 启动会话清理任务（每 300 秒清理过期会话）
- **关闭阶段**：
  - 取消所有后台任务
  - 停止会话清理任务

> **Vercel 环境说明**：在 Vercel Serverless 上（`IS_VERCEL=True`），不启动后台轮询器和数据库初始化，因为 Serverless 函数是无状态的，不适合运行长生命周期任务。轮询器仅在本地开发环境运行。

#### 中间件链

按注册顺序（后注册先执行），请求经过的中间件依次为：

1. **CORS 中间件** — 跨域资源共享
   - `allow_origins`：配置的 CORS 白名单 + 前端 origin
   - `allow_origin_regex`：匹配 `localhost`、`192.168.*`、`*.pages.dev`、`*.vercel.app`
   - `allow_methods`：`GET`、`POST`、`PATCH`
   - `allow_headers`：`X-Session-Id`、`Content-Type`、`User-Agent`
   - `allow_credentials`：`False`

2. **SlowAPI 中间件** — 速率限制
   - 基于 `X-Forwarded-For` 头识别客户端（适配 Cloudflare Worker 代理）
   - 各端点通过 `@limiter.limit()` 装饰器配置限制

3. **安全与请求体限制中间件** — 自定义 HTTP 中间件
   - 请求体大小限制：10MB（`MAX_BODY_BYTES`）
   - 安全响应头：
     - `X-Content-Type-Options: nosniff`
     - `X-Frame-Options: DENY`
     - `Referrer-Policy: strict-origin-when-cross-origin`
     - `Permissions-Policy: camera=(), microphone=(), geolocation=()`
     - 生产环境：`Strict-Transport-Security: max-age=31536000; includeSubDomains`

4. **全局异常处理器**
   - 捕获所有未处理异常，记录日志，返回 500 + 中文错误消息

#### 路由注册

```python
app.include_router(auth.router)       # /auth/*
app.include_router(academic.router)   # /me, /schedule, /exams, ...
app.include_router(ehall.router)      # /ehall/*
app.include_router(ecard.router)      # /ecard/*
app.include_router(push.router)       # /push/*
app.include_router(weather.router)    # /weather/*
app.include_router(ws_router)         # /ws/notifications
app.include_router(internal_router)   # /internal/* （懒加载）
```

> **注意**：`internal_router` 在 `create_app()` 内部懒加载导入，避免循环依赖。

---

## 2.2 路由层设计

路由层位于 `services/api/app/routes/`，负责 HTTP 端点定义、请求校验和响应序列化。所有需要认证的路由通过 `Depends(require_session)` 注入会话。

### 2.2.1 依赖注入 — `deps.py`

`deps.py` 是路由层的核心依赖模块，提供 `require_session` 依赖注入函数。

#### `require_session(request, x_session_id)`

**职责**：解析并验证用户会话，是所有需认证端点的入口守卫。

**执行流程**：

1. **检查 Session-Id 头**：若缺失，返回 401
2. **从数据库加载会话**：调用 `sessions.get(session_id)`
   - 内含 DB 连接重试（3 次，应对 Neon 冷启动延迟）
   - 内含 read-after-write 重试（3 次，应对 PostgreSQL 复制延迟）
3. **检查会话吊销状态**：若 `revoked_at` 非空，返回 401（单设备登录策略）
4. **注入 Worker Cookie**：调用 `_inject_worker_cookies()`
5. **空闲过期检测**：若 Worker 未注入 Cookie 且空闲超过 25 分钟，返回 401
6. **Touch 会话**：更新 `last_active_at`

#### `_inject_worker_cookies(session, request)`

**职责**：将 Cloudflare Worker 边缘节点传来的新鲜 Cookie 注入到会话客户端中。

**机制**：

- 读取 `X-Worker-Auth` 头确认请求来自 Worker
- 读取 `Cookie` 头注入 JWXT Cookie 到 `session.client`
- 读取 `X-Ehall-Cookies` 头注入 ehall Cookie 到 `session.ehall_client`
- 读取 `X-Student-Account` 头恢复账号信息
- 若 `session.client` 为 `None`（DB Cookie 过期），尝试从 Worker Cookie 重建客户端（**恢复机制**）

**关键常量**：

| 常量 | 值 | 含义 |
|------|-----|------|
| `SESSION_IDLE_STALE_THRESHOLD` | 25 分钟 | JWXT 会话通常 30 分钟过期，提前 5 分钟触发重新登录 |

### 2.2.2 认证路由 — `auth.py`

**前缀**：`/auth`  
**标签**：`auth`  
**速率限制**：登录相关端点 10 次/分钟

| 端点 | 方法 | 功能 | 认证 |
|------|------|------|------|
| `/auth/public-key` | GET | 获取 RSA 公钥（用于密码加密传输） | 否 |
| `/auth/login` | POST | 账号密码登录（教务系统） | 否 |
| `/auth/captcha` | POST | 提交验证码完成登录 | 否 |
| `/auth/ly/start` | GET | 发起 SSO 登录（重定向到 CAS） | 否 |
| `/auth/ly/callback` | GET | SSO 回调（接收 CAS ticket） | 否 |
| `/auth/ly/complete` | POST | 完成 SSO 登录（用 ticket 换取 JWXT Cookie） | 否 |
| `/auth/auto-login` | POST | CAS 自动登录（含验证码 OCR） | 否 |
| `/auth/relogin` | POST | 凭据令牌重新登录 | 否 |
| `/auth/student-info` | GET | 获取学生详细信息（登录后异步调用） | 是 |
| `/auth/logout` | POST | 注销登录 | 是 |

#### 登录流程

**1. 普通登录（`/auth/login`）**

```
客户端 → POST /auth/login {account, password/encryptedPassword}
  → 解密密码（若 encryptedPassword）
  → client.login(account, password)
  → 若需验证码 → 返回 captcha_required + 验证码图片
  → 若成功 → sessions.create() → 返回 sessionId
```

**2. CAS 自动登录（`/auth/auto-login`）**

```
客户端 → POST /auth/auto-login {account, password/encryptedPassword}
  → 解密密码
  → CasAutoLogin.auto_login(account, password)
    → 访问 CAS 登录页
    → 提取验证码 → OCR 识别（最多 15 次重试）
    → RSA 加密密码 → 提交 CAS
    → 跟随重定向获取 JWXT Cookie + ehall Cookie
  → 创建 SchoolSdkClient + EhallClient
  → 加密凭据（Fernet）→ sessions.create()
  → 返回 sessionId + credentialToken + ehall 信息
```

**3. 重新登录（`/auth/relogin`）**

```
客户端 → POST /auth/relogin {credentialToken}
  → 解密凭据令牌（Fernet，带 TTL）
  → CasAutoLogin.auto_login(account, password)
  → 创建新会话 → 返回 sessionId
```

**4. SSO 登录（`/auth/ly/start` → `/auth/ly/callback` → `/auth/ly/complete`）**

```
客户端 → GET /auth/ly/start
  → 生成 state → 重定向到 CAS
CAS → GET /auth/ly/callback?ticket=xxx&state=yyy
  → 验证 state → 重定向回前端
客户端 → POST /auth/ly/complete {ssoCode: ticket}
  → 用 ticket 换取 JWXT Cookie
  → 创建会话 → 返回 sessionId
```

### 2.2.3 教务路由 — `academic.py`

**前缀**：无（根级路由）  
**标签**：`academic`  
**认证**：全部需要

| 端点 | 方法 | 功能 |
|------|------|------|
| `/me` | GET | 获取学生信息 |
| `/schedule` | GET | 获取课表（支持 year/term 筛选） |
| `/exams` | GET | 获取考试安排（支持 year/term 筛选） |
| `/grades` | GET | 获取成绩（支持 year/term 筛选） |
| `/attendance` | GET | 获取考勤记录（支持 year/term 筛选） |
| `/credits` | GET | 获取学分统计 |
| `/notices` | GET | 获取通知列表（教务 + ehall 合并去重） |
| `/notices/detail` | GET | 获取通知详情 |

#### 缓存回退机制

所有教务路由使用 `_run_with_cache_fallback()` 实现**缓存回退**：

1. 尝试调用教务系统 API
2. 成功 → 保存到 `DataCache` 表 → 返回结果
3. 失败（401 除外）→ 尝试从 `DataCache` 加载缓存 → 返回缓存数据 + `X-Data-Source: cache` 头

#### 通知合并

`/notices` 端点合并教务系统通知和 ehall 通知：

1. 获取教务系统通知（`client.get_notices()`）
2. 获取 ehall 通知（`ehall_client.get_notice_items()`）
3. 按 `(category, title, url)` 去重
4. 使用 `notice_utils` 清洗文本、过滤乱码

### 2.2.4 一站式服务路由 — `ehall.py`

**前缀**：`/ehall`  
**标签**：`ehall`  
**认证**：全部需要

| 端点 | 方法 | 功能 |
|------|------|------|
| `/ehall/tasks` | GET | 获取待办/申请/已办/关注/待阅/已阅/草稿 |
| `/ehall/affairs` | GET | 获取办事大厅事项列表 |
| `/ehall/applications` | GET | 获取申请列表 |
| `/ehall/progress` | GET | 获取进度概览 |
| `/ehall/leave/preview` | POST | 请假预览（计算缺课信息） |
| `/ehall/leave/fill` | POST | 自动填写请假申请 |
| `/ehall/leave/attachment` | POST | 上传请假附件 |

#### 请假流程

**预览（`/ehall/leave/preview`）**：

1. 根据请假日期范围，从课表计算受影响课程
2. 按课程分组，统计缺课次数
3. 检查必填字段是否完整（`missingFields`）

**自动填写（`/ehall/leave/fill`）**：

1. 生成请假预览
2. 匹配任课教师为 ehall 经办人（`staff_service.resolve_teacher()`）
3. 生成自动填表脚本（`leave_service.build_leave_fill_script()`）
4. 生成经办人选择脚本（`leave_service.build_leave_handler_script()`）
5. 上传附件到 ehall
6. 返回填表脚本 + 经办人信息 + 未匹配教师列表

### 2.2.5 一卡通路由 — `ecard.py`

**前缀**：`/ecard`  
**标签**：`ecard`  
**认证**：全部需要

| 端点 | 方法 | 功能 |
|------|------|------|
| `/ecard/rooms` | GET | 搜索宿舍列表（服务端过滤，1 小时缓存） |
| `/ecard/binding` | POST | 绑定宿舍 |
| `/ecard/summary` | GET | 获取水电费余额摘要 |
| `/ecard/refresh` | POST | 刷新水电费余额 |
| `/ecard/summary-cache` | PATCH | 更新客户端缓存的余额数据 |
| `/ecard/reminder` | PATCH | 更新提醒设置 |
| `/ecard/consumption` | GET | 获取月度消费记录 |

#### 宿舍列表缓存

- 全量宿舍列表约 6700 条 / 880 KB，从一卡通 API 获取需约 2.5 秒
- 使用模块级变量 `_rooms_cache` 缓存，TTL 1 小时
- 支持关键词搜索（校区/楼栋/房间号），服务端过滤后返回

#### 绑定与余额

- 绑定宿舍时自动查询余额（`refresh_binding()`）
- 余额数据持久化到 `EcardBinding.last_summary_json`
- 支持低余额提醒配置（阈值、提醒时间、提醒项目）

### 2.2.6 推送路由 — `push.py`

**前缀**：`/push`  
**标签**：`push`  
**认证**：大部分需要

| 端点 | 方法 | 功能 | 认证 |
|------|------|------|------|
| `/push/web/config` | GET | 获取 Web Push VAPID 配置 | 否 |
| `/push/web/register` | POST | 注册 Web Push 订阅 | 是 |
| `/push/web/unregister` | POST | 注销 Web Push 订阅 | 是 |
| `/push/register` | POST | 注册 JPush 推送 | 是 |
| `/push/unregister` | POST | 注销 JPush 推送 | 是 |
| `/push/test` | POST | 发送测试推送 | 是 |
| `/push/poll` | GET | 轮询推送消息（HTTP fallback） | 是 |
| `/push/test-session` | POST | 创建测试会话（仅 debug 模式） | 否 |

### 2.2.7 天气路由 — `weather.py`

**前缀**：`/weather`  
**标签**：`weather`  
**认证**：无需

| 端点 | 方法 | 功能 |
|------|------|------|
| `/weather` | GET | 获取天气数据（代理 wttr.in） |

**特性**：

- 支持 `lat`/`lon` 参数定位，默认广州
- 内存缓存 30 分钟（按坐标键）
- wttr.in 超时/错误时返回过期缓存
- 将 wttr.in 原始数据转换为中文格式（天气代码、风向、风力等级）
- 包含 3 日天气预报

### 2.2.8 内部路由 — `internal.py`

**前缀**：`/internal`  
**标签**：`internal`  
**认证**：`X-Internal-Key` 头（与 `INTERNAL_API_KEY` 环境变量匹配）

这些端点仅供 Cloudflare Worker 调用，用于卸载需要 Python 运行时的操作。

| 端点 | 方法 | 功能 |
|------|------|------|
| `/internal/ocr` | POST | 验证码 OCR 识别 |
| `/internal/decrypt-password` | POST | RSA 密码解密 |
| `/internal/create-session` | POST | 从 CAS 登录结果创建会话 |

#### 安全机制

- 所有端点需通过 `X-Internal-Key` 头验证
- RSA 密钥不匹配时返回 400 + 详细错误信息（提示前端刷新公钥）
- `/internal/create-session` 跳过 JWXT Cookie 验证（Worker 边缘 IP 绑定）

---

## 2.3 客户端层设计

客户端层封装了与外部系统（教务系统、ehall、一卡通）的 HTTP 交互，是后端最核心的业务逻辑层。

### 2.3.1 教务系统客户端 — `school_client.py`

**代码量**：约 2084 行，是后端最大的文件。  
**核心类**：`SchoolSdkClient`

#### 职责

- 封装 JWXT（教务管理系统）的所有 API 调用
- 管理登录态（Cookie 管理、请求重试）
- 通过 Worker 代理发送请求（保持 IP 绑定）
- 使用 vendored school_sdk + 补丁

#### 关键异常类

| 异常 | 继承 | 含义 |
|------|------|------|
| `AuthenticationError` | `RuntimeError` | 认证失败（Cookie 过期/无效） |
| `MissingProxySlotError` | `NotImplementedError` | 缺少代理槽位（考勤功能依赖代理） |
| `CaptchaRequired` | `RuntimeError` | 登录需要验证码（携带 `CaptchaChallenge`） |

#### 关键数据类

| 类 | 用途 |
|----|------|
| `CaptchaChallenge` | 验证码挑战（token + 图片 base64 + client 引用） |

#### 构造参数

```python
SchoolSdkClient(
    base_url: str,                    # JWXT 基础 URL
    timeout_seconds: int = 15,        # 请求超时
    httpx_client: Any | None = None,  # 外部 httpx 客户端（CAS 登录用）
    session_id: str | None = None,    # 会话 ID（Worker 代理用）
    worker_proxy_origin: str | None = None,  # Worker 代理 origin
)
```

#### 核心 API 方法

| 方法 | 功能 | JWXT 路径 |
|------|------|-----------|
| `login(account, password)` | 账号密码登录 | CAS SSO |
| `login_with_cookies(cookies, account, validate)` | Cookie 登录 | — |
| `submit_captcha(code)` | 提交验证码 | CAS SSO |
| `get_info()` | 获取学生信息 | `/jwglxt/xsxxxggl/xsgrxxwh_cxXsgrxx.html` |
| `get_schedule(year, term)` | 获取课表 | `/jwglxt/kbcx/xskbcx_cxXsKb.html` |
| `get_exams(year, term)` | 获取考试安排 | `/jwglxt/kwgl/kscx_cxXsksxxIndex.html` |
| `get_grades(year, term)` | 获取成绩 | — |
| `get_attendance(year, term)` | 获取考勤 | `/jwglxt/jxdmgl/jxdmqkcx_cxJxdmqkcxIndex.html` |
| `get_credits()` | 获取学分 | `/jwglxt/design/funcData_cxFuncDataList.html` |
| `get_notices()` | 获取通知列表 | `/jwglxt/xtgl/index_cxNews.html` |
| `get_notice_detail(url)` | 获取通知详情 | — |
| `logout()` | 注销 | — |

#### Worker 代理机制

```python
def _jwxt_origin(self) -> str:
    if self._worker_proxy_origin:
        return self._worker_proxy_origin
    parsed = urlparse(self.base_url)
    return f"{parsed.scheme}://{parsed.netloc}"
```

- 当 `worker_proxy_origin` 设置时，所有 JWXT 请求通过 Cloudflare Worker 代理
- Worker 根据 `X-Jwxt-Session-Id` 头识别会话，注入对应的 Cookie
- 保持 Worker 边缘 IP 绑定，使 IP 绑定的 Cookie 始终有效

#### 请求重试

- 上游 JWXT 请求最多重试 2 次（`_MAX_RETRIES = 2`）
- 指数退避基础延迟 0.5 秒（`_RETRY_BACKOFF_BASE = 0.5`）
- 仅对可重试异常（网络错误、5xx）重试

#### 缓存

- 使用 `simple_cache` 装饰器，TTL 10 分钟（`CACHE_TTL`）
- 基于 `(args, kwargs)` 生成缓存键

#### 依赖关系

- → `school_sdk_patches.py`：应用 SDK 补丁
- → `vendor/school_sdk/`：底层 SDK
- → `config.py`：读取配置
- ← `routes/academic.py`：教务路由调用
- ← `routes/auth.py`：登录路由调用
- ← `routes/ehall.py`：请假预览调用 `get_schedule()`
- ← `sessions.py`：会话重建时调用 `login_with_cookies()`

### 2.3.2 一站式服务客户端 — `ehall_client.py`

**代码量**：约 809 行  
**核心类**：`EhallClient`

#### 职责

- 封装 ehall（一站式服务大厅）的所有 API 调用
- 管理登录态（Cookie + Authorization token）
- 请假工作流（填写申请、上传附件）
- 并发获取多类别任务

#### 关键异常

| 异常 | 继承 | 含义 |
|------|------|------|
| `EhallAuthenticationError` | `RuntimeError` | ehall 认证失败 |

#### 构造参数

```python
EhallClient(
    base_url: str,                    # ehall 基础 URL
    cookies: str | dict = "",         # Cookie 字符串或字典
    auth_token: str | None = None,    # Authorization token
    timeout_seconds: int = 15,        # 请求超时
)
```

#### 任务端点映射

```python
TASK_ENDPOINTS = {
    "待办": "api/bpm/processes/tasks/pending",
    "申请": "api/bpm/processes/tasks/apply",
    "已办": "api/bpm/processes/tasks/done",
    "关注": "api/bpm/processes/tasks/follow",
    "待阅": "api/bpm/processes/tasks/unread",
    "已阅": "api/bpm/processes/tasks/read",
    "草稿": "api/bpm/processes/tasks/draft",
}
```

#### 核心 API 方法

| 方法 | 功能 |
|------|------|
| `get_notice_items(page_size)` | 获取通知列表（并发获取 7 个类别） |
| `get_affairs()` | 获取办事大厅事项 |
| `get_applications()` | 获取申请列表 |
| `get_progress_overview()` | 获取进度概览（含分类统计） |
| `fill_leave_application(...)` | 填写请假申请 |
| `upload_leave_attachment(...)` | 上传请假附件 |

#### 请假工作流常量

| 常量 | 值 | 含义 |
|------|-----|------|
| `LEAVE_WORKFLOW_NUMBER` | `R_S003_B036` | 请假流程编号 |
| `LEAVE_WORKFLOW_PROCESS_ID` | `c6a5de7f...` | 请假流程 ID |
| `ATTACHMENT_WORKFLOW_NUMBER` | `R_S004_B002` | 附件上传流程编号 |

#### 请求重试

- 上游 ehall 请求最多重试 2 次（`_EHALL_MAX_RETRIES = 2`）
- 指数退避基础延迟 0.5 秒

#### 依赖关系

- → `config.py`：读取配置
- ← `routes/ehall.py`：ehall 路由调用
- ← `sessions.py`：会话重建时调用
- ← `jobs.py`：通知轮询器调用 `get_notice_items()`

### 2.3.3 一卡通客户端 — `ecard_client.py`

**代码量**：约 371 行  
**核心类**：`EcardClient`  
**关键数据类**：`EcardRoomRef`

#### 职责

- 封装融校云一卡通 API 调用
- 宿舍列表查询、余额查询、消费记录查询
- API 签名计算

#### 关键异常

| 异常 | 继承 | 含义 |
|------|------|------|
| `EcardConfigurationError` | `RuntimeError` | 配置缺失（openid/secret 未设置） |
| `EcardApiError` | `RuntimeError` | 一卡通 API 调用失败 |

#### 签名计算（`calc_sign()`）

```python
def calc_sign(params: dict, secret: str | None = None) -> str:
    filtered = {k: v for k, v in params.items() if k not in ("token", "sign")}
    raw = "&".join(f"{key}={filtered[key]}" for key in sorted(filtered)) + f"&{secret_value}"
    return hashlib.md5(raw.encode()).hexdigest().upper()
```

- 过滤 `token` 和 `sign` 参数
- 按 key 字典序排列
- 拼接 secret 后 MD5 哈希

#### `EcardRoomRef` 数据类

```python
@dataclass(frozen=True)
class EcardRoomRef:
    impl_type: str       # 实现类型（如 CGCOMMON1111）
    school_area_no: str  # 校区编号
    building_no: str     # 楼栋编号
    room_num: str        # 房间号

    @property
    def id(self) -> str:
        return "|".join((self.impl_type, self.school_area_no, self.building_no, self.room_num))
```

- 使用 `|` 分隔的复合 ID 标识宿舍
- `from_id()` 方法从字符串解析

#### 核心 API 方法

| 方法 | 功能 |
|------|------|
| `rooms()` | 获取全量宿舍列表 |
| `balance(room_ref, student_id)` | 查询水电费余额 |
| `consumption(room_ref, month)` | 查询月度消费记录 |

#### 请求代理

- 所有请求通过 `worker_proxy_origin` 代理（Cloudflare Worker）
- 模拟微信 User-Agent（`WX_UA`）
- 不验证 TLS（`ecard_verify_tls: bool = False`）

#### 依赖关系

- → `config.py`：读取 ecard 配置（openid、secret、proxy origin）
- ← `routes/ecard.py`：一卡通路由调用
- ← `jobs.py`：水电费提醒轮询器调用

---

## 2.4 服务层设计

### 2.4.1 会话管理 — `sessions.py`

**代码量**：约 600 行  
**核心类**：`SessionStore`、`AppSession`

#### 设计目标

为 Vercel Serverless 无状态环境设计持久化会话存储。每次冷启动后，从数据库重建客户端对象。

#### `AppSession` 数据类

```python
@dataclass
class AppSession:
    id: str                           # 会话 ID（UUID hex）
    client: Any                       # SchoolSdkClient 实例
    student_name: str | None          # 学生姓名
    ehall_client: Any | None          # EhallClient 实例
    created_at: datetime              # 创建时间
    last_active_at: datetime          # 最后活跃时间
    push_registration_id: str | None  # JPush 注册 ID
    push_platform: str                # 推送平台（默认 android）
    encrypted_credentials: str | None # Fernet 加密的凭据令牌
    revoked_at: datetime | None       # 吊销时间
    revoked_reason: str | None        # 吊销原因
    student_account: str | None       # 学号
```

#### `SessionStore` 类

**核心方法**：

| 方法 | 功能 |
|------|------|
| `create(client, student_name, ...)` | 创建会话（写入 DB + 内存缓存） |
| `get(session_id, touch=True)` | 获取会话（DB 优先 → 重建客户端 → 内存缓存） |
| `touch(session_id)` | 更新最后活跃时间 |
| `update(session_id, **fields)` | 更新会话字段（白名单：push_registration_id、encrypted_credentials 等） |
| `remove(session_id)` | 删除会话 |
| `start_cleanup_task()` | 启动定期清理任务（每 300 秒） |
| `stop_cleanup_task()` | 停止清理任务 |
| `_purge_expired()` | 清理过期会话 |

#### 会话创建流程（`create()`）

1. 从客户端对象提取 JWXT Cookie 和 ehall Cookie
2. 生成 UUID 作为会话 ID
3. **单设备登录策略**：吊销同一账号的已有会话
4. 写入 `AppSessionModel` 到数据库（含 3 次重试）
5. 存入内存缓存 `_sessions`

#### 会话获取流程（`get()`）

1. 获取 DB 连接（3 次重试，应对 Neon 冷启动）
2. 查询 `AppSessionModel`
3. 若未找到 → read-after-write 重试（3 次，应对复制延迟）
4. 检查滑动 TTL（`last_active_at + TTL`）
5. 检查吊销状态
6. 若内存缓存命中 → 更新字段并返回
7. 若缓存未命中 → 从 DB Cookie 重建客户端对象
   - 重建失败时 `client=None`，允许 Worker Cookie 注入恢复
8. Touch 并返回

#### 凭据加密/解密

```python
def encrypt_credentials(account: str, password: str, key: str) -> str:
    """使用 Fernet 加密 account:password"""

def decrypt_credentials(token: str, key: str, ttl_seconds: int | None = None) -> tuple[str, str]:
    """解密凭据令牌，返回 (account, password)"""
```

- 使用 `cryptography.fernet.Fernet` 加密
- 密钥通过 SHA-256 哈希配置中的 `CREDENTIAL_ENCRYPTION_KEY` 生成
- 解密支持 TTL 检查

#### 客户端重建

```python
def _rebuild_school_client(jwxt_cookies, validate_cookies=False, session_id=None, account=None):
    """从存储的 Cookie 重建 SchoolSdkClient"""

def _rebuild_ehall_client(ehall_cookies, ehall_auth_token):
    """从存储的 Cookie 重建 EhallClient"""
```

- 默认不验证 Cookie（`validate_cookies=False`），因为 Worker 边缘 IP 绑定的 Cookie 无法从 Vercel IP 验证
- 重建失败时返回 `client=None`，依赖 Worker Cookie 注入恢复

#### 依赖关系

- → `database.py`：`AppSessionModel` 模型
- → `school_client.py`：重建客户端
- → `ehall_client.py`：重建客户端
- → `config.py`：读取 `credential_encryption_key`
- ← `main.py`：创建 SessionStore 实例
- ← `routes/deps.py`：获取/更新会话
- ← `routes/auth.py`：创建会话
- ← `routes/internal.py`：创建会话

### 2.4.2 请假服务 — `leave_service.py`

**代码量**：约 339 行

#### 职责

- 请假预览生成（计算缺课信息）
- 自动填表脚本生成
- 经办人选择脚本生成

#### 关键常量

```python
SECTION_TIMES = [
    (time(9, 0), time(9, 40)),    # 第1节
    (time(9, 40), time(10, 20)),  # 第2节
    ...
    (time(21, 10), time(21, 50)), # 第16节
]
```

定义了 16 节课的时间表，用于将课表中的节次转换为具体时间。

#### 核心函数

| 函数 | 功能 |
|------|------|
| `build_leave_preview(courses, start_date, end_date, year, term, first_week_start)` | 生成请假预览（受影响课程列表 + 缺课次数） |
| `build_leave_fill_script(start_date, end_date, reason, courses)` | 生成自动填表 JavaScript 脚本 |
| `build_leave_handler_script(matched_teachers)` | 生成经办人选择 JavaScript 脚本 |
| `leave_days(start_date, end_date)` | 计算请假天数 |
| `default_first_week_start(year, term)` | 计算学期第一周起始日 |

#### 预览生成逻辑

1. 根据日期范围遍历每一天
2. 计算当天所在周次（相对学期第一周）
3. 匹配课表中当天有课的课程
4. 按课程分组，统计缺课次数
5. 检查必填字段（课程代码、教学班代码、课程性质、教师）

#### 依赖关系

- → `school_client.py`：使用 `pick()` 工具函数
- ← `routes/ehall.py`：请假路由调用

### 2.4.3 教职工服务 — `staff_service.py`

**代码量**：约 206 行  
**核心数据类**：`StaffCandidate`、`TeacherResolution`

#### 职责

- 从 ehall 同步教职工信息到数据库
- 教师姓名匹配（用于请假经办人选择）

#### 核心函数

| 函数 | 功能 |
|------|------|
| `sync_staff_from_ehall_cookie(cookie_header)` | 从 ehall API 同步教职工数据 |
| `ensure_staff_loaded(cookie_header)` | 确保教职工数据已加载（优先 ehall 同步，回退 JSON 文件） |
| `resolve_teacher(teacher_name)` | 解析教师姓名，返回匹配结果 |
| `import_staff_records(records)` | 批量导入教职工记录 |
| `import_staff_from_json_fallback()` | 从 JSON 文件导入（回退方案） |

#### 教师匹配

```python
@dataclass(frozen=True)
class TeacherResolution:
    teacher: str                     # 原始教师姓名
    status: str                      # 匹配状态
    match: StaffCandidate | None     # 精确匹配结果
    candidates: list[StaffCandidate] | None  # 候选列表（模糊匹配）
```

- 优先精确匹配 `cn_name`
- 支持模糊匹配返回候选列表
- 匹配不到时返回空候选列表

#### 依赖关系

- → `database.py`：`StaffMember` 模型
- → `config.py`：`ehall_staff_sync_url`、`ehall_staff_json_path`
- ← `routes/ehall.py`：请假填表时调用

### 2.4.4 缓存服务 — `cache_service.py`

**代码量**：约 135 行

#### 职责

- 基于 `DataCache` 表的持久化缓存
- 为教务路由提供缓存回退机制

#### 核心函数

| 函数 | 功能 |
|------|------|
| `save_cache(student_id, resource, data, params)` | 保存缓存（upsert） |
| `load_cache(student_id, resource, params)` | 加载缓存 |
| `get_cached_at(student_id, resource, params)` | 获取缓存时间 |
| `load_and_get_cached_at(student_id, resource, params)` | 一次查询获取缓存数据 + 时间 |
| `clear_cache_for_student(student_id)` | 清除学生所有缓存 |

#### 缓存键设计

```
cache_key = "{student_id}:{resource}:{params_hash}"
```

- `student_id`：学号
- `resource`：资源类型（如 `schedule`、`exams`、`grades`）
- `params_hash`：参数的 SHA-256 前 16 位（如 `{"year": "2024", "term": "1"}`）

#### 依赖关系

- → `database.py`：`DataCache` 模型
- ← `routes/academic.py`：教务路由的缓存回退

### 2.4.5 通知工具 — `notice_utils.py`

**代码量**：约 52 行

#### 职责

- 通知文本清洗（去除控制字符、多余空白）
- 乱码检测（检测 UTF-8 编码错误、Mojibake）
- 通知项标准化和过滤

#### 核心函数

| 函数 | 功能 |
|------|------|
| `clean_notice_text(value)` | 清洗通知文本（去除控制字符、合并空白） |
| `looks_garbled(value)` | 检测文本是否乱码 |
| `normalize_notice_item(item)` | 标准化通知项（清洗 category/title/summary/date） |
| `is_valid_notice_item(item)` | 判断通知项是否有效（非空、非乱码、含可读字符） |
| `valid_notice_items(items)` | 批量过滤有效通知项 |

#### 乱码检测逻辑

1. 检测 UTF-8 替换字符（`\ufffd`）和 C1 控制字符（`\u0080-\u009f`）
2. 检测 Mojibake 特征字符（如 `Ã`、`Â`、`€`、`œ` 等）
3. 若同时出现 Mojibake 字母和 Mojibake 标记，判定为乱码

#### 依赖关系

- ← `routes/academic.py`：通知路由过滤
- ← `jobs.py`：通知轮询器过滤

---

## 2.5 后台任务设计 — `jobs.py`

**代码量**：约 671 行

后台任务仅在本地开发环境运行（`IS_VERCEL=False`），Vercel Serverless 环境不启动。

### 2.5.1 通知轮询器

**函数**：`run_notice_poller(app)` / `run_notice_poller_once(app)`  
**间隔**：`push_poll_interval_seconds`（默认 1800 秒 = 30 分钟）

#### 执行流程

1. 遍历所有活跃会话（`sessions._sessions`）
2. 对每个会话并发执行：
   a. 获取教务通知 + ehall 通知（合并去重）
   b. 与缓存对比，找出新通知
   c. 通过 WebSocket 推送 + JPush 推送 + Web Push 推送
3. 更新缓存

#### `NoticeCache` 类

```python
class NoticeCache:
    def __init__(self):
        self._titles_by_session: dict[str, set[str]] = {}

    def get_cached_titles(self, session_id) -> set[str]
    def update(self, session_id, titles: set[str])
    def remove(self, session_id)
```

- 按 session_id 存储已推送通知的 key 集合
- 通知 key 格式：`"{category}|{title}|{url}"`
- 首次轮询仅建立基线，不推送

### 2.5.2 考试提醒轮询器

**函数**：`run_exam_reminder_poller(app)` / `run_exam_reminder_once(app)`  
**间隔**：30 分钟

#### 执行流程

1. 遍历所有活跃会话
2. 对每个会话并发执行：
   a. 获取考试列表
   b. 筛选今天的考试
   c. 检查是否已提醒（缓存）
   d. 构建考试提醒消息（含进度条 Live Update 信息）
   e. 通过 WebSocket + JPush + Web Push 推送
3. 标记已提醒

#### `ExamReminderCache` 类

```python
class ExamReminderCache:
    def __init__(self):
        self._reminded: dict[str, set[str]] = {}

    def is_reminded(self, session_id, exam_key) -> bool
    def mark_reminded(self, session_id, exam_key)
    def remove(self, session_id)
```

- 考试 key 格式：`"{courseName}|{time}"`
- 每个考试仅提醒一次

#### 考试时间解析

- 解析格式：`"2025-01-15 09:00-11:00"`
- 提取开始时间作为 Live Update 的 `endTime`
- 已过开始时间的考试跳过提醒

### 2.5.3 成绩更新轮询器

**函数**：`run_grade_update_poller(app)` / `run_grade_update_once(app)`  
**间隔**：`push_poll_interval_seconds`（默认 30 分钟）

#### 执行流程

1. 遍历所有活跃会话
2. 对每个会话并发执行：
   a. 获取学号
   b. 获取成绩列表
   c. 与缓存快照对比，找出变化的成绩
   d. 通过 WebSocket + JPush + Web Push 推送
3. 更新缓存

#### `GradeUpdateCache` 类

```python
class GradeUpdateCache:
    def __init__(self):
        self._grades_by_student: dict[str, dict[str, str]] = {}

    def get(self, student_id) -> dict[str, str]
    def update(self, student_id, grades: dict[str, str])
    def remove(self, student_id)
```

- 按 student_id 存储成绩快照
- 快照 key：`"{term}|{courseName}"`
- 快照 value：`"{score}|{gradePoint}"`

#### 成绩变化检测

```python
def changed_grade_items(items, previous) -> list[dict]:
    """返回新增或分数/绩点变化的课程"""
```

- 新增课程：key 不在 previous 中
- 变化课程：score 或 gradePoint 与 previous 不同

### 2.5.4 水电费提醒轮询器

**函数**：`run_ecard_reminder_poller(app)` / `run_ecard_reminder_once(app)`  
**间隔**：根据用户配置的提醒时间动态计算

#### 执行流程

1. 收集所有启用提醒的宿舍绑定
2. 计算下次提醒时间（`_next_reminder_at()`）
3. 等待到提醒时间
4. 对每个绑定：
   a. 查询水电费余额
   b. 根据阈值判断是否需要提醒
   c. 构建提醒消息（含 Live Update 进度信息）
   d. 通过 WebSocket + JPush + Web Push 推送
5. 更新提醒计数（每天每项最多 2 次）

#### 提醒消息生成（`ecard_reminder_message()`）

| 条件 | 消息 |
|------|------|
| 电量 < 10 度 | "电量极低" |
| 电量 < 阈值 | "电量偏低" |
| 冷水 < 阈值 | "冷水偏低" |
| 热水 < 阈值 | "热水偏低" |
| 无阈值触发 | "今日水电费"（汇总） |

#### 提醒时间管理

- 支持用户自定义提醒时间（最多 2 个）
- 默认 08:00
- 每日重置提醒计数
- 同一项目每天最多提醒 2 次

---

## 2.6 推送服务设计 — `push.py`

**代码量**：约 178 行

### 2.6.1 JPush 推送

#### `send_push(registration_ids, title, alert, extras)`

- 使用 JPush V3 API（`https://api.jpush.cn/v3/push`）
- 支持 Android 和 iOS
- 认证：`app_key:master_secret`（Basic Auth）
- 生产环境使用 APNs 生产证书
- 超时 10 秒

#### `send_broadcast(title, alert, extras)`

- 全量广播推送
- `audience: "all"`

#### `send_push_to_all(registration_ids, title, alert, extras)`

- 分批推送（每批 1000 个 registration_id）
- JPush 单次推送上限 1000

#### 通知构建（`_build_notification()`）

```python
{
    "alert": alert,
    "android": {"alert": alert, "extras": extras},
    "ios": {"alert": alert, "title": title, "extras": extras},
}
```

### 2.6.2 Web Push 推送

#### `send_web_push_to_student(student_id, title, body, extras)`

- 使用 `pywebpush` 库
- VAPID 协议认证
- 查询 `WebPushSubscription` 表获取订阅信息
- 推送失败时：
  - 404/410：删除无效订阅
  - 其他错误：记录日志

#### `is_web_push_enabled()`

- 检查 `web_push_vapid_public_key` 和 `web_push_vapid_private_key` 是否配置

### 2.6.3 推送消息格式

推送消息包含以下 Live Update 字段（用于 iOS Live Activity）：

| 字段 | 含义 |
|------|------|
| `id` | 消息唯一标识 |
| `type` | 消息类型（`new_notice`、`exam_reminder`、`grade_update`、`ecard_reminder`） |
| `liveUpdate` | 是否为 Live Update |
| `style` | 显示样式（`progress`） |
| `shortCriticalText` | 简短关键文本 |
| `progressMax` | 进度最大值 |
| `progressCurrent` | 进度当前值 |
| `progress` | 进度百分比（0-1） |
| `endTime` | 结束时间（epoch ms） |
| `ongoing` | 是否持续中 |

---

## 2.7 辅助模块

### 2.7.1 配置管理 — `config.py`

**代码量**：约 108 行  
**核心类**：`Settings`（继承 `pydantic_settings.BaseSettings`）

#### 配置项分类

| 分类 | 配置项 | 默认值 |
|------|--------|--------|
| **教务系统** | `jw_base_url` | `https://jwxt.seig.edu.cn/jwglxt` |
| | `jwxt_worker_proxy_origin` | 空（直连） |
| **ehall** | `ehall_base_url` | `https://ehall.gzus.edu.cn` |
| | `ehall_staff_sync_url` | 空 |
| | `ehall_staff_json_path` | 空 |
| | `ehall_csrf_key` | 空 |
| **CAS** | `cas_login_url` | `https://cas.gzus.edu.cn/lyuapServer/login` |
| | `ehall_service_url` | `http://ehall.gzus.edu.cn/shiro-cas` |
| | `jwxt_sso_service_url` | `https://jwxt.seig.edu.cn/sso/lyiotlogin` |
| **一卡通** | `ecard_base_url` | `https://ecarduser.gzus.edu.cn` |
| | `ecard_worker_proxy_origin` | `https://onegzus.cc.cd` |
| | `ecard_openid` / `ecard_unionid` / `ecard_secret` | 空 |
| | `ecard_verify_tls` | `False` |
| | `ecard_daily_reminder_hour` / `minute` | 8:00 |
| **推送** | `jpush_app_key` / `jpush_master_secret` | 空 |
| | `web_push_vapid_public_key` / `private_key` / `subject` | 空 |
| | `push_poll_interval_seconds` | 1800 |
| **会话** | `session_ttl_seconds` | 7200（2 小时） |
| | `sso_ttl_seconds` | 300（5 分钟） |
| | `ehall_session_ttl_hours` | 24 |
| **数据库** | `database_url` | 空（必须设置） |
| | `db_pool_size` | 3 |
| | `db_max_overflow` | 5 |
| | `db_pool_timeout` | 10 |
| | `db_pool_recycle` | 300 |
| **安全** | `credential_encryption_key` | 空（生产必须设置） |
| | `rsa_private_key_pem` | 空（自动生成） |
| | `internal_api_key` | 空 |
| **网络** | `request_timeout_seconds` | 6 |
| | `request_connect_timeout_seconds` | 5 |
| | `cas_login_timeout_seconds` | 60 |
| **CORS** | `cors_origins` | localhost 列表 |
| | `cors_origin_regex` | localhost/192.168.* 正则 |
| **应用** | `app_latest_version` / `build` | `0.1.1` / `4` |
| | `app_min_supported_version` / `build` | `0.0.1` / `1` |
| | `debug` | `False` |

#### 生产环境验证

`get_settings()` 使用 `@lru_cache` 缓存，首次调用时执行验证：

- `CREDENTIAL_ENCRYPTION_KEY` 必须设置
- `PUBLIC_API_BASE_URL` 必须使用 HTTPS
- `FRONTEND_BASE_URL` 必须使用 HTTPS

### 2.7.2 数据库管理 — `database.py`

**代码量**：约 322 行

#### ORM 模型

| 模型 | 表名 | 用途 |
|------|------|------|
| `EhallSession` | `ehall_sessions` | ehall 会话存储（已弃用，保留兼容） |
| `EcardBinding` | `ecard_bindings` | 一卡通宿舍绑定 + 提醒配置 |
| `PushRegistration` | `push_registrations` | JPush 推送注册 |
| `WebPushSubscription` | `web_push_subscriptions` | Web Push 订阅 |
| `DataCache` | `data_cache` | 持久化缓存 |
| `StaffMember` | `staff_members` | 教职工信息 |
| `AppSessionModel` | `app_sessions` | 应用会话持久化 |

#### `AppSessionModel` 详细字段

| 字段 | 类型 | 用途 |
|------|------|------|
| `id` | `String(64)` PK | 会话 ID |
| `student_name` | `String(100)` | 学生姓名 |
| `student_account` | `String(100)` | 学号 |
| `created_at` | `DateTime` | 创建时间 |
| `last_active_at` | `DateTime` | 最后活跃时间 |
| `push_registration_id` | `String(300)` | JPush 注册 ID |
| `push_platform` | `String(50)` | 推送平台 |
| `jwxt_cookies` | `Text` | JWXT Cookie 字符串 |
| `ehall_cookies` | `Text` | ehall Cookie 字符串 |
| `ehall_auth_token` | `Text` | ehall Authorization token |
| `encrypted_credentials` | `Text` | Fernet 加密凭据 |
| `revoked_at` | `DateTime` | 吊销时间 |
| `revoked_reason` | `String(100)` | 吊销原因 |

#### `EcardBinding` 详细字段

| 字段 | 类型 | 用途 |
|------|------|------|
| `student_id` | `String(100)` UK | 学号 |
| `room_id` | `String(200)` | 宿舍 ID（EcardRoomRef.id 格式） |
| `room_display` | `String(200)` | 宿舍显示名称 |
| `reminder_enabled` | `Boolean` | 是否启用提醒 |
| `low_power_threshold` | `Float` | 低电量阈值（默认 30 度） |
| `low_cold_water_threshold` | `Float` | 低冷水阈值（默认 5 吨） |
| `low_hot_water_threshold` | `Float` | 低热水阈值（默认 10 元） |
| `reminder_times` | `Text` | 提醒时间列表（JSON，最多 2 个） |
| `reminder_items` | `Text` | 提醒项目列表（JSON） |
| `last_summary_json` | `Text` | 最近余额数据（JSON） |
| `last_checked_at` | `DateTime` | 最近检查时间 |
| `last_reminded_date` | `String(20)` | 最近提醒日期 |
| `last_reminded_times` | `Text` | 当日提醒次数（JSON） |

#### 引擎管理

- **同步引擎**：`get_sync_engine()` → PostgreSQL（连接池）/ SQLite（StaticPool）
- **异步引擎**：`get_async_engine()` → `postgresql+asyncpg` / `sqlite+aiosqlite`
- **URL 解析**：自动处理 `postgres://` → `postgresql://` 等格式差异
- **验证**：生产环境拒绝 SQLite 文件数据库，仅允许 PostgreSQL 或 `:memory:`

#### 轻量迁移（`_ensure_columns()`）

```python
def _ensure_columns(engine, table, columns: dict[str, str]) -> None:
    """为已有表添加新列（幂等操作，适合 Serverless 冷启动）"""
```

- 不使用迁移框架，每次冷启动执行 `ALTER TABLE ADD COLUMN`
- 已存在的列会静默忽略
- 当前迁移：`app_sessions` 表添加 `student_account`、`revoked_at`、`revoked_reason`

#### SQLite 优化

- WAL 模式
- `synchronous=NORMAL`
- 64MB 缓存
- 5 秒忙等待超时

### 2.7.3 请求/响应模型 — `schemas.py`

**代码量**：约 424 行

所有 Pydantic 模型定义，用于请求验证和响应序列化。

#### 认证相关

| 模型 | 用途 |
|------|------|
| `LoginRequest` | 登录请求（支持明文/RSA加密密码） |
| `AutoLoginRequest` | 自动登录请求 |
| `ReloginRequest` | 重新登录请求（凭据令牌） |
| `CaptchaRequest` | 验证码提交 |
| `SsoCompleteRequest` | SSO 完成请求 |
| `AuthResponse` | 认证响应 |

#### 教务相关

| 模型 | 用途 |
|------|------|
| `StudentInfo` | 学生信息 |
| `ScheduleCourse` | 课表课程 |
| `ExamItem` | 考试安排 |
| `GradeItem` | 成绩 |
| `AttendanceItem` / `AttendanceRecord` / `AttendanceResponse` | 考勤 |
| `CreditItem` | 学分统计 |
| `NoticeItem` / `NoticeDetail` | 通知 |

#### ehall 相关

| 模型 | 用途 |
|------|------|
| `EhallAffairItem` | ehall 事项 |
| `EhallApplicationItem` | ehall 申请 |
| `EhallProgressItem` / `EhallProgressCategory` / `EhallProgressOverview` | ehall 进度 |
| `LeavePreviewRequest` / `LeavePreviewResponse` | 请假预览 |
| `LeaveFillRequest` / `LeaveFillResponse` | 请假填写 |
| `LeaveAttachmentUploadRequest` | 请假附件上传 |
| `TeacherHandlerSelection` / `StaffCandidateItem` / `MatchedTeacherItem` | 教师经办人 |

#### 一卡通相关

| 模型 | 用途 |
|------|------|
| `EcardBindingRequest` | 宿舍绑定请求 |
| `EcardSummary` | 余额摘要 |
| `EcardReminderRequest` | 提醒设置请求 |
| `EcardRoomItem` | 宿舍列表项 |
| `EcardConsumptionItem` / `EcardConsumptionResponse` | 消费记录 |

#### 推送相关

| 模型 | 用途 |
|------|------|
| `PushRegisterRequest` | JPush 注册请求 |
| `WebPushSubscriptionRequest` | Web Push 订阅请求 |
| `WebPushConfigResponse` | Web Push 配置响应 |

#### 关键设计模式

- 所有模型使用 `alias` 支持 camelCase JSON 字段名
- `LoginRequest.resolve_password()` 和 `AutoLoginRequest.resolve_password()` 内置密码解密逻辑
- `EcardSummaryCacheRequest` 使用 `extra = "forbid"` 防止未知字段

### 2.7.4 RSA 密钥管理 — `rsa_keys.py`

**代码量**：约 57 行  
**核心类**：`RsaKeyManager`（单例 `rsa_key_manager`）

#### 职责

- 管理 RSA 密钥对（用于密码加密传输）
- 前端用公钥加密密码 → 后端用私钥解密

#### 密钥来源

1. 优先从配置读取 `RSA_PRIVATE_KEY_PEM`（支持 .env 文件）
2. 回退到环境变量 `RSA_PRIVATE_KEY`
3. 均无则自动生成 2048 位 RSA 密钥对

> **注意**：自动生成的密钥在每次冷启动时会变化，导致前端缓存的公钥失效。生产环境必须设置 `RSA_PRIVATE_KEY_PEM`。

#### Key ID

```python
self._key_id = hashlib.sha256(pub_der).hexdigest()[:12]
```

- 基于公钥 DER 编码的 SHA-256 前 12 位
- 用于检测密钥不匹配（前端 keyId ≠ 后端 keyId）

#### 解密

```python
def decrypt(self, base64_ciphertext: str) -> str:
    ciphertext = base64.b64decode(base64_ciphertext)
    plaintext = self._private_key.decrypt(ciphertext, padding.PKCS1v15())
    return plaintext.decode()
```

- 使用 PKCS#1 v1.5 填充（与前端加密方式匹配）

### 2.7.5 验证码 OCR — `captcha_ocr.py`

**代码量**：约 42 行  
**核心类**：`CaptchaOcr`（单例 `captcha_ocr`）

#### 职责

- 封装 ddddocr 验证码识别
- 懒加载 ddddocr 库

#### 特性

- ddddocr 懒加载：服务器启动时不需要安装 ddddocr
- 识别失败返回空字符串（不抛异常）
- ddddocr 未安装时抛出 `RuntimeError`，给出安装提示

### 2.7.6 CAS 自动登录 — `cas_auto_login.py`

**代码量**：约 651 行  
**核心类**：`CasAutoLogin`  
**核心数据类**：`CasLoginResult`

#### 职责

- 实现完整的 CAS SSO 自动登录流程
- 包含验证码 OCR、RSA 加密、重定向跟踪
- 同时获取 JWXT Cookie 和 ehall Cookie

#### CAS 登录流程

```
1. GET CAS 登录页 → 提取 lt/execution/加密参数
2. 若有验证码 → OCR 识别（最多 15 次重试）
3. RSA 加密密码（BigInt.js 风格，非标准 PKCS#1）
4. POST CAS 登录 → 跟随重定向
5. 获取 JWXT Cookie
6. 可选：访问 ehall → 获取 ehall Cookie + auth token
```

#### RSA 加密实现

```python
def _rsa_encrypt(plaintext: str) -> str:
    """BigInt.js 风格 RSA 加密（零填充，非 PKCS#1）"""
```

- 模拟 CAS 前端的 `encryptedString` 函数
- 使用 Dave Shapiro 的 BigInt 库的自定义零填充
- 每个 chunk：2 字节打包为 BigInt digit（小端序：低字节 + 高字节<<8）
- RSA 加密：`c = m^e mod n`

#### CAS 错误码

| 错误码 | 含义 |
|--------|------|
| `FALSE` | 用户名或密码错误 |
| `CODEFALSE` | 验证码错误 |
| `PASSERROR` | 密码错误（含锁定信息） |
| `NOUSER` | 用户不存在 |
| `USERDISABLED` | 用户已禁用 |
| `USERLOCK` | 用户已锁定 |
| `ISPHONEOREMAILORANSWER` | 需要二次验证 |
| `ISMODIFYPASS` | 需要修改密码 |
| `NETWORKCOMMITMENT` | 需要网络承诺 |
| `PEOPLEMOREACCOUNT` | 多账号 |

#### OCR 纠错

```python
_OCR_CHAR_FIXES = {
    "o": "0", "O": "0",
    "l": "1", "I": "1", "|": "1",
    "S": "5", "s": "5",
    "b": "6", "G": "6",
    "B": "8",
    "g": "9", "q": "9",
}
```

- CAS 验证码为算术题（如 `3+5=?`）
- OCR 常见误识别字符映射
- 仅在原始 OCR 结果无法解析为有效表达式时应用

#### `CasLoginResult` 数据类

```python
@dataclass
class CasLoginResult:
    account: str                      # 学号
    cookies: str                      # JWXT Cookie 字符串
    ehall_cookies: str | None         # ehall Cookie
    ehall_auth_token: str | None      # ehall Authorization token
    error: str | None                 # 错误信息
    httpx_client: Any | None          # httpx 客户端（含 Cookie jar）
```

#### 依赖关系

- → `captcha_ocr.py`：验证码识别
- ← `routes/auth.py`：`auto_login` 和 `relogin` 端点调用
- ← `routes/internal.py`：Worker 调用的 CAS 登录

### 2.7.7 速率限制 — `rate_limit.py`

**代码量**：4 行

```python
limiter = Limiter(key_func=get_remote_address, default_limits=[])
```

- 使用 `slowapi` 库
- 基于远程 IP 地址限制
- 无默认限制，各端点通过装饰器单独配置
- `get_remote_address` 尊重 `X-Forwarded-For` 头（适配 Cloudflare Worker 代理）

### 2.7.8 WebSocket 管理 — `ws.py`

**代码量**：约 103 行  
**核心类**：`ConnectionManager`

#### `ConnectionManager` 类

| 方法 | 功能 |
|------|------|
| `connect(websocket, session_id)` | 接受 WebSocket 连接 |
| `disconnect(session_id)` | 断开连接 |
| `enqueue(session_id, message)` | 入队消息（含 ID 生成和 extras 提取） |
| `drain(session_id)` | 排空待推送消息（HTTP 轮询回退） |
| `send_to_session(session_id, message)` | 发送消息到指定会话 |
| `broadcast(message)` | 广播消息到所有连接 |

#### WebSocket 端点

```
ws://host/ws/notifications?sessionId=xxx
```

- 连接时验证 sessionId
- 验证失败关闭连接（code=4001）
- 保持连接直到客户端断开

#### 消息格式

每条消息自动添加：

- `id`：UUID（若未提供）
- `extras`：提取的 Live Update 字段

#### HTTP 轮询回退

- `/push/poll` 端点调用 `manager.drain()` 获取待推送消息
- 用于不支持 WebSocket 的环境

---

## 2.8 Vendored 代码

### 2.8.1 学校 SDK — `vendor/school_sdk/`

**路径**：`services/api/app/vendor/school_sdk/`

这是从 [FarmerChillax/new-school-sdk](https://github.com/FarmerChillax/new-school-sdk) fork 并打过补丁的版本。

#### 目录结构

```
vendor/school_sdk/
├── __init__.py
├── check_code/        # 验证码处理
├── client/            # 核心客户端
│   └── api/
│       └── schedule_parse.py  # 课表解析（已补丁）
├── config.py          # SDK 配置
├── PyRsa/             # RSA 加密
├── session/           # 会话管理
├── type.py            # 类型定义
└── utils.py           # 工具函数
```

> **重要**：不要从上游更新此 SDK，除非同时检查 `school_sdk_patches.py` 中的补丁是否仍然适用。

### 2.8.2 SDK 补丁管理 — `school_sdk_patches.py`

**代码量**：约 139 行

#### 职责

- 修复 school-sdk 的兼容性问题
- 为 GZUS 16 节课时间表打补丁
- 修复学生信息获取

#### 补丁列表

| 补丁函数 | 功能 |
|----------|------|
| `apply_school_sdk_import_patches()` | 修复 Python 3.14 兼容性（`ast.Bytes` → `ast.Constant`） |
| `apply_school_sdk_patches()` | 替换课表解析器的 `SCHEDULE_TIME` 为 GZUS 16 节课时间表 |
| `apply_school_sdk_info_patch()` | 修复学生信息获取逻辑 |

#### GZUS 16 节课时间表

```python
DEFAULT_SCHEDULE_TIME = {
    "1":  {"start": "0900", "end": "0940"},
    "2":  {"start": "0940", "end": "1020"},
    "3":  {"start": "1040", "end": "1120"},
    "4":  {"start": "1120", "end": "1200"},
    "5":  {"start": "1230", "end": "1310"},
    "6":  {"start": "1310", "end": "1350"},
    "7":  {"start": "1400", "end": "1440"},
    "8":  {"start": "1440", "end": "1520"},
    "9":  {"start": "1530", "end": "1610"},
    "10": {"start": "1610", "end": "1650"},
    "11": {"start": "1700", "end": "1740"},
    "12": {"start": "1740", "end": "1820"},
    "13": {"start": "1900", "end": "1940"},
    "14": {"start": "1940", "end": "2020"},
    "15": {"start": "2030", "end": "2110"},
    "16": {"start": "2110", "end": "2150"},
}
```

#### 补丁标记

- 使用 `_gzus_pro_schedule_patch_applied` 和 `_gzus_pro_info_patch_applied` 标记防止重复应用
- 补丁在 `SchoolSdkClient` 构造时自动应用

---

## 2.9 模块依赖关系总览

```
┌─────────────────────────────────────────────────────────────────┐
│                        main.py (入口)                           │
│  创建 FastAPI → 注册中间件 → 挂载路由 → 管理生命周期            │
└───────────────┬─────────────────────────────────────────────────┘
                │
    ┌───────────┼───────────────────────────────────────────┐
    │           │                                           │
    ▼           ▼                                           ▼
┌────────┐ ┌─────────┐                              ┌──────────┐
│ routes │ │ sessions│                              │  jobs    │
│ (8个)  │ │ (Store) │                              │ (4轮询器)│
└───┬────┘ └────┬────┘                              └────┬─────┘
    │           │                                        │
    │     ┌─────┴──────┐                          ┌──────┴──────┐
    │     │            │                          │             │
    ▼     ▼            ▼                          ▼             ▼
┌──────────┐ ┌──────────┐ ┌──────────┐    ┌──────────┐  ┌──────────┐
│school_   │ │ehall_    │ │ecard_    │    │push.py   │  │ws.py    │
│client.py │ │client.py │ │client.py │    │(JPush/   │  │(WebSocket│
│          │ │          │ │          │    │WebPush)  │  │Manager) │
└────┬─────┘ └──────────┘ └──────────┘    └──────────┘  └──────────┘
     │
     ▼
┌──────────────────┐
│vendor/school_sdk/│
│+ school_sdk_     │
│  patches.py      │
└──────────────────┘

┌──────────────────────────────────────────────────────────────┐
│                     辅助模块 (横切关注点)                     │
├──────────┬──────────┬──────────┬──────────┬─────────────────┤
│config.py │database  │schemas   │rsa_keys  │captcha_ocr.py   │
│(Settings)│(7 Models)│(40+ 模型)│(RSA加解密)│(ddddocr)        │
├──────────┼──────────┼──────────┼──────────┼─────────────────┤
│cas_auto_ │leave_    │staff_    │cache_    │notice_utils.py  │
│login.py  │service.py│service.py│service.py│(文本清洗/乱码)   │
│(CAS登录) │(请假)    │(教职工)  │(持久缓存)│                 │
├──────────┼──────────┼──────────┤          │                 │
│rate_     │ws.py     │          │          │                 │
│limit.py  │(WS管理)  │          │          │                 │
└──────────┴──────────┴──────────┴──────────┴─────────────────┘
```

### 核心数据流

```
Flutter 客户端
    │
    ▼
Cloudflare Worker（边缘节点）
    │ 注入 X-Worker-Auth + Cookie 头
    ▼
FastAPI 路由层
    │ Depends(require_session)
    ▼
SessionStore → AppSessionModel (PostgreSQL)
    │ 重建客户端对象
    ▼
客户端层 (SchoolSdkClient / EhallClient / EcardClient)
    │ 通过 Worker 代理或直连
    ▼
外部系统 (JWXT / ehall / 融校云)
```