# Tasks

- [x] Task 1: 删除移动端顶栏，迁移设置项到 MorePage
  - [x] SubTask 1.1: 在 `_DashboardShellState.pageContent` 中，compact 模式下跳过 `pageHeader` 渲染，页面内容直接从 SafeArea 顶部开始
  - [x] SubTask 1.2: 删除 compact 模式下的 `_headerVisible`、`_scrollDeltaAccum` 及 `NotificationListener` 滚动隐藏逻辑
  - [x] SubTask 1.3: 在 MorePage 底部新增"设置"区域，包含学年 ComboBox、学期 ComboBox、深色模式 ToggleSwitch、退出登录 Button
  - [x] SubTask 1.4: MorePage 接收 year/term/darkMode/onThemeChanged/onLogout/onYearChanged/onTermChanged 等回调参数
  - [x] SubTask 1.5: 桌面端顶栏和滚动隐藏逻辑保持不变

- [x] Task 2: AsyncPanel 数据缓存改造
  - [x] SubTask 2.1: 将 `AsyncPanel` 从 `StatelessWidget` 改为 `StatefulWidget`
  - [x] SubTask 2.2: 在 state 中缓存 future 结果（`_data`、`_error`、`_loading`），initState 中执行 future 并缓存结果
  - [x] SubTask 2.3: didUpdateWidget 中仅当 future 实例变化时重新执行（比较 future 引用或添加 refreshKey 机制）
  - [x] SubTask 2.4: 提供 `refresh()` 方法供外部手动刷新（如下拉刷新场景）

- [x] Task 3: 通知页面 UI 优化
  - [x] SubTask 3.1: 将 `NoticesPage` 改为 `StatefulWidget`，使用改造后的 `AsyncPanel` 缓存通知数据
  - [x] SubTask 3.2: 按分类分组展示通知，每组使用分类标题 + 分隔线
  - [x] SubTask 3.3: 重构 `NoticeCard`：标题加大加粗、日期紧跟标题下方、分类使用小号胶囊标签（Chip）
  - [x] SubTask 3.4: 通知卡片可点击，点击后导航到通知详情页

- [x] Task 4: 通知详情功能
  - [x] SubTask 4.1: 后端新增 `GET /notices/detail` 路由，接受 `url` 查询参数，代理请求教务系统通知页面并提取正文 HTML
  - [x] SubTask 4.2: 后端 `school_client.py` 新增 `get_notice_detail(url)` 方法
  - [x] SubTask 4.3: 后端 `schemas.py` 新增 `NoticeDetail` schema（title、date、content_html、url）
  - [x] SubTask 4.4: 前端 `api_client.dart` 新增 `fetchNoticeDetail(url)` 方法
  - [x] SubTask 4.5: 前端新增 `NoticeDetailPage`，使用 WebView 渲染通知正文 HTML
  - [x] SubTask 4.6: 后端新增单元测试覆盖通知详情接口

- [ ] Task 5: 使用 MCP 调试应用验证所有改动
  - [ ] SubTask 5.1: 编译 profile APK 并安装到实机
  - [ ] SubTask 5.2: 验证移动端无顶栏、MorePage 设置区域正常
  - [ ] SubTask 5.3: 验证切换深色模式不重载数据
  - [ ] SubTask 5.4: 验证通知页面分组展示和详情查看
  - [ ] SubTask 5.5: 验证桌面端顶栏和功能不受影响

# Task Dependencies
- [Task 2] independent（AsyncPanel 改造可独立进行）
- [Task 1] independent（顶栏删除和设置迁移可独立进行）
- [Task 3] depends on [Task 2]（通知页面使用改造后的 AsyncPanel）
- [Task 4] depends on [Task 3]（详情功能依赖通知页面可点击）
- [Task 5] depends on [Task 1, 2, 3, 4]（最终验证依赖所有改动完成）
