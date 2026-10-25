# 软帮手微信小程序 MVP

原生微信小程序客户端，复用仓库中的 FastAPI 教务接口。当前 MVP 功能为：学校账号登录、微信一键登录与一对一绑定、三端共享学年学期、首页、周课表/全部课程、成绩、考勤、考试、通知、生活缴费查询与个人信息。

## 接口地址

`utils/config.ts` 按 `envVersion` 自动分流，**不需要手改地址**：

| 运行版本                    | 接口地址                                    |
| ----------------------- | --------------------------------------- |
| `develop`（开发者工具）/ `trial`（体验版） | `https://test-api.onrein.top/api` |
| `release`（正式版）           | `https://onegzus.onrein.top/api`          |

两个域名都必须加入微信公众平台的 **request 合法域名**，否则真机验收会直接报 `request:fail url not in domain list`。

> 接口路径与后端真实路由一致：教务相关接口挂在**根路径**下（`/me`、`/schedule`、`/grades`、`/attendance`、`/exams`、`/notices`），**没有 `/academic` 前缀**；请求按当前学年学期带 `year`、`term`；共享偏好为 `/settings/academic-period` 与 `/settings/schedule`；生活缴费为 `/ecard/summary`、`/ecard/rooms`、`/ecard/binding`；登录为 `/mini/auth/login`、`/mini/auth/wechat-login`，绑定为 `/mini/auth/wechat-binding`；退出为 `/auth/logout`。写成 `/academic/*` 会得到 404。

## 协议与通知详情

两份完整协议以仓库 `docs/terms-of-service.md` 和 `docs/privacy-policy.md` 为唯一维护源；`npm install`、检查、页面回归与预览前自动执行 `npm run build:legal`，生成的 `utils/generated/` 不提交。直接导入开发者工具前须先安装依赖；修改协议后运行生成命令再编译。

登录页和「我的」提供完整协议阅读入口。首次或协议内容更新时须确认同意；本地保存 `legal.acceptedVersion`，有效会话在确认后可继续使用，未确认不发起业务查询。协议内容没有变化时不会重写生成文件，以免触发开发者工具重编译。

通知可点击打开原生详情。教务来源读取 `/notices/detail` 并显示纯文本正文；办事大厅、公众号展示已有摘要，管理员通知展示发布说明与封面。有地址时可复制原文链接；本轮不使用 `web-view` 或预览附件。详情失败可重试，空正文和封面失败有明确提示。

## 学期与周课表

- 登录、会话恢复和回到前台时自动拉取共享学年学期；未初始化时按当前日期推导并写回服务端。
- 课表顶部的学年学期选择器会同步到 App/Web；课表默认周视图，支持周一至周日、16 节、1–30 周、前后周、回到本周、第一周日期编辑、单双周和冲突课程并排展示。
- 「全部课程」保留缺少星期或节次定位的课程；点击课程块或课程卡可查看教师、地点、节次和周次。

## 微信绑定与一键登录

- 微信只用于确认小程序身份，学校 Cookie、密码、`session_key` 和 AppSecret 不进入小程序存储或响应。
- 首次使用先点「微信一键登录」；未绑定时按提示使用学号密码登录，再确认绑定当前微信。个人页可查看绑定状态、绑定或二次确认解绑。
- 服务端必须在部署环境配置 `WECHAT_MINIPROGRAM_APP_ID` 与 `WECHAT_MINIPROGRAM_APP_SECRET`；模板只保留空占位符，绝不把 AppSecret 写进仓库。

## 生活缴费（宿舍绑定）

**首页**有一个「水电余额」模块，直接展示电费 / 冷水 / 热水；**生活缴费页**支持在**小程序内直接绑定宿舍**，不再要求用户先去 App 或 Web 端：

1. 未绑定时首页提示去「生活缴费」绑定；生活缴费页显示「绑定宿舍」按钮（已绑定时显示「重新绑定宿舍」）。
2. 点开后输入楼栋/房间号关键词（如 `A2-932`）搜索 —— 后端全量约 6700 条（~880KB），**必须带关键词**，不能拉全量。
3. 在结果里点「绑定」，成功后就地展示水电余额，首页模块同步更新。

绑定**只写我们自己的库**（`EcardBinding`），随后读上游余额；不向学校系统写入任何东西，改绑只是改一行。

> 设计要点：首页的水电模块**独立加载、独立结算**。它依赖第三方一卡通服务，是最容易失败的一个；
> 若并进核心数据的 `Promise.all`，一次水电接口失败会把整个首页打成错误页。
> 现在的行为是水电卡片内提示失败，近期课程/考试提醒照常渲染——有专门的页面回归用例守着这条。

注意两点：

- **演示账号无法绑定**：写操作被服务端中间件拦截（403「演示账号仅支持查看」），所以绑定流程只能靠页面回归（mock）验证；
- 真实账号查询宿舍需要服务端配置 `ECARD_OPENID` / `ECARD_SECRET`，缺失时会报 `未配置 ECARD_OPENID`。

## 本地运行

构建与测试脚本使用 Node.js 20 或更新的稳定版本。

1. 在微信开发者工具中导入此目录。
2. 当前仓库已配置正式 AppID `wx2fb65b853ae73231`（原始 ID `gh_a0c613258490`，已备案）；如使用其他 AppID，只修改 `project.config.json`，不要在前端配置 AppSecret。
3. 开发者工具「设置 → 安全设置」开启服务端口（页面回归与自动预览都需要）。
4. 启动 `services/api`（测试环境见仓库 `deploy/tencent/TEST_ENV.md`）。

## 测试

```bash
npm install
npm test              # typecheck + 逻辑单测（可在 CI 跑）
npm run test:pages    # 开发者工具页面回归（全程 mock 请求，需开发者工具已登录）
npm run test:live     # 真实链路检查（不 mock，打测试域名真实接口，需测试账号）
npm run test:all      # test + test:pages
npm run auto-preview  # CLI 自动预览，推送真机验收包
```

- **逻辑单测**（`tests/`）：`utils/` 用 `tsc` 编译到 `.test-build/` 后用 Node 内置 `node:test` 运行，不引入测试框架依赖。覆盖解析器字段校验与凭据过滤、学期偏好、单双周/日期换算/冲突排版、`envVersion` 分流、请求层 401/结构化错误/网络失败、`requireSession`。
- **页面回归**（`scripts/page-regression.js`）：通过 `miniprogram-automator` 连接开发者工具，全程 mock `wx.request`，因此不需要演示账号密码，日志里也不会出现真实凭据。覆盖空输入、错误密码、登录、七个页面加载、学期选择器、周课表/周次选择/课程详情、微信绑定/解绑、未绑定微信引导、401 清理会话、下拉刷新、退出登录、5xx 错误态、无会话跳转。
- **真实链路**（`scripts/live-api-check.js`）：**不 mock** 任何请求，用真实账号打测试域名真实接口，验证「开发者工具 → test-api.onrein.top → nginx → FastAPI → 学校 CAS」整条链路。它是 **request 合法域名白名单** 的第一道验证：白名单没配好会直接报 `url not in domain list`，脚本会识别并给出提示。
  两种断言档位（`MINI_EXPECT`）：
  - `demo`（默认）——数据是固定 fixture，可断言具体数值（7 门课、5 条成绩…）；
  - `real`——真实学生账号，数据不可预知，只做结构性断言：能登录、页面加载完、无错误态、**不卡在空白**（必须看到数据或页面显式空态）、本地无凭据落盘。会打印实际观测到的条数作为证据。

  ```bash
  # 演示账号
  MINI_EXPECT=demo MINI_TEST_ACCOUNT=<账号> MINI_TEST_PASSWORD=<密码> npm run test:live
  # 真实学生账号（注意：真实账号连续登录失败可能触发学校侧锁定，不要反复重试）
  MINI_EXPECT=real MINI_TEST_ACCOUNT=<学号> MINI_TEST_PASSWORD=<密码> npm run test:live
  ```
- 失败现场（截图 + 控制台日志）默认写到项目目录**之外**的 `../onegzus-miniprogram-test-artifacts/`。**不要改回项目内**：开发者工具监听项目目录，往项目里写文件会触发重新编译，AppService 重载后注入的 mock 失效，回归会成片假失败。可用 `WECHAT_TEST_ARTIFACT_DIR` 覆盖。

> 踩坑记录：**不要在没装 mock 的情况下调用 `restoreWxMethod('request')`** —— 实测会把 `wx.request` 弄成非函数，之后所有真实请求都报 `wx.request is not a function`。真实链路脚本因此改为直接检查 `typeof wx.request`。若已进入该状态，关闭项目窗口后重开即可恢复。

环境变量：

| 变量                          | 用途                        | 默认值                                      |
| --------------------------- | ------------------------- | ---------------------------------------- |
| `WECHAT_DEVTOOLS_CLI`       | 开发者工具 CLI 路径              | macOS `/Applications/wechatwebdevtools.app/Contents/MacOS/cli` |
| `WECHAT_AUTO_PORT`          | 自动化端口                     | `9420`                                   |
| `WECHAT_TEST_ARTIFACT_DIR`  | 失败现场与预览信息输出目录             | `<project>/../onegzus-miniprogram-test-artifacts` |

## 安全边界

小程序只保存 `sessionId`、展示身份字段、学期偏好及已同意的协议版本。`/mini/auth/login` 与 `/mini/auth/wechat-login` 只返回短期会话信息，会过滤学校 Cookie、办事大厅 Token 和长期自动登录凭据；不要改为调用通用 `/auth/auto-login`。微信 OpenID 服务端只保存不可逆查询指纹与加密原值，微信 code、OpenID、`session_key`、AppSecret 不写日志。

请求层只在**携带过会话**的 401 上清理本地会话；登录接口自身返回的 401 属于凭据错误，本地没有需要清理的会话。错误文案优先透传服务端 `detail`（能区分「账号或密码错误」「会话已过期」「当前设备已被管理员下线」），仅在缺少 `detail` 时按是否携带会话兜底。

小程序推送订阅、附件上传、自动请假与 FTP 不属于此 MVP，需在完成主体、域名与隐私合规配置后再接入。
