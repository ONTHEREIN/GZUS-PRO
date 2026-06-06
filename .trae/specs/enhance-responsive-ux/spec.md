# 响应式布局与功能增强 Spec

## Why
当前移动端各数据页面（考勤、考试、成绩、学分）在宽屏设备上仍为单栏布局，空间利用率低；通知简介仅展示教务系统列表行的截断文本，信息量不足；底栏 Tab 固定不可自定义，无法满足用户个性化需求；考勤/考试页面缺少筛选排序能力；成绩页与考试页之间无关联。本次变更旨在全面提升信息密度、交互灵活性和用户体验。

## What Changes
- 所有数据页面（考勤、考试、成绩、学分、通知）在宽屏（≥720dp）下默认使用多栏响应式布局
- 考试界面时间地点突出显示（使用醒目的颜色和图标）
- 通知简介改为获取通知详情链接中的正文内容摘要（后端在列表接口中直接返回 content_summary）
- 新增"更多"底栏 Tab，将除课表与信息以外的 Tab 放进更多页面
- 支持用户自定义底栏 Tab 和更多页面的功能项
- 新增文字滚动显示界面（MarqueeText 组件），用于标题过长时自动滚动
- 考勤界面新增筛选排序功能：支持按正常/迟到/早退/旷课/请假数量正倒序排列，筛选出有异常的课程
- 考试界面新增按学期正倒序排序
- 成绩界面支持点击考试 Tab 栏自动关联具体考试（跳转到考试页面并定位到对应考试）

## Impact
- Affected specs: optimize-mobile-ui（底栏自定义已部分实现）、refine-mobile-ux（通知详情已部分实现）
- Affected code:
  - `apps/mobile_web/lib/main.dart` — 所有页面组件的布局重构、底栏自定义、筛选排序、考试关联
  - `apps/mobile_web/lib/api_client.dart` — NoticeItem 新增 contentSummary 字段
  - `services/api/app/school_client.py` — 通知列表接口返回 content_summary
  - `services/api/app/schemas.py` — NoticeItem schema 新增 content_summary 字段

## ADDED Requirements

### Requirement: 响应式多栏布局
所有数据页面在宽屏（≥720dp）下 SHALL 使用多栏布局，提升信息密度。

#### Scenario: 移动端单栏
- **WHEN** 屏幕宽度 < 720dp
- **THEN** 所有页面保持当前单栏布局不变

#### Scenario: 宽屏多栏 - 考勤页
- **WHEN** 屏幕宽度 >= 720dp
- **THEN** 考勤页左侧显示考勤总览面板，右侧显示考勤详情列表

#### Scenario: 宽屏多栏 - 考试页
- **WHEN** 屏幕宽度 >= 720dp
- **THEN** 考试页左侧显示学期筛选和排序，右侧显示考试列表

#### Scenario: 宽屏多栏 - 成绩页
- **WHEN** 屏幕宽度 >= 720dp
- **THEN** 成绩页左侧显示学期筛选和统计，右侧显示成绩列表

#### Scenario: 宽屏多栏 - 学分页
- **WHEN** 屏幕宽度 >= 720dp
- **THEN** 学分页左侧显示总览和进度，右侧显示学分详情列表

#### Scenario: 宽屏多栏 - 通知页
- **WHEN** 屏幕宽度 >= 720dp
- **THEN** 通知页左侧显示通知列表，右侧显示选中通知的详情内容（主从布局）

### Requirement: 考试界面时间地点突出显示
考试条目中的时间和地点 SHALL 使用醒目的视觉样式突出显示。

#### Scenario: 时间突出显示
- **WHEN** 渲染考试条目
- **THEN** 考试时间使用 `colorScheme.primary` 颜色和加粗字体，前方带 `Icons.schedule` 图标

#### Scenario: 地点突出显示
- **WHEN** 渲染考试条目
- **THEN** 考试地点使用 `colorScheme.tertiary` 颜色和加粗字体，前方带 `Icons.location_on` 图标

### Requirement: 通知简介获取链接内容
通知列表中的简介 SHALL 展示通知详情链接中的正文内容摘要，而非教务系统列表行的截断文本。

#### Scenario: 后端返回 content_summary
- **WHEN** 后端获取通知列表
- **THEN** 对每条通知，若其 url 非空，后端 SHALL 请求该 url 页面，提取正文内容的前 120 字作为 content_summary 返回
- **AND** 若提取失败或无内容，content_summary 为 null，回退到原有 summary 字段

#### Scenario: 前端展示 content_summary
- **WHEN** 前端渲染通知卡片
- **THEN** 优先展示 `contentSummary`，若为空则回退到 `summary`

#### Scenario: 性能保障
- **WHEN** 通知列表包含多条通知
- **THEN** 后端 SHALL 并发请求通知详情（最大并发数 5），总耗时不超过 10 秒，超时则对应条目的 content_summary 为 null

### Requirement: 自定义底栏与更多页面
系统 SHALL 支持用户自定义底栏 Tab 和更多页面的功能项。

#### Scenario: 默认底栏配置
- **WHEN** 用户首次使用应用
- **THEN** 底栏默认显示：信息、课表、更多（3 个 Tab）
- **AND** 更多页面中显示：通知、考勤、考试、成绩、学分

#### Scenario: 底栏编辑模式
- **WHEN** 用户在更多页面点击编辑按钮
- **THEN** 进入编辑模式，底栏区域和更多页区域可拖拽排序和增删
- **AND** 底栏最多 5 个 Tab，最少 2 个 Tab（课表和信息固定不可移除）
- **AND** "更多" Tab 固定在底栏末尾，不可移除

#### Scenario: 偏好持久化
- **WHEN** 用户完成底栏编辑
- **THEN** 偏好保存到 SharedPreferences，下次启动自动恢复

#### Scenario: 恢复默认
- **WHEN** 用户点击"恢复默认"按钮
- **THEN** 底栏恢复为默认配置（信息、课表、更多）

### Requirement: 文字滚动显示
系统 SHALL 提供 MarqueeText 组件，当文字内容超出容器宽度时自动滚动显示。

#### Scenario: 文字超出滚动
- **WHEN** 文字内容超出容器宽度
- **THEN** 文字自动从右向左滚动，滚动到末尾后停顿 1 秒再从开头开始

#### Scenario: 文字未超出
- **WHEN** 文字内容未超出容器宽度
- **THEN** 文字静态显示，不滚动

#### Scenario: 应用场景
- **WHEN** 通知标题、考试课程名等文本可能过长
- **THEN** 使用 MarqueeText 组件替代普通 Text，确保完整信息可见

### Requirement: 考勤筛选排序
考勤界面 SHALL 支持筛选和排序功能。

#### Scenario: 排序功能
- **WHEN** 用户点击排序按钮
- **THEN** 弹出排序选项：按正常次数、迟到次数、早退次数、旷课次数、请假次数的正序/倒序排列

#### Scenario: 筛选功能
- **WHEN** 用户点击筛选按钮
- **THEN** 弹出筛选选项：仅显示有迟到的课程、仅显示有早退的课程、仅显示有旷课的课程、仅显示有请假的课程、显示全部

#### Scenario: 筛选排序组合
- **WHEN** 用户同时设置筛选和排序
- **THEN** 先按筛选条件过滤，再按排序条件排列

#### Scenario: 排序指示器
- **WHEN** 当前有排序生效
- **THEN** 排序按钮显示当前排序状态（如"迟到↓"）

### Requirement: 考试按学期正倒序排序
考试界面 SHALL 支持按学期正序或倒序排列。

#### Scenario: 学期倒序（默认）
- **WHEN** 用户选择"按学期排列"模式
- **THEN** 默认按学期倒序排列（最新学期在前）

#### Scenario: 学期正序
- **WHEN** 用户切换排序方向
- **THEN** 按学期正序排列（最早学期在前）

#### Scenario: 排序方向切换
- **WHEN** 用户点击排序方向按钮
- **THEN** 切换正序/倒序，列表立即更新

### Requirement: 成绩关联考试
成绩界面 SHALL 支持点击考试 Tab 栏自动关联具体考试。

#### Scenario: 点击考试关联
- **WHEN** 用户在成绩页面点击某条成绩的"考试"标签
- **THEN** 跳转到考试页面，自动定位到对应课程的考试条目
- **AND** 对应考试条目高亮显示 2 秒后恢复

#### Scenario: 无对应考试
- **WHEN** 用户点击的成绩没有对应的考试记录
- **THEN** 显示 SnackBar 提示"未找到对应考试记录"

## MODIFIED Requirements

### Requirement: MobileNavBar 动态 Tab
原 MobileNavBar 使用固定的 `_navItems` 列表。修改后：
- MobileNavBar 根据用户自定义配置动态渲染 Tab
- 最后一个固定为"更多" Tab
- Tab 数据来源于 NavPreferences 服务

### Requirement: DashboardShell 页面路由
原 DashboardShell 使用固定索引映射页面。修改后：
- 根据用户自定义的底栏配置动态构建页面列表
- "更多" Tab 对应 MorePage，MorePage 中的功能项点击后导航到对应页面
- 页面导航使用 Map<String, Widget> 映射，通过 tabId 查找

### Requirement: NoticeCard 简介
原 NoticeCard 展示 `item.summary`。修改后：
- 优先展示 `item.contentSummary`，为空时回退到 `item.summary`

## REMOVED Requirements

（无移除项）
