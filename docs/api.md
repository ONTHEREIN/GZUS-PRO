# API 概览

本文档记录软帮手后端当前公开给客户端使用的主要接口。实际字段以 `services/api/app/schemas.py`、路由代码和 OpenAPI 输出为准。

生产入口为 `https://onegzus.onrein.top/api`。除公开内容、天气和认证初始化接口外，接口通常使用 `X-Session-Id` 请求头传递应用会话；WebSocket 通知使用 `/ws/notifications?sessionId=...`。

## Auth

### `GET /auth/public-key`

获取账号密码登录所需的 RSA 公钥信息。客户端使用公钥加密密码后再提交；服务端仍支持兼容旧客户端的 `password` 字段，但生产环境必须通过 HTTPS 访问。

### `POST /auth/auto-login`

账号密码登录并建立应用会话。典型请求：

```json
{"account":"20240000","password":"<password>"}
```

成功响应包含 `sessionId`、学生身份信息和用于后续自动登录的 `credentialToken`。`credentialToken` 是敏感凭据，只能存储在客户端安全存储中，不能写入日志或展示给用户。

学校认证所需的验证码由后端登录流程按上游要求处理；验证码内容和临时 token 不会作为普通业务数据持久化。

### `GET /auth/ly/start` / `GET /auth/ly/callback`

发起办事大厅统一登录并处理 CAS 回调。后端生成短期 `state`，校验 CAS ticket 后换取教务会话。

### `POST /auth/ly/native-start` / `POST /auth/ly/native-complete`

移动端原生 SSO 的 PKCE 启动和完成接口。

### `POST /auth/ly/complete`

完成 Web SSO 回调：

```json
{"ssoCode":"<one-time-code>"}
```

`ssoCode` 只能使用一次，并在短期内失效。

### `POST /auth/relogin`

使用客户端安全存储的 `credentialToken` 恢复登录。令牌过期、撤销或与当前账号不匹配时必须重新登录。

### `POST /auth/logout`

撤销当前应用会话并清理服务端会话资源。客户端还应删除本机凭据、缓存和推送注册；后台持续通知授权需要通过 `PUT /notifications/background` 关闭。

## Academic

- `GET /me`：当前学生信息。
- `GET /auth/student-info`：登录后补充学生信息和头像的入口。
- `GET /schedule?year=2026&term=1`：课表。
- `GET /exams?year=2026&term=1`：考试安排。
- `GET /grades?year=2026&term=1`：成绩。
- `GET /attendance?year=2026&term=1`：考勤汇总。
- `GET /attendance/details?year=2026&term=1`：考勤明细。
- `GET /credits`：学分统计。
- `GET /notices`、`GET /notices/detail`：通知列表和详情。
- `GET /dashboard`：首页聚合数据。
- `GET /widget-snapshot`：Android/iOS 桌面组件刷新所需的最小数据快照。

部分接口优先使用学校 SDK 能力，缺失的页面通过已登录学校会话的 `proxy_request` 补齐；失败时可能返回带来源和时间的缓存数据。

## Ehall 与业务

- `GET /ehall/tasks`、`/affairs`、`/applications`、`/progress`：办事大厅通知、事项、应用和进度。
- `GET /ehall/leave/teachers/search`：教师查找。
- `POST /ehall/leave/preview`：预览请假表单。
- `POST /ehall/leave/fill`：填写请假表单。
- `POST /ehall/leave/attachment`：上传请假附件。
- `POST /feedback`：提交反馈工单，可包含联系方式、客户端诊断日志和附件；单个请求附件总大小上限为 6 MB。

请假接口只处理当前登录账号主动发起的业务；附件名、类型、大小和 Base64 内容会在服务端校验。

## Ecard 与天气

- `GET /ecard/rooms`：获取可选择的宿舍列表，不返回余额。
- `POST /ecard/binding`：绑定当前账号选择的宿舍。
- `GET /ecard/summary`、`POST /ecard/refresh`：读取或刷新电费、冷水、热水摘要。
- `PATCH /ecard/reminder`：设置低余额提醒。
- `GET /ecard/consumption`、`GET /ecard/consumption/overview`：一卡通消费明细和统计。
- `GET /weather`：按默认城市或经纬度查询天气；客户端仅在用户授权位置后提供近似位置。

融校云的 `openid`/`unionid` 和服务端凭据只存在于后端配置，不能返回给客户端。

## Settings 与本地调课

- `GET /settings/schedule`：读取账号级课表偏好。
- `PUT /settings/schedule`：保存学期第一周、自动周次、引导状态和课表显示偏好。
- `GET /settings/schedule/adjustments`：读取本地调课同步记录。
- `POST /settings/schedule/adjustments`：创建调课记录。
- `PATCH /settings/schedule/adjustments/{client_id}`：更新调课记录。
- `POST /settings/schedule/adjustments/{client_id}/restore`：恢复调课记录。

## Notifications 与 Push

### 动态通知

- `GET /notifications/events`：读取当前账号最近的通知中心事件。
- `GET /notifications/events/pending`：读取当前安装实例尚未展示的事件，需要 `X-Installation-Id`。
- `POST /notifications/events/{event_id}/presented`：记录已展示。
- `POST /notifications/events/{event_id}/read`：标记已读。

### 后台持续通知

- `GET /notifications/background`：读取后台通知授权状态。
- `PUT /notifications/background`：开启或关闭后台持续通知；开启时需要最新的 `credentialToken`。
- `PUT /notifications/course-reminders`：同步课程提醒计划。
- `PATCH /notifications/preferences`：设置通知类别（通知、成绩、考试、考勤）。

### 设备推送注册

- `GET /push/web/config`、`POST /push/web/register`、`POST /push/web/unregister`：Web Push。
- `POST /push/ios/register`、`POST /push/ios/unregister`：iOS APNs。
- `POST /push/ios/course-schedule`：同步 iOS 本地课程提醒计划。
- `POST /push/ios/live-activity-tokens` 及注销接口：iOS Live Activities 令牌。

推送令牌只用于向对应账号和安装实例投递通知；登出、取消授权或令牌失效时应注销。

## 公开内容

- `GET /content/login-slides`：登录页公开轮播配置。
- `GET /content/login-slides/{slide_id}/image`：登录页图片资源。

管理后台还提供通知、公众号文章、登录轮播、Shiply 资源和运维接口；这些接口不属于普通客户端 API，必须使用管理员会话，并遵守内部审计和权限约束。

## 健康检查

- `GET /health`：基础存活检查。
- `GET /health/ready`：数据库和服务就绪检查。

内部 cron 接口只监听服务器本机并要求 `X-Internal-Key`，不会通过公开 Nginx 路由暴露。
