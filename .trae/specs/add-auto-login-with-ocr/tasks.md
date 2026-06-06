# Tasks

- [x] Task 1: 添加 ddddocr 依赖到后端项目
  - [x] SubTask 1.1: 在 `services/api/pyproject.toml` 的 dependencies 中添加 `ddddocr>=1.5.0`
  - [x] SubTask 1.2: 在 `services/api/pyproject.toml` 的 dependencies 中添加 `Pillow>=10.0.0`（ddddocr 依赖）

- [x] Task 2: 创建验证码 OCR 识别模块
  - [x] SubTask 2.1: 创建 `services/api/app/captcha_ocr.py`
  - [x] SubTask 2.2: 实现 `CaptchaOcr` 类，封装 ddddocr 初始化和识别逻辑
  - [x] SubTask 2.3: 实现 `recognize(image_bytes: bytes) -> str` 方法，接收图片字节数据返回识别结果

- [x] Task 3: 创建 CAS 自动登录模块
  - [x] SubTask 3.1: 创建 `services/api/app/cas_auto_login.py`
  - [x] SubTask 3.2: 实现 `CasAutoLogin` 类，封装 agent-browser 自动登录流程
  - [x] SubTask 3.3: 实现 `_open_cas_page()` 方法：使用 agent-browser 打开 CAS 登录页
  - [x] SubTask 3.4: 实现 `_fill_credentials(account, password)` 方法：自动填写用户名和密码
  - [x] SubTask 3.5: 实现 `_capture_captcha()` 方法：截取验证码图片
  - [x] SubTask 3.6: 实现 `_fill_captcha(code)` 方法：填写验证码
  - [x] SubTask 3.7: 实现 `_submit_and_wait()` 方法：提交登录并等待结果
  - [x] SubTask 3.8: 实现 `_read_cookies()` 方法：读取教务系统和办事大厅的 cookie
  - [x] SubTask 3.9: 实现 `auto_login(account, password) -> CasLoginResult` 主方法，串联以上步骤并包含验证码重试逻辑（最多 3 次）

- [x] Task 4: 添加自动登录 API 端点
  - [x] SubTask 4.1: 在 `services/api/app/routes/auth.py` 中添加 `POST /auth/auto-login` 端点
  - [x] SubTask 4.2: 端点接收 `AutoLoginRequest(account, password)` 请求体
  - [x] SubTask 4.3: 调用 `CasAutoLogin.auto_login()` 执行自动登录
  - [x] SubTask 4.4: 登录成功后创建 session，返回 `AuthResponse` 格式响应
  - [x] SubTask 4.5: 登录失败返回 HTTP 401，detail 包含具体错误原因

- [x] Task 5: Flutter 端添加自动登录 API 方法
  - [x] SubTask 5.1: 在 `apps/mobile_web/lib/api_client.dart` 的 `ApiClient` 类中添加 `autoLogin(String account, String password)` 方法
  - [x] SubTask 5.2: 方法调用 `POST /auth/auto-login`，返回 `LoginResult`

- [x] Task 6: Flutter 端集成自动登录 UI
  - [x] SubTask 6.1: 在 `apps/mobile_web/lib/mobile_sso_io.dart` 的 `MobileSsoLoginPage` 中添加"一键登录"按钮
  - [x] SubTask 6.2: 点击按钮后调用 `ApiClient.autoLogin()`，显示进度状态
  - [x] SubTask 6.3: 登录成功后返回 `MobileCookieLoginResult`
  - [x] SubTask 6.4: 登录失败时显示错误信息，提供回退到 WebView 手动登录的选项

- [ ] Task 7: 验证与测试
  - [ ] SubTask 7.1: 验证后端 `ruff check` 通过
  - [ ] SubTask 7.2: 验证 Flutter `flutter analyze` 通过
  - [ ] SubTask 7.3: 手动测试自动登录流程

# Task Dependencies
- [Task 1] 无依赖，可先行
- [Task 2] 依赖 [Task 1]
- [Task 3] 依赖 [Task 2]
- [Task 4] 依赖 [Task 3]
- [Task 5] 依赖 [Task 4]（需要端点就绪）
- [Task 6] 依赖 [Task 5]
- [Task 7] 依赖 [Task 6]
