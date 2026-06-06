# 简化登录流程（纯 HTTP 自动登录 + 自动重登）Spec

## Why
当前登录流程依赖 WebView 手动输入账密和验证码，体验繁琐。用户只需输入办事大厅账密，后端通过纯 HTTP 请求自动完成 CAS 登录（含验证码 OCR 识别），登录过期后自动重新登录，全程无需 WebView。

## What Changes
- **BREAKING**: 重写 `cas_auto_login.py`，从 agent-browser 改为纯 httpx HTTP 请求实现 CAS 登录
- **BREAKING**: 移除 `MobileSsoLoginPage`（WebView 登录页），登录页直接调用后端 auto-login API
- 后端新增凭据加密存储，用于自动重登
- 后端新增自动重登机制：session 过期时使用存储的凭据重新登录
- Flutter 端登录页简化为账密输入 + 单一登录按钮
- Flutter 端新增自动重登逻辑：API 返回 401 时自动重登并重试请求

## Impact
- Affected specs: add-auto-login-with-ocr, fix-login-persistence-logic
- Affected code:
  - `services/api/app/cas_auto_login.py` — 重写为 httpx 实现
  - `services/api/app/routes/auth.py` — 修改 auto-login 端点，新增凭据存储
  - `services/api/app/sessions.py` — AppSession 新增凭据存储字段
  - `services/api/app/schemas.py` — 修改 AutoLoginRequest
  - `apps/mobile_web/lib/main.dart` — 简化登录页，移除 WebView 登录
  - `apps/mobile_web/lib/mobile_sso_io.dart` — 移除 MobileSsoLoginPage，保留 ehall WebView
  - `apps/mobile_web/lib/mobile_sso_stub.dart` — 同步更新
  - `apps/mobile_web/lib/api_client.dart` — 新增自动重登逻辑

## ADDED Requirements

### Requirement: 纯 HTTP CAS 自动登录
系统 SHALL 通过 httpx 直接发送 HTTP 请求完成 CAS 登录，不使用 agent-browser。

#### Scenario: CAS 登录成功
- **WHEN** 后端收到 auto-login 请求
- **THEN** 使用 httpx GET `https://cas.gzus.edu.cn/lyuapServer/login?service=...`
- **AND** 解析 HTML 提取隐藏表单字段（lt、execution、_eventId 等）
- **AND** 提取验证码图片 URL 并 GET 下载图片
- **AND** 使用 ddddocr 识别验证码
- **AND** POST 登录表单（username、password、captcha、隐藏字段）
- **AND** 跟随重定向获取 jwxt cookies
- **AND** 导航到 ehall 获取 ehall cookies 和 auth token
- **AND** 返回 CasLoginResult

#### Scenario: 验证码识别失败重试
- **WHEN** POST 登录表单后 CAS 仍返回登录页（验证码错误）
- **THEN** 重新 GET 登录页获取新验证码并重试，最多 3 次
- **AND** 3 次后仍失败则返回错误

#### Scenario: 账密错误
- **WHEN** CAS 返回用户名或密码错误提示
- **THEN** 立即返回错误"账号或密码错误"，不重试验证码

### Requirement: 凭据加密存储
系统 SHALL 在 session 中加密存储用户凭据，用于自动重登。

#### Scenario: 登录成功后存储凭据
- **WHEN** auto-login 成功创建 session
- **THEN** 将 account 和 password 加密存储在 AppSession 中
- **AND** 加密密钥来自配置项 `CREDENTIAL_ENCRYPTION_KEY`

#### Scenario: 登出时清除凭据
- **WHEN** 用户登出
- **THEN** 清除 session 中的凭据

### Requirement: 自动重登
系统 SHALL 在 session 过期时自动使用存储的凭据重新登录。

#### Scenario: API 请求时 session 过期
- **WHEN** 客户端请求 API 时 session 已过期
- **THEN** 后端尝试使用存储的凭据重新执行 CAS 自动登录
- **AND** 重登成功后创建新 session 并返回数据
- **AND** 重登失败则返回 401

#### Scenario: 凭据不存在
- **WHEN** session 过期且无存储的凭据（如密码登录的 session）
- **THEN** 返回 401，客户端跳转登录页

### Requirement: 简化登录页 UI
系统 SHALL 将登录页简化为账密输入 + 单一登录按钮。

#### Scenario: 用户登录
- **WHEN** 用户在登录页输入账号和密码并点击"登录"
- **THEN** 调用后端 `/auth/auto-login` API
- **AND** 显示登录进度（"正在登录..."）
- **AND** 登录成功后进入主页

#### Scenario: 登录失败
- **WHEN** auto-login 失败
- **THEN** 显示错误信息（如"账号或密码错误"）
- **AND** 用户可重新输入并重试

### Requirement: Flutter 端自动重登
系统 SHALL 在 API 请求返回 401 时自动重登。

#### Scenario: 请求失败自动重登
- **WHEN** API 请求返回 401 且本地保存了账号密码
- **THEN** 自动调用 `/auth/auto-login` 重新登录
- **AND** 登录成功后重试原始请求
- **AND** 登录失败则跳转登录页

#### Scenario: 无保存凭据
- **WHEN** API 请求返回 401 且本地无保存的账号密码
- **THEN** 直接跳转登录页

## MODIFIED Requirements

### Requirement: LoginPage
原 LoginPage 有账密登录和"办事大厅登录"两个入口。修改后：
- 移除"办事大厅登录"按钮和 WebView 跳转
- 账密登录改为调用 `/auth/auto-login`（后端自动处理 CAS + 验证码）
- 移除验证码手动输入 UI（后端自动识别）
- 保留账号密码输入框和单一"登录"按钮

### Requirement: cas_auto_login.py
原实现使用 agent-browser CLI。修改后：
- 完全使用 httpx HTTP 请求
- GET CAS 页面 → 解析 HTML → GET 验证码 → OCR → POST 登录
- 移除所有 agent-browser 相关代码

### Requirement: AppSession
原 AppSession 仅存储 client 和 student_name。修改后：
- 新增 `encrypted_credentials: str | None` 字段存储加密的凭据

### Requirement: _startMobileSso
移除此方法，不再需要 WebView 登录流程。

## REMOVED Requirements

### Requirement: MobileSsoLoginPage
**Reason**: 登录流程简化为纯 API 调用，不再需要 WebView 登录页
**Migration**: 登录页直接调用 `/auth/auto-login`，无需 WebView

### Requirement: agent-browser 依赖
**Reason**: 后端改用纯 HTTP 请求，不需要浏览器自动化
**Migration**: 使用 httpx 直接发送 HTTP 请求
