# 丰富 Widget 信息与可滚动布局 Spec

## Why
首页 Widget 卡片内容被截断（今日时间线只显示 4 条、业务进度只显示 3 条），无法滚动查看更多；桌面 Widget 仍为纯文字堆叠，缺少色彩区块、图标装饰等 MD3 Express 视觉元素，信息密度低且与首页卡片视觉风格差距大。

## What Changes
- 首页 Widget 卡片内容区改为可滚动，移除 `take(4)`/`take(3)` 硬截断
- 桌面 Widget 布局按 MD3 Express 指南重构：增加色彩区块（primaryContainer 内容区）、图标装饰行、分割线等视觉层次
- 桌面 Widget 使用 `ListView`（RemoteViews StackView）实现列表滚动
- 扩充桌面 Widget 数据传递，增加更多字段以支持丰富布局
- 统一桌面 Widget 尺寸为 4×2 大卡片，提供足够空间展示内容

## Impact
- Affected specs: align-widget-design（已完成，本次在其基础上深化）
- Affected code:
  - `lib/main.dart` — `_NextClassHomeCard`、`_TodayTimelineHomeCard`、`_UtilitiesHomeCard`、`_BusinessProgressHomeCard`、`_HomeCard`、`_HomeWidgetBridge.update()`
  - `android/app/src/main/res/layout/widget_home_card.xml` — 布局重构
  - `android/app/src/main/kotlin/cn/gzus/pro/HomeWidgetProvider.kt` — 数据映射
  - `android/app/src/main/kotlin/cn/gzus/pro/MainActivity.kt` — SharedPreferences 字段
  - `android/app/src/main/res/xml/widget_next_class.xml` — 尺寸调整
  - `android/app/src/main/res/xml/widget_utilities.xml` — 尺寸调整
  - `android/app/src/main/res/xml/widget_business_progress.xml` — 尺寸调整

## ADDED Requirements

### Requirement: 首页 Widget 卡片内容可滚动
首页 Widget 卡片的内容区域 SHALL 支持滚动，不再硬截断数据条目。

#### Scenario: 今日时间线卡片滚动
- **WHEN** 今日课程超过 4 节
- **THEN** 卡片内容区可垂直滚动显示全部课程，而非截断为 4 条

#### Scenario: 业务进度卡片滚动
- **WHEN** 业务进度条目超过 3 条
- **THEN** 卡片内容区可垂直滚动显示全部条目，而非截断为 3 条

#### Scenario: 其他卡片
- **WHEN** 下一节课或水电费卡片内容超出卡片高度
- **THEN** 内容区可滚动查看完整信息

### Requirement: 桌面 Widget MD3 Express 视觉风格
桌面 Widget SHALL 按 Material Design 3 Express 指南，使用色彩区块、图标装饰、视觉层次来丰富布局，而非纯文字堆叠。

#### Scenario: 下一节课 Widget
- **WHEN** 渲染下一节课桌面 Widget
- **THEN** 内容区使用 primaryContainer 色彩区块，课程名大号粗体（22sp），下方显示带图标的 meta 行（时间图标+时间、地点图标+教室、人物图标+教师）
- **WHEN** 无课程数据
- **THEN** 显示 primaryContainer 色彩区块中的空状态文案

#### Scenario: 今日课表 Widget
- **WHEN** 渲染今日课表桌面 Widget
- **THEN** 使用可滚动列表（StackView）展示课程条目，每条包含时间、课程名、教室/教师，进行中的课程用 primaryContainer 高亮
- **WHEN** 无课程
- **THEN** 显示空状态文案

#### Scenario: 生活缴费 Widget
- **WHEN** 渲染生活缴费桌面 Widget
- **THEN** 使用三列色彩区块分别显示冷水（蓝色调）、热水（红色调）、电费（黄色调），每列包含图标、标签、数值
- **WHEN** 未绑定宿舍
- **THEN** 显示"未绑定宿舍"提示

#### Scenario: 办事大厅 Widget
- **WHEN** 渲染办事大厅桌面 Widget
- **THEN** 使用可滚动列表展示进度条目，每条包含标题、状态标签、进度信息
- **WHEN** 无进度
- **THEN** 显示空状态文案

### Requirement: 桌面 Widget 统一大尺寸
所有桌面 Widget SHALL 使用 4×2 大卡片尺寸，提供足够空间展示丰富内容。

#### Scenario: Widget 尺寸
- **WHEN** 用户添加桌面 Widget
- **THEN** 默认尺寸为 4 列 × 2 行（targetCellWidth=4, targetCellHeight=2），最小 250dp × 140dp

### Requirement: 桌面 Widget 列表可滚动
今日课表和办事大厅桌面 Widget SHALL 支持内容滚动。

#### Scenario: 今日课表 Widget 滚动
- **WHEN** 今日课程超过 Widget 可见区域
- **THEN** 用户可在 Widget 上滚动查看更多课程

#### Scenario: 办事大厅 Widget 滚动
- **WHEN** 业务进度条目超过 Widget 可见区域
- **THEN** 用户可在 Widget 上滚动查看更多条目

### Requirement: 扩充桌面 Widget 数据传递
_HomeWidgetBridge.update() SHALL 传递更丰富的数据字段，支持桌面 Widget 的 MD3 Express 布局。

#### Scenario: 下一节课数据
- **WHEN** 更新下一节课 Widget 数据
- **THEN** 传递字段包含：课程名、时间、教室、教师、状态（进行中/待开始/无课程）

#### Scenario: 今日课表数据
- **WHEN** 更新今日课表 Widget 数据
- **THEN** 传递字段包含：课程列表（每条含时间、课程名、教室、教师、是否进行中），不再限制为 4 条

#### Scenario: 生活缴费数据
- **WHEN** 更新生活缴费 Widget 数据
- **THEN** 传递字段包含：冷水数值、热水数值、电费数值、宿舍名、是否绑定、更新时间

#### Scenario: 办事大厅数据
- **WHEN** 更新办事大厅 Widget 数据
- **THEN** 传递字段包含：进度列表（每条含标题、状态、当前节点、进度百分比），不再限制为 1 条
