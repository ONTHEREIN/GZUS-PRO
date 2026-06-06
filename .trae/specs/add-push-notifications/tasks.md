# Tasks

- [x] Task 1: 后端推送配置和 Schema
  - [x] SubTask 1.1: 在 `Settings` 中新增极光推送和 WebSocket 配置项（`jpush_app_key`, `jpush_master_secret`, `push_poll_interval_seconds`, `ws_heartbeat_seconds`, `debug`）
  - [x] SubTask 1.2: 在 `.env.example` 中新增对应环境变量示例
  - [x] SubTask 1.3: 在 `schemas.py` 中新增 `PushRegisterRequest` schema

- [x] Task 2: 后端推送 Token 管理路由
  - [x] SubTask 2.1: 创建 `services/api/app/routes/push.py`，实现 `POST /push/register` 和 `POST /push/unregister`
  - [x] SubTask 2.2: 在 `sessions.py` 的 `AppSession` 中新增 `push_registration_id` 和 `push_platform` 字段
  - [x] SubTask 2.3: 在 `main.py` 中注册推送路由

- [x] Task 3: 后端极光推送发送模块
  - [x] SubTask 3.1: 创建 `services/api/app/push.py`，实现 `send_push()` 异步函数，调用 JPush REST API
  - [x] SubTask 3.2: 支持 `registration_id` 精确推送和广播推送
  - [x] SubTask 3.3: 推送失败时记录日志但不抛异常（降级处理）

- [x] Task 4: 后端 WebSocket 端点
  - [x] SubTask 4.1: 创建 `services/api/app/ws.py`，实现 `ConnectionManager` 管理 `session_id → WebSocket` 映射
  - [x] SubTask 4.2: 实现 `/ws/notifications` WebSocket 端点，验证 `X-Session-Id`，维持连接
  - [x] SubTask 4.3: 实现心跳机制，定期检查会话有效性，过期时以 code 4001 关闭
  - [x] SubTask 4.4: 在 `main.py` 中注册 WebSocket 路由

- [x] Task 5: 后端通知变更检测定时任务
  - [x] SubTask 5.1: 创建 `services/api/app/jobs.py`，实现 `check_new_notices()` 定时任务
  - [x] SubTask 5.2: 对每个活跃会话调用 `get_notices()`，与缓存对比检测新增
  - [x] SubTask 5.3: 新增通知同时通过 WebSocket 和极光推送发送
  - [x] SubTask 5.4: 在 `main.py` 的 `lifespan` 中启动定时任务

- [x] Task 6: Flutter 端依赖和配置
  - [x] SubTask 6.1: 在 `pubspec.yaml` 中新增 `jpush_flutter`、`flutter_local_notifications`、`web_socket_channel` 依赖
  - [x] SubTask 6.2: Android `AndroidManifest.xml` 新增推送权限和极光 meta-data
  - [x] SubTask 6.3: Android `build.gradle.kts` 调整 `minSdk = 21`
  - [x] SubTask 6.4: iOS `AppDelegate.swift` 注册极光推送和 APNs

- [x] Task 7: Flutter 本地通知服务
  - [x] SubTask 7.1: 创建 `local_notification_service.dart`，封装 `flutter_local_notifications` 初始化和展示逻辑
  - [x] SubTask 7.2: 配置默认通知渠道和权限请求
  - [x] SubTask 7.3: 实现通知点击回调，解析 extras 跳转到对应页面

- [x] Task 8: Flutter 极光推送服务
  - [x] SubTask 8.1: 创建 `push_service.dart`，封装 `JPush` 初始化、事件监听、Token 管理
  - [x] SubTask 8.2: 前台收到推送时调用本地通知服务展示
  - [x] SubTask 8.3: 点击推送时解析 extras 并触发导航

- [x] Task 9: Flutter WebSocket 服务
  - [x] SubTask 9.1: 创建 `ws_service.dart`，封装 WebSocket 连接、消息接收、自动重连逻辑
  - [x] SubTask 9.2: 收到消息时调用本地通知服务展示
  - [x] SubTask 9.3: 实现指数退避重连策略（1s → 2s → 4s → ... → 60s）
  - [x] SubTask 9.4: 登出时主动断开连接

- [x] Task 10: Flutter 集成到主流程
  - [x] SubTask 10.1: 在 `api_client.dart` 中新增 `registerPush()` 和 `unregisterPush()` 方法
  - [x] SubTask 10.2: 在 `main.dart` 登录成功后初始化推送服务、注册 Token、建立 WebSocket 连接
  - [x] SubTask 10.3: 在 `main.dart` 登出时注销推送、断开 WebSocket
  - [x] SubTask 10.4: App 从后台恢复时检查 WebSocket 连接状态

- [x] Task 11: 端到端测试和验证
  - [x] SubTask 11.1: 后端推送路由单元测试
  - [x] SubTask 11.2: 后端 WebSocket 端点测试
  - [x] SubTask 11.3: 后端极光推送模块测试（mock JPush API）
  - [x] SubTask 11.4: 后端定时任务测试

# Task Dependencies
- [Task 2] depends on [Task 1]
- [Task 3] depends on [Task 1]
- [Task 5] depends on [Task 2, Task 3, Task 4]
- [Task 8] depends on [Task 6, Task 7]
- [Task 9] depends on [Task 6, Task 7]
- [Task 10] depends on [Task 7, Task 8, Task 9]
- [Task 11] depends on [Task 2, Task 3, Task 4, Task 5]
