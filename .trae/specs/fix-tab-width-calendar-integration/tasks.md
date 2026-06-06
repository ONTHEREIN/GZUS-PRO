# Tasks

- [x] Task 1: 修正 Tab 栏宽度以适配多栏布局
  - [x] SubTask 1.1: 修改 `MobileNavBar` 的 `NavigationBar`，确保在宽屏下宽度占满屏幕，各 Tab 均匀分布
  - [x] SubTask 1.2: 修改 `AppSidebar` 的 `NavigationRail`，确保 extended 模式下宽度足够显示完整标签文字（设置 `minWidth` 和 `minExtendedWidth`）
  - [x] SubTask 1.3: 验证窄屏下底栏行为不变

- [x] Task 2: 通知链接可点击 + 点击通知 Tab 自动打开网页
  - [x] SubTask 2.1: 在 `pubspec.yaml` 中添加 `url_launcher` 依赖
  - [x] SubTask 2.2: 修改 `NoticeCard`，将 URL 区域从 `SelectableText` 改为 `GestureDetector` + `Text`，样式使用主题色 + 下划线，点击后调用 `url_launcher` 打开网页
  - [x] SubTask 2.3: 在 `_DashboardShellState` 中添加 `_hasAutoOpenedNotices` 标志位
  - [x] SubTask 2.4: 当用户切换到 notices Tab 时（且 `_hasAutoOpenedNotices` 为 false），加载通知列表后自动打开第一条有 URL 的通知链接
  - [x] SubTask 2.5: 设置 `_hasAutoOpenedNotices = true`，后续切换不再自动打开

- [x] Task 3: 默认页面改为课表
  - [x] SubTask 3.1: 修改 `_DashboardShellState` 的 `initState`，在 `_loadNavConfig` 完成后将 `index` 设为课表 Tab 的索引（`_navBarTabs.indexWhere((t) => t.tabId == 'schedule')`）
  - [x] SubTask 3.2: 修改 `NavPreferences.reset()` 恢复默认后，同样将 index 指向课表 Tab

- [x] Task 4: 课表页新增导出 ICS 和一键导入日历按钮
  - [x] SubTask 4.1: 在 `_showScheduleTools` 的 Wrap 中添加「导出 ICS」按钮（`Icons.download` 图标）
  - [x] SubTask 4.2: 按钮点击时调用 `generateIcs` 生成 ICS 内容，移动端使用 `share_plus` 调起分享，Web 端触发下载
  - [x] SubTask 4.3: 添加导出中加载状态，防止重复点击；无课表数据时按钮置灰
  - [x] SubTask 4.4: 在 Wrap 中添加「一键导入日历」按钮（`Icons.event_available` 图标）
  - [x] SubTask 4.5: 移动端生成 ICS 文件保存到临时目录，使用 `share_plus` 直接调起日历应用；Web 端行为与导出一致
  - [x] SubTask 4.6: 无课表数据时「一键导入日历」按钮置灰

- [x] Task 5: 考试页新增导入至日历功能
  - [x] SubTask 5.1: 在 `api_client.dart` 中新增 `generateExamIcs` 函数，将 `List<PeriodExam>` 转换为 ICS 格式（每个考试生成 VEVENT，包含 SUMMARY、DTSTART/DTEND、LOCATION、DESCRIPTION）
  - [x] SubTask 5.2: 在 `ExamItem` 中添加时间解析辅助方法，尝试从 `time` 字段解析出日期时间
  - [x] SubTask 5.3: 在考试页面（宽屏和窄屏布局）的工具栏区域添加「导入至日历」按钮（`Icons.event_available` 图标）
  - [x] SubTask 5.4: 按钮点击时调用 `generateExamIcs`，移动端使用 `share_plus` 调起分享/日历导入，Web 端触发下载
  - [x] SubTask 5.5: 无考试数据时按钮置灰

- [x] Task 6: 运行静态分析验证
  - [x] SubTask 6.1: 运行 `flutter pub get` 确保依赖安装成功
  - [x] SubTask 6.2: 运行 `flutter analyze` 确保无静态分析错误

# Task Dependencies
- [Task 2] depends on [Task 1]（Tab 栏宽度修正后再处理通知交互，避免布局冲突）
- [Task 4] independent（课表导出/导入可独立实现，`generateIcs` 已存在）
- [Task 5] depends on [Task 4]（考试 ICS 生成复用课表的分享逻辑模式）
- [Task 3] independent（默认页面切换可独立实现）
- [Task 6] depends on [Task 1, 2, 3, 4, 5]（最终验证依赖所有改动完成）
