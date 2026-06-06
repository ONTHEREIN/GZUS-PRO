# 应用内自动登录（验证码 OCR 识别）Spec

## Why
当前办事大厅登录流程需要用户在 WebView 中手动输入密码和验证码，体验较差。通过在后端使用 agent-browser 自动化浏览器操作 + ddddocr 自动识别验证码，可以实现用户只需提供账密即可一键登录办事大厅。

## What Changes
- 后端新增 CAS 登录自动化模块，使用 agent-browser 驱动浏览器完成登录
- 后端新增 ddddocr 验证码识别服务
- 后端新增 `/auth/auto-login` API 端点，接收账密后自动完成登录
- Flutter 端新增自动登录入口，替代 WebView 手动登录流程
- 后端 pyproject.toml 新增 ddddocr 依赖

## Impact
- Affected specs: optimize-login-page
- Affected code:
  - `services/api/app/routes/auth.py` — 新增自动登录端点
  - `services/api/app/cas_auto_login.py` — 新增 CAS 自动登录模块
  - `services/api/app/captcha_ocr.py` — 新增验证码 OCR 模块
  - `services/api/pyproject.toml` — 新增依赖
  - `apps/mobile_web/lib/mobile_sso_io.dart` — 新增自动登录调用
  - `apps/mobile_web/lib/api_client.dart` — 新增自动登录 API 方法

## ADDED Requirements

### Requirement: CAS 自动登录服务
系统 SHALL 提供基于 agent-browser 的 CAS 自动登录服务，自动完成账密填写和验证码识别。

#### Scenario: 自动登录成功
- **WHEN** 用户提交账号和密码
- **THEN** 系统使用 agent-browser 打开 CAS 登录页面 `https://cas.gzus.edu.cn/lyuapServer/login`
- **AND** 自动填写用户名和密码
- **AND** 自动截取验证码图片并使用 ddddocr 识别
- **AND** 自动填写验证码并提交
- **AND** 等待登录成功后获取教务系统 cookie 和办事大厅 cookie
- **AND** 返回登录结果（sessionId、studentName、studentId）

#### Scenario: 验证码识别失败重试
- **WHEN** 验证码识别结果导致登录失败
- **THEN** 系统自动刷新验证码并重新识别，最多重试 3 次
- **AND** 3 次重试后仍失败则返回错误信息

#### Scenario: CAS 页面加载超时
- **WHEN** CAS 登录页面加载超过 30 秒
- **THEN** 返回错误信息"登录页面加载超时，请稍后重试"

#### Scenario: 账密错误
- **WHEN** 账号或密码错误导致登录失败
- **THEN** 返回错误信息"账号或密码错误"

### Requirement: 验证码 OCR 识别
系统 SHALL 使用 ddddocr 库自动识别 CAS 登录页面的验证码图片。

#### Scenario: 识别验证码
- **WHEN** 从 CAS 页面截取到验证码图片
- **THEN** 使用 ddddocr 进行 OCR 识别
- **AND** 返回识别结果字符串

#### Scenario: 验证码图片获取
- **WHEN** CAS 页面加载完成
- **THEN** 通过 agent-browser 定位验证码图片元素
- **AND** 截取验证码图片的 PNG 数据
- **AND** 将图片数据传递给 ddddocr 进行识别

### Requirement: 自动登录 API 端点
系统 SHALL 提供 `/auth/auto-login` POST 端点。

#### Scenario: 请求自动登录
- **WHEN** 客户端发送 POST `/auth/auto-login`，body 包含 `account` 和 `password`
- **THEN** 后端启动自动登录流程
- **AND** 返回与现有登录端点相同格式的响应（`status`、`sessionId`、`studentName`、`studentId`）

#### Scenario: 自动登录失败
- **WHEN** 自动登录流程失败
- **THEN** 返回 HTTP 401，detail 包含具体错误原因

### Requirement: Flutter 端自动登录集成
系统 SHALL 在 Flutter 端提供自动登录入口。

#### Scenario: 用户选择自动登录
- **WHEN** 用户在登录页输入账号密码后点击"一键登录"
- **THEN** 调用后端 `/auth/auto-login` 端点
- **AND** 显示登录进度状态（正在打开登录页、正在识别验证码、正在登录等）
- **AND** 登录成功后自动获取 session 并进入主页

#### Scenario: 自动登录失败回退
- **WHEN** 自动登录失败
- **THEN** 显示错误信息
- **AND** 提供回退到 WebView 手动登录的选项

## MODIFIED Requirements

### Requirement: MobileSsoLoginPage
原 MobileSsoLoginPage 仅支持 WebView 手动登录。修改后：
- 新增"一键登录"按钮，调用后端自动登录 API
- 保留 WebView 手动登录作为备选方案
- 自动登录过程中显示进度状态

### Requirement: ApiClient
原 ApiClient 仅支持 `login` 和 `mobileCookieLogin`。修改后：
- 新增 `autoLogin(String account, String password)` 方法
- 返回 `LoginResult`，与现有登录方法格式一致
