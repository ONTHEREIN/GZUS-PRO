# 修复与验收范围

验收日期：2026-09-30。范围为当前未提交工作树中已完成的审计修复；完成桌面组件后台调课同步后暂停，不继续扩大审计范围。尚未提交或部署这些修复。已有暂存改动及其他 UI 改动保持原状，不把整个工作树 diff 都算作本次审计成果。

目前的结论是：下述自动化检查覆盖的路径没有发现未解决的新增回归。测试通过不代表所有模块、学校接口、生产环境和真实设备都已经完整验收。

## 已修复的问题与涉及模块

| 范围 | 已修复的问题及当前行为 | 主要代码模块 | 验证依据 |
| --- | --- | --- | --- |
| 登录、凭据、会话 | 退出或管理员下线后撤销恢复凭据，过期会话也不能绕过撤销；处理同账号会话更新与撤销竞争；SSO 支持受约束的恢复令牌；SSO 与小程序登录限流；生产返回地址收紧；登录密码加密失败明确终止；CAS ticket 日志脱敏；账号切换清理旧身份状态 | API `routes/auth.py`、`routes/deps.py`、`routes/mini_program.py`、`sessions.py`、`school_session_service.py`、`cas_auto_login.py`；Flutter `api_client.dart`、`auth_storage.dart`、登录页与导航壳 | `test_auth.py`、`test_sessions.py`、`test_school_session_service.py`、`test_cas_auto_login.py`、`test_mini_program.py`；Flutter 凭据与登录测试 |
| WebSocket、推送、后台通知、实况 | 旧连接不能清理新连接；注销关闭连接并丢弃待发数据；Web Push 校验目标与密钥、限制外部请求并禁止重定向；推送令牌绑定会话/凭据，撤销旧绑定不会误删转移后的新绑定；通知 claim 防止多设备重复展示并支持到期接管；实况到期结束与失败重试；撤销会话停止后台通知；初始化保留通知点击回调，课程提醒失败仍可重试 | API `ws.py`、`push.py`、`cloud_notifications.py`、`apns_service.py`、`jobs.py`、通知与推送路由；Flutter `ws_service.dart`、后台/实况/通知/提醒服务、`web/gzus_pwa.js`；Android 后台与提醒模块 | 后端 WebSocket、推送、后台通知测试；Flutter 实况、通知初始化、课程提醒同步测试；Android `LiveUpdatePayloadTest` |
| 课表与日期调课 | 本地规则、快照、离线队列按账号和学期隔离；上传确认只删除已上传版本，保留并发新增与撤回；撤回使用修订号，冲突明确处理；无账号归属的旧记录需用户确认导入；首页、请假、提醒使用具体日期生效实例；空生效列表不会退回原课；修复跨周下一节课及课程身份/元数据传递 | Flutter `models/schedule_override.dart`、`schedule_adjustment_sync.dart`、课表/首页/请假页面、提醒服务；API 请假路由与数据模型 | `schedule_adjustment_sync_test.dart`、`home_schedule_sync_test.dart`、`course_reminder_sync_test.dart`、`leave_effective_schedule_test.dart`；后端教务与请假测试 |
| 桌面组件 | 前台编辑课表更新组件上下文；后台读取最新云端调课，叠加本机规则与待同步操作；已确认或较新的云端修订优先于旧队列缓存；Android/iOS 都按具体日期计算今日、本周、下一节课，304 和跨日重新投影，旧课程不会在下一周重复；组件周课表使用实际本周；配置 generation 与锁阻止旧成功/401 响应写入或清除新账号；退出清除缓存；组件同步失败不阻塞课表页面并显示原因 | API `widget_schedule.py`、`routes/academic.py`；Flutter `widget_schedule_bridge.dart`、首页与课表页；Android `WidgetRefreshWorker.kt`、`WidgetEffectiveSchedule.kt`、`WidgetRefreshTransactions.kt`、`MainActivity.kt`、`HomeWidgetProvider.kt`；iOS `WidgetSnapshotStore.swift`、`AppDelegate.swift`、`OneGzusWidgets.swift` | 后端 `test_widget_snapshot.py`；Flutter 组件桥接、首页与调课测试；Android 日期投影与会话事务测试；iOS RunnerTests |
| 请假 | 修复生效实例模型转换错误；显式空列表具有权威性；保留学校填表所需原始字段；没有匹配课程时明确报错；限制原始课表展开至 30 周并防日期溢出；超大附件提前拒绝 | API `leave_service.py`、`schemas.py`、`routes/ehall.py`；Flutter `pages/leave/auto_leave_page.dart` | 请假预览、边界与接口测试；Flutter 生效课程传递测试。未向学校提交真实请假 |
| 首页成绩与考试 | 缓存按账号/学期隔离；旧异步结果不写入新账号，不保留旧卡片；刷新失败明确展示错误 | Flutter 首页、`api_client.dart`、相关模型 | `home_schedule_sync_test.dart`、首页与缓存测试。覆盖缓存及展示边界，不等于成绩/考试业务全部审计 |
| 一卡通、水电费与提醒 | 共享 token 只保留在进程内，清理旧明文数据库 token；过期刷新与并发失效处理不会清除新 token；避免写入共享余额历史；提醒时间校验与重启调度；生产验证 TLS | API `ecard_client.py`、`routes/ecard.py`、`jobs.py`、`database.py`、配置 | `test_ecard.py`、配置及后台任务测试。未进行真实充值或缴费 |
| 管理后台、内容、公众号与天气 | 未发布通知图片只能通过管理员预览；限制图片 MIME 类型并验证返回图片的 base64；反馈列表不读取全部大附件；公众号文章/封面请求限制可信地址与重定向；天气增加限流与缓存容量限制 | API 管理、内容、天气路由，`image_media.py`、`wechat_service.py`、`shiply_content.py`；Flutter 管理反馈与通知页面 | 管理员、通知图片、反馈、轮播图、公众号、天气测试。只覆盖这些边界 |
| 数据库、服务就绪与部署检查 | readiness 检查模型所需表和列；生产迁移限制锁等待与语句时间；测试内存 SQLite 使用独立连接并串行化连接使用；后台轮询故障使 ready 失败；生产配置 preflight；发布脚本在数据库备份后检查候选版本再激活；部署验证改用 ready 并按 range 检查大 WASM；生产禁止 demo、HTTP ehall 和关闭一卡通 TLS 校验 | API `database.py`、`config.py`、`main.py`、`deployment_preflight.py`；API CI；腾讯云部署脚本与环境模板 | 数据库、配置、ready、preflight 测试；部署脚本语法检查。未执行真实生产迁移或发布 |

## 桌面组件的兼容与验收边界

- 新客户端使用只读 `POST /widget-snapshot` 和 `dated-v1` 课表协议；原 `GET /widget-snapshot` 保留，供旧客户端使用。POST 不保存设备规则，也不向学校写入数据。
- 新客户端后台同步依赖新 API，交付时需要先部署兼容 POST 的后端，再发布客户端。本次没有部署，因此线上不会自动获得这些修复。
- 原生旧配置没有新课表上下文时，需要登录后返回首页刷新配置。课表页在配置未就绪时显示明确提示。
- 后端课表展开与 Flutter 的周次分段、单双周、停课、替换、新增、连续移动及冲突替换规则对齐；课程保留具体日期和实例编号。
- iOS 先按当天重新投影缓存，再尝试联网；下一节组件申请约 30 分钟后的时间线刷新。操作系统调度频率、锁屏表现及后台保活仍需真机验收。
- 学校课表字段异常返回可序列化的 502；无效日期、重复调课编号、跨学期队列返回 422；未登录返回 401；失败不会伪造为空课表。

## 最终回归检查

| 检查 | 结果 | 证据 |
| --- | --- | --- |
| 后端全量 pytest | 464 项通过 | `/tmp/gzus-final-api.log`；内存 SQLite，与仓库既有测试策略一致 |
| 后端 Ruff | 通过 | `.venv/bin/python -m ruff check .` |
| Flutter 全量测试 | 253 项通过 | `/tmp/gzus-final-flutter.log` |
| Flutter analyze | 无问题 | `/tmp/gzus-final-analyze.log` |
| Android Kotlin 编译与原生测试 | 编译成功，13 项通过，0 失败 | `/tmp/gzus-final-android.log`；`WidgetEffectiveScheduleTest` 3 项、`WidgetRefreshTransactionsTest` 3 项、`LiveUpdatePayloadTest` 6 项、`WidgetLayoutTest` 1 项 |
| iOS 模拟器 RunnerTests | 8 项通过，0 失败，编译成功 | `/tmp/gzus-final-ios.log`；包含 Runner 与 Widget 扩展构建 |
| 部署脚本语法 | 通过 | `bash -n` 检查 `activate_release.sh` 与 `verify.sh` |
| Web 推送脚本语法 | 通过 | 使用 Codex 内置 Node 运行 `node --check apps/mobile_web/web/gzus_pwa.js` |
| Diff 空白检查 | 通过 | `git diff --check` |

测试过程暴露的课表等待原生通道、旧加载副作用和测试计时器问题已处理，最终 Flutter 全量检查通过。自动化用例使用仓库既有学校接口替身与原生通道测试环境；它们可以验证逻辑、隔离与错误边界，不能替代真实学校服务与真机端到端验收。依赖弃用提示、Flutter 插件尚未支持 SPM 的提示及模拟器环境诊断仍存在；不把这些提示当作测试失败，也不宣称依赖兼容性已经全面检查。

日志位于本机临时目录，可能被系统清理；保留测试代码与命令作为可重跑依据。

## 尚未涉及或未完成验收的范围

这里区分“未做专项修复”与“共享逻辑已改，但业务全流程未验收”。未覆盖不代表已确认存在漏洞。

| 范围 | 当前覆盖状态 | 尚缺的验证 |
| --- | --- | --- |
| FTP 作业上传 | 未做专项源码修复或业务审计 | 上传、覆盖、编码、失败恢复与权限的真实流程 |
| 教职工查询、同步 | 未做专项源码修复或完整审计 | 真实数据同步、分页、权限及学校异常响应 |
| 静态介绍网站 `website/` | 未做专项源码修复或审计 | 页面、链接、可访问性与发布验证 |
| 微信小程序前端 | 前端未做完整专项修复；后端共享登录/鉴权有改动 | 小程序从登录到各业务页的端到端验收 |
| 学分、考勤、通知详情、个人信息、应用与办事业务 | 共享会话、API 或后台通知链路有改动，默认测试通过 | 各业务字段和学校语义、全部详情、分页及异常状态的完整审计 |
| 成绩、考试 | 首页隔离与展示边界已修复 | 各详情页、统计计算、历史学期与学校数据的完整语义验收 |
| 管理后台 CRUD、公众号同步 | 已修复撤销、图片、附件及外部请求边界 | 所有角色操作、后台增删改查、真实 RSS/合集同步全流程 |
| 学校写操作 | 本次未执行 | 请假提交、审批、充值/缴费等真实业务验收 |
| 真机通知与组件 | 已做逻辑测试、Android 编译及 iOS 模拟器测试 | Android/iOS 真机推送、后台保活、跨日刷新、桌面组件点击与锁屏实况 |
| PostgreSQL 生产行为 | 代码检查及 SQLite 测试已覆盖部分逻辑；本机未运行真实 PostgreSQL | 多进程并发、锁与迁移、撤销/claim 竞争的真实 PG 验证；SQLite 串行测试不能代替它 |
| 生产部署、备份恢复 | 检查代码与脚本已修复；未发布 | 真实候选部署、迁移失败回退、数据库备份恢复与上线后的业务闭环 |

当前没有在已执行回归中发现未解决的新增问题；上述未验收范围保持明确标记。后续继续审计时，应从这些边界恢复，而不是把当前测试结果解释为整个产品已完成安全与业务验收。
