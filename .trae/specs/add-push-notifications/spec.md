# 通知推送功能 Spec

## Why
当前 GZUS-PRO 只能由用户主动打开 App 拉取通知列表，无法在后台或 App 关闭时及时获知教务系统的新通知、成绩更新、考试提醒等信息。大陆用户无法稳定使用 FCM，需要同时集成极光推送（后台推送兜底）和 WebSocket 实时通道（前台即时通知），实现全场景覆盖。

## What Changes
- Flutter 端集成 `jpush_flutter` 插件，实现极光推送注册、接收、点击跳转
- Flutter 端集成 `flutter_local_notifications` 插件，实现前台本地通知展示
- Flutter 端新增 WebSocket 连接管理，登录后自动建立长连接，登出/断网自动重连
- 后端新增 `/push/register` 和 `/push/unregister` 接口，管理用户设备 Token
- 后端新增 WebSocket 端点 `/ws/notifications`，向前台用户实时推送通知
- 后端新增极光推送发送模块，通过 JPush REST API 发送后台推送
- 后端新增通知变更检测定时任务，轮询教务系统检测新通知并触发推送
- 后端 `Settings` 新增极光推送和 WebSocket 相关配置项
- Android `AndroidManifest.xml` 新增推送所需权限和极光 meta-data
- iOS 端新增推送权限配置

## Impact
- Affected specs: 通知模块、认证模块
- Affected code:
  - `apps/mobile_web/pubspec.yaml` — 新增依赖
  - `apps/mobile_web/lib/main.dart` — 登录/登出流程集成推送初始化
  - `apps/mobile_web/lib/api_client.dart` — 新增推送注册 API 调用
  - `apps/mobile_web/lib/push_service.dart` — 新文件，极光推送服务封装
  - `apps/mobile_web/lib/ws_service.dart` — 新文件，WebSocket 连接管理
  - `apps/mobile_web/lib/local_notification_service.dart` — 新文件，本地通知展示
  - `apps/mobile_web/android/app/src/main/AndroidManifest.xml` — 推送权限和极光配置
  - `apps/mobile_web/android/app/build.gradle.kts` — minSdk 调整
  - `services/api/app/config.py` — 新增配置项
  - `services/api/app/main.py` — 注册推送路由、WebSocket 端点、定时任务
  - `services/api/app/routes/push.py` — 新文件，推送注册/注销路由
  - `services/api/app/push.py` — 新文件，极光推送发送模块
  - `services/api/app/ws.py` — 新文件，WebSocket 连接管理
  - `services/api/app/jobs.py` — 新文件，通知变更检测定时任务
  - `services/api/app/schemas.py` — 新增推送相关 schema

## ADDED Requirements

### Requirement: 极光推送集成（Flutter 端）
系统 SHALL 在 Flutter 端集成极光推送 SDK（`jpush_flutter`），实现以下功能：
1. App 启动时初始化极光推送
2. 登录成功后获取 Registration ID 并上传到后端
3. 前台收到推送时通过本地通知展示
4. 点击通知时跳转到对应的通知详情页面
5. 登出时调用后端注销接口移除 Registration ID
6. Registration ID 刷新时自动更新到后端

#### Scenario: 登录后注册推送
- **WHEN** 用户成功登录
- **THEN** App 获取极光 Registration ID 并调用 `POST /push/register` 上传

#### Scenario: 前台收到极光推送
- **WHEN** App 在前台时收到极光推送消息
- **THEN** 通过 `flutter_local_notifications` 展示本地通知

#### Scenario: 点击通知跳转
- **WHEN** 用户点击推送通知
- **THEN** App 打开并导航到通知详情页面（携带 extras 中的 url 参数）

#### Scenario: 登出时注销推送
- **WHEN** 用户登出
- **THEN** App 调用 `POST /push/unregister` 移除 Registration ID

### Requirement: WebSocket 实时通道（Flutter 端）
系统 SHALL 在 Flutter 端建立 WebSocket 长连接，实现以下功能：
1. 登录成功后自动连接 `ws://{api_base}/ws/notifications`
2. 连接时通过 `X-Session-Id` header 传递会话标识
3. 收到消息时通过本地通知展示
4. 连接断开时自动重连（指数退避，最大间隔 60 秒）
5. 登出时主动断开连接
6. App 从后台恢复到前台时检查连接状态，必要时重连

#### Scenario: 前台实时接收通知
- **WHEN** WebSocket 连接正常且后端推送新通知消息
- **THEN** App 立即收到消息并通过本地通知展示

#### Scenario: 断线自动重连
- **WHEN** WebSocket 连接意外断开
- **THEN** App 按指数退避策略自动重连（1s → 2s → 4s → ... → 60s）

#### Scenario: 登出断开连接
- **WHEN** 用户登出
- **THEN** App 主动关闭 WebSocket 连接，停止重连

### Requirement: 本地通知展示
系统 SHALL 通过 `flutter_local_notifications` 插件展示本地通知：
1. 初始化时请求通知权限
2. 配置默认通知渠道（channel id: `gzus_pro_notifications`）
3. 收到推送消息（极光或 WebSocket）时统一通过本地通知展示
4. 通知点击事件统一处理，跳转到对应页面

#### Scenario: 展示本地通知
- **WHEN** 收到推送消息（标题 + 内容）
- **THEN** 系统弹出本地通知，标题为推送标题，内容为推送正文

### Requirement: 推送 Token 管理（后端）
系统 SHALL 提供推送设备 Token 的注册和注销接口：
1. `POST /push/register` — 接收 Registration ID 和平台信息，与当前会话关联存储
2. `POST /push/unregister` — 移除当前会话关联的 Registration ID
3. Token 存储在内存中（与现有 SessionStore 一致），结构为 `session_id → [registration_id, platform]`
4. 同一会话多次注册时覆盖旧 Token

#### Scenario: 注册推送 Token
- **WHEN** 客户端调用 `POST /push/register` 携带 `registrationId` 和 `platform`
- **THEN** 后端将 Registration ID 与当前会话关联存储

#### Scenario: 注销推送 Token
- **WHEN** 客户端调用 `POST /push/unregister`
- **THEN** 后端移除当前会话关联的 Registration ID

### Requirement: WebSocket 端点（后端）
系统 SHALL 提供 WebSocket 端点 `/ws/notifications`：
1. 通过 `X-Session-Id` header 验证会话
2. 会话有效时维持连接，会话过期时关闭连接（code 4001）
3. 连接管理器维护 `session_id → WebSocket` 映射
4. 提供广播方法，向所有在线用户推送消息

#### Scenario: 建立 WebSocket 连接
- **WHEN** 客户端连接 `/ws/notifications` 并携带有效的 `X-Session-Id`
- **THEN** 服务端接受连接并加入连接管理器

#### Scenario: 会话过期断开
- **WHEN** WebSocket 连接对应的会话已过期
- **THEN** 服务端以 code 4001 关闭连接

### Requirement: 极光推送发送模块（后端）
系统 SHALL 提供极光推送发送模块，通过 JPush REST API 发送推送：
1. 使用 `httpx` 异步调用 JPush REST API（`https://api.jpush.cn/v3/push`）
2. 支持 Android 和 iOS 双平台推送
3. 支持 `registration_id` 精确推送和广播推送
4. 推送消息包含 `title`、`alert`、`extras`（含通知类型和 URL）
5. 通过 `Settings` 读取极光 AppKey 和 Master Secret

#### Scenario: 向指定用户推送
- **WHEN** 系统检测到某用户有新通知
- **THEN** 通过该用户的 Registration ID 发送极光推送

#### Scenario: 极光推送失败降级
- **WHEN** 极光推送 API 调用失败
- **THEN** 记录错误日志但不影响 WebSocket 通道推送

### Requirement: 通知变更检测定时任务（后端）
系统 SHALL 提供定时任务，定期检测教务系统通知变更并触发推送：
1. 使用 `asyncio` 定时任务，默认每 30 分钟执行一次
2. 对每个活跃会话，调用 `get_notices()` 获取最新通知列表
3. 与上次缓存的通知列表对比，检测新增通知
4. 新增通知同时通过 WebSocket（前台用户）和极光推送（后台用户）发送
5. 推送消息格式：`{"type": "new_notice", "title": "...", "body": "...", "url": "..."}`
6. 缓存存储在内存中，结构为 `session_id → [上次通知标题列表]`

#### Scenario: 检测到新通知
- **WHEN** 定时任务轮询发现教务系统有新增通知
- **THEN** 向在线用户通过 WebSocket 推送，向离线用户通过极光推送

#### Scenario: 无新通知
- **WHEN** 定时任务轮询未发现新增通知
- **THEN** 不发送任何推送

#### Scenario: 会话过期跳过
- **WHEN** 会话已过期或 `get_notices()` 返回 401
- **THEN** 跳过该会话，不发送推送

### Requirement: 推送配置项（后端）
系统 SHALL 在 `Settings` 中新增以下配置项：
1. `jpush_app_key: str` — 极光推送 AppKey
2. `jpush_master_secret: str` — 极光推送 Master Secret
3. `push_poll_interval_seconds: int = 1800` — 通知轮询间隔（秒）
4. `ws_heartbeat_seconds: int = 30` — WebSocket 心跳间隔（秒）
5. `debug: bool = False` — 是否为调试模式（影响极光 APNs 环境）

#### Scenario: 配置项从环境变量读取
- **WHEN** 后端启动
- **THEN** 从 `.env` 文件或环境变量读取极光推送配置

### Requirement: Android 推送权限和配置
系统 SHALL 在 Android 端配置推送所需权限和极光 meta-data：
1. 新增 `INTERNET`、`ACCESS_NETWORK_STATE`、`WAKE_LOCK` 权限
2. 新增极光 `AppKey` meta-data
3. 新增极光推送 `JPushReceiver` 声明
4. `minSdk` 调整为 21（极光推送最低要求）

#### Scenario: Android 推送正常工作
- **WHEN** Android App 集成极光推送后运行
- **THEN** 能正常注册、接收推送和点击跳转

### Requirement: iOS 推送权限配置
系统 SHALL 在 iOS 端配置推送权限：
1. 在 `Info.plist` 中无额外配置（极光推送运行时请求权限）
2. 在 `AppDelegate.swift` 中注册极光推送和 APNs

#### Scenario: iOS 推送正常工作
- **WHEN** iOS App 集成极光推送后运行
- **THEN** 能正常注册 APNs、接收推送和点击跳转

## MODIFIED Requirements

### Requirement: 登录流程
登录成功后，除了现有会话持久化逻辑外，还需：
1. 初始化极光推送并上传 Registration ID
2. 建立 WebSocket 连接
3. 请求本地通知权限

### Requirement: 登出流程
登出时，除了现有会话清理逻辑外，还需：
1. 调用后端注销推送 Token
2. 关闭 WebSocket 连接
3. 停止极光推送（可选，保留 Token 但不再接收）

## REMOVED Requirements
无
