# 移动端 UI 深度优化 Spec

## Why
当前移动端存在三个体验问题：1) 顶栏占用空间且信息冗余，设置项散落在顶栏 Flyout 中不易发现；2) 切换深色模式、展开 JSON 等状态变更会触发整个页面重建（FutureBuilder 重新执行 future），导致闪烁和数据重载；3) 通知页面信息密度低，无法查看通知详情内容。

## What Changes
- 删除移动端顶栏（`pageHeader`），将学年/学期选择器、深色模式开关、退出按钮移至 MorePage 设置区域
- 将 `AsyncPanel` 从 `StatelessWidget` + `FutureBuilder` 改为 `StatefulWidget` + 缓存数据，确保父级 setState 不触发 future 重新执行
- 通知页面重构：按分类分组展示、突出标题和日期、点击通知可查看详情（WebView 或内嵌 HTML 渲染）
- 后端新增 `/notices/{id}` 详情接口，返回通知正文 HTML

## Impact
- Affected specs: optimize-mobile-ui（顶栏删除与 MorePage 设置迁移）
- Affected code:
  - `apps/mobile_web/lib/main.dart` — DashboardShell、AsyncPanel、NoticesPage、MorePage
  - `apps/mobile_web/lib/api_client.dart` — 新增 fetchNoticeDetail 方法
  - `services/api/app/routes/academic.py` — 新增 /notices/detail 路由
  - `services/api/app/school_client.py` — 新增 get_notice_detail 方法
  - `services/api/app/schemas.py` — 新增 NoticeDetail schema

## ADDED Requirements

### Requirement: 删除移动端顶栏
移动端（compact 模式）不再渲染 `pageHeader`，页面内容直接占满屏幕。

#### Scenario: 移动端无顶栏
- **WHEN** 屏幕宽度 < 720dp
- **THEN** 不渲染顶栏区域，页面内容从 SafeArea 顶部开始

#### Scenario: 桌面端不变
- **WHEN** 屏幕宽度 >= 720dp
- **THEN** 顶栏照常显示，行为不变

### Requirement: 设置项迁移至 MorePage
深色模式开关、学年/学期选择器、退出登录按钮移至 MorePage 底部"设置"区域。

#### Scenario: MorePage 显示设置区域
- **WHEN** 用户进入"更多"页
- **THEN** 底部显示设置区域，包含：学年选择器、学期选择器、深色模式开关、退出登录按钮

### Requirement: AsyncPanel 数据缓存
`AsyncPanel` 改为 `StatefulWidget`，future 结果缓存在 state 中，父级 rebuild 不重新执行 future。

#### Scenario: 切换深色模式不重载数据
- **WHEN** 用户切换深色模式
- **THEN** 当前页面数据不重新加载，仅主题切换

#### Scenario: 展开 JSON 不重载数据
- **WHEN** 用户在课表页切换 JSON 显示
- **THEN** 课表数据不重新加载，仅 UI 层显示/隐藏 JSON 面板

#### Scenario: 首次加载仍正常请求
- **WHEN** 页面首次构建
- **THEN** 正常执行 future 并显示加载状态

### Requirement: 通知页面优化
通知页面按分类分组展示，突出标题和日期，支持点击查看详情。

#### Scenario: 按分类分组展示
- **WHEN** 通知列表加载完成
- **THEN** 按分类（如"通知公告"、"教务通知"等）分组展示，每组有分类标题

#### Scenario: 突出重要信息
- **WHEN** 渲染通知卡片
- **THEN** 标题使用较大字号和加粗，日期紧随标题下方，分类标签使用小号胶囊标签

#### Scenario: 点击查看详情
- **WHEN** 用户点击某条通知
- **THEN** 打开通知详情页，展示通知正文内容（通过 WebView 渲染教务系统页面或后端获取的 HTML）

### Requirement: 通知详情后端接口
后端新增通知详情获取能力。

#### Scenario: 获取通知详情
- **WHEN** 前端请求 `GET /notices/detail?url=<notice_url>`
- **THEN** 后端代理请求教务系统通知页面，提取正文 HTML 并返回

## MODIFIED Requirements

### Requirement: DashboardShell 移动端布局
原：移动端渲染 `pageHeader` + `pageContent` 两层结构
改：移动端仅渲染 `pageContent`，顶栏相关代码（`_headerVisible`、滚动隐藏逻辑）在 compact 模式下不执行

## REMOVED Requirements

### Requirement: 移动端顶栏滚动自动隐藏
**Reason**: 顶栏已删除，滚动隐藏逻辑不再需要
**Migration**: 删除 `_headerVisible`、`_scrollDeltaAccum` 及相关 `NotificationListener` 代码（仅 compact 模式下删除，桌面端保留）
