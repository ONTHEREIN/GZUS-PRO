# Tasks

- [x] Task 1: 首页 Widget 卡片内容可滚动
  - [x] SubTask 1.1: `_TodayTimelineHomeCard` 移除 `take(4)`，内容区用 `SingleChildScrollView` 包裹并设置 maxHeight 约束
  - [x] SubTask 1.2: `_BusinessProgressHomeCard` 移除 `take(3)`，内容区用 `SingleChildScrollView` 包裹并设置 maxHeight 约束
  - [x] SubTask 1.3: `_NextClassHomeCard` 和 `_UtilitiesHomeCard` 内容区增加 maxHeight 约束 + 滚动支持

- [x] Task 2: 桌面 Widget 布局重构 — 下一节课（MD3 Express 风格）
  - [x] SubTask 2.1: 创建 `widget_next_class.xml` 独立布局，使用 primaryContainer 色彩区块 + 大号课程名 + 图标 meta 行
  - [x] SubTask 2.2: 更新 `HomeWidgetProvider.kt` 中 next 类型的 `updateWidget` 使用新布局
  - [x] SubTask 2.3: 扩充 `_HomeWidgetBridge.update()` 传递 next 的教室、教师、状态等独立字段
  - [x] SubTask 2.4: 更新 `MainActivity.kt` SharedPreferences 存储新字段

- [x] Task 3: 桌面 Widget 布局重构 — 今日课表（可滚动列表）
  - [x] SubTask 3.1: 创建 `widget_today_schedule.xml` 布局，header + StackView（可滚动课程列表）
  - [x] SubTask 3.2: 创建 `widget_today_item.xml` 单条课程布局（时间 + 色点 + 课程名 + 教室/教师）
  - [x] SubTask 3.3: 创建 `TodayScheduleFactory` RemoteViewsFactory 服务，从 SharedPreferences 读取课程列表
  - [x] SubTask 3.4: 扩充 `_HomeWidgetBridge.update()` 传递 today 的完整课程列表（含时间、课程名、教室、教师、是否进行中）
  - [x] SubTask 3.5: 更新 `MainActivity.kt` 存储新字段，更新 `HomeWidgetProvider.kt` 绑定 StackView

- [x] Task 4: 桌面 Widget 布局重构 — 生活缴费（三列色彩区块）
  - [x] SubTask 4.1: 创建 `widget_utilities.xml` 独立布局，三列色彩区块（冷水蓝/热水红/电费黄）
  - [x] SubTask 4.2: 扩充 `_HomeWidgetBridge.update()` 传递 utility 的冷水/热水/电费独立数值字段
  - [x] SubTask 4.3: 更新 `MainActivity.kt` 和 `HomeWidgetProvider.kt`

- [x] Task 5: 桌面 Widget 布局重构 — 办事大厅（可滚动列表）
  - [x] SubTask 5.1: 创建 `widget_progress.xml` 布局，header + StackView（可滚动进度列表）
  - [x] SubTask 5.2: 创建 `widget_progress_item.xml` 单条进度布局（标题 + 状态标签 + 进度信息）
  - [x] SubTask 5.3: 创建 `BusinessProgressFactory` RemoteViewsFactory 服务
  - [x] SubTask 5.4: 扩充 `_HomeWidgetBridge.update()` 传递 progress 的完整进度列表
  - [x] SubTask 5.5: 更新 `MainActivity.kt` 和 `HomeWidgetProvider.kt`

- [x] Task 6: 统一桌面 Widget 尺寸为 4×2
  - [x] SubTask 6.1: 修改 `widget_next_class.xml` 为 targetCellWidth=4, targetCellHeight=2
  - [x] SubTask 6.2: 修改 `widget_utilities.xml` 为 targetCellWidth=4, targetCellHeight=2
  - [x] SubTask 6.3: 修改 `widget_business_progress.xml` 为 targetCellWidth=4, targetCellHeight=2

- [x] Task 7: 验证首页和桌面 Widget 的滚动与视觉效果
  - [x] SubTask 7.1: 首页卡片内容超出时可滚动
  - [x] SubTask 7.2: 桌面 Widget 渲染 MD3 Express 风格布局
  - [x] SubTask 7.3: 桌面今日课表和办事大厅 Widget 可滚动

# Task Dependencies
- Task 2-5 依赖 Task 1（先确定首页数据结构再设计桌面 Widget）
- Task 6 独立，可与 Task 2-5 并行
- Task 7 依赖 Task 1-6 全部完成
