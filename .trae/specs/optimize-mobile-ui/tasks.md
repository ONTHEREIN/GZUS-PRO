# Tasks

- [x] Task 1: 重构 MobileNavBar，支持动态 Tab 和"更多"页
  - [x] SubTask 1.1: 定义 NavConfig 数据模型（tabId、icon、label、shortLabel），创建默认配置和"更多"页配置
  - [x] SubTask 1.2: 实现 NavPreferences 服务，负责从 SharedPreferences 读取/保存底栏自定义偏好
  - [x] SubTask 1.3: 重构 MobileNavBar 组件，根据 NavConfig 列表动态渲染 Tab，最后一个固定为"更多"
  - [x] SubTask 1.4: 实现 MorePage 页面，以网格布局展示非底栏功能入口
  - [x] SubTask 1.5: 更新 DashboardShell，根据 NavConfig 动态构建 pages 列表，"更多"页使用 MorePage

- [x] Task 2: 实现底栏自定义编辑功能
  - [x] SubTask 2.1: 在 MorePage 添加编辑按钮，进入编辑模式
  - [x] SubTask 2.2: 实现编辑模式 UI：底栏区域和更多页区域可拖拽排序
  - [x] SubTask 2.3: 实现添加/移除 Tab 逻辑（底栏最多 5 个，"更多"不可移除）
  - [x] SubTask 2.4: 实现"恢复默认"按钮
  - [x] SubTask 2.5: 编辑完成后保存偏好到 SharedPreferences

- [x] Task 3: 顶栏异形屏适配与自动隐藏
  - [x] SubTask 3.1: 重构顶栏组件，移动端高度精简至 48dp，筛选工具收入溢出菜单（PopupMenuButton）
  - [x] SubTask 3.2: 正确处理顶部 SafeArea，使用 MediaQuery.padding 适配异形屏
  - [x] SubTask 3.3: 实现滚动驱动自动隐藏/显示：监听 ScrollController，向下滚动隐藏、向上滚动显示
  - [x] SubTask 3.4: 添加隐藏/显示的滑动动画（AnimatedSlide + AnimatedOpacity，时长 200ms）

- [x] Task 4: 课表页今日视图
  - [x] SubTask 4.1: 在 SchedulePage 顶部添加"今日"/"周课表"切换 Tab
  - [x] SubTask 4.2: 实现 TodayScheduleView 组件，以时间线列表展示当天课程
  - [x] SubTask 4.3: 处理今日无课程的空状态

- [x] Task 5: 课表页左右滑动切换周次
  - [x] SubTask 5.1: 为 TimetableView 添加水平滑动手势检测（GestureDetector onHorizontalDragEnd）
  - [x] SubTask 5.2: 实现周次切换的滑动过渡动画（PageView 或 AnimatedSwitcher）
  - [x] SubTask 5.3: 实现周次标题点击弹出底部选择器（BottomSheet + 周次列表，标记当前周）
  - [x] SubTask 5.4: 滑动切换后同步更新 DashboardShell 的 year/term/currentWeek 状态

- [x] Task 6: 课表页课程颜色自定义
  - [x] SubTask 6.1: 实现 ScheduleColorPrefs 服务，从 SharedPreferences 读取/保存课程颜色映射
  - [x] SubTask 6.2: 在课程详情底部 Sheet 中添加颜色选择区域（预设色板 + 自定义输入）
  - [x] SubTask 6.3: 修改 TimetableView 的 _courseColor 方法，优先使用自定义颜色，回退到 hash 色板

- [x] Task 7: 课表页课程详情优化
  - [x] SubTask 7.1: 将课程详情从 ContentDialog 改为 BottomSheet 展示
  - [x] SubTask 7.2: BottomSheet 高度限制为屏幕 70%，从底部滑入动画
  - [x] SubTask 7.3: 在 BottomSheet 顶部显示课程颜色圆点，点击触发颜色修改

- [x] Task 8: 移动端信息密度提升
  - [x] SubTask 8.1: 重构 AttendancePage 移动端布局：概览使用紧凑进度条 + 数字，课程行使用紧凑行卡片
  - [x] SubTask 8.2: 重构 ExamsPage 移动端布局：考试条目使用紧凑行卡片，即将到来的考试置顶高亮
  - [x] SubTask 8.3: 重构 GradesPage 移动端布局：成绩条目使用紧凑行卡片，补考记录折叠展示
  - [x] SubTask 8.4: 重构 CreditsPage 移动端布局：概览使用紧凑进度条 + 横向条形图

# Task Dependencies
- [Task 2] depends on [Task 1]（自定义编辑需要动态 Tab 基础）
- [Task 5] depends on [Task 4]（周次切换与视图切换在同一页面）
- [Task 6] depends on [Task 7]（颜色选择入口在详情 BottomSheet 中）
- [Task 7] depends on [Task 5]（详情优化与课表交互重构一起）
- [Task 8] independent（可与其他任务并行）
