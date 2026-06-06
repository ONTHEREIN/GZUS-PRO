# Tasks

- [x] Task 1: 在 `api_client.dart` 中实现 ICS 生成逻辑
  - [x] SubTask 1.1: 创建 `generateIcs` 顶层函数，接收 `List<ScheduleCourse>`、`firstWeekStart`、`year`、`term` 参数，返回 ICS 字符串
  - [x] SubTask 1.2: 实现周次解析函数 `parseWeeks`，支持 "1-16"、"1-8,10-16"、"1-16单"、"1-16双" 等格式，返回 `List<int>`
  - [x] SubTask 1.3: 实现日期时间计算：根据 `firstWeekStart` + week + weekday 计算日期，结合 `scheduleTimes` 的 startSection/endSection 计算起止时间
  - [x] SubTask 1.4: 为每个课程的每周生成 VEVENT，包含 SUMMARY、LOCATION、DESCRIPTION、DTSTART、DTEND、UID 字段
  - [x] SubTask 1.5: 组装完整 ICS 文件（VCALENDAR 包裹 + PRODID + VERSION + 所有 VEVENT）

- [x] Task 2: 在课表工具弹窗中添加「导出日历」按钮及交互逻辑
  - [x] SubTask 2.1: 在 `_showScheduleTools` 的 Wrap 中添加「导出日历」按钮（FluentIcons.calendar 或类似图标）
  - [x] SubTask 2.2: 按钮点击时调用 `generateIcs` 生成 ICS 内容
  - [x] SubTask 2.3: 移动端使用 `share_plus` 包调起系统分享；Web 端使用 `dart:html` 触发下载
  - [x] SubTask 2.4: 添加导出中加载状态，防止重复点击
  - [x] SubTask 2.5: 无课表数据时按钮置灰

- [x] Task 3: 添加依赖并验证
  - [x] SubTask 3.1: 在 `pubspec.yaml` 中添加 `share_plus` 依赖
  - [x] SubTask 3.2: 运行 `flutter pub get` 确保依赖安装成功
  - [x] SubTask 3.3: 运行 `flutter analyze` 确保无静态分析错误

# Task Dependencies
- [Task 2] depends on [Task 1]
- [Task 3] depends on [Task 2]
