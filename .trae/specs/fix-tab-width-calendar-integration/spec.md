# Tab 栏宽度修正与日历集成 Spec

## Why
当前各页面 Tab 栏宽度在宽屏设备上不够宽，无法充分利用多栏布局的空间；通知界面中的 URL 仅以纯文本展示不可点击，且点击通知 Tab 不会自动打开对应网页；默认启动页面为"信息"页而非最常用的"课表"页；课表页的 ICS 导出功能（`generateIcs` 函数已存在）缺少 UI 入口和一键导入日历能力；考试页缺少日历导入功能。

## What Changes
- 修正 `MobileNavBar` 和 `AppSidebar` 的宽度，使其在宽屏下能够充分利用空间以容纳多栏布局
- 通知卡片中的 URL 转换为可点击链接，点击后使用 `url_launcher` 打开对应网页
- 点击通知 Tab 时自动打开通知详情中获取的链接网页
- 默认页面从"信息"改为"课表"（`index` 初始值调整为课表 Tab 索引）
- 课表页新增「导出 ICS」按钮和「一键导入日历」按钮（复用已有的 `generateIcs` 函数）
- 考试页新增「导入至日历」功能，将考试信息生成 ICS 并导入日历

## Impact
- Affected specs: add-schedule-ics-export（ICS 生成函数已存在但 UI 按钮未实现）、enhance-responsive-ux（多栏布局 Tab 栏宽度需适配）
- Affected code:
  - `apps/mobile_web/lib/main.dart` — MobileNavBar 宽度修正、AppSidebar 宽度修正、NoticeCard 可点击链接、默认页面切换、课表导出/导入按钮、考试导入按钮
  - `apps/mobile_web/lib/api_client.dart` — 新增考试 ICS 生成函数
  - `apps/mobile_web/pubspec.yaml` — 新增 `url_launcher` 依赖

## ADDED Requirements

### Requirement: Tab 栏宽度修正
各页面的 Tab 栏（底栏 NavigationBar 和侧栏 NavigationRail）在宽屏设备上 SHALL 具有足够的宽度以容纳多栏布局。

#### Scenario: 底栏宽度适配
- **WHEN** 屏幕宽度 >= 720dp 且使用底栏 NavigationBar
- **THEN** NavigationBar 宽度占满屏幕宽度，各 Tab 均匀分布，不会因多栏布局内容过宽而挤压

#### Scenario: 侧栏宽度适配
- **WHEN** 屏幕宽度 >= 720dp 且使用侧栏 NavigationRail
- **THEN** NavigationRail 的 extended 模式下宽度足够显示完整的 Tab 标签文字，不截断

#### Scenario: 窄屏不变
- **WHEN** 屏幕宽度 < 720dp
- **THEN** 底栏 NavigationBar 保持当前行为不变

### Requirement: 通知链接可点击
通知卡片中的 URL SHALL 转换为可点击的超链接，点击后打开对应网页。

#### Scenario: URL 显示为可点击链接
- **WHEN** 通知卡片中 `item.url` 非空
- **THEN** URL 以可点击的链接样式显示（使用主题色、下划线），而非纯文本 SelectableText
- **AND** 点击链接后使用 `url_launcher` 在外部浏览器中打开该 URL

#### Scenario: 无 URL 时不显示链接
- **WHEN** 通知卡片中 `item.url` 为空
- **THEN** 不显示链接区域

### Requirement: 点击通知 Tab 自动打开网页
点击底栏/侧栏的通知 Tab 时 SHALL 自动打开通知详情中获取的链接网页。

#### Scenario: 首次点击通知 Tab
- **WHEN** 用户点击通知 Tab 进入通知页面
- **THEN** 加载通知列表，若第一条通知有 URL，自动使用 `url_launcher` 在外部浏览器中打开该 URL
- **AND** 通知页面正常展示通知列表

#### Scenario: 通知无 URL
- **WHEN** 用户点击通知 Tab 且通知列表中没有通知包含 URL
- **THEN** 仅展示通知列表，不尝试打开任何网页

#### Scenario: 再次切换到通知 Tab
- **WHEN** 用户从其他 Tab 切换回通知 Tab
- **THEN** 不自动打开网页（仅在首次进入时自动打开）

### Requirement: 默认页面改为课表
应用启动后的默认页面 SHALL 为课表页。

#### Scenario: 首次启动
- **WHEN** 用户首次启动应用并登录成功
- **THEN** 默认显示课表页（schedule Tab），而非信息页（info Tab）

#### Scenario: 恢复默认配置
- **WHEN** 用户在更多页面点击"恢复默认"
- **THEN** 底栏恢复默认配置后，初始选中项为课表 Tab

### Requirement: 课表导出 ICS 按钮
课表工具弹窗中 SHALL 提供「导出 ICS」按钮，复用已有的 `generateIcs` 函数。

#### Scenario: 导出 ICS 文件
- **WHEN** 用户在课表工具弹窗中点击「导出 ICS」按钮
- **THEN** 调用 `generateIcs` 生成 ICS 内容
- **AND** 移动端使用 `share_plus` 调起系统分享面板，用户可选择日历应用导入
- **AND** Web 端触发浏览器下载，文件名格式为 `课表_{学年}_{学期}.ics`

#### Scenario: 无课表数据
- **WHEN** 当前学期无课表数据
- **THEN** 「导出 ICS」按钮置灰不可点击

#### Scenario: 导出中状态
- **WHEN** ICS 文件正在生成
- **THEN** 按钮显示加载状态，防止重复点击

### Requirement: 课表一键导入日历
课表工具弹窗中 SHALL 提供「一键导入日历」按钮，直接将 ICS 文件通过系统日历 Intent 打开。

#### Scenario: 移动端一键导入
- **WHEN** 用户在移动端点击「一键导入日历」按钮
- **THEN** 生成 ICS 文件并保存到临时目录，使用 `url_launcher` 以 `file://` URI 或通过 `share_plus` 直接调起系统日历应用
- **AND** 若系统无日历应用，回退到系统分享面板

#### Scenario: Web 端
- **WHEN** 用户在 Web 端点击「一键导入日历」按钮
- **THEN** 行为与「导出 ICS」一致（触发浏览器下载）

#### Scenario: 无课表数据
- **WHEN** 当前学期无课表数据
- **THEN** 「一键导入日历」按钮置灰不可点击

### Requirement: 考试导入至日历
考试页面 SHALL 提供「导入至日历」功能，将考试信息生成 ICS 并导入日历。

#### Scenario: 生成考试 ICS
- **WHEN** 用户在考试页面点击「导入至日历」按钮
- **THEN** 将当前显示的考试列表转换为 ICS 格式（每个考试生成一个 VEVENT，包含课程名、时间、地点）
- **AND** 移动端使用 `share_plus` 调起系统分享/日历导入
- **AND** Web 端触发浏览器下载，文件名格式为 `考试_{学年}_{学期}.ics`

#### Scenario: 考试时间解析
- **WHEN** 考试的 `time` 字段包含日期时间信息
- **THEN** 系统尝试解析为 DTSTART/DTEND；若解析失败，仅将时间信息放入 DESCRIPTION

#### Scenario: 无考试数据
- **WHEN** 当前无考试数据
- **THEN** 「导入至日历」按钮置灰不可点击

## MODIFIED Requirements

### Requirement: NoticeCard URL 显示
原 NoticeCard 中 URL 使用 `SelectableText` 显示。修改后：
- URL 使用 `InkWell` 或 `GestureDetector` 包裹，样式为主题色 + 下划线
- 点击后使用 `url_launcher` 打开网页

### Requirement: DashboardShell 默认页面
原 DashboardShell 中 `index = 0` 默认选中第一个 Tab（信息页）。修改后：
- 默认选中课表 Tab（根据 `_navBarTabs` 中课表的索引确定初始 `index`）

### Requirement: 课表工具弹窗
原课表工具弹窗仅包含「仅本周/全部课程」和「JSON」开关。修改后：
- 新增「导出 ICS」按钮
- 新增「一键导入日历」按钮

## REMOVED Requirements

（无移除项）
