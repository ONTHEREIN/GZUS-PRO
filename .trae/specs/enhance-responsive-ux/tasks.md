# Tasks

- [x] Task 1: 实现 MarqueeText 组件
  - [x] SubTask 1.1: 创建 MarqueeText StatefulWidget，接收 text、style、scrollSpeed 参数
  - [x] SubTask 1.2: 使用 LayoutBuilder 检测文字是否超出容器宽度
  - [x] SubTask 1.3: 超出时使用 AnimationController 驱动文字从右向左滚动，末尾停顿 1 秒后循环
  - [x] SubTask 1.4: 未超出时静态显示

- [x] Task 2: 实现自定义底栏与更多页面
  - [x] SubTask 2.1: 定义 NavTabConfig 数据模型（tabId、icon、label、shortLabel、isFixed），创建默认配置（底栏：信息、课表、更多；更多页：通知、考勤、考试、成绩、学分）
  - [x] SubTask 2.2: 实现 NavPreferences 服务，从 SharedPreferences 读取/保存底栏自定义偏好
  - [x] SubTask 2.3: 重构 MobileNavBar，根据 NavTabConfig 列表动态渲染 Tab，最后一个固定为"更多"
  - [x] SubTask 2.4: 重构 MorePage，以网格布局展示非底栏功能入口，支持点击导航到对应页面
  - [x] SubTask 2.5: 在 MorePage 添加编辑按钮，进入编辑模式支持拖拽排序和增删 Tab
  - [x] SubTask 2.6: 编辑完成后保存偏好到 SharedPreferences，提供"恢复默认"按钮
  - [x] SubTask 2.7: 更新 DashboardShell，根据 NavTabConfig 动态构建 pages 列表，"更多"页使用 MorePage

- [x] Task 3: 通知简介获取链接内容
  - [x] SubTask 3.1: 后端 `NoticeItem` schema 新增 `content_summary: str | None = None` 字段
  - [x] SubTask 3.2: 后端 `_query_notices` 方法中，对每条有 url 的通知并发请求详情页面，提取正文前 120 字作为 content_summary（最大并发 5，总超时 10 秒）
  - [x] SubTask 3.3: 前端 `NoticeItem` 类新增 `contentSummary` 字段
  - [x] SubTask 3.4: 前端 `NoticeCard` 优先展示 `contentSummary`，为空时回退到 `summary`

- [x] Task 4: 响应式多栏布局
  - [x] SubTask 4.1: 考勤页宽屏布局：左侧考勤总览面板 + 右侧考勤详情列表（Row + Expanded）
  - [x] SubTask 4.2: 考试页宽屏布局：左侧学期筛选排序面板 + 右侧考试列表
  - [x] SubTask 4.3: 成绩页宽屏布局：左侧学期筛选统计面板 + 右侧成绩列表
  - [x] SubTask 4.4: 学分页宽屏布局：左侧总览进度面板 + 右侧学分详情列表
  - [x] SubTask 4.5: 通知页宽屏布局：左侧通知列表 + 右侧选中通知详情（主从布局，点击左侧条目右侧显示详情）

- [x] Task 5: 考试界面时间地点突出显示
  - [x] SubTask 5.1: 考试时间使用 `colorScheme.primary` + 加粗 + `Icons.schedule` 图标
  - [x] SubTask 5.2: 考试地点使用 `colorScheme.tertiary` + 加粗 + `Icons.location_on` 图标

- [x] Task 6: 考勤筛选排序功能
  - [x] SubTask 6.1: 将 AttendancePage 改为 StatefulWidget，维护筛选和排序状态
  - [x] SubTask 6.2: 添加排序 PopupMenu：按正常/迟到/早退/旷课/请假次数的正序/倒序
  - [x] SubTask 6.3: 添加筛选 PopupMenu：仅显示有迟到/早退/旷课/请假的课程，或显示全部
  - [x] SubTask 6.4: 排序按钮显示当前排序状态文字（如"迟到↓"）
  - [x] SubTask 6.5: 筛选排序组合逻辑：先筛选再排序

- [x] Task 7: 考试按学期正倒序排序
  - [x] SubTask 7.1: 在 ExamsPage 的"按学期排列"模式下新增排序方向切换按钮（IconButton with Icons.swap_vert）
  - [x] SubTask 7.2: 默认倒序（最新学期在前），点击切换为正序
  - [x] SubTask 7.3: 切换后列表立即更新

- [x] Task 8: 成绩关联考试
  - [x] SubTask 8.1: 在 GradeMobileCard 和 GradeGroupRow 中，为每条成绩添加"考试"标签按钮
  - [x] SubTask 8.2: 点击"考试"标签时，通过 DashboardShell 回调导航到考试页面
  - [x] SubTask 8.3: 考试页面接收高亮参数，自动滚动到对应考试条目并高亮 2 秒
  - [x] SubTask 8.4: 无对应考试时显示 SnackBar 提示

# Task Dependencies
- [Task 1] independent（MarqueeText 可独立实现）
- [Task 2] independent（底栏自定义可独立实现，但需在 Task 4 之前完成以确定页面路由结构）
- [Task 3] independent（通知简介后端改造可独立进行）
- [Task 4] depends on [Task 2]（多栏布局需要确定页面路由结构）
- [Task 5] independent（考试突出显示可独立实现）
- [Task 6] independent（考勤筛选排序可独立实现）
- [Task 7] independent（考试排序可独立实现）
- [Task 8] depends on [Task 2]（成绩关联考试需要页面导航机制）
