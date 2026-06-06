# Tasks

- [x] Task 1: Flutter 权限检测服务
  - [x] SubTask 1.1: 创建 `permission_service.dart`，实现 `PermissionService` 类
  - [x] SubTask 1.2: 通过 MethodChannel 调用原生 Android 检测自启动权限
  - [x] SubTask 1.3: 通过 MethodChannel 调用原生 Android 检测电池优化权限
  - [x] SubTask 1.4: 通过 MethodChannel 调用原生 Android 检测通知权限
  - [x] SubTask 1.5: 通过 MethodChannel 打开自启动设置页面
  - [x] SubTask 1.6: 通过 MethodChannel 打开电池优化设置页面

- [x] Task 2: Flutter 引导页面
  - [x] SubTask 2.1: 创建 `background_guide_page.dart`，实现引导页面 UI
  - [x] SubTask 2.2: 实现三个权限卡片（自启动、电池优化、通知权限）
  - [x] SubTask 2.3: 实现权限状态实时检测和显示
  - [x] SubTask 2.4: 实现「打开自启动设置」跳转逻辑
  - [x] SubTask 2.5: 实现「关闭电池优化」跳转逻辑
  - [x] SubTask 2.6: 实现「打开通知权限」请求逻辑
  - [x] SubTask 2.7: 实现「已完成配置」和「暂不配置」按钮逻辑
  - [x] SubTask 2.8: 实现引导状态持久化（SharedPreferences）

- [x] Task 3: Flutter 后台保活服务
  - [x] SubTask 3.1: 创建 `background_service.dart`，封装前台服务调用
  - [x] SubTask 3.2: 实现 `enableForegroundService()` 启动前台服务
  - [x] SubTask 3.3: 实现 `disableForegroundService()` 停止前台服务
  - [x] SubTask 3.4: 实现隐藏最近任务入口的方法

- [x] Task 4: Android 原生端实现
  - [x] SubTask 4.1: 修改 `MainActivity.kt`，实现 MethodChannel 处理器
  - [x] SubTask 4.2: 实现 `checkAutoStartPermission` 方法（兼容多厂商）
  - [x] SubTask 4.3: 实现 `openAutoStartSettings` 方法（跳转厂商设置）
  - [x] SubTask 4.4: 实现 `openBatteryOptimizationSettings` 方法
  - [x] SubTask 4.5: 创建 `BackgroundService.kt`，实现前台服务
  - [x] SubTask 4.6: 创建前台通知渠道

- [x] Task 5: Android Manifest 配置
  - [x] SubTask 5.1: 新增 `FOREGROUND_SERVICE` 权限
  - [x] SubTask 5.2: 新增 `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` 权限
  - [x] SubTask 5.3: 新增 `BackgroundService` 服务声明

- [x] Task 6: 主流程集成
  - [x] SubTask 6.1: 在 `main.dart` 登录成功后判断是否跳转引导页
  - [x] SubTask 6.2: 在引导页完成后启动前台保活服务
  - [x] SubTask 6.3: 在设置页面添加「重新配置后台权限」入口
  - [x] SubTask 6.4: 在 `DashboardShell` 集成设置入口

- [x] Task 7: 测试和验证
  - [x] SubTask 7.1: 验证自启动权限检测逻辑
  - [x] SubTask 7.2: 验证电池优化设置跳转
  - [x] SubTask 7.3: 验证前台服务启动和通知显示
  - [x] SubTask 7.4: 验证引导页面流程完整性

# Task Dependencies
- [Task 2] depends on [Task 1]
- [Task 3] depends on [Task 1]
- [Task 6] depends on [Task 1, Task 2, Task 3]
- [Task 5] depends on [Task 4]
- [Task 4] can run in parallel with [Task 1, Task 2]
