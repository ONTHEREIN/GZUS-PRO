# 软帮手

<p align="center">
  <img src="website/assets/widget_final_today_schedule.png" alt="软帮手" width="260">
</p>

<p align="center">
  <b>OneGZUS</b>
</p>

<p align="center">
  课表、成绩、考勤、水电费、请假、考试提醒 — 一个 App 搞定全部教务事务。
</p>

<p align="center">
  <a href="#features"><img src="https://img.shields.io/badge/功能介绍-2563EB?style=flat-square" alt="功能介绍"></a>
  <img src="https://img.shields.io/badge/腾讯云自托管-059669?style=flat-square&logo=tencentcloud&logoColor=white" alt="腾讯云自托管">
  <img src="https://img.shields.io/badge/License-MIT-yellow?style=flat-square" alt="License">
</p>

---

## 这个 App 能帮你做什么？

每天打开四五个系统查信息，真的累了。软帮手把你在学校需要的教务功能全部放在一起：

- **早上醒来** — 看一眼今日课表，知道今天在哪上课
- **考完试** — 成绩推送直接通知你，不用每隔一小时刷新教务系统
- **月底查账** — 水电费余额实时显示，不怕突然停水停电
- **考前一周** — 考试安排自动提醒，不怕记错时间
- **需要请假** — 手机填写申请，查看审批进度，不用打印纸质单子

## 功能特性

| 功能 | 描述 | 使用场景 |
|------|------|----------|
| **智能课表** | 今日课程时间线、周视图课表、ICS 日历导出 | 每天查看上课地点 |
| **成绩查询** | 实时成绩推送、绩点计算、学分统计 | 期末查成绩 |
| **考勤管理** | 出勤记录查询、缺勤提醒、考勤统计 | 学期中自查考勤 |
| **考试提醒** | 考试安排同步、考前推送、倒计时 | 考前确认时间地点 |
| **水电费查询** | 实时余额、用量统计、缴费提醒 | 月底查水电费 |
| **校园通知** | 教务通知推送、已读标记、历史归档 | 关注选课/学籍通知 |
| **请假系统** | 在线申请、进度追踪、附件上传 | 事假/病假/公假 |
| **一卡通** | 余额查询、消费记录、充值提醒 | 查消费明细 |
| **Android 桌面组件** | 下一节课、今日课表、生活缴费、业务进度 | 不打开 App 也能看关键信息 |
| **深色模式** | 自动跟随系统主题 | 夜间使用 |

## 界面预览

<p align="center">
  <img src="website/assets/widget_final_today_schedule.png" width="200" alt="首页">
  <img src="website/assets/widget_final_schedule_warm_fixed.png" width="200" alt="课表">
  <img src="website/assets/widget_final_utilities.png" width="200" alt="工具">
  <img src="website/assets/widget_final_business_progress.png" width="200" alt="请假">
</p>

## 快速开始

### Web 版（推荐）

无需下载，浏览器打开即用：

```
https://onegzus.onrein.top
```

支持手机浏览器，可添加到主屏幕获得类似原生 App 的体验。

### Android 版

下载 APK 安装包安装即可：

1. 下载最新版本 APK
2. 允许安装未知来源应用
3. 使用学校统一身份认证登录

> 首次登录后，App 会自动记住会话，之后无需重复登录。

#### 桌面组件示例

Android 版支持 4 类桌面组件：

- **下一节课**：显示课程名、时间、教室、老师
- **今日课表**：显示当天课程列表
- **生活缴费**：显示电费、冷水、热水余额
- **业务进度**：显示请假/办事大厅审批状态

添加方法：在 Android 桌面长按空白处，进入"小组件/Widget"，找到软帮手后拖到桌面。打开 App 并刷新首页后，组件会同步最新数据。

### iOS

由于 Apple 开发者账号费用较高，暂未上架 App Store。iOS 用户建议使用 Web 版，可添加到主屏幕作为快捷方式使用。

## 常见问题

**Q: 使用这个 App 安全吗？**

A: 完全安全。App 使用学校官方统一身份认证登录，不会存储你的教务密码。所有数据均从学校官方系统实时获取。

**Q: 数据是实时的吗？**

A: 是的。课表、成绩、考勤等数据均实时从学校教务系统获取。网络不佳时会自动展示缓存数据，恢复后自动刷新。

**Q: 这个 App 收费吗？**

A: 完全免费。这是学生自发开发的开源项目，没有任何广告或内购。

**Q: 发现 Bug 怎么办？**

A: 欢迎通过 GitHub Issues 提交反馈，或直接联系开发者。

## 开发相关

如果你对这个项目的技术实现感兴趣，或者想参与开发：

- **前端**: Flutter 3.x，一套代码构建 Web + Android + iOS
- **后端**: FastAPI + Python，高性能异步 API 服务
- **部署**: 腾讯云自托管，Nginx 提供 Web 服务并反向代理 FastAPI

生产环境由 GitHub Actions 在测试通过后通过 SSH 和 rsync 自动部署。

## 项目结构

```
GZUS-PRO/
├── apps/mobile_web/          # Flutter 前端
├── services/api/             # FastAPI 后端
├── docs/                     # 文档与隐私政策
├── website/                  # 项目介绍网站
└── .github/workflows/        # CI/CD 部署配置
```

## 部署架构

| 服务 | 平台 | 项目名 | 说明 |
|------|------|--------|------|
| Web 应用 | 腾讯云 | `onegzus.onrein.top` | Nginx 托管 Flutter Web 静态资源 |
| API 服务 | 腾讯云 | `onegzus-api` | FastAPI 常驻进程，由 systemd 管理 |
| 数据库 | 自托管 PostgreSQL | `DATABASE_URL` | 持久化会话和业务数据，不依赖 Neon |

客户端通过 `https://onegzus.onrein.top/api` 访问后端，不再经过 Cloudflare Worker 或
Vercel。推送至 `master` 分支后，GitHub Actions 会先运行测试，再通过 SSH 和 rsync
部署到腾讯云；前端部署后重载 Nginx，后端部署后重启 `onegzus-api` 服务。

## 免责声明

本项目为广州软件学院学生自发开发的开源工具，仅供学习交流使用。

- 使用本工具产生的所有数据归学校教务系统所有
- 请遵守学校相关规定，合理使用教务系统接口
- 开发者不对因使用本工具产生的任何问题负责

## 许可证

[MIT License](./LICENSE)

---

<p align="center">
  Made with &#10084; by GZUS students
</p>
