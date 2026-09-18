# 软帮手（OneGZUS）

软帮手是广州软件学院学生开发的教务与校园生活助手，把课表、成绩、考勤、考试、通知、请假和生活缴费等常用信息集中到一个界面中。

> 本项目是非官方、非营利的开源工具，仅供学习交流和个人校园生活辅助使用。学校官方系统是相关数据和业务结果的最终依据。

[![License](https://img.shields.io/badge/License-MIT-yellow?style=flat-square)](./LICENSE)
[![Flutter](https://img.shields.io/badge/Flutter-3.44%2B-02569B?style=flat-square&logo=flutter&logoColor=white)](https://flutter.dev/)
[![Backend](https://img.shields.io/badge/Backend-FastAPI-009688?style=flat-square)](https://fastapi.tiangolo.com/)

## 使用入口

- Web：<https://onegzus.onrein.top>
- 源码：<https://github.com/ONTHEREIN/GZUS-PRO>
- [隐私政策](./docs/privacy-policy.md)
- [用户服务协议](./docs/terms-of-service.md)
- [开源组件与致谢](./docs/acknowledgements.md)
- [文档索引](./docs/README.md)

## 功能

| 模块 | 能力 |
| --- | --- |
| 首页与课表 | 今日课程、周课表、课程详情、天气、ICS 日历导出、按学期设置第一周 |
| 成绩与学分 | 成绩查询、绩点与学分统计、成绩变化提醒 |
| 考勤与考试 | 考勤记录和统计、考试时间地点、倒计时与提醒 |
| 通知中心 | 教务通知、办事大厅通知、公众号文章、已读状态和历史记录 |
| 请假与办事 | 请假申请、审批进度、教师查找、附件上传和常用办事入口 |
| 一卡通与生活缴费 | 一卡通余额/消费记录，电费、冷水、热水余额和低余额提醒 |
| 提醒 | 应用内通知、Web Push、Android 本地/后台提醒、iOS APNs 与实况活动（需系统授权） |
| 桌面组件 | Android 与 iOS 的下一节课、今日/周课表、考试、成绩、生活缴费和业务进度组件 |
| 个性化 | 深色模式、主题色、字体大小、首页模块和导航栏自定义、课表本地调课 |
| 其他 | 作业文件上传、反馈工单、离线缓存和登录状态恢复 |

不同平台和不同学校系统权限会影响可用功能；通知、定位、相册/相机、日历等能力均按需申请并可在系统设置中关闭。

## 快速开始

### 直接使用

浏览器打开 <https://onegzus.onrein.top> 即可使用 Web 版。手机浏览器可以将页面添加到主屏幕，获得接近原生应用的体验。

### Android

项目提供 Android 构建配置和桌面组件。安装经过签名的 APK 后，使用广州软件学院统一身份认证登录；通知、后台提醒和桌面组件需要在系统中授予相应权限。

### iOS

仓库包含 iOS 原生工程、WidgetKit 桌面组件和 Live Activities 实况活动。当前是否能直接安装取决于开发者签名和分发方式；没有可用签名时，建议使用 Web 版并添加到主屏幕。

## 常见问题

### 应用会保存我的密码吗？

账号密码登录时，密码通过 HTTPS 发送到后端完成学校认证。默认勾选“记住密码并自动登录”时，密码和自动登录凭据会保存在本机的安全存储中，用于下次填充和恢复登录；取消勾选后不会保存这两项内容。后端不保存明文密码，但用户主动开启后台持续通知后，服务端会保存经过加密的自动登录凭据，用于按授权轮询学校系统。

### 数据是实时的吗？

应用优先从学校官方系统获取数据；网络或上游系统暂时不可用时，部分页面会展示带时间标记的缓存数据。成绩、考勤、考试、通知和缴费等内容请以学校系统最终结果为准。

### 为什么没有收到通知？

请检查应用或浏览器的通知权限、系统电池策略和网络状态。后台持续通知需要单独完成授权，并依赖学校系统、推送服务和设备系统均可用；课程提醒也可以只使用设备本地提醒。

### 如何反馈问题？

登录后进入“更多 → 反馈问题”，或在 [GitHub Issues](https://github.com/ONTHEREIN/GZUS-PRO/issues) 提交反馈。应用内反馈可附带你主动选择的文件，以及最近的客户端诊断日志；请勿在描述或附件中提交密码、验证码、Cookie 等敏感信息。

## 本地开发

环境要求：Flutter 3.44.0、Dart 3.4+、Python 3.11+ 和 [uv](https://docs.astral.sh/uv/)。

### 前端

```bash
cd apps/mobile_web
flutter pub get
flutter test
flutter analyze
flutter run -d chrome --dart-define=API_BASE_URL=http://127.0.0.1:8000/api
```

构建 Web：

```bash
flutter build web --release \
  --dart-define=API_BASE_URL=https://onegzus.onrein.top/api \
  --no-web-resources-cdn
```

### 后端

```bash
cd services/api
uv sync --extra dev
PYTHONPATH=. uv run pytest
uv run ruff check .
PYTHONPATH=. uv run uvicorn app.main:app --reload \
  --reload-dir app --reload-exclude .venv \
  --host 0.0.0.0
```

本地环境变量参考 [`services/api/.env.example`](./services/api/.env.example)。测试会自动使用内存 SQLite；生产环境必须使用 PostgreSQL，并设置凭据加密密钥。Windows 开发者也可以使用仓库根目录的 `restart.ps1` 启动本地 API 和 Flutter Web。

### 编译时配置

前端通过 `API_BASE_URL` 指定后端地址，默认值为生产 API。Android/iOS 的推送、Shiply 资源和签名配置使用对应的 `--dart-define` 或原生工程配置；不要把生产密钥、真实账号或密码提交到仓库。

## 项目结构

```text
GZUS-PRO/
├── apps/mobile_web/       # Flutter Web、Android、iOS 客户端
├── services/api/          # FastAPI 后端、学校系统连接器和后台任务
├── docs/                  # 用户协议、隐私政策、API 和开发文档
├── deploy/tencent/        # 腾讯云生产部署脚本与说明
├── third_party/           # 经审查后纳入仓库的第三方代码
└── .github/workflows/     # 测试、构建和生产部署流程
```

## 运行架构

```text
Flutter Web / Android / iOS
            │ HTTPS
            ▼
腾讯云 Nginx ── /api ──► FastAPI（onegzus-api）
                              │
                              ├── 广州软件学院教务/办事大厅/一卡通系统
                              └── 自托管 PostgreSQL
```

生产环境只使用腾讯云上的 Nginx、FastAPI、PostgreSQL 和学校系统连接器，不依赖 Vercel、Cloudflare Worker 或其他替代生产入口。推送、天气和 Shiply 等外部服务仅在对应功能启用且满足权限/配置条件时使用。

## 文档与隐私

- [隐私政策](./docs/privacy-policy.md)：面向用户的数据收集、使用、存储和权利说明。
- [内部隐私规范](./docs/privacy.md)：登录凭据、Cookie、日志和测试数据的技术约束。
- [用户服务协议](./docs/terms-of-service.md)：服务范围、使用规范和免责声明。
- [API 文档](./docs/api.md)：认证、教务、通知、反馈等接口概览。
- [开源组件与致谢](./docs/acknowledgements.md)：直接依赖、内置 SDK 和致谢信息。

## 许可证

本项目源代码按 [MIT License](./LICENSE) 发布。学校系统数据、学校名称和相关业务内容不属于本项目的开源授权范围；第三方依赖按各自许可证使用，详见[致谢清单](./docs/acknowledgements.md)。

---

Made with ❤️ by GZUS students
