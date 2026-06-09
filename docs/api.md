# API

所有接口默认使用 `X-Session-Id` 请求头传递应用会话。后端只保存学校系统会话，不保存明文密码。

## Auth

### `POST /auth/login`

Request:

```json
{"account":"20240000","password":"<password>"}
```

Response:

```json
{"status":"ok","sessionId":"...","studentName":"张三"}
```

需要验证码时：

```json
{"status":"captcha_required","captchaToken":"...","captchaImage":"data:image/png;base64,..."}
```

### `POST /auth/captcha`

Request:

```json
{"captchaToken":"...","code":"abcd"}
```

### `GET /auth/ly/start`

发起联奕科技单点登录。后端生成短期 `state` 后跳转到 CAS 登录页。

可选 Query：

- `return_url`：登录完成后允许回跳的前端地址，仅接受 `FRONTEND_BASE_URL` 同源地址。

### `GET /auth/ly/callback`

CAS 回调接口。后端校验 CAS ticket，换取 JWXT ProxyTicket，请求教务 SSO 并捕获教务 cookie。

成功后重定向到前端并携带一次性 `ssoCode`；失败时携带 `ssoError`。

### `POST /auth/ly/complete`

Request:

```json
{"ssoCode":"..."}
```

Response:

```json
{"status":"ok","sessionId":"...","studentName":"张三"}
```

`ssoCode` 只能使用一次，过期或重复提交会返回 400。

### `POST /auth/logout`

销毁应用会话和服务端学校系统 cookies。

## Academic

- `GET /me`
- `GET /schedule?year=2025&term=1`
- `GET /exams?year=2025&term=1`
- `GET /grades?year=2025&term=1`
- `GET /attendance?year=2025&term=1`
- `GET /credits`
- `GET /notices`

`exams`、`attendance`、`credits`、`notices` 使用 `school-sdk` 登录后的 `proxy_request` 补齐。`notices` 会读取教务首页通知/消息区，并在存在“更多”入口时继续抓取列表页。

## Ecard

后端通过环境变量 `ECARD_OPENID` / `ECARD_UNIONID` 调用融校云接口；前端不会接触或展示这些值。

- `GET /ecard/rooms`：宿舍选择列表，仅返回校区、楼栋、房号，不返回余额。
- `POST /ecard/binding`：绑定当前登录学号的宿舍。
- `GET /ecard/summary`：当前绑定宿舍的电费、冷水、热水余额。
- `POST /ecard/refresh`：立即刷新余额。
- `PATCH /ecard/reminder`：设置每日提醒开关和低电阈值。
- `GET /ecard/consumption`：一卡通消费记录；接口受限时返回 `status=limited`。
