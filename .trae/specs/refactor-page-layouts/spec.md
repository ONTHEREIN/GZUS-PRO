# 页面布局 MD3 风格重构 Spec

## Why
虽然全局 MD3 组件迁移已完成，但部分页面的布局结构仍沿用旧设计模式，未充分利用 Material Design 3 的现代化布局规范。需要对除首页和考勤页以外的页面进行布局重构，使其更符合 MD3 的卡片布局、间距规范和视觉层次。

## What Changes
- 优化 ExamsPage 布局结构，使用 MD3 Card 组件和正确的间距规范
- 优化 GradesPage 布局结构，增强视觉层次
- 优化 CreditsPage 布局结构，改进卡片设计
- 优化 EcardPage 布局结构，改进生活缴费展示
- 优化 MorePage 布局结构，改进功能入口展示

## Impact
- Affected specs: migrate-to-md3
- Affected code: `apps/mobile_web/lib/main.dart` 中的 ExamsPage、GradesPage、CreditsPage、EcardPage、MorePage

## ADDED Requirements

### Requirement: ExamsPage 布局优化
系统 SHALL 重构考试页布局，使其更符合 MD3 卡片布局规范。

#### Scenario: 移动端考试列表
- **WHEN** 屏幕宽度 < 640dp
- **THEN** 使用 `Card` 组件展示考试信息，卡片圆角使用 16dp，卡片间距使用 12dp
- **AND** 考试时间和地点使用强调色突出显示

#### Scenario: 桌面端考试列表
- **WHEN** 屏幕宽度 >= 640dp
- **THEN** 使用 `SimpleTable` 展示考试信息，表格头部使用 `surfaceContainerHighest` 背景
- **AND** 补考/重修条目使用强调色高亮

### Requirement: GradesPage 布局优化
系统 SHALL 重构成绩页布局，增强视觉层次。

#### Scenario: 移动端成绩卡片
- **WHEN** 屏幕宽度 < 640dp
- **THEN** 使用 `Card` 组件展示成绩，学分和绩点使用 `InfoTile` 组件
- **AND** 补考记录使用 `ExpansionTile` 展开

#### Scenario: 桌面端成绩表格
- **WHEN** 屏幕宽度 >= 640dp
- **THEN** 使用两栏布局：左侧显示统计信息，右侧显示成绩列表
- **AND** 成绩表格使用 MD3 规范的分割线和间距

### Requirement: CreditsPage 布局优化
系统 SHALL 重构学分页布局，改进卡片设计。

#### Scenario: 学分概览卡片
- **WHEN** 展示学分信息
- **THEN** 使用 `Card` 组件，学分进度条使用 `LinearProgressIndicator`
- **AND** 使用 `InfoTile` 展示必修/选修学分详情

#### Scenario: 桌面端学分展示
- **WHEN** 屏幕宽度 >= 720dp
- **THEN** 使用两栏布局：左侧概览，右侧详情
- **AND** 各类学分使用清晰的视觉区分

### Requirement: EcardPage 布局优化
系统 SHALL 重构生活缴费页布局，改进余额展示。

#### Scenario: 余额卡片
- **WHEN** 展示水电余额
- **THEN** 使用 `Card` 组件，低电量时使用 error 颜色警告
- **AND** 余额数字使用大字体突出显示

#### Scenario: 宿舍绑定列表
- **WHEN** 用户需要绑定宿舍
- **THEN** 使用 `ListTile` 展示宿舍列表，支持搜索过滤
- **AND** 使用 `TextField` 带搜索图标

### Requirement: MorePage 布局优化
系统 SHALL 重构更多页布局，改进功能入口展示。

#### Scenario: 功能入口网格
- **WHEN** 展示功能入口
- **THEN** 使用 `SliverGrid` 布局，每个入口使用 `Card` 包裹
- **AND** 图标使用 primary 颜色，标签使用 labelSmall 样式

#### Scenario: 设置区域
- **WHEN** 展示设置选项
- **THEN** 使用 `ListTile` 配合 `DropdownMenu`、`Switch` 等组件
- **AND** 使用 SegmentedButton 切换主题模式

## MODIFIED Requirements

### Requirement: ExamTable
原 ExamTable 使用简单 Container 布局。修改后：
- 移动端使用 `Card` 组件，增强阴影和圆角
- 桌面端表格使用 MD3 规范的边框和间距

### Requirement: GradeGroupList
原 GradeGroupList 使用简单布局。修改后：
- 移动端使用 `Card` + `InfoTile` 组合
- 桌面端表格使用 MD3 分割线和背景色

### Requirement: CreditCard
原 CreditCard 使用简单 Container。修改后：
- 使用 `Card` 组件，增强视觉效果
- 进度条使用 MD3 颜色

### Requirement: _EcardSummaryPanel
原 _EcardSummaryPanel 使用简单布局。修改后：
- 使用 `Card` 组件展示余额
- 使用 `_BalanceCard` 子组件，增强视觉层次

### Requirement: _MoreGridItem
原 _MoreGridItem 使用简单 Container。修改后：
- 使用 `Card` 组件，增强点击反馈
- 图标和文字使用 MD3 规范样式
