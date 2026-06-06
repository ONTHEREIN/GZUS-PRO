# Tasks

- [x] Task 1: 修复 `_startMobileSso` 登录逻辑
  - [x] SubTask 1.1: 传递 `api: widget.api` 给 `MobileSsoLoginPage`
  - [x] SubTask 1.2: 处理 `usedAutoLogin` 分支：自动登录成功时直接调用 `onLoggedIn`，跳过 `mobileCookieLogin`
  - [x] SubTask 1.3: WebView 登录成功时传递 `ehallCookies` 和 `ehallAuthToken` 给 `mobileCookieLogin`

- [x] Task 2: 持久化 ehall cookies
  - [x] SubTask 2.1: 在 `_saveMobileSsoCookies` 中保存 `auth.ehallAuthToken`
  - [x] SubTask 2.2: 在 `_clearSavedSession` 中清除 `auth.ehallAuthToken`
  - [x] SubTask 2.3: 在 `mobile_sso_io.dart` 的 `_loadInitialUrl` 中注入持久化的 `ehallAuthToken` 到 sessionStorage

- [x] Task 3: 同步 `mobile_sso_stub.dart`
  - [x] SubTask 3.1: `MobileCookieLoginResult` 添加 `usedAutoLogin` 和 `autoLoginResult` 字段
  - [x] SubTask 3.2: `MobileSsoLoginPage` 添加 `api` 可选参数

- [x] Task 4: 验证
  - [x] SubTask 4.1: 运行 `flutter analyze` 确认无编译错误

# Task Dependencies
- [Task 1] 和 [Task 2] 可并行执行
- [Task 3] 无依赖，可并行
- [Task 4] 依赖 [Task 1-3]
