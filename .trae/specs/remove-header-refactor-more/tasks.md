# Tasks

- [x] Task 1: 删除手机端顶栏并清理相关状态
  - [x] SubTask 1.1: 移除 `_mobileHeaderVisible` 和 `_mobileHeaderToolsVisible` 字段
  - [x] SubTask 1.2: 移除顶栏相关的 ValueListenableBuilder 和 header UI 代码块
  - [x] SubTask 1.3: 更新 `_onScrollNotification`，移除顶栏显隐联动逻辑（只保留底栏）
  - [x] SubTask 1.4: 在 `dispose()` 中移除 `_mobileHeaderVisible.dispose()`
  - [x] SubTask 1.5: 手机端 Column 中移除顶栏相关的 SizedBox，内容区域直接接在 banner 下方

- [x] Task 2: 手机端内容区域添加顶部安全区
  - [x] SubTask 2.1: 手机端主内容区域的 SafeArea 设置 `top: true`（替代顶栏遮挡状态栏）
  - [x] SubTask 2.2: 桌面端 SafeArea 保持 `top: false`（或根据实际需要调整）

- [x] Task 3: 重构 MorePage 布局结构
  - [x] SubTask 3.1: 将页面标题改为 MD3 风格（使用 `headlineSmall` 或 `titleLarge`，加粗）
  - [x] SubTask 3.2: 将学年、学期、外观模式、自动隐藏底栏等设置项组织到"快捷设置"分组
  - [x] SubTask 3.3: 使用 Card + ListTile 包裹设置项，添加合适的 leading icon
  - [x] SubTask 3.4: 将退出登录按钮组织到"账户"分组，使用 ListTile 样式
  - [x] SubTask 3.5: 各分组之间添加 24dp 间距和 Divider

- [x] Task 4: 优化 MorePage 网格视觉
  - [x] SubTask 4.1: 网格 Card 圆角从 12 改为 16
  - [x] SubTask 4.2: 编辑模式下的分组标题使用 MD3 titleSmall 样式
  - [x] SubTask 4.3: 确保网格项在非编辑模式下有合适的点击反馈（保持 _ScaleTap）

- [x] Task 5: 验证和清理
  - [x] SubTask 5.1: 运行 `flutter analyze` 检查语法错误
  - [x] SubTask 5.2: 检查是否还有未使用的变量/导入

# Task Dependencies
- Task 2 依赖 Task 1（先移除顶栏再调整安全区）
- Task 3 和 Task 4 可以并行执行
- Task 5 依赖所有前置任务
