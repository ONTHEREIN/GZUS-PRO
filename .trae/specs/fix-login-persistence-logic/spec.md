# 修复持久化登录与登录逻辑 Spec

## Why
上一轮实现的自动登录功能存在多个逻辑缺陷：1) `_startMobileSso` 未传递 `api` 参数给 `MobileSsoLoginPage`，导致一键登录永远不可用；2) 自动登录成功后 `usedAutoLogin` 未被调用方处理，仍会调用 `mobileCookieLogin` 导致重复登录或失败；3) `mobile_sso_stub.dart` 的 `MobileCookieLoginResult` 和 `MobileSsoLoginPage` 与 io 版本不同步；4) WebView 登录成功后的 ehall cookies 未传递给 `mobileCookieLogin`，导致办事大厅会话丢失；5) ehall cookies 未持久化，每次打开办事大厅 WebView 都需要重新登录。

## What Changes
- 修复 `_startMobileSso` 传递 `api` 参数给 `MobileSsoLoginPage`
- 修复 `_startMobileSso` 处理 `usedAutoLogin` 分支，自动登录成功时直接使用 `autoLoginResult`
- 修复 WebView 登录成功后传递 `ehallCookies` 和 `ehallAuthToken` 给 `mobileCookieLogin`
- 同步 `mobile_sso_stub.dart` 的 `MobileCookieLoginResult` 和 `MobileSsoLoginPage` 签名
- 持久化 ehall cookies 到 SharedPreferences，供 `_EhallWebViewPage` 使用

## Impact
- Affected specs: add-auto-login-with-ocr
- Affected code:
  - `apps/mobile_web/lib/main.dart` — 修复 `_startMobileSso` 登录逻辑
  - `apps/mobile_web/lib/mobile_sso_io.dart` — 持久化 ehall cookies
  - `apps/mobile_web/lib/mobile_sso_stub.dart` — 同步类签名

## ADDED Requirements

### Requirement: ehall cookies 持久化
系统 SHALL 在登录成功后将 ehall cookies 和 auth token 持久化到 SharedPreferences。

#### Scenario: WebView 登录成功后持久化
- **WHEN** WebView 登录成功获取到 ehall cookies 和 auth token
- **THEN** 将 `auth.ehallCookies` 和 `auth.ehallAuthToken` 保存到 SharedPreferences

#### Scenario: 自动登录成功后持久化
- **WHEN** 自动登录成功
- **THEN** 将后端返回的 ehall session 信息保存到 SharedPreferences

#### Scenario: 登出时清除 ehall 持久化数据
- **WHEN** 用户登出
- **THEN** 清除 `auth.ehallCookies` 和 `auth.ehallAuthToken`

## MODIFIED Requirements

### Requirement: _startMobileSso
原 `_startMobileSso` 未传递 `api` 参数且未处理 `usedAutoLogin`。修改后：
- 传递 `api: widget.api` 给 `MobileSsoLoginPage`
- 当 `result.usedAutoLogin` 为 true 时，直接使用 `result.autoLoginResult` 调用 `_finishLogin`
- 当 `result.usedAutoLogin` 为 false 时，传递 `ehallCookies` 和 `ehallAuthToken` 给 `mobileCookieLogin`

### Requirement: MobileCookieLoginResult (stub)
原 stub 版本缺少 `usedAutoLogin` 和 `autoLoginResult` 字段。修改后：
- 与 io 版本保持一致，添加 `usedAutoLogin` 和 `autoLoginResult` 字段

### Requirement: MobileSsoLoginPage (stub)
原 stub 版本缺少 `api` 参数。修改后：
- 添加 `api` 可选参数，与 io 版本签名一致
