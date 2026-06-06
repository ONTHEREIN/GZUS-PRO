# 加强应用保活策略 Spec

## Why
当前 GZUS-PRO 在用户从最近任务列表划掉应用后，Android 系统会终止整个进程（包括 Foreground Service）。国产 ROM（华为、小米、OPPO、vivo 等）普遍不遵守 `START_STICKY` 的重启承诺，导致后台轮询服务无法恢复，用户收不到任何推送通知。需要加强保活策略，确保进程被杀后能尽快恢复消息接收能力。

## What Changes
- `BackgroundService.kt` 新增 `onTaskRemoved` 回调，在用户划掉后台时立即尝试重启服务
- `BackgroundService.kt` 新增 `AlarmManager` 定时心跳机制，作为 Service 被杀后的兜底重启手段
- 新增 `KeepAliveReceiver`，接收 AlarmManager 的定时广播并重启 BackgroundService
- `AndroidManifest.xml` 新增 AlarmManager 相关权限和 Receiver 声明
- `BackgroundService.kt` 轮询失败时增加指数退避重试，避免网络异常时频繁请求
- `BackgroundService.kt` 在服务重启后自动恢复 `appForeground` 状态为 false（因为 App 不在前台）
- Flutter 端 `main.dart` 在 `_initPushServices` 时确保 BackgroundService 配置的 sessionId 和 apiBaseUrl 与当前一致

## Impact
- Affected specs: add-background-persistence, add-push-notifications
- Affected code:
  - `apps/mobile_web/android/app/src/main/kotlin/cn/gzus/pro/BackgroundService.kt` — 核心修改
  - `apps/mobile_web/android/app/src/main/AndroidManifest.xml` — 新增权限和 Receiver
  - `apps/mobile_web/android/app/src/main/kotlin/cn/gzus/pro/KeepAliveReceiver.kt` — 新文件
  - `apps/mobile_web/lib/main.dart` — 确保 BackgroundService 配置同步

## ADDED Requirements

### Requirement: onTaskRemoved 服务重启
系统 SHALL 在 `BackgroundService.onTaskRemoved()` 回调中尝试重启服务：
1. 在 `onTaskRemoved` 中延迟 1 秒后发送 `ACTION_START` Intent 重新启动自身
2. 同时设置一个 AlarmManager 定时器在 5 秒后触发，作为双重保障
3. 在重启 Intent 中携带 SharedPreferences 中保存的 apiBaseUrl 和 sessionId

#### Scenario: 用户划掉后台
- **WHEN** 用户从最近任务列表划掉 GZUS-PRO
- **THEN** `onTaskRemoved` 被触发，1 秒后尝试重启 BackgroundService，5 秒后 AlarmManager 兜底重启

#### Scenario: 系统直接杀死进程（无 onTaskRemoved）
- **WHEN** 系统因内存不足直接杀死进程，不触发 `onTaskRemoved`
- **THEN** AlarmManager 定时心跳在下一个周期触发 `KeepAliveReceiver`，检测并重启服务

### Requirement: AlarmManager 定时心跳
系统 SHALL 使用 `AlarmManager` 设置周期性心跳，作为服务被杀后的兜底重启机制：
1. 使用 `AlarmManager.setExactAndAllowWhileIdle()` 设置精确闹钟（允许在 Doze 模式下触发）
2. 心跳间隔为 5 分钟（300 秒），在省电和及时性之间取得平衡
3. 心跳触发时，检查 BackgroundService 是否正在运行，若未运行则重启
4. 服务启动时注册心跳，服务停止时取消心跳
5. 使用 `PendingIntent.FLAG_IMMUTABLE` 确保 Android 12+ 兼容性

#### Scenario: 服务正常运行时心跳触发
- **WHEN** AlarmManager 心跳触发且 BackgroundService 正在运行
- **THEN** 不做任何操作，重新注册下一次心跳

#### Scenario: 服务被杀后心跳触发
- **WHEN** AlarmManager 心跳触发且 BackgroundService 未运行
- **THEN** 启动 BackgroundService 并重新注册心跳

#### Scenario: 用户主动登出
- **WHEN** 用户主动登出，调用 `disableForegroundService()`
- **THEN** 取消 AlarmManager 心跳，不再尝试重启服务

### Requirement: KeepAliveReceiver
系统 SHALL 新增 `KeepAliveReceiver` 广播接收器：
1. 接收 AlarmManager 发送的定时心跳广播
2. 检查 SharedPreferences 中是否有有效的 sessionId 和 apiBaseUrl
3. 若有有效配置且 BackgroundService 未运行，则启动服务
4. 重新注册下一次 AlarmManager 心跳

#### Scenario: 心跳广播触发且有有效会话
- **WHEN** KeepAliveReceiver 收到心跳广播，且 SharedPreferences 中有 sessionId 和 apiBaseUrl
- **THEN** 检查 BackgroundService 是否运行，未运行则启动

#### Scenario: 心跳广播触发但无有效会话
- **WHEN** KeepAliveReceiver 收到心跳广播，但 SharedPreferences 中无 sessionId 或 apiBaseUrl
- **THEN** 不启动服务，不注册下一次心跳

### Requirement: 轮询失败指数退避
系统 SHALL 在 BackgroundService 轮询 `/push/poll` 失败时使用指数退避策略：
1. 连续失败时，轮询间隔从 30 秒逐步增加：30s → 60s → 120s → 300s（最大 5 分钟）
2. 成功一次后立即重置为 30 秒
3. 使用 `ScheduledExecutorService` 的 `schedule` 方法替代 `scheduleWithFixedDelay`，以便动态调整间隔

#### Scenario: 连续轮询失败
- **WHEN** `/push/poll` 连续返回错误或网络超时
- **THEN** 轮询间隔按指数退避增加，最大不超过 5 分钟

#### Scenario: 轮询恢复成功
- **WHEN** 之前有失败，但本次轮询成功
- **THEN** 轮询间隔重置为 30 秒

### Requirement: 服务重启后状态恢复
系统 SHALL 在 BackgroundService 重启后正确恢复状态：
1. 从 SharedPreferences 读取 `appForeground` 标志
2. 若 App 进程不存在（即用户划掉了后台），将 `appForeground` 设为 `false`
3. 这样轮询到新消息时会正确弹出 Native 通知

#### Scenario: 服务重启且 App 不在前台
- **WHEN** BackgroundService 通过 AlarmManager 或 onTaskRemoved 重启
- **THEN** 将 `appForeground` 设为 `false`，确保新消息通过 Native 通知弹出

### Requirement: AndroidManifest 新增配置
系统 SHALL 在 `AndroidManifest.xml` 中新增：
1. `SCHEDULE_EXACT_ALARM` 权限（Android 12+ 精确闹钟所需）
2. `KeepAliveReceiver` 声明，监听自定义 action `cn.gzus.pro.action.KEEP_ALIVE`

#### Scenario: Android 12+ 设备使用精确闹钟
- **WHEN** 应用在 Android 12+ 设备上运行
- **THEN** AlarmManager 能正常设置精确闹钟（用户需在系统设置中授予精确闹钟权限）

### Requirement: Flutter 端配置同步
系统 SHALL 在 Flutter 端 `_initPushServices` 时确保 BackgroundService 的配置与当前会话一致：
1. 每次调用 `enableForegroundService` 时都传入最新的 apiBaseUrl 和 sessionId
2. 这确保即使服务已在运行，配置也会被更新

#### Scenario: 会话刷新后配置同步
- **WHEN** 用户重新打开 App，_initPushServices 被调用
- **THEN** BackgroundService 收到最新的 apiBaseUrl 和 sessionId，覆盖旧配置

## MODIFIED Requirements

### Requirement: 前台保活服务（原 add-background-persistence spec）
在原有 ForegroundService 基础上增加：
1. `onTaskRemoved` 回调中尝试重启服务
2. AlarmManager 心跳作为兜底重启机制
3. 轮询失败指数退避
4. 服务重启后正确恢复 `appForeground` 状态

### Requirement: 登出流程（原 add-push-notifications spec）
登出时除了停止 ForegroundService 外，还需：
1. 取消 AlarmManager 心跳定时器
2. 清除 KeepAliveReceiver 的 PendingIntent

## REMOVED Requirements
无
