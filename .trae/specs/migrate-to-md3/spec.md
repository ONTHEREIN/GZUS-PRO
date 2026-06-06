# 全局 MD3 设计风格迁移 Spec

## Why
当前应用使用 `fluent_ui`（Windows Fluent Design 风格），在移动端体验上与 Android/iOS 原生风格差异较大，不符合移动端用户的设计预期。迁移至 Material Design 3（MD3）可以让应用获得原生级别的视觉一致性、更好的平台适配性，以及 Flutter 官方长期维护的组件库支持。参考 https://m3.material.io/develop/flutter 。

## What Changes
- **BREAKING** 移除 `fluent_ui` 依赖，全面替换为 Flutter 原生 Material 库（`package:flutter/material.dart`）
- `FluentApp` 替换为 `MaterialApp`，启用 `useMaterial3: true`
- `FluentThemeData` 替换为 `ThemeData`，使用 MD3 ColorScheme
- 所有 `ScaffoldPage` 替换为 `Scaffold`
- 所有 `FluentPageRoute` 替换为 `MaterialPageRoute`
- 移动端底栏 `MobileNavBar` 替换为 `NavigationBar`
- 桌面端侧边栏 `AppSidebar` 替换为 `NavigationRail`
- `Flyout`/`FlyoutContent` 替换为 `PopupMenuButton`/`PopupMenuEntry`
- `ComboBox` 替换为 `DropdownMenu`
- `ToggleSwitch` 替换为 `Switch`
- `InfoBar` 替换为 `SnackBar`
- `ProgressRing` 替换为 `CircularProgressIndicator`
- `ProgressBar` 替换为 `LinearProgressIndicator`
- `Expander` 替换为 `ExpansionTile`
- `FluentIcons.*` 替换为 `Icons.*`（Material Icons）
- `FluentTheme.of(context).accentColor` 替换为 `Theme.of(context).colorScheme.primary`
- `FluentTheme.of(context).inactiveColor` 替换为 `Theme.of(context).colorScheme.onSurfaceVariant`
- `FluentTheme.of(context).resources.*` 替换为 `Theme.of(context).colorScheme.*` / `Theme.of(context).dividerColor`
- `Button` 替换为对应的 Material 按钮（`FilledButton`、`OutlinedButton`、`TextButton`、`IconButton`）
- 所有自定义绘制组件的颜色引用迁移至 MD3 ColorScheme

## Impact
- Affected specs: optimize-mobile-ui、optimize-login-page、refine-mobile-ux（所有 UI 相关 spec 的组件层均受影响）
- Affected code: `apps/mobile_web/lib/main.dart`（全部 UI 代码）、`apps/mobile_web/pubspec.yaml`（移除 fluent_ui 依赖）

## ADDED Requirements

### Requirement: MaterialApp 与 MD3 主题
系统 SHALL 使用 `MaterialApp` 替代 `FluentApp`，并启用 `useMaterial3: true`，配置完整的 MD3 ColorScheme。

#### Scenario: 亮色主题
- **WHEN** 应用以亮色模式运行
- **THEN** 使用基于 `ColorScheme.fromSeed()` 生成的 MD3 亮色主题，主色保持蓝色系

#### Scenario: 暗色主题
- **WHEN** 应用以暗色模式运行
- **THEN** 使用同一 seed color 生成的 MD3 暗色主题

#### Scenario: 主题切换
- **WHEN** 用户切换深色模式
- **THEN** 仅切换主题数据，不触发数据重载

### Requirement: 移动端 NavigationBar
系统 SHALL 在移动端使用 Material 3 `NavigationBar` 替代自定义 `MobileNavBar`，展示底部导航 Tab。

#### Scenario: 底栏展示
- **WHEN** 屏幕宽度 < 720dp
- **THEN** 使用 `NavigationBar` 组件展示底部导航，每个 Tab 使用 `NavigationDestination`（icon + label）
- **AND** 选中态使用 MD3 默认的 indicator 样式

#### Scenario: Tab 切换
- **WHEN** 用户点击底栏 Tab
- **THEN** 切换到对应页面，选中态高亮

### Requirement: 桌面端 NavigationRail
系统 SHALL 在桌面端使用 Material 3 `NavigationRail` 替代自定义 `AppSidebar`。

#### Scenario: 侧边栏展示
- **WHEN** 屏幕宽度 >= 720dp
- **THEN** 使用 `NavigationRail` 组件展示侧边导航
- **AND** 宽度 >= 1024dp 时显示 extended 模式（图标+标签），< 1024dp 时显示紧凑模式（仅图标）

#### Scenario: 导航项切换
- **WHEN** 用户点击侧边栏导航项
- **THEN** 切换到对应页面，选中态使用 MD3 indicator

### Requirement: Scaffold 页面结构
系统 SHALL 使用 Material `Scaffold` 替代 `ScaffoldPage`，配合 `AppBar`（桌面端）或无 AppBar（移动端）。

#### Scenario: 移动端页面结构
- **WHEN** 屏幕宽度 < 720dp
- **THEN** 使用 `Scaffold`，不显示 AppBar，内容区域使用 SafeArea

#### Scenario: 桌面端页面结构
- **WHEN** 屏幕宽度 >= 720dp
- **THEN** 使用 `Scaffold` + `AppBar`，AppBar 显示页面标题和操作按钮

### Requirement: Flyout 替换为 PopupMenu
系统 SHALL 将 `Flyout`/`FlyoutContent` 替换为 Material `PopupMenuButton`/`PopupMenuEntry`。

#### Scenario: 溢出菜单
- **WHEN** 用户点击顶栏更多按钮
- **THEN** 弹出 `PopupMenuButton` 菜单，包含学年选择、学期选择、深色模式开关、退出登录

### Requirement: ComboBox 替换为 DropdownMenu
系统 SHALL 将 `ComboBox`/`ComboBoxItem` 替换为 Material `DropdownMenu`。

#### Scenario: 学年/学期选择
- **WHEN** 用户需要选择学年或学期
- **THEN** 使用 `DropdownMenu` 组件，支持从下拉列表中选择

### Requirement: ToggleSwitch 替换为 Switch
系统 SHALL 将 `ToggleSwitch` 替换为 Material `Switch`。

#### Scenario: 深色模式开关
- **WHEN** 用户切换深色模式
- **THEN** 使用 MD3 `Switch` 组件，带有 thumb 和 track 的 MD3 样式

### Requirement: InfoBar 替换为 SnackBar
系统 SHALL 将 `InfoBar` 替换为 Material `SnackBar`。

#### Scenario: 错误提示
- **WHEN** 数据加载失败
- **THEN** 使用 `SnackBar` 显示错误信息，支持关闭操作

### Requirement: ProgressRing/ProgressBar 替换
系统 SHALL 将 `ProgressRing` 替换为 `CircularProgressIndicator`，将 `ProgressBar` 替换为 `LinearProgressIndicator`。

#### Scenario: 加载指示器
- **WHEN** 页面正在加载数据
- **THEN** 使用 `CircularProgressIndicator` 显示加载状态

#### Scenario: 进度条
- **WHEN** 需要展示进度（如考勤率、学分进度）
- **THEN** 使用 `LinearProgressIndicator`，配合 MD3 颜色

### Requirement: Expander 替换为 ExpansionTile
系统 SHALL 将 `Expander` 替换为 Material `ExpansionTile`。

#### Scenario: 成绩详情展开
- **WHEN** 用户点击成绩条目
- **THEN** 使用 `ExpansionTile` 展开显示详情

### Requirement: FluentIcons 替换为 Material Icons
系统 SHALL 将所有 `FluentIcons.*` 替换为对应的 `Icons.*`（Material Icons）。

#### Scenario: 图标映射
- **WHEN** 组件需要显示图标
- **THEN** 使用 Material Icons 库中的对应图标，保持语义一致

### Requirement: 颜色系统迁移
系统 SHALL 将所有 Fluent UI 颜色引用迁移至 MD3 ColorScheme。

#### Scenario: 主色调
- **WHEN** 组件需要使用主色调
- **THEN** 使用 `Theme.of(context).colorScheme.primary` 替代 `FluentTheme.of(context).accentColor`

#### Scenario: 次要文字颜色
- **WHEN** 组件需要使用次要/不活跃文字颜色
- **THEN** 使用 `Theme.of(context).colorScheme.onSurfaceVariant` 替代 `FluentTheme.of(context).inactiveColor`

#### Scenario: 背景色
- **WHEN** 组件需要使用背景色
- **THEN** 使用 `Theme.of(context).colorScheme.surface` / `surfaceContainer` 替代 `FluentTheme.of(context).resources.solidBackgroundFillColorBase`

#### Scenario: 分割线颜色
- **WHEN** 组件需要使用分割线颜色
- **THEN** 使用 `Theme.of(context).colorScheme.outlineVariant` 替代 `FluentTheme.of(context).resources.controlStrokeColorDefault`

### Requirement: Button 迁移
系统 SHALL 将 Fluent UI `Button` 替换为对应的 Material 按钮。

#### Scenario: 主要操作按钮
- **WHEN** 需要主要操作按钮（如登录）
- **THEN** 使用 `FilledButton`

#### Scenario: 次要操作按钮
- **WHEN** 需要次要操作按钮
- **THEN** 使用 `OutlinedButton`

#### Scenario: 文字按钮
- **WHEN** 需要低强调度按钮
- **THEN** 使用 `TextButton`

#### Scenario: 图标按钮
- **WHEN** 需要图标按钮
- **THEN** 使用 `IconButton`

### Requirement: 移除 fluent_ui 依赖
系统 SHALL 从 `pubspec.yaml` 中移除 `fluent_ui` 依赖，确保代码中无任何 fluent_ui 引用。

#### Scenario: 编译通过
- **WHEN** 执行 `flutter build` 或 `flutter run`
- **THEN** 编译成功，无 fluent_ui 相关错误

#### Scenario: 无残留引用
- **WHEN** 在代码中搜索 `fluent_ui` 或 `FluentTheme` 或 `FluentApp`
- **THEN** 无匹配结果

## MODIFIED Requirements

### Requirement: LoginPage
原 LoginPage 使用 `ScaffoldPage` + `FluentTheme`。修改后：
- 使用 Material `Scaffold` 作为页面容器
- 使用 `Theme.of(context)` 获取主题数据
- `FluentPageRoute` 替换为 `MaterialPageRoute`
- 输入框使用 Material `TextField` + `InputDecoration`
- 登录按钮使用 `FilledButton`
- 验证码图片展示保持不变

### Requirement: DashboardShell
原 DashboardShell 使用 `ScaffoldPage` + `Flyout` + `ComboBox` + `ToggleSwitch`。修改后：
- 使用 Material `Scaffold`
- `Flyout` 替换为 `PopupMenuButton`
- `ComboBox` 替换为 `DropdownMenu`
- `ToggleSwitch` 替换为 `Switch`
- `FluentIcons.*` 替换为 `Icons.*`

### Requirement: MorePage
原 MorePage 使用 Fluent UI 组件。修改后：
- 使用 Material `Card` / `ListTile` 展示功能入口
- 设置区域使用 `Switch`、`DropdownMenu` 等 Material 组件

### Requirement: SchedulePage
原 SchedulePage 使用 `ScaffoldPage` + Fluent UI 组件。修改后：
- 使用 Material `Scaffold`
- 底部 Sheet 使用 Material `showModalBottomSheet`
- 周次选择器使用 Material `showModalBottomSheet` + `Chip` 选择

### Requirement: AsyncPanel
原 AsyncPanel 使用 `InfoBar` 显示错误。修改后：
- 使用 `SnackBar` 或 `LinearProgressIndicator` + 错误文字显示

### Requirement: 所有数据页面（AttendancePage、ExamsPage、GradesPage、CreditsPage）
原页面使用 `ProgressBar`、`Expander`、`InfoBar` 等 Fluent 组件。修改后：
- `ProgressBar` → `LinearProgressIndicator`
- `Expander` → `ExpansionTile`
- `InfoBar` → `SnackBar`
- 所有颜色引用迁移至 MD3 ColorScheme

## REMOVED Requirements

### Requirement: fluent_ui 依赖
**Reason**: 全面迁移至 Material Design 3，不再需要 Fluent Design 库
**Migration**: 从 pubspec.yaml 移除 `fluent_ui: ^4.9.2`，所有引用替换为 Material 组件

### Requirement: FluentPageRoute
**Reason**: 使用 MaterialPageRoute 替代
**Migration**: 所有 `FluentPageRoute(builder: ...)` 替换为 `MaterialPageRoute(builder: ...)`
