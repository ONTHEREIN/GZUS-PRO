# 对齐首页 Widget 与桌面 Widget 设计 Spec

## Why
首页 Widget（Flutter 应用内卡片）和桌面 Widget（Android AppWidget）视觉风格和内容结构差异较大——首页卡片使用 Material 3 动态配色、图标、富布局，而桌面 Widget 仅为纯文本堆叠、硬编码颜色，导致用户在两个场景间体验割裂。

## What Changes
- 统一桌面 Widget 与首页 Widget 的配色体系，从硬编码色值迁移到与 Material 3 语义色对齐的静态色值
- 重构桌面 Widget 布局，增加图标行、badge 样式对齐首页 `_HomeCard` 的 header 结构
- 对齐四种 Widget（下一节课、今日课表、生活缴费、办事大厅）的内容字段映射，使桌面 Widget 展示的信息层次与首页卡片一致
- 统一圆角、间距、字号等视觉参数

## Impact
- Affected specs: 无
- Affected code:
  - `android/app/src/main/res/layout/widget_home_card.xml` — 布局重构
  - `android/app/src/main/res/drawable/widget_home_background.xml` — 背景色对齐
  - `android/app/src/main/res/drawable/widget_badge_background.xml` — badge 色对齐
  - `android/app/src/main/kotlin/cn/gzus/pro/HomeWidgetProvider.kt` — 数据映射调整
  - `lib/main.dart` 中 `_HomeWidgetBridge.update()` — 传递对齐后的字段

## ADDED Requirements

### Requirement: 统一配色体系
桌面 Widget 的配色 SHALL 与首页 Widget 的 Material 3 语义色对齐，使用静态近似色值（因 AppWidget 不支持动态主题）。

#### Scenario: 深色/浅色模式
- **WHEN** 系统处于浅色模式
- **THEN** 桌面 Widget 背景使用 `surfaceContainerLow` 近似色 `#F7F7F7`，卡片边框使用 `outlineVariant` 近似色 `#CAC4D0`
- **WHEN** 系统处于深色模式
- **THEN** 桌面 Widget 背景使用深色近似色 `#1C1B1F`，文字色自动切换为浅色

### Requirement: 统一 Header 布局
桌面 Widget 的 header 区域 SHALL 与首页 `_HomeCard` 的 icon + title + badge 三段式布局对齐。

#### Scenario: Header 渲染
- **WHEN** 桌面 Widget 渲染 header
- **THEN** 左侧显示对应图标（下一节课→时钟、今日课表→时间线、生活缴费→水滴、办事大厅→路线），中间为标题文字，右侧为 badge 标签
- **AND** badge 样式使用圆角 8dp 的胶囊形，背景色对齐首页 `secondaryContainer` 近似色

### Requirement: 统一内容信息层次
桌面 Widget 的内容区域 SHALL 按与首页卡片一致的信息层次展示数据。

#### Scenario: 下一节课 Widget
- **WHEN** 有下一节课数据
- **THEN** 显示：课程名（大号粗体）→ 时间+地点（meta 行）→ 教师+状态（detail 行）
- **WHEN** 无课程数据
- **THEN** 显示"今天没有更多课程"空状态文案

#### Scenario: 今日课表 Widget
- **WHEN** 有今日课程
- **THEN** 显示：标题含课程数量 → 最多 4 条课程摘要（时间 + 课程名）→ 周次 meta
- **WHEN** 无课程
- **THEN** 显示"今日无课"空状态文案

#### Scenario: 生活缴费 Widget
- **WHEN** 已绑定宿舍
- **THEN** 显示：标题含宿舍名 → 冷水/热水/电费三列数值 → 更新时间 meta
- **WHEN** 未绑定
- **THEN** 显示"未绑定宿舍"提示

#### Scenario: 办事大厅 Widget
- **WHEN** 有业务进度
- **THEN** 显示：标题 → 状态+当前节点 meta → 进度百分比+日期 detail
- **WHEN** 无进度
- **THEN** 显示"暂无业务进度"空状态文案

### Requirement: 统一视觉参数
桌面 Widget 的圆角、间距、字号 SHALL 与首页卡片对齐。

#### Scenario: 参数一致性
- **WHEN** 对比首页卡片与桌面 Widget
- **THEN** 卡片圆角 16dp（桌面 Widget 当前 22dp → 改为 16dp）
- **AND** 内边距 16dp
- **AND** badge 圆角 8dp、字号 11sp
- **AND** 标题字号 18sp 粗体
- **AND** 正文/描述字号 13sp
- **AND** meta 字号 13sp 粗体
- **AND** detail 字号 12sp

### Requirement: 深色模式支持
桌面 Widget SHALL 支持系统深色模式，自动切换配色。

#### Scenario: 系统切换深色模式
- **WHEN** 系统切换到深色模式
- **THEN** 桌面 Widget 背景色、文字色、badge 色自动切换为深色方案
