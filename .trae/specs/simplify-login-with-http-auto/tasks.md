# Tasks

- [x] Task 1: 重写 `cas_auto_login.py` 为纯 httpx 实现
  - [x] SubTask 1.1: 实现 `_get_cas_login_page()` — GET CAS 登录页，返回 HTML 和 cookies
  - [x] SubTask 1.2: 实现 `_parse_login_form(html)` — 解析 HTML 提取隐藏字段（lt、execution、_eventId）和验证码图片 URL
  - [x] SubTask 1.3: 实现 `_download_captcha(url, cookies)` — GET 验证码图片，返回 bytes
  - [x] SubTask 1.4: 实现 `_submit_login(form_data, cookies)` — POST 登录表单，跟随重定向
  - [x] SubTask 1.5: 实现 `_is_login_success(response)` — 判断登录是否成功（URL 不再是 CAS 登录页）
  - [x] SubTask 1.6: 实现 `_is_wrong_credentials(response)` — 判断是否账密错误（不重试）
  - [x] SubTask 1.7: 实现 `_extract_jwxt_cookies(client)` — 从 httpx client cookie jar 提取 jwxt cookies
  - [x] SubTask 1.8: 实现 `_get_ehall_session(jwxt_cookies)` — 用 jwxt cookies 导航到 ehall，获取 ehall cookies 和 auth token
  - [x] SubTask 1.9: 重写 `auto_login()` 主方法，串联以上步骤，含验证码重试逻辑
  - [x] SubTask 1.10: 移除所有 agent-browser 相关代码和 subprocess 调用

- [x] Task 2: 后端凭据存储与自动重登
  - [x] SubTask 2.1: `AppSession` 新增 `encrypted_credentials: str | None` 字段
  - [x] SubTask 2.2: 实现 `encrypt_credentials()` 和 `decrypt_credentials()`，使用 Fernet 对称加密
  - [x] SubTask 2.3: 修改 `/auth/auto-login` 端点，登录成功后返回 credentialToken
  - [x] SubTask 2.4: 新增 `/auth/relogin` 端点，接收 credentialToken，解密后重新登录
  - [x] SubTask 2.5: 客户端存储 credentialToken，session 过期时发送 relogin 请求

- [x] Task 3: Flutter 端简化登录页
  - [x] SubTask 3.1: 修改 `_LoginPageState._login()` 方法，改为调用 `api.autoLogin()`
  - [x] SubTask 3.2: 移除验证码手动输入 UI（captchaToken、captchaImage、captchaController 等）
  - [x] SubTask 3.3: 移除 `_startMobileSso()` 方法和"办事大厅登录"按钮
  - [x] SubTask 3.4: 移除 `_saveMobileSsoCookies()` 方法
  - [x] SubTask 3.5: 登录成功后保存 credentialToken 到 SharedPreferences

- [x] Task 4: Flutter 端自动重登
  - [x] SubTask 4.1: 在 `ApiClient` 中添加 `_withReloginRetry()` 包装器，401 时自动调用 `relogin()`
  - [x] SubTask 4.2: 重登成功后重试原始请求
  - [x] SubTask 4.3: 重登失败则调用 `onReloginFailed` 回调通知 UI

- [x] Task 5: 清理旧代码
  - [x] SubTask 5.1: 从 `mobile_sso_io.dart` 移除 `MobileSsoLoginPage`（保留 `_EhallWebViewPage`）
  - [x] SubTask 5.2: 从 `mobile_sso_stub.dart` 移除 `MobileSsoLoginPage`
  - [x] SubTask 5.3: 从 `api_client.dart` 移除 `mobileCookieLogin` 方法
  - [x] SubTask 5.4: 从 `auth.py` 移除 `/auth/mobile-cookie-login` 端点

- [x] Task 6: 验证
  - [x] SubTask 6.1: 后端 `ruff check` 通过
  - [x] SubTask 6.2: Flutter `flutter analyze` 通过

# Task Dependencies
- [Task 1] 无依赖，可先行
- [Task 2] 依赖 [Task 1]
- [Task 3] 依赖 [Task 2]（需要 auto-login 端点就绪）
- [Task 4] 依赖 [Task 3]
- [Task 5] 依赖 [Task 3]（确认不再需要旧代码后再清理）
- [Task 6] 依赖 [Task 1-5]
