# 移除顶栏并重构更多页 Spec

## Why
当前 DashboardShell 在手机端有一个顶栏（显示学生姓名、主题切换、退出登录等），占用了宝贵的垂直空间。将这些功能整合到"更多"页面可以使主界面更简洁，同时"更多"页当前的布局较为简单，需要按照 Material Design 3 风格重构以提供更合理的功能分组和视觉层次。

## What Changes
- **删除手机端顶栏**：移除 DashboardShell 中 `_mobileHeaderVisible` 相关的顶栏区域（包含学生姓名、主题切换按钮、退出登录按钮）
- **顶栏功能迁移到 MorePage**：将主题切换、退出登录、学年学期设置等功能整合到 MorePage
- **重构 MorePage 布局**：
  - 按功能分组（导航管理、快捷设置、账户操作）
  - 使用 MD3 风格的 ListTile、Card、Divider 组织内容
  - 网格区域保留但优化视觉呈现
- **顶部安全区适配**：
  - 手机端：页面内容顶部使用 SafeArea 适配刘海屏/状态栏
  - 桌面端：无需额外安全区处理，保持现有 padding

## Impact
- Affected code: `apps/mobile_web/lib/main.dart` 中的 `DashboardShell` 和 `MorePage`
- Breaking: 用户交互路径变化（主题切换从顶栏点击变为进入更多页操作）

## ADDED Requirements

### Requirement: 手机端无顶栏布局
The system SHALL 在手机端（compact 模式）隐藏顶栏区域，释放状态栏下方的垂直空间。

#### Scenario: 首页浏览
- **WHEN** 用户在手机端浏览首页
- **THEN** 页面内容从屏幕顶部（考虑安全区）开始，不显示学生姓名和工具按钮的顶栏

### Requirement: MorePage 功能分组
The system SHALL 在 MorePage 中按逻辑分组展示所有功能和设置。

#### Scenario: 进入更多页
- **WHEN** 用户点击底部导航的"更多"
- **THEN** 页面显示：
  - 顶部：页面标题"更多"（大号 MD3 标题样式）
  - 导航管理区：可编辑的底栏标签管理（网格形式）
  - 快捷设置区：学年、学期、外观模式、自动隐藏底栏开关
  - 账户操作区：退出登录按钮

### Requirement: 顶部安全区适配
The system SHALL 根据设备类型正确设置 SafeArea。

#### Scenario: 手机端刘海屏
- **WHEN** 应用在手机端运行（compact 模式）
- **THEN** 所有页面内容顶部避开状态栏/刘海区域

#### Scenario: 桌面端
- **WHEN** 应用在桌面端运行（非 compact 模式）
- **THEN** 页面顶部使用正常的 padding，不额外添加 SafeArea top

## MODIFIED Requirements

### Requirement: DashboardShell 布局结构
**原行为**: 手机端顶部有固定高度的 header 区域（48px + 状态栏高度），包含学生姓名、展开工具按钮、主题切换和退出登录。
**新行为**: 
- 手机端完全移除 header 区域
- `_mobileHeaderVisible` 和 `_mobileHeaderToolsVisible` 状态及相关逻辑移除
- 滚动时不再联动隐藏/显示顶栏（只保留底栏的自动隐藏）
- 主题切换和退出登录功能迁移到 MorePage
- 学年学期设置从 MorePage 的底部提升到"快捷设置"分组

### Requirement: MorePage 视觉风格
**原行为**: 简单的网格 + 底部零散设置项，使用基础 Card 样式。
**新行为**:
- 使用 MD3 风格的分组标题（labelMedium / titleMedium）
- 设置项使用标准 ListTile 组件，带 leading icon
- 网格项使用 surfaceContainer 颜色的 Card，圆角 16dp
- 分组之间使用 24dp 间距和 Divider
- 编辑模式下的网格保持现有功能但视觉更统一

## REMOVED Requirements

### Requirement: 手机端顶栏
**Reason**: 顶栏占用垂直空间，功能可以整合到 MorePage。
**Migration**: 主题切换、退出登录按钮移动到 MorePage；学生姓名显示在首页模块中已存在，无需额外展示。
