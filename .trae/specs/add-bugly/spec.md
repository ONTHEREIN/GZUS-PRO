# Bugly 集成 Spec

## Why
当前 GZUS-PRO 缺乏完善的崩溃监控和异常上报机制，无法及时发现和定位线上问题。需要集成腾讯 Bugly 来实现以下功能：
1. 崩溃和 ANR 自动上报
2. 自定义异常上报
3. 应用版本和渠道管理
4. 用户行为追踪
5. 稳定性指标监控

## What Changes
- Android 端集成 Bugly SDK
- iOS 端集成 Bugly SDK
- Flutter 端新增 `bugly_service.dart` 封装 Bugly 初始化和异常上报
- Flutter 端新增全局异常捕获
- Flutter 端新增用户标识和设备信息上报
- Android `AndroidManifest.xml` 新增 Bugly 所需权限
- Android `build.gradle.kts` 新增 Bugly 依赖和配置
- iOS `Info.plist` 新增 Bugly 配置
- iOS `Podfile` 新增 Bugly 依赖

## Impact
- Affected specs: 无
- Affected code:
  - `apps/mobile_web/pubspec.yaml` — 新增依赖（可选，使用原生集成）
  - `apps/mobile_web/lib/bugly_service.dart` — 新文件，Bugly 服务封装
  - `apps/mobile_web/lib/main.dart` — 全局异常捕获集成
  - `apps/mobile_web/android/app/src/main/AndroidManifest.xml` — Bugly 权限和配置
  - `apps/mobile_web/android/app/build.gradle.kts` — Bugly 依赖和配置
  - `apps/mobile_web/android/app/src/main/kotlin/cn/gzus/pro/MainActivity.kt` — Bugly 初始化
  - `apps/mobile_web/ios/Podfile` — Bugly 依赖
  - `apps/mobile_web/ios/Runner/Info.plist` — Bugly 配置
  - `apps/mobile_web/ios/Runner/AppDelegate.swift` — Bugly 初始化

## ADDED Requirements

### Requirement: Bugly 集成（Android 端）
系统 SHALL 在 Android 端集成 Bugly SDK，实现以下功能：
1. 在 `MainActivity.kt` 中初始化 Bugly
2. 配置 App ID 和 App Key
3. 启用崩溃和 ANR 自动上报
4. 配置应用版本和渠道
5. 配置调试模式开关
6. 新增 Bugly 所需权限：INTERNET, ACCESS_NETWORK_STATE, ACCESS_WIFI_STATE, READ_PHONE_STATE

#### Scenario: Android 应用启动初始化 Bugly
- **WHEN** Android 应用启动
- **THEN** Bugly SDK 被正确初始化，崩溃和 ANR 自动上报开启

#### Scenario: Android 发生崩溃
- **WHEN** Android 应用发生 Java/Kotlin 崩溃或 ANR
- **THEN** Bugly 自动捕获并上报崩溃信息

### Requirement: Bugly 集成（iOS 端）
系统 SHALL 在 iOS 端集成 Bugly SDK，实现以下功能：
1. 在 `AppDelegate.swift` 中初始化 Bugly
2. 配置 App ID
3. 启用崩溃自动上报
4. 配置应用版本和渠道
5. 配置调试模式开关

#### Scenario: iOS 应用启动初始化 Bugly
- **WHEN** iOS 应用启动
- **THEN** Bugly SDK 被正确初始化，崩溃自动上报开启

#### Scenario: iOS 发生崩溃
- **WHEN** iOS 应用发生 Objective-C/Swift 崩溃
- **THEN** Bugly 自动捕获并上报崩溃信息

### Requirement: Bugly 集成（Flutter 端）
系统 SHALL 在 Flutter 端封装 Bugly 服务，实现以下功能：
1. 全局捕获 Dart 异常（`FlutterError.onError`、`PlatformDispatcher.instance.onError`）
2. 上报自定义异常
3. 设置用户标识（登录后设置学号，登出时清空）
4. 设置标签和关键数据
5. 封装 Bugly 初始化逻辑

#### Scenario: Flutter 发生 Dart 异常
- **WHEN** Flutter 应用发生 Dart 异常
- **THEN** 异常被全局捕获并上报到 Bugly

#### Scenario: 登录后设置用户标识
- **WHEN** 用户成功登录
- **THEN** 将学号设置为 Bugly 用户标识

#### Scenario: 登出时清空用户标识
- **WHEN** 用户登出
- **THEN** 清空 Bugly 用户标识

### Requirement: 应用版本和渠道配置
系统 SHALL 在 Bugly 中正确配置应用版本和渠道：
1. Android 渠道：从 `build.gradle.kts` 读取 `applicationId` 和 `versionName`
2. iOS 渠道：从 `Info.plist` 读取 `CFBundleIdentifier` 和 `CFBundleShortVersionString`
3. 渠道标识统一为 `gzus_pro`

#### Scenario: 版本信息正确上报
- **WHEN** 崩溃或异常上报
- **THEN** 上报信息中包含正确的应用版本和渠道

### Requirement: 调试模式开关
系统 SHALL 提供调试模式开关：
1. 调试模式：开启日志输出，不上报真实数据到 Bugly
2. 发布模式：关闭日志输出，上报数据到 Bugly
3. 通过 `debug` 配置项控制

#### Scenario: 调试模式下不真实上报
- **WHEN** 应用在调试模式运行
- **THEN** Bugly 不上报真实数据到服务器

## MODIFIED Requirements

### Requirement: 登录流程
登录成功后，除了现有逻辑外，还需：
1. 设置 Bugly 用户标识为学号

### Requirement: 登出流程
登出时，除了现有逻辑外，还需：
1. 清空 Bugly 用户标识

## REMOVED Requirements
无
