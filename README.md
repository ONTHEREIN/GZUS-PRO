# 软帮手（OneGZUS）

软帮手是广州软件学院学生开发的教务与校园生活助手，把课表、成绩、考勤、考试、通知、请假和生活缴费等常用信息集中到一个界面中。仓库包含 Flutter 客户端（Web / Android / iOS）、微信小程序客户端、FastAPI 后端和官网介绍页。

> 本项目是非官方、非营利的开源工具，仅供学习交流和个人校园生活辅助使用。学校官方系统是相关数据和业务结果的最终依据。

[![License](https://img.shields.io/badge/License-MIT-yellow?style=flat-square)](./LICENSE)
[![Flutter](https://img.shields.io/badge/Flutter-3.44%2B-02569B?style=flat-square&logo=flutter&logoColor=white)](https://flutter.dev/)
[![Backend](https://img.shields.io/badge/Backend-FastAPI-009688?style=flat-square)](https://fastapi.tiangolo.com/)
[![Mini Program](https://img.shields.io/badge/WeChat-Mini%20Program-07C160?style=flat-square)](./apps/wechat_miniprogram/)

## 使用入口

- Web：<https://onegzus.onrein.top>
- 官网：<https://onegzus.onrein.top/home/>
- Android：从 [GitHub Releases](https://github.com/ONTHEREIN/GZUS-PRO/releases/latest) 下载最新 APK
- iOS：仓库包含 iOS 原生工程；能否直接安装取决于签名与分发方式，没有可用签名时建议使用 Web 版
- 微信小程序：源码在 [`apps/wechat_miniprogram`](./apps/wechat_miniprogram/)，当前为 MVP，官网暂未提供入口，可按源码在微信开发者工具中运行
- 源码：<https://github.com/ONTHEREIN/GZUS-PRO>
- [隐私政策](./docs/privacy-policy.md)
- [用户服务协议](./docs/terms-of-service.md)
- [开源组件与致谢](./docs/acknowledgements.md)
- [文档索引](./docs/README.md)

## 功能

### Flutter 客户端（Web / Android / iOS）

| 模块 | 能力 |
| --- | --- |
| 首页与课表 | 今日课程、周课表、课程详情、天气、ICS 日历导出、按学期设置第一周、本地与云端调课 |
| 成绩与学分 | 成绩查询、绩点与学分统计、成绩变化提醒 |
| 考勤与考试 | 考勤记录与统计、考试时间地点、倒计时与提醒 |
| 通知中心 | 教务通知、办事大厅通知、公众号文章、校历类通知，WebSocket 实时更新 |
| 请假与办事 | 自动请假（原生客户端）、业务进度、教师查找、附件上传和常用办事入口 |
| 一卡通与生活缴费 | 一卡通余额/消费记录；绑定宿舍后查询电费、冷水、热水余额和低余额提醒 |
| 提醒 | 应用内通知、Web Push、Android 本地/后台提醒与实况通知、iOS APNs、实况活动与灵动岛（需系统授权） |
| 桌面组件 | Android 与 iOS 的下一节课、今日/周课表、考试、成绩、生活缴费和业务进度组件，iOS 另支持锁屏组件 |
| 个性化 | 深色模式、主题色、字体大小、首页模块和导航栏自定义、自定义背景 |
| 其他 | 作业文件上传（FTP，仅原生客户端）、反馈工单与诊断日志、离线缓存、PWA、登录状态恢复与设备授权持久登录 |
| 管理后台 | 管理员可在应用内查看总览、会话、管理员、反馈工单、校历通知、登录轮播、公众号文章、Shiply 资源和系统状态 |

### 微信小程序（MVP）

- 学校账号登录，以及微信一键登录与一对一微信绑定；本地只保存短期会话、展示身份、学期偏好和已同意的协议版本。
- 与 App/Web 共享学年学期：首页、周课表/全部课程、成绩、考勤、考试、通知（含详情）、生活缴费（可在小程序内绑定宿舍）和个人信息。
- 首次使用需阅读并同意用户服务协议与隐私政策；协议内容更新后需要重新确认。
- 当前 MVP 不包含推送订阅、附件上传、自动请假和 FTP 上传。接口地址按运行版本自动分流：开发者工具/体验版连接测试环境，正式版连接生产环境。

不同平台和不同学校系统权限会影响可用功能；通知、定位、相册/相机、日历等能力均按需申请并可在系统设置中关闭。

## 快速开始

### Web

浏览器打开 <https://onegzus.onrein.top> 即可使用。手机浏览器可以将页面添加到主屏幕（PWA），获得接近原生应用的体验；官网 <https://onegzus.onrein.top/home/> 提供三端入口和安装指引。

### Android

项目提供 Android 构建配置和桌面组件。从 [GitHub Releases](https://github.com/ONTHEREIN/GZUS-PRO/releases/latest) 下载最新 APK 并安装，使用广州软件学院统一身份认证登录；通知、后台提醒和桌面组件需要在系统中授予相应权限。

### iOS

仓库包含 iOS 原生工程、WidgetKit 桌面/锁屏组件和 Live Activities 实况活动。当前是否能直接安装取决于开发者签名和分发方式；没有可用签名时，建议使用 Web 版并添加到主屏幕。

### 微信小程序

小程序源码处于 MVP 阶段。在 `apps/wechat_miniprogram/` 内执行 `npm install` 安装依赖（会自动生成协议文本），再用微信开发者工具导入该目录；开发者工具需开启服务端口才能运行页面回归。测试 AppID、接口域名分流和分层验收命令见 [`apps/wechat_miniprogram/README.md`](./apps/wechat_miniprogram/README.md)。

## 常见问题

### 应用会保存我的密码吗？

账号密码登录时，密码通过 HTTPS 发送到后端完成学校认证，后端不保存明文密码。默认勾选“记住密码并自动登录”时，密码和自动登录凭据会保存在本机的安全存储中，用于下次填充和恢复登录；取消勾选后不会保存这两项内容。用户主动开启后台持续通知后，服务端会保存经过加密的自动登录凭据，用于按授权轮询学校系统。微信小程序本地只保存短期会话、展示身份、学期偏好和已同意的协议版本，不保存学校密码与 Cookie。

### 数据是实时的吗？

应用优先从学校官方系统获取数据；网络或上游系统暂时不可用时，部分页面会展示带时间标记的缓存数据。成绩、考勤、考试、通知和缴费等内容请以学校系统最终结果为准。

### 为什么没有收到通知？

请检查应用或浏览器的通知权限、系统电池策略和网络状态。后台持续通知需要单独完成授权，并依赖学校系统、推送服务和设备系统均可用；课程提醒也可以只使用设备本地提醒。微信小程序当前 MVP 不提供推送订阅。

### 微信小程序和 App 有什么区别？

小程序复用同一个后端，核心查询数据和学年学期与 App/Web 共享，并支持微信一键登录与宿舍绑定。它不包含桌面组件、系统推送、自动请假和 FTP 上传等原生能力，具体范围见[小程序说明](./apps/wechat_miniprogram/README.md)。

### 如何反馈问题？

登录后进入“更多 → 反馈问题”，或在 [GitHub Issues](https://github.com/ONTHEREIN/GZUS-PRO/issues) 提交反馈。应用内反馈可附带你主动选择的文件，以及最近的客户端诊断日志；请勿在描述或附件中提交密码、验证码、Cookie 等敏感信息。

## 本地开发

环境要求：Flutter 3.44.0、Dart 3.4+、Python 3.11+、Node.js 20+ 和 [uv](https://docs.astral.sh/uv/)。

### Flutter 客户端

```bash
cd apps/mobile_web
flutter pub get
flutter test
flutter analyze
flutter run -d chrome --dart-define=API_BASE_URL=http://127.0.0.1:8000
```

构建 Web：

```bash
flutter build web --release \
  --dart-define=API_BASE_URL=https://onegzus.onrein.top/api \
  --no-web-resources-cdn
```

本地直连 `uvicorn` 时后端路由没有 `/api` 前缀；生产环境经 Nginx 反向代理后才使用 `/api`。Android 模拟器中 `localhost`/`127.0.0.1` 会自动改写为 `10.0.2.2`。Windows 开发者也可以使用仓库根目录的 `build_deploy.ps1`（构建 APK 并安装）或 `restart.ps1`（启动本地 API 和 Flutter Web）。

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

本地环境变量参考 [`services/api/.env.example`](./services/api/.env.example)。测试会自动使用内存 SQLite；生产环境必须使用 PostgreSQL，并设置凭据加密密钥。生产发布前会运行 `python -m app.deployment_preflight --production --check-database` 做路由、配置和数据库检查。

### 微信小程序

```bash
cd apps/wechat_miniprogram
npm install
npm test          # 类型检查 + 逻辑单测
npm run test:pages  # 开发者工具页面回归（mock 请求，需开发者工具已登录并开启服务端口）
```

协议文本以 `docs/terms-of-service.md` 和 `docs/privacy-policy.md` 为唯一维护源，`npm run build:legal` 会生成不提交的 `utils/generated/`。失败现场写到项目目录之外，避免开发者工具重编译导致回归假失败。详见[小程序说明](./apps/wechat_miniprogram/README.md)。

### 官网

```bash
cd website
npm install
npm run dev       # Vite 开发服务器，站点挂在 /home/ 路径下
npm run build     # 产物在 dist/client/
```

官网是独立的 React 静态站点，使用 Vite 构建，`base` 固定为 `/home/`，由腾讯云 Nginx 托管，不参与 Flutter Web 的发布流程；发布与回滚见 [`deploy/tencent/README.md`](./deploy/tencent/README.md)。

### 编译时配置

前端通过 `API_BASE_URL` 指定后端地址，默认值为生产 API。Android/iOS 的推送、Shiply 资源和签名配置使用对应的 `--dart-define` 或原生工程配置；小程序的后端地址由 `utils/config.ts` 按运行版本自动选择。不要把生产密钥、真实账号或密码提交到仓库。

## 项目结构

```text
GZUS-PRO/
├── apps/
│   ├── mobile_web/        # Flutter 客户端（Web、Android、iOS）
│   └── wechat_miniprogram/ # 微信小程序客户端（原生小程序 + TypeScript，MVP）
├── services/api/          # FastAPI 后端、学校系统连接器和后台任务
├── website/               # 官网介绍页（React + Vite，挂载在 /home/）
├── deploy/tencent/        # 腾讯云生产/测试环境部署脚本与说明
├── docs/                  # 用户协议、隐私政策、API 和开发文档
├── tools/                 # 独立辅助脚本
├── third_party/           # 经审查后纳入仓库的第三方代码
└── .github/workflows/     # 测试、构建和生产部署流程
```

## 运行架构

```text
Flutter Web / Android / iOS            微信小程序
            │ HTTPS                      │ HTTPS
            └──────────────┬───────────────┘
                           ▼
                    腾讯云 Nginx
                    ├── /         Flutter Web 静态资源
                    ├── /home/    官网介绍页（React 静态站）
                    └── /api ──► FastAPI（onegzus-api）
                                    ├── 广州软件学院教务/办事大厅/一卡通系统
                                    ├── 自托管 PostgreSQL
                                    └── 后台轮询任务与仅本机 cron
```

生产环境只使用腾讯云上的 Nginx、FastAPI、PostgreSQL 和学校系统连接器，不依赖 Vercel、Cloudflare Worker 或其他替代生产入口。推送、天气和 Shiply 等外部服务仅在对应功能启用且满足权限/配置条件时使用。

测试环境与生产共用一台腾讯云主机，但使用独立域名、端口、目录、数据库和 systemd 服务（`test-api.onrein.top`、`onegzus-test-api`、`/opt/onegzus-test`、`onegzus_test` 库）；生产与测试库必须隔离，详见 [`deploy/tencent/TEST_ENV.md`](./deploy/tencent/TEST_ENV.md)。

## 测试与 CI

```bash
# 后端（services/api/）
PYTHONPATH=. uv run pytest
uv run ruff check .

# Flutter 客户端（apps/mobile_web/）
flutter test
flutter analyze

# 微信小程序（apps/wechat_miniprogram/）
npm test
```

| 工作流 | 触发 | 作用 |
| --- | --- | --- |
| `ci-api.yml` | PR 中 `services/api/**` 变更 | 复用 `api-tests.yml` 跑 pytest 和 ruff |
| `ci-frontend.yml` | PR 中 `apps/mobile_web/**` 变更 | 复用 `frontend-tests.yml` 跑 Flutter 测试 |
| `ci-miniprogram.yml` | PR 或 push master（小程序或两份协议变更） | `npm ci` + 类型检查 + 逻辑单测 |
| `deploy-prod-api.yml` | push master 且 `services/api/**` 变更 | 测试通过后备份数据库、发布并原子切换 API release |
| `deploy-prod-frontend.yml` | push master 且 `apps/mobile_web/**` 变更 | 测试通过后构建并原子切换 Flutter Web release |
| `security.yml` | PR 和 push master | Actions 校验、提交密钥扫描和生产依赖审计 |
| `live-activity-visual-probe.yml` | 手动触发 | 在生产执行 iOS 实况活动视觉探针 |

`api-tests.yml` 和 `frontend-tests.yml` 是可复用工作流，供 PR 检查与生产部署共同调用。官网发布是独立的手动流程（`deploy/tencent/scripts/publish_site.sh`），不经过 GitHub Actions。

## 文档与隐私

- [文档索引](./docs/README.md)：全部文档的分类入口。
- [隐私政策](./docs/privacy-policy.md)：面向用户的数据收集、使用、存储和权利说明，覆盖 Flutter 客户端与微信小程序。
- [用户服务协议](./docs/terms-of-service.md)：服务范围、使用规范和免责声明。
- [内部隐私规范](./docs/privacy.md)：登录凭据、Cookie、日志和测试数据的技术约束。
- [API 文档](./docs/api.md)：认证、教务、通知、缴费和反馈等接口概览。
- [数据访问边界](./docs/scraping-boundaries.md)：访问学校系统的范围与限制。
- [开源组件与致谢](./docs/acknowledgements.md)：直接依赖、内置 SDK 和致谢信息。
- [腾讯云部署说明](./deploy/tencent/README.md)：生产发布、备份、监控与官网部署。
- [小程序分层测试环境](./deploy/tencent/TEST_ENV.md)：测试环境、页面回归与真机验收说明。

## 许可证

本项目源代码按 [MIT License](./LICENSE) 发布。学校系统数据、学校名称和相关业务内容不属于本项目的开源授权范围；第三方依赖按各自许可证使用，详见[致谢清单](./docs/acknowledgements.md)。

---

Made with ❤️ by GZUS students
