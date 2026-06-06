# Tasks

- [ ] Task 1: 优化 ExamsPage 布局
  - [ ] SubTask 1.1: 移动端考试卡片使用 `Card` 组件，设置合适的圆角和间距
  - [ ] SubTask 1.2: 考试时间和地点使用强调色突出显示
  - [ ] SubTask 1.3: 桌面端表格头部使用 `surfaceContainerHighest` 背景

- [ ] Task 2: 优化 GradesPage 布局
  - [ ] SubTask 2.1: 移动端成绩卡片使用 `Card` + `InfoTile` 组合
  - [ ] SubTask 2.2: 补考记录使用 `ExpansionTile` 展开
  - [ ] SubTask 2.3: 桌面端使用两栏布局，左侧统计右侧列表

- [ ] Task 3: 优化 CreditsPage 布局
  - [ ] SubTask 3.1: 学分卡片使用 `Card` 组件
  - [ ] SubTask 3.2: 学分进度条使用 `LinearProgressIndicator`
  - [ ] SubTask 3.3: 使用 `InfoTile` 展示必修/选修学分详情

- [ ] Task 4: 优化 EcardPage 布局
  - [ ] SubTask 4.1: 余额展示使用 `Card` 组件
  - [ ] SubTask 4.2: 低电量时使用 error 颜色警告
  - [ ] SubTask 4.3: 余额数字使用大字体突出显示

- [ ] Task 5: 优化 MorePage 布局
  - [ ] SubTask 5.1: 功能入口使用 `Card` 组件包裹
  - [ ] SubTask 5.2: 设置区域使用 `ListTile` 布局
  - [ ] SubTask 5.3: 使用 `SegmentedButton` 切换主题模式

- [ ] Task 6: 验证布局重构
  - [ ] SubTask 6.1: 执行 `flutter analyze` 确认无编译错误
  - [ ] SubTask 6.2: 执行 `flutter build web` 确认构建成功

# Task Dependencies
- [Task 1-5] 互相独立，可并行执行
- [Task 6] 必须在所有其他 Task 完成后执行
