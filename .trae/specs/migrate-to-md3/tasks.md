# Tasks

- [x] Task 1: 迁移 App 入口与主题系统
  - [x] SubTask 1.1: 将 `FluentApp` 替换为 `MaterialApp`，启用 `useMaterial3: true`
  - [x] SubTask 1.2: 配置 MD3 `ThemeData`，使用 `ColorScheme.fromSeed(seedColor: Colors.blue)` 生成亮色和暗色主题
  - [x] SubTask 1.3: 将 `import 'package:fluent_ui/fluent_ui.dart'` 替换为 `import 'package:flutter/material.dart'`
  - [x] SubTask 1.4: 移除 `import 'package:flutter/material.dart' show showModalBottomSheet'` 的限定导入（现在直接从 material 导入）

- [x] Task 2: 迁移 LoadingPage
  - [x] SubTask 2.1: `ScaffoldPage` → `Scaffold`
  - [x] SubTask 2.2: `ProgressRing` → `CircularProgressIndicator`
  - [x] SubTask 2.3: `FluentIcons.education` → `Icons.school`
  - [x] SubTask 2.4: `FluentTheme.of(context).accentColor` → `Theme.of(context).colorScheme.primary`

- [x] Task 3: 迁移 LoginPage
  - [x] SubTask 3.1: `ScaffoldPage` → `Scaffold`
  - [x] SubTask 3.2: `FluentTheme.of(context).brightness` → `Theme.of(context).brightness`
  - [x] SubTask 3.3: `FluentPageRoute` → `MaterialPageRoute`
  - [x] SubTask 3.4: 登录表单中的 Fluent UI 输入框/按钮迁移为 Material 组件（`TextField` + `FilledButton`）
  - [x] SubTask 3.5: `FluentIcons.*` → `Icons.*`

- [x] Task 4: 迁移 DashboardShell 导航与顶栏
  - [x] SubTask 4.1: `ScaffoldPage` → `Scaffold`
  - [x] SubTask 4.2: `MobileNavBar` 替换为 Material `NavigationBar` + `NavigationDestination`
  - [x] SubTask 4.3: `AppSidebar` 替换为 Material `NavigationRail`
  - [x] SubTask 4.4: `FlyoutController` + `FlyoutTarget` + `FlyoutContent` 替换为 `PopupMenuButton` + `PopupMenuEntry`
  - [x] SubTask 4.5: `ComboBox` 替换为 `DropdownMenu`
  - [x] SubTask 4.6: `ToggleSwitch` 替换为 `Switch`
  - [x] SubTask 4.7: `FluentIcons.*` → `Icons.*`
  - [x] SubTask 4.8: 所有 `FluentTheme.of(context)` 颜色引用迁移至 `Theme.of(context).colorScheme.*`

- [x] Task 5: 迁移 MorePage
  - [x] SubTask 5.1: `ScaffoldPage` → `Scaffold`
  - [x] SubTask 5.2: 功能入口卡片迁移为 Material `Card` + `ListTile`
  - [x] SubTask 5.3: 设置区域 `ComboBox` → `DropdownMenu`，`ToggleSwitch` → `Switch`
  - [x] SubTask 5.4: `FluentIcons.*` → `Icons.*`
  - [x] SubTask 5.5: 颜色引用迁移至 MD3 ColorScheme

- [x] Task 6: 迁移 AsyncPanel
  - [x] SubTask 6.1: `InfoBar` → 内联错误展示
  - [x] SubTask 6.2: `ProgressRing` → `CircularProgressIndicator`
  - [x] SubTask 6.3: 颜色引用迁移

- [x] Task 7: 迁移 InfoPage
  - [x] SubTask 7.1: `ScaffoldPage` → `Scaffold`
  - [x] SubTask 7.2: `FluentIcons.*` → `Icons.*`
  - [x] SubTask 7.3: 颜色引用迁移至 MD3 ColorScheme

- [x] Task 8: 迁移 NoticesPage 与 NoticeDetailPage
  - [x] SubTask 8.1: `ScaffoldPage` → `Scaffold`
  - [x] SubTask 8.2: `FluentPageRoute` → `MaterialPageRoute`
  - [x] SubTask 8.3: 通知卡片迁移为 Material `Card` + `ListTile`
  - [x] SubTask 8.4: `FluentIcons.*` → `Icons.*`
  - [x] SubTask 8.5: 颜色引用迁移

- [x] Task 9: 迁移 SchedulePage（课表页）
  - [x] SubTask 9.1: `ScaffoldPage` → `Scaffold`
  - [x] SubTask 9.2: 视图切换组件迁移为 Material 组件
  - [x] SubTask 9.3: 底部 Sheet 保持使用 `showModalBottomSheet`
  - [x] SubTask 9.4: `FluentIcons.*` → `Icons.*`
  - [x] SubTask 9.5: 颜色引用迁移

- [x] Task 10: 迁移 TimetableView 与 TodayScheduleView
  - [x] SubTask 10.1: `ProgressBar` → `LinearProgressIndicator`
  - [x] SubTask 10.2: `FluentIcons.*` → `Icons.*`
  - [x] SubTask 10.3: 颜色引用迁移至 MD3 ColorScheme

- [x] Task 11: 迁移 AttendancePage
  - [x] SubTask 11.1: `ScaffoldPage` → `Scaffold`
  - [x] SubTask 11.2: `ProgressBar` → `LinearProgressIndicator`
  - [x] SubTask 11.3: `Expander` → `ExpansionTile`
  - [x] SubTask 11.4: `FluentIcons.*` → `Icons.*`
  - [x] SubTask 11.5: 颜色引用迁移

- [x] Task 12: 迁移 ExamsPage
  - [x] SubTask 12.1: `ScaffoldPage` → `Scaffold`
  - [x] SubTask 12.2: `FluentIcons.*` → `Icons.*`
  - [x] SubTask 12.3: 颜色引用迁移

- [x] Task 13: 迁移 GradesPage
  - [x] SubTask 13.1: `ScaffoldPage` → `Scaffold`
  - [x] SubTask 13.2: `Expander` → `ExpansionTile`
  - [x] SubTask 13.3: `ProgressBar` → `LinearProgressIndicator`
  - [x] SubTask 13.4: `FluentIcons.*` → `Icons.*`
  - [x] SubTask 13.5: 颜色引用迁移

- [x] Task 14: 迁移 CreditsPage
  - [x] SubTask 14.1: `ScaffoldPage` → `Scaffold`
  - [x] SubTask 14.2: `ProgressBar` → `LinearProgressIndicator`
  - [x] SubTask 14.3: `Expander` → `ExpansionTile`
  - [x] SubTask 14.4: `FluentIcons.*` → `Icons.*`
  - [x] SubTask 14.5: 颜色引用迁移

- [x] Task 15: 迁移辅助组件（PagePanel、AccentPanel、_LoginFormCard、_IconBadge、_IconLabel 等）
  - [x] SubTask 15.1: 所有自定义辅助组件中的 Fluent UI 引用迁移为 Material
  - [x] SubTask 15.2: `Button` → 对应 Material 按钮
  - [x] SubTask 15.3: 颜色引用迁移

- [x] Task 16: 清理与验证
  - [x] SubTask 16.1: 从 `pubspec.yaml` 移除 `fluent_ui` 依赖
  - [x] SubTask 16.2: 全局搜索确认无 `fluent_ui`、`FluentApp`、`FluentTheme`、`FluentIcons`、`ScaffoldPage`、`FluentPageRoute` 残留引用
  - [x] SubTask 16.3: 执行 `flutter analyze` 确认无编译错误
  - [x] SubTask 16.4: 执行 `flutter build web` 确认构建成功

# Task Dependencies
- [Task 1] 必须最先完成，所有后续 Task 依赖主题系统就绪
- [Task 2-15] 互相独立，可并行执行
- [Task 16] 必须在所有其他 Task 完成后执行
