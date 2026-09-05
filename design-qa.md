# 灵动岛设计 QA

## 对照基线

- Source visual truth: `/Users/decrein/Downloads/灵动岛设计总览 2/pages/灵动岛设计总览.html`
- Source captures: `/Users/decrein/Coding_Project/GZUS-PRO/dynamic-island-source.png`, `/Users/decrein/Coding_Project/GZUS-PRO/dynamic-island-source-course-expanded.png`, `/Users/decrein/Coding_Project/GZUS-PRO/dynamic-island-source-utility-expanded.png`
- Implementation captures: `/Users/decrein/Coding_Project/GZUS-PRO/dynamic-island-implementation-course-final.png`, `/Users/decrein/Coding_Project/GZUS-PRO/dynamic-island-implementation-utility-final.png`
- Responsive captures: `/Users/decrein/Coding_Project/GZUS-PRO/dynamic-island-implementation-tablet.png`, `/Users/decrein/Coding_Project/GZUS-PRO/dynamic-island-implementation-desktop.png`
- Viewports: 390 × 844、768 × 900、1440 × 1000 CSS px
- Density normalization: Playwright `scale: css`, deviceScaleFactor 1；390 × 844 source 与 implementation 均为 390 × 844 px。Focused source 分别为 358 × 256 和 358 × 295 px。
- State: 浅色主题；课程展开/紧凑/关闭/重新打开；水电展开；平板与桌面紧凑态。

## Findings

当前没有仍需处理的 P0/P1/P2 问题。

- 字体与排版：中文使用系统字体，标题、正文、辅助文字层级与设计稿一致；小字号采用较高字重，长文本具备省略与缩放约束。
- 间距与布局：Compact 208 px、Expanded 最大 420 px、26 px 圆角、12 px 内边距和 5 px 进度条均已落实；390/768/1440 三档无裁切或溢出。
- 颜色与令牌：课程/业务蓝、考试/考勤橙、水电青、成绩绿均与设计稿一致；表面、前景、边框会随系统明暗主题切换。
- 图片与图标：设计不包含位图资产；Flutter 使用 Material 图标，iOS 使用 SF Symbols，Android 使用系统通知图标与事件色，没有占位图、emoji 或手绘图形。
- 文案与内容：课程、水电示例与设计稿同状态对照；按钮文案按目标页面映射。
- 通知类型语义：课程/考试才展示真实倒计时；新通知、成绩、考勤和水电不再把过期时间误当倒计时，已完成事件也不再显示满格进度条；Android 通知与小米 Focus/Island 元数据保持同一规则。
- 交互：点击展开/收起、关闭、重新触发、目标页面按钮、P1–P5 抢占与 FIFO 队列、生命周期均已验证；浏览器控制台 0 error。

## Full-view comparison evidence

- 390 × 844：组件保持顶部安全区，展开宽度随移动端可用宽度收缩，按钮和正文未遮挡页面内容。
- 768 × 900 与 1440 × 1000：Compact 保持 208 px 胶囊宽度并居中，不随大屏无节制拉伸。
- Android/iOS 系统展示通过实际 Debug/Simulator 编译，原生结构与设计稿的 leading/center/trailing/bottom 语义一致。

## Focused region comparison evidence

- 课程展开态：圆形课程图标、双行标题区、正文、5 px 蓝色进度和全宽 CTA 与 source focused capture 一致。
- 水电展开态：移除进度条，改为类别摘要与三块独立指标；颜色、信息层级和 CTA 与 source focused capture 一致。

## Comparison history

1. 首轮发现 P1：Flutter 表面被固定为深色，与设计稿浅色手机状态不一致。修复为主题自适应表面、前景、边框和指标底色；复拍后浅色状态一致。
2. 第二轮发现 P2：水电正文与三指标重复、持续事件缺少手动关闭。修复为水电类别摘要 + 三指标，并让所有事件支持关闭按钮与上滑关闭；复拍验证关闭、重新打开及水电布局通过。
3. 第三轮发现 P1：非倒计时通知沿用短过期时间，导致灵动岛右侧重复短文案/倒计时，成绩等完成事件显示满格进度条。收紧 iOS 倒计时白名单、同步 Flutter 倒计时与进度显示条件，并在 Android 原生层过滤已完成进度；窄屏 320 px + 1.5 倍字号回归通过。

## Residual P3

- Flutter Web 的系统字体抗锯齿与设计稿浏览器字体存在轻微平台差异，属于运行环境差异，不影响原生应用。
- QA 预览页保留为开发入口，便于后续调整事件视觉；不进入默认应用启动链路。

## Implementation checklist

- [x] Flutter 应用内 Compact / Expanded 与响应式布局
- [x] P1–P5 优先级、FIFO 队列与最多 5 条
- [x] 倒计时格式、生命周期、查看/关闭行为
- [x] iOS Dynamic Island、Lock Screen、Minimal 与事件色/图标
- [x] Android promoted ongoing notification 与小米 Focus/Island 元数据
- [x] Flutter 测试、静态检查、Android Debug、iOS Simulator 编译
- [x] 同视口视觉 QA 与交互复验

final result: passed
