# Tasks

- [x] Task 1: BackgroundService 增加 onTaskRemoved 重启逻辑
  - [x] SubTask 1.1: 在 `onTaskRemoved` 中延迟 1 秒后发送 `ACTION_START` Intent 重启服务
  - [x] SubTask 1.2: 在 `onTaskRemoved` 中同时设置 AlarmManager 5 秒后兜底重启
  - [x] SubTask 1.3: 重启 Intent 中携带 SharedPreferences 中的 apiBaseUrl 和 sessionId

- [x] Task 2: 实现 AlarmManager 定时心跳机制
  - [x] SubTask 2.1: 在 BackgroundService `onStartCommand` 中注册 AlarmManager 心跳（5 分钟间隔）
  - [x] SubTask 2.2: 使用 `setExactAndAllowWhileIdle` 设置精确闹钟，兼容 Doze 模式
  - [x] SubTask 2.3: 在 `ACTION_STOP` 和 `onDestroy` 中取消 AlarmManager 心跳
  - [x] SubTask 2.4: 使用 `PendingIntent.FLAG_IMMUTABLE` 确保 Android 12+ 兼容性

- [x] Task 3: 创建 KeepAliveReceiver
  - [x] SubTask 3.1: 新建 `KeepAliveReceiver.kt`，接收 `cn.gzus.pro.action.KEEP_ALIVE` 广播
  - [x] SubTask 3.2: 检查 SharedPreferences 中是否有有效 sessionId 和 apiBaseUrl
  - [x] SubTask 3.3: 若有有效配置且 BackgroundService 未运行，则启动服务
  - [x] SubTask 3.4: 重新注册下一次 AlarmManager 心跳

- [x] Task 4: AndroidManifest.xml 新增配置
  - [x] SubTask 4.1: 新增 `SCHEDULE_EXACT_ALARM` 权限
  - [x] SubTask 4.2: 新增 `KeepAliveReceiver` 声明，监听 `cn.gzus.pro.action.KEEP_ALIVE`

- [x] Task 5: 轮询失败指数退避
  - [x] SubTask 5.1: 将 `scheduleWithFixedDelay` 改为 `schedule`，支持动态间隔
  - [x] SubTask 5.2: 连续失败时间隔从 30s 递增：30s → 60s → 120s → 300s（最大 5 分钟）
  - [x] SubTask 5.3: 成功一次后重置间隔为 30 秒

- [x] Task 6: 服务重启后状态恢复
  - [x] SubTask 6.1: 服务启动时检查 App 进程是否存在，若不存在则将 `appForeground` 设为 false
  - [x] SubTask 6.2: 在 `onStartCommand` 中增加进程存活检测逻辑

- [x] Task 7: Flutter 端配置同步
  - [x] SubTask 7.1: 确保 `_initPushServices` 每次都传入最新 apiBaseUrl 和 sessionId
  - [x] SubTask 7.2: 登出时确保 AlarmManager 心跳被取消（通过 stopForegroundService）

# Task Dependencies
- [Task 3] depends on [Task 2]（KeepAliveReceiver 需要知道 AlarmManager 心跳的注册逻辑）
- [Task 4] depends on [Task 3]（Manifest 声明依赖 Receiver 实现）
- [Task 5] can run in parallel with [Task 2, Task 3]
- [Task 6] can run in parallel with [Task 5]
- [Task 7] can run in parallel with [Task 1-6]
