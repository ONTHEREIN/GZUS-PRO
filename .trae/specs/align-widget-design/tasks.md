# Tasks

- [x] Task 1: 重构桌面 Widget 布局文件，对齐首页 `_HomeCard` 结构
  - [x] SubTask 1.1: 修改 `widget_home_card.xml`，添加图标 ImageView、重构 header 为 icon+title+badge 横向排列
  - [x] SubTask 1.2: 调整内容区域字段顺序和样式，对齐首页信息层次（title→meta→detail）
  - [x] SubTask 1.3: 统一字号（标题 18sp 粗体、正文 13sp、meta 13sp 粗体、detail 12sp、badge 11sp 粗体）
  - [x] SubTask 1.4: 统一间距（内边距 16dp、元素间距与首页一致）

- [x] Task 2: 对齐配色体系，支持深色模式
  - [x] SubTask 2.1: 创建 `res/values/colors_widget.xml` 定义浅色模式 Widget 语义色（对齐 Material 3 近似值）
  - [x] SubTask 2.2: 创建 `res/values-night/colors_widget.xml` 定义深色模式 Widget 语义色
  - [x] SubTask 2.3: 修改 `widget_home_background.xml` 使用语义色引用替代硬编码 `#F7FAF5`
  - [x] SubTask 2.4: 修改 `widget_badge_background.xml` 使用语义色引用替代硬编码 `#D4E3F5`
  - [x] SubTask 2.5: 修改 `widget_home_card.xml` 中文字颜色使用语义色引用
  - [x] SubTask 2.6: 将卡片圆角从 22dp 改为 16dp

- [x] Task 3: 添加 Widget 图标资源
  - [x] SubTask 3.1: 添加四种 Widget 对应的矢量图标（时钟、时间线、水滴、路线）到 `res/drawable/`
  - [x] SubTask 3.2: 在 `HomeWidgetProvider.kt` 中根据 kind 设置对应图标

- [x] Task 4: 调整 `_HomeWidgetBridge.update()` 数据映射
  - [x] SubTask 4.1: 对齐"下一节课"字段：title→课程名、description→状态描述、meta→时间+地点、detail→教师+状态
  - [x] SubTask 4.2: 对齐"今日课表"字段：title→含课程数量、description→描述、meta→周次+节数、detail→课程列表
  - [x] SubTask 4.3: 对齐"生活缴费"字段：title→宿舍名/未绑定、description→描述、meta→冷水+热水+电费、detail→更新时间
  - [x] SubTask 4.4: 对齐"办事大厅"字段：title→业务名、description→描述、meta→状态+节点、detail→进度+日期

- [x] Task 5: 验证四种桌面 Widget 在浅色/深色模式下的渲染效果
  - [x] SubTask 5.1: 浅色模式下四种 Widget 截图对比首页卡片
  - [x] SubTask 5.2: 深色模式下四种 Widget 截图对比首页卡片

# Task Dependencies
- Task 2 依赖 Task 1（布局需要引用语义色）
- Task 3 依赖 Task 1（图标需要添加到布局中）
- Task 4 独立，可与 Task 1-3 并行
- Task 5 依赖 Task 1-4 全部完成
