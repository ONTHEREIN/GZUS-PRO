# Privacy

- 后端不持久化账号密码。
- 学校系统 cookies 只保存在服务端内存会话中。
- 联奕单点登录流程中，CAS ticket、ProxyTicket、JWXT cookie 和一次性 `ssoCode` 不写入前端持久化存储。
- 移动端 WebView 单点登录只把教务 cookie 发送给后端换取本系统会话；登录完成后清理 WebView cookie。
- 前端只保存本系统 `sessionId` 和展示用学生姓名，用于刷新页面后恢复登录态。
- 日志不得输出密码、cookies、验证码 token。
- 默认不实现“记住密码”。
- 真实账号测试不得写入仓库、测试快照或日志。
