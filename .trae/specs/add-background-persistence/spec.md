# 后台保活与系统权限引导功能 Spec

## Why
当前 GZUS-PRO 的极光推送在用户登录后正常工作，但大陆 Android 系统（华为、小米、OPPO、vivo 等）对后台应用管控严格：
- 系统默认禁止自启动，导致 App 重启后无法接收推送
- 系统默认开启电池优化，会自动休眠后台应用，导致推送延迟或丢失
- 通知权限可能未授予，导致通知无法弹出

因此需要一套引导流程，帮助用户在首次登录后完成必要的系统权限配置，并提供可选的后台保活策略。

## What Changes
- 新增 Flutter 引导页面 `BackgroundGuidePage`，首次登录后引导用户完成系统权限配置
- 新增 Android 后台保活服务 `BackgroundService`，支持前台服务保活和隐藏最近任务入口
- 新增权限检测服务 `PermissionService`，检测自启动、电池优化、通知权限状态
- Android `AndroidManifest.xml` 新增必要的权限声明和服务声明
- 在登录成功后判断是否已完成引导，未完成则跳转到引导页
- 用户可在设置页面重新打开引导页

## Impact
- Affected specs: 登录模块、推送模块、设置页面
- Affected code:
  - `apps/mobile_web/lib/background_guide_page.dart` — 新文件，引导页面
  - `apps/mobile_web/lib/permission_service.dart` — 新文件，权限检测服务
  - `apps/mobile_web/lib/background_service.dart` — 新文件，后台保活服务
  - `apps/mobile_web/lib/main.dart` — 首次登录跳转引导页
  - `apps/mobile_web/android/app/src/main/AndroidManifest.xml` — 新增权限和服务声明
  - `apps/mobile_web/android/app/src/main/kotlin/.../MainActivity.kt` — 新增厂商自启动跳转

## ADDED Requirements

### Requirement: 权限检测服务
系统 SHALL 提供 `PermissionService` 类，通过 MethodChannel 与原生 Android 通信，检测以下权限状态：
1. `自启动权限` — 检测应用是否在系统的自启动白名单中
2. `电池优化权限` — 检测应用是否在电池优化白名单中（忽略电池优化）
3. `通知权限` — 检测系统通知权限是否已授予

返回结构为 `Map<String, bool>`，键为权限标识，值为是否已授权。

#### Scenario: 检测自启动权限
- **WHEN** 调用 `PermissionService.checkAutoStart()`
- **THEN** 返回 `true`（已授权）或 `false`（未授权）

#### Scenario: 检测电池优化权限
- **WHEN** 调用 `PermissionService.checkBatteryOptimization()`
- **THEN** 返回 `true`（已优化白名单）或 `false`（需要优化）

#### Scenario: 检测通知权限
- **WHEN** 调用 `PermissionService.checkNotificationPermission()`
- **THEN** 返回 `true`（已授权）或 `false`（未授权）

### Requirement: 权限引导页面
系统 SHALL 在首次登录后显示引导页面 `BackgroundGuidePage`，包含以下功能：
1. 页面标题为「优化推送体验」，副标题说明为何需要配置
2. 三个权限卡片，分别展示自启动、电池优化、通知权限的状态和引导操作
3. 每个卡片显示当前状态（已开启/未开启）和操作按钮
4. 「打开自启动设置」按钮 — 跳转至系统自启动设置页面
5. 「关闭电池优化」按钮 — 跳转至电池优化设置页面
6. 「打开通知权限」按钮 — 调用 `LocalNotificationService.init()` 触发系统权限弹窗
7. 「已完成配置」按钮 — 仅当三个权限全部通过时才可点击，点击后保存状态并返回
8. 底部「暂不配置」链接 — 跳过引导，保存跳过状态但不阻止用户进入 App
9. 通过 `SharedPreferences` 持久化 `background_guide_completed` 标志

#### Scenario: 首次登录进入引导页
- **WHEN** 用户首次登录成功且 `background_guide_completed` 为 false
- **THEN** 显示 `BackgroundGuidePage`

#### Scenario: 三个权限全部通过
- **WHEN** 用户依次完成三个权限配置，所有检测返回 true
- **THEN** 「已完成配置」按钮变为可点击状态

#### Scenario: 用户跳过引导
- **WHEN** 用户点击「暂不配置」
- **THEN** 保存 `background_guide_completed = true`，进入主页面，下次登录不再显示

### Requirement: 跳转到系统设置页面
系统 SHALL 通过 MethodChannel 跳转至各厂商的系统设置页面：
1. `openAutoStartSettings()` — 打开厂商自带的应用自启动管理页面
2. `openBatteryOptimizationSettings()` — 打开系统电池优化设置页面（通用 intent）
3. 每个方法返回 `bool`，指示是否成功打开

针对主流厂商（华为、小米、OPPO、vivo）使用厂商特定的 intent 和组件名跳转， fallback 到通用设置页面。

#### Scenario: 华为设备打开自启动设置
- **WHEN** 用户点击「打开自启动设置」
- **THEN** 尝试打开华为的「自启动管理」页面，若失败则打开通用设置

#### Scenario: 通用设备打开电池优化设置
- **WHEN** 用户点击「关闭电池优化」
- **THEN** 打开系统电池优化设置页面，用户手动选择忽略本应用

### Requirement: 前台保活服务
系统 SHALL 提供可选的后台保活服务 `BackgroundService`：
1. 使用 Android 前台服务（`ForegroundService`），显示一个持久通知
2. 通知标题为「GZUS-PRO 正在运行」，内容为「用于接收教务通知」
3. 用户可点击通知进入 App，不主动消失
4. 在 `LocalNotificationService` 中添加一个 `enableForegroundService()` 方法
5. 在 `main.dart` 登录成功后调用 `enableForegroundService()`
6. 服务运行期间 App 在最近任务中可见但不会被系统自动杀死

#### Scenario: 启用前台服务
- **WHEN** 用户登录成功后
- **THEN** 前台服务启动，显示持久通知

#### Scenario: 服务通知被用户点击
- **WHEN** 用户点击前台服务通知
- **THEN** 打开 App 主界面

### Requirement: 隐藏最近任务入口（可选）
系统 SHALL 提供选项让用户选择是否隐藏最近任务入口：
1. 在引导页面增加一个开关「在最近任务中隐藏应用」
2. 开关默认关闭（不在最近任务中隐藏）
3. 开启后，通过 `MainActivity` 设置 `FLAG_EXCLUDE_FROM_RECENTS` 隐藏任务入口
4. 保存用户偏好到 `SharedPreferences`（`hide_from_recents`）

#### Scenario: 用户开启隐藏入口
- **WHEN** 用户开启「在最近任务中隐藏应用」开关
- **THEN** 下次打开 App 时设置 `FLAG_EXCLUDE_FROM_RECENTS`，App 不出现在最近任务列表

### Requirement: Android 原生端实现
系统 SHALL 在原生 Android 端实现以下功能：

#### MethodChannel 处理器（MainActivity.kt）
1. `checkAutoStartPermission` — 检测自启动权限（通过调用厂商 API 或包管理器检测）
2. `openAutoStartSettings` — 跳转厂商自启动设置页面
3. `openBatteryOptimizationSettings` — 跳转电池优化设置页面

#### 自启动权限检测逻辑
由于不同厂商检测方式不同，采用以下策略：
1. 尝试调用厂商特定 API 检测（如华为 `HwPowerManager`）
2. 若无法检测，返回 `false`（保守策略，引导用户手动配置）

#### 前台服务（BackgroundService.kt）
1. 继承 `android.app.Service`
2. `onCreate` — 创建通知渠道
3. `onStartCommand` — 启动前台通知，返回 `START_STICKY`
4. `onBind` — 返回 null
5. `onDestroy` — 停止前台通知

#### AndroidManifest.xml 新增
```xml
<uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>
<uses-permission android:name="android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS"/>
<uses-permission android:name="android.permission.REQUEST_DELETE_PACKAGES"/>
<service android:name=".BackgroundService" android:exported="false" android:foregroundServiceType="dataSync"/>
```

#### Activity 属性调整
在 `MainActivity` 的 `launchMode` 保持 `singleTop`，由 Flutter 控制 Activity 行为。

### Requirement: 偏好存储
系统 SHALL 使用 `SharedPreferences` 存储以下配置：
1. `background_guide_completed: bool` — 是否已完成引导（默认 false）
2. `foreground_service_enabled: bool` — 是否启用前台服务（默认 true）
3. `hide_from_recents: bool` — 是否隐藏最近任务入口（默认 false）

#### Scenario: 读取引导状态
- **WHEN** App 启动时
- **THEN** 从 `SharedPreferences` 读取 `background_guide_completed`

## MODIFIED Requirements

### Requirement: 登录流程
登录成功后，判断 `background_guide_completed` 状态：
1. 若 `false` → 跳转到 `BackgroundGuidePage`
2. 若 `true` → 进入 `DashboardShell` 主页面

### Requirement: 引导页面返回
用户点击「已完成配置」或「暂不配置」后：
1. 保存 `background_guide_completed = true`
2. 若 `foreground_service_enabled` 为 `true`，启动前台保活服务
3. 跳转到 `DashboardShell` 主页面

## REMOVED Requirements
无
