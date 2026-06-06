# Tasks

- [ ] Task 1: Android 端 Bugly 集成
  - [ ] SubTask 1.1: 在 `android/app/build.gradle.kts` 中新增 Bugly 依赖
  - [ ] SubTask 1.2: 在 `AndroidManifest.xml` 中新增 Bugly 所需权限
  - [ ] SubTask 1.3: 创建/修改 `MainActivity.kt` 实现 Bugly 初始化
  - [ ] SubTask 1.4: 配置 Bugly App ID 和渠道

- [ ] Task 2: iOS 端 Bugly 集成
  - [ ] SubTask 2.1: 在 `ios/Podfile` 中新增 Bugly 依赖
  - [ ] SubTask 2.2: 在 `Info.plist` 中新增 Bugly 配置
  - [ ] SubTask 2.3: 在 `AppDelegate.swift` 中实现 Bugly 初始化
  - [ ] SubTask 2.4: 配置 Bugly App ID 和渠道

- [ ] Task 3: Flutter 端 Bugly 服务封装
  - [ ] SubTask 3.1: 创建 `lib/bugly_service.dart`，封装 Bugly 初始化和异常上报
  - [ ] SubTask 3.2: 实现全局异常捕获（FlutterError.onError、PlatformDispatcher.instance.onError）
  - [ ] SubTask 3.3: 实现自定义异常上报方法
  - [ ] SubTask 3.4: 实现用户标识设置方法

- [ ] Task 4: Flutter 端集成到主流程
  - [ ] SubTask 4.1: 在 `main.dart` 中集成 Bugly 初始化
  - [ ] SubTask 4.2: 在登录成功后设置 Bugly 用户标识
  - [ ] SubTask 4.3: 在登出时清空 Bugly 用户标识

# Task Dependencies
- [Task 3] 可独立进行
- [Task 4] depends on [Task 3]
