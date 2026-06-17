# 第5章 API 接口设计

> 软帮手（OneGZUS）软件设计文档  
> 版本：1.0  
> 最后更新：2026-06-17

---

## 目录

- [5.1 API 设计原则](#51-api-设计原则)
- [5.2 认证接口](#52-认证接口-auth)
- [5.3 教务接口](#53-教务接口-academic)
- [5.4 一站式服务接口](#54-一站式服务接口-ehall)
- [5.5 一卡通接口](#55-一卡通接口-ecard)
- [5.6 推送接口](#56-推送接口-push)
- [5.7 天气接口](#57-天气接口-weather)
- [5.8 内部接口](#58-内部接口-internal)
- [5.9 WebSocket 接口](#59-websocket-接口)
- [5.10 健康检查](#510-健康检查)
- [5.11 错误处理与状态码](#511-错误处理与状态码)

---

## 5.1 API 设计原则

### 5.1.1 RESTful 风格

后端 API 遵循 RESTful 设计规范：

| 原则 | 实践 |
|------|------|
| 资源化 URL | 使用名词表示资源（如 `/me`、`/schedule`、`/ecard/rooms`） |
| HTTP 方法语义 | `GET` 查询、`POST` 创建/提交、`PATCH` 部分更新 |
| 查询参数过滤 | 列表接口通过查询参数筛选（如 `?year=2025&term=1`） |
| 嵌套资源 | 子资源通过路径嵌套（如 `/ehall/leave/preview`） |
| 统一前缀 | 各模块使用独立前缀（`/auth`、`/ehall`、`/ecard`、`/push`、`/weather`、`/internal`） |

### 5.1.2 统一响应格式

所有接口使用 JSON 响应体。成功响应直接返回数据模型或包含 `status` 字段的状态对象：

**列表响应**（直接返回数组）：
```json
[
  {"courseName": "高等数学", "score": "90", "credit": "4.0"},
  {"courseName": "大学英语", "score": "85", "credit": "3.0"}
]
```

**状态对象响应**（含 `status` 字段）：
```json
{
  "status": "ok",
  "sessionId": "a1b2c3d4...",
  "studentName": "张三"
}
```

**缓存降级响应**（教务接口在会话过期时返回缓存数据，附带额外响应头）：
```
HTTP/1.1 200 OK
X-Data-Source: cache
X-Data-Cached-At: 2026-06-17T08:30:00
```

**错误响应**（统一 `detail` 字段）：
```json
{
  "detail": "会话已过期，请重新登录"
}
```

### 5.1.3 错误处理策略

| 层级 | 处理方式 |
|------|----------|
| Pydantic 校验 | FastAPI 自动返回 422，包含字段级错误详情 |
| 业务异常 | 抛出 `HTTPException`，携带中文 `detail` 消息 |
| 认证异常 | `AuthenticationError` → 401，触发前端自动重登录 |
| 功能未实现 | `MissingProxySlotError` → 501，表示该功能需 Worker 代理 |
| 外部服务异常 | 一卡通 API 错误 → 502/503，区分配置错误与运行时错误 |
| 全局兜底 | `global_exception_handler` 捕获所有未处理异常 → 500，记录完整堆栈 |

### 5.1.4 认证机制

所有需要认证的接口通过 `X-Session-Id` 请求头传递应用会话标识：

```
X-Session-Id: a1b2c3d4e5f6...
```

**会话解析流程**（`require_session` 依赖注入）：

1. 从 `X-Session-Id` 头提取会话 ID
2. 从 PostgreSQL（`app_sessions` 表）加载会话记录
3. 注入 Cloudflare Worker 传递的新鲜 Cookie（通过 `X-Worker-Auth` + `Cookie` 头）
4. 若 Worker 未注入 Cookie 且会话空闲超过 25 分钟 → 返回 401
5. 更新 `last_active_at` 时间戳（滑动 TTL）

**单设备登录**：同一学号新会话创建时，旧会话自动标记为 `revoked`（`revoked_reason: "single_device_login"`），后续请求返回 401。

---

## 5.2 认证接口 (`/auth`)

路由前缀：`/auth`  
标签：`auth`  
速率限制：登录类接口 `10/minute`

### 5.2.1 GET /auth/public-key

获取 RSA 公钥，用于前端加密密码后传输。

| 项目 | 说明 |
|------|------|
| 认证 | 无需认证 |
| 速率限制 | 无 |

**请求参数**：无

**响应格式**：

```json
{
  "publicKey": "-----BEGIN PUBLIC KEY-----\nMIIBIjANBgkq...\n-----END PUBLIC KEY-----",
  "keyId": "k1a2b3c4"
}
```

| 字段 | 类型 | 说明 |
|------|------|------|
| `publicKey` | `string` | PEM 格式 RSA 公钥 |
| `keyId` | `string` | 密钥标识，用于后续解密时匹配密钥版本 |

**错误情况**：无（公钥始终可获取）

---

### 5.2.2 POST /auth/login

账号密码登录，支持明文密码或 RSA 加密密码。

| 项目 | 说明 |
|------|------|
| 认证 | 无需认证 |
| 速率限制 | `10/minute` |

**请求体**（`LoginRequest`）：

```json
{
  "account": "2023001001",
  "password": "plaintext_password",
  "encryptedPassword": "RSA_encrypted_base64",
  "keyId": "k1a2b3c4"
}
```

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `account` | `string` | 是 | 学号，最小长度 1 |
| `password` | `string \| null` | 否* | 明文密码 |
| `encryptedPassword` | `string \| null` | 否* | RSA 加密后的 Base64 密码 |
| `keyId` | `string \| null` | 否 | 加密使用的密钥 ID |

> *`password` 和 `encryptedPassword` 二选一，必须提供其中一个。

**响应格式**（`AuthResponse`）：

登录成功：
```json
{
  "status": "ok",
  "sessionId": "a1b2c3d4e5f6...",
  "studentName": "张三",
  "studentId": null
}
```

需要验证码：
```json
{
  "status": "captcha_required",
  "captchaToken": "token_abc123",
  "captchaImage": "data:image/png;base64,..."
}
```

| 字段 | 类型 | 说明 |
|------|------|------|
| `status` | `"ok" \| "captcha_required"` | 登录状态 |
| `sessionId` | `string \| null` | 会话 ID（仅 `ok` 状态返回） |
| `studentName` | `string \| null` | 学生姓名 |
| `studentId` | `string \| null` | 学生学号（登录时通常为 null，需后续获取） |
| `captchaToken` | `string \| null` | 验证码令牌（仅 `captcha_required` 状态） |
| `captchaImage` | `string \| null` | 验证码图片 Base64（仅 `captcha_required` 状态） |
| `credentialToken` | `string \| null` | 凭证令牌（用于自动重登录） |
| `ehallCookies` | `string \| null` | 一站式服务 Cookie |
| `ehallAuthToken` | `string \| null` | 一站式服务认证令牌 |

**错误情况**：

| 状态码 | 条件 | detail |
|--------|------|--------|
| 400 | 未提供密码或密码解密失败 | `"必须提供 password 或 encryptedPassword"` / `"密码解密失败，请重新登录"` |
| 401 | 账号或密码错误 | `"用户名或密码错误"` |

---

### 5.2.3 POST /auth/captcha

提交验证码以完成登录流程。

| 项目 | 说明 |
|------|------|
| 认证 | 无需认证 |
| 速率限制 | `10/minute` |

**请求体**（`CaptchaRequest`）：

```json
{
  "captchaToken": "token_abc123",
  "code": "a3b7"
}
```

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `captchaToken` | `string` | 是 | 登录时返回的验证码令牌 |
| `code` | `string` | 是 | 用户输入的验证码 |

**响应格式**（`AuthResponse`）：

```json
{
  "status": "ok",
  "sessionId": "a1b2c3d4e5f6...",
  "studentName": "张三",
  "studentId": null
}
```

**错误情况**：

| 状态码 | 条件 | detail |
|--------|------|--------|
| 400 | 验证码令牌已过期 | `"验证码会话已过期"` |
| 401 | 验证码错误 | `"验证码错误"` |

---

### 5.2.4 GET /auth/ly/start

发起联奕（CAS）SSO 登录流程，重定向到 CAS 登录页面。

| 项目 | 说明 |
|------|------|
| 认证 | 无需认证 |

**请求参数**：

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `return_url` | `string` | 否 | 登录成功后的回调 URL，默认为前端首页 |

**响应**：`302 Redirect` → CAS 登录页面 URL

```
Location: https://cas.gzus.edu.cn/lyuapServer/login?service=...&state=...
```

**安全校验**：`return_url` 必须与 `FRONTEND_BASE_URL` 同源或为 `localhost`，否则回退到前端首页。

---

### 5.2.5 GET /auth/ly/callback

CAS 认证回调，CAS 认证成功后回调此接口。

| 项目 | 说明 |
|------|------|
| 认证 | 无需认证 |

**请求参数**：

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `ticket` | `string` | 是 | CAS Service Ticket |
| `state` | `string` | 是 | SSO 状态标识（防 CSRF） |

**响应**：`302 Redirect` → `return_url`（附带 state 对应的回调地址）

**错误情况**：

| 状态码 | 条件 | detail |
|--------|------|--------|
| 400 | 缺少 ticket | `"缺少 ticket"` |
| 400 | state 无效 | `"SSO state 无效"` |

---

### 5.2.6 POST /auth/ly/complete

完成 SSO 登录，使用 CAS Service Ticket 兑换教务系统会话。

| 项目 | 说明 |
|------|------|
| 认证 | 无需认证 |

**请求体**（`SsoCompleteRequest`）：

```json
{
  "ssoCode": "ST-12345-abcdef-cas"
}
```

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `ssoCode` | `string` | 是 | CAS Service Ticket |

**响应格式**（`AuthResponse`）：

```json
{
  "status": "ok",
  "sessionId": "a1b2c3d4e5f6...",
  "studentName": "张三",
  "studentId": null
}
```

**内部流程**：
1. 使用 Ticket 请求教务系统 SSO 入口，获取 JWXT Cookie
2. 使用 Cookie 创建 `SchoolSdkClient` 并验证身份
3. 创建应用会话并返回

**错误情况**：

| 状态码 | 条件 | detail |
|--------|------|--------|
| 400 | 缺少 SSO 凭证 | `"缺少 SSO 凭证"` |
| 401 | Ticket 兑换失败 | `"SSO 凭证兑换失败，请重新登录"` |
| 401 | 未获取到教务系统会话 | `"SSO 登录未获取到教务系统会话"` |

---

### 5.2.7 POST /auth/auto-login

自动登录（CAS SSO 流程），同时获取教务系统和一站式服务会话。

| 项目 | 说明 |
|------|------|
| 认证 | 无需认证 |
| 速率限制 | `10/minute` |
| Worker 边缘处理 | 是（Worker 在边缘节点拦截并处理） |

**请求体**（`AutoLoginRequest`）：

```json
{
  "account": "2023001001",
  "password": "plaintext_password",
  "encryptedPassword": "RSA_encrypted_base64",
  "keyId": "k1a2b3c4"
}
```

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `account` | `string` | 是 | 学号 |
| `password` | `string \| null` | 否* | 明文密码 |
| `encryptedPassword` | `string \| null` | 否* | RSA 加密密码 |
| `keyId` | `string \| null` | 否 | 密钥 ID |

**响应格式**（`AuthResponse`）：

```json
{
  "status": "ok",
  "sessionId": "a1b2c3d4e5f6...",
  "studentName": "张三",
  "studentId": null,
  "credentialToken": "Fernet_encrypted_token...",
  "ehallCookies": "cookie_string",
  "ehallAuthToken": "auth_token_string"
}
```

**内部流程**：
1. 解密密码（若使用加密密码）
2. 通过 `CasAutoLogin` 执行 CAS SSO 自动登录
3. 获取 JWXT Cookie + ehall Cookie/AuthToken
4. 创建 `SchoolSdkClient` 和 `EhallClient`
5. 使用 Fernet 加密凭证生成 `credentialToken`（用于后续自动重登录）
6. 创建应用会话

**错误情况**：

| 状态码 | 条件 | detail |
|--------|------|--------|
| 400 | 密码解密失败 | `"密码解密失败，请重新登录"` |
| 401 | CAS 登录失败 | 具体错误信息 |

---

### 5.2.8 POST /auth/relogin

凭证重登录，使用之前保存的加密凭证重新建立会话。

| 项目 | 说明 |
|------|------|
| 认证 | 可选（`X-Session-Id` 头用于检查旧会话是否被撤销） |
| 速率限制 | `10/minute` |
| Worker 边缘处理 | 是 |

**请求体**（`ReloginRequest`）：

```json
{
  "credentialToken": "Fernet_encrypted_token..."
}
```

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `credentialToken` | `string` | 是 | Fernet 加密的凭证令牌 |

**响应格式**（`AuthResponse`）：

```json
{
  "status": "ok",
  "sessionId": "new_session_id...",
  "studentName": "张三",
  "studentId": null,
  "credentialToken": "original_token",
  "ehallCookies": "cookie_string",
  "ehallAuthToken": "auth_token_string"
}
```

**内部流程**：
1. 检查旧会话是否被撤销（`X-Session-Id` 头）
2. 使用 `CREDENTIAL_ENCRYPTION_KEY` 解密凭证令牌，获取账号密码
3. 执行 CAS 自动登录
4. 创建新会话，生成新的 Fernet 凭证令牌

**错误情况**：

| 状态码 | 条件 | detail |
|--------|------|--------|
| 401 | 旧会话已被撤销 | `"账号已在其他设备登录，请重新登录"` |
| 401 | 凭证令牌已过期 | `"凭据已失效，请重新登录"` |
| 401 | CAS 登录失败 | 具体错误信息 |

---

### 5.2.9 POST /auth/logout

注销当前会话。

| 项目 | 说明 |
|------|------|
| 认证 | 可选（`X-Session-Id` 头） |

**请求参数**：无请求体

**响应格式**：

```json
{
  "status": "ok"
}
```

**内部流程**：
1. 从 `X-Session-Id` 头获取会话 ID
2. 从内存缓存和 PostgreSQL 中删除会话记录

---

### 5.2.10 GET /auth/student-info

登录后异步获取学生详细信息（避免阻塞登录响应）。

| 项目 | 说明 |
|------|------|
| 认证 | 需要 `X-Session-Id` |

**请求参数**：无

**响应格式**：

```json
{
  "status": "ok",
  "studentId": "2023001001",
  "info": {
    "studentId": "2023001001",
    "name": "张三",
    "college": "计算机学院",
    "major": "软件工程",
    "className": "软工1班",
    "photoDataUrl": "data:image/jpeg;base64,..."
  }
}
```

**错误情况**：

| 状态码 | 条件 | detail |
|--------|------|--------|
| 401 | 未登录 | `"未登录"` |
| 401 | 会话已过期 | `"会话已过期"` |
| 500 | 获取信息失败 | `"获取学生信息失败"` |

---

## 5.3 教务接口 (Academic)

路由前缀：无（直接挂载在根路径）  
标签：`academic`  
认证：所有接口需要 `X-Session-Id` 头  
缓存：所有接口支持 `cache_service` 数据库缓存 + `school_client` 内存简单缓存

### 5.3.1 缓存策略

教务接口使用两级缓存机制：

| 层级 | 实现 | 存储位置 | 特点 |
|------|------|----------|------|
| L1 | `school_client.simple_cache` | 进程内存 | 短 TTL，同一请求周期内复用 |
| L2 | `cache_service` (DataCache 表) | PostgreSQL | 持久化缓存，跨冷启动可用 |

**缓存降级流程**（`_run_with_cache_fallback`）：

1. 尝试执行实际的教务系统 API 调用
2. 成功 → 保存结果到 L2 缓存，返回数据
3. 失败（非 401 错误）→ 尝试从 L2 缓存加载
4. 缓存命中 → 返回缓存数据，附加 `X-Data-Source: cache` 和 `X-Data-Cached-At` 响应头
5. 缓存未命中 → 抛出原始异常

**缓存键格式**：`{student_id}:{resource}:{params_hash}`

---

### 5.3.2 GET /me

获取当前登录学生信息。

**请求参数**：无

**响应格式**（`StudentInfo`）：

```json
{
  "studentId": "2023001001",
  "name": "张三",
  "college": "计算机学院",
  "major": "软件工程",
  "className": "软工1班",
  "grade": "2023",
  "gender": "男",
  "idNumber": "4401********1234",
  "birthDate": "2004-05-15",
  "ethnicity": "汉族",
  "politicalStatus": "共青团员",
  "enrollDate": "2023-09-01",
  "nativePlace": "广东广州",
  "studentStatus": "在读",
  "educationLevel": "本科",
  "phone": "138****5678",
  "email": "zhangsan@example.com",
  "address": "广东省广州市",
  "photoDataUrl": "data:image/jpeg;base64,..."
}
```

| 字段 | 类型 | 说明 |
|------|------|------|
| `studentId` | `string` | 学号 |
| `name` | `string` | 姓名 |
| `college` | `string \| null` | 学院 |
| `major` | `string \| null` | 专业 |
| `className` | `string \| null` | 班级 |
| `grade` | `string \| null` | 年级 |
| `gender` | `string \| null` | 性别 |
| `idNumber` | `string \| null` | 身份证号（脱敏） |
| `birthDate` | `string \| null` | 出生日期 |
| `ethnicity` | `string \| null` | 民族 |
| `politicalStatus` | `string \| null` | 政治面貌 |
| `enrollDate` | `string \| null` | 入学日期 |
| `nativePlace` | `string \| null` | 籍贯 |
| `studentStatus` | `string \| null` | 学籍状态 |
| `educationLevel` | `string \| null` | 学历层次 |
| `phone` | `string \| null` | 联系电话 |
| `email` | `string \| null` | 邮箱 |
| `address` | `string \| null` | 地址 |
| `photoDataUrl` | `string \| null` | 证件照 Base64 Data URL |

**错误情况**：

| 状态码 | 条件 | detail |
|--------|------|--------|
| 401 | 会话过期 | `"会话已过期，请重新登录"` |
| 501 | 功能未实现 | `MissingProxySlotError` |

---

### 5.3.3 GET /schedule

获取课表。

**请求参数**：

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `year` | `string \| null` | 否 | 学年（如 `"2025"`） |
| `term` | `string \| null` | 否 | 学期（如 `"1"` 或 `"2"`） |

**响应格式**（`ScheduleCourse[]`）：

```json
[
  {
    "name": "高等数学",
    "teacher": "李教授",
    "classroom": "A101",
    "weekday": 1,
    "startSection": 1,
    "endSection": 2,
    "weeks": "1-16",
    "raw": { "kcm": "高等数学", "xs": "64" }
  }
]
```

| 字段 | 类型 | 说明 |
|------|------|------|
| `name` | `string` | 课程名称 |
| `teacher` | `string \| null` | 授课教师 |
| `classroom` | `string \| null` | 教室 |
| `weekday` | `int \| null` | 星期几（1=周一，7=周日） |
| `startSection` | `int \| null` | 开始节次 |
| `endSection` | `int \| null` | 结束节次 |
| `weeks` | `string \| null` | 上课周次（如 `"1-16"`） |
| `raw` | `dict \| null` | 教务系统原始数据 |

---

### 5.3.4 GET /exams

获取考试安排。

**请求参数**：

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `year` | `string \| null` | 否 | 学年 |
| `term` | `string \| null` | 否 | 学期 |

**响应格式**（`ExamItem[]`）：

```json
[
  {
    "courseName": "高等数学",
    "date": "2026-01-10",
    "weekday": "周五",
    "time": "09:00-11:00",
    "location": "A201",
    "seat": "15",
    "type": "闭卷",
    "credit": "4.0",
    "campus": "主校区",
    "remark": ""
  }
]
```

| 字段 | 类型 | 说明 |
|------|------|------|
| `courseName` | `string` | 课程名称 |
| `date` | `string` | 考试日期 |
| `weekday` | `string` | 星期 |
| `time` | `string \| null` | 考试时间 |
| `location` | `string \| null` | 考试地点 |
| `seat` | `string \| null` | 座位号 |
| `type` | `string \| null` | 考试类型 |
| `credit` | `string \| null` | 学分 |
| `campus` | `string \| null` | 校区 |
| `remark` | `string \| null` | 备注 |

---

### 5.3.5 GET /grades

获取成绩。

**请求参数**：

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `year` | `string \| null` | 否 | 学年 |
| `term` | `string \| null` | 否 | 学期 |

**响应格式**（`GradeItem[]`）：

```json
[
  {
    "courseName": "高等数学",
    "score": "90",
    "credit": "4.0",
    "gradePoint": "4.0",
    "term": "2025-2026-1"
  }
]
```

| 字段 | 类型 | 说明 |
|------|------|------|
| `courseName` | `string` | 课程名称 |
| `score` | `string \| null` | 成绩 |
| `credit` | `string \| null` | 学分 |
| `gradePoint` | `string \| null` | 绩点 |
| `term` | `string \| null` | 学期 |

---

### 5.3.6 GET /attendance

获取考勤记录。

**请求参数**：

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `year` | `string \| null` | 否 | 学年 |
| `term` | `string \| null` | 否 | 学期 |

**响应格式**（`AttendanceResponse`）：

```json
{
  "status": "ok",
  "items": [
    {
      "courseName": "高等数学",
      "courseCode": "MATH101",
      "academicYear": "2025",
      "term": "1",
      "normal": 14,
      "late": 1,
      "leaveEarly": 0,
      "absent": 1,
      "leave": 0,
      "total": 16,
      "records": [
        {
          "date": "2026-03-15",
          "status": "absent",
          "statusLabel": "旷课",
          "count": 1,
          "time": "08:00",
          "remark": null
        }
      ]
    }
  ]
}
```

| 字段 | 类型 | 说明 |
|------|------|------|
| `status` | `"not_implemented" \| "ok"` | 状态（部分学校不支持考勤查询） |
| `items` | `AttendanceItem[]` | 考勤列表 |

**AttendanceItem 字段**：

| 字段 | 类型 | 说明 |
|------|------|------|
| `courseName` | `string` | 课程名称 |
| `courseCode` | `string \| null` | 课程代码 |
| `academicYear` | `string \| null` | 学年 |
| `term` | `string \| null` | 学期 |
| `normal` | `int` | 正常次数 |
| `late` | `int` | 迟到次数 |
| `leaveEarly` | `int` | 早退次数 |
| `absent` | `int` | 旷课次数 |
| `leave` | `int` | 请假次数 |
| `total` | `int` | 总次数 |
| `records` | `AttendanceRecord[]` | 详细记录 |

**AttendanceRecord 字段**：

| 字段 | 类型 | 说明 |
|------|------|------|
| `date` | `string \| null` | 日期 |
| `status` | `string` | 状态（`"normal"` / `"late"` / `"absent"` / `"leave"` / `"leave_early"`） |
| `statusLabel` | `string \| null` | 状态中文标签 |
| `count` | `int` | 次数 |
| `time` | `string \| null` | 时间 |
| `remark` | `string \| null` | 备注 |

---

### 5.3.7 GET /credits

获取学分统计。

**请求参数**：无

**响应格式**（`CreditItem[]`）：

```json
[
  {
    "studentId": "2023001001",
    "name": "张三",
    "college": "计算机学院",
    "major": "软件工程",
    "grade": "2023",
    "totalCredit": "160",
    "requiredCredit": "120",
    "selectedCredit": "40",
    "requiredExpected": 120.0,
    "electiveExpected": 30.0,
    "otherExpected": 10.0,
    "requiredEarned": 100.0,
    "electiveEarned": 25.0,
    "otherEarned": 8.0,
    "totalExpected": 160.0,
    "totalEarned": 133.0
  }
]
```

| 字段 | 类型 | 说明 |
|------|------|------|
| `studentId` | `string \| null` | 学号 |
| `name` | `string \| null` | 姓名 |
| `college` | `string \| null` | 学院 |
| `major` | `string \| null` | 专业 |
| `grade` | `string \| null` | 年级 |
| `totalCredit` | `string \| null` | 总学分要求 |
| `requiredCredit` | `string \| null` | 必修学分要求 |
| `selectedCredit` | `string \| null` | 选修学分要求 |
| `requiredExpected` | `float` | 必修学分期望 |
| `electiveExpected` | `float` | 选修学分期望 |
| `otherExpected` | `float` | 其他学分期望 |
| `requiredEarned` | `float` | 已获必修学分 |
| `electiveEarned` | `float` | 已获选修学分 |
| `otherEarned` | `float` | 已获其他学分 |
| `totalExpected` | `float` | 总期望学分 |
| `totalEarned` | `float` | 总已获学分 |

---

### 5.3.8 GET /notices

获取通知公告列表（合并教务系统 + 一站式服务通知）。

**请求参数**：无

**响应格式**（`NoticeItem[]`）：

```json
[
  {
    "category": "通知",
    "title": "关于2026年春季学期注册的通知",
    "date": "2026-02-20",
    "url": "https://jwxt.seig.edu.cn/notice/123",
    "summary": "请各位同学按时完成注册...",
    "contentSummary": "请各位同学按时完成注册手续..."
  }
]
```

| 字段 | 类型 | 说明 |
|------|------|------|
| `category` | `string` | 分类（默认 `"通知"`） |
| `title` | `string` | 标题 |
| `date` | `string \| null` | 发布日期 |
| `url` | `string \| null` | 链接 |
| `summary` | `string \| null` | 摘要 |
| `contentSummary` | `string \| null` | 内容摘要 |

**数据合并逻辑**：
1. 从教务系统获取通知列表
2. 若存在 ehall 会话，从一站式服务获取通知
3. 去重（基于 `category + title + url` 三元组）
4. 过滤无效条目（`is_valid_notice_item`）

---

### 5.3.9 GET /notices/detail

获取通知详情。

**请求参数**：

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `url` | `string` | 是 | 通知 URL（查询参数） |

**响应格式**（`NoticeDetail`）：

```json
{
  "title": "关于2026年春季学期注册的通知",
  "date": "2026-02-20",
  "contentHtml": "<p>请各位同学...</p>",
  "url": "https://jwxt.seig.edu.cn/notice/123"
}
```

| 字段 | 类型 | 说明 |
|------|------|------|
| `title` | `string` | 标题 |
| `date` | `string \| null` | 发布日期 |
| `contentHtml` | `string` | HTML 内容 |
| `url` | `string` | 原始链接 |

---

## 5.4 一站式服务接口 (`/ehall`)

路由前缀：`/ehall`  
标签：`ehall`  
认证：所有接口需要 `X-Session-Id` 头  
特殊说明：若 `ehall_client` 不存在，大部分接口返回空列表而非报错

### 5.4.1 GET /ehall/tasks

获取待办事项。

**请求参数**：无

**响应格式**（`NoticeItem[]`）：

```json
[
  {
    "category": "待办",
    "title": "学生请假审批",
    "date": "2026-06-15",
    "url": "https://ehall.gzus.edu.cn/task/123",
    "summary": "张三提交了请假申请"
  }
]
```

**特殊行为**：`ehall_client` 不存在或认证失败时返回空数组 `[]`。

---

### 5.4.2 GET /ehall/applications

获取可申请事项。

**请求参数**：无

**响应格式**（`EhallApplicationItem[]`）：

```json
[
  {
    "id": "app_001",
    "title": "学生请假",
    "department": "学生处",
    "type": "在线办理",
    "tags": ["常用", "学生"],
    "summary": "在线提交请假申请",
    "url": "https://ehall.gzus.edu.cn/app/leave"
  }
]
```

| 字段 | 类型 | 说明 |
|------|------|------|
| `id` | `string \| null` | 事项 ID |
| `title` | `string` | 标题 |
| `department` | `string \| null` | 部门 |
| `type` | `string \| null` | 类型 |
| `tags` | `string[]` | 标签列表 |
| `summary` | `string \| null` | 摘要 |
| `url` | `string \| null` | 链接 |

---

### 5.4.3 GET /ehall/progress

获取办事进度。

**请求参数**：无

**响应格式**（`EhallProgressOverview`）：

```json
{
  "categories": [
    { "label": "全部", "count": 5 },
    { "label": "审批中", "count": 2 },
    { "label": "已完成", "count": 3 }
  ],
  "items": [
    {
      "id": "proc_001",
      "title": "学生请假",
      "category": "学生事务",
      "status": "approving",
      "statusLabel": "审批中",
      "date": "2026-06-15",
      "summary": "辅导员审批中",
      "currentNode": "辅导员审批",
      "handler": "王老师",
      "progress": 60,
      "url": "https://ehall.gzus.edu.cn/progress/001"
    }
  ]
}
```

**EhallProgressCategory 字段**：

| 字段 | 类型 | 说明 |
|------|------|------|
| `label` | `string` | 分类标签 |
| `count` | `int` | 数量 |

**EhallProgressItem 字段**：

| 字段 | 类型 | 说明 |
|------|------|------|
| `id` | `string \| null` | 进程 ID |
| `title` | `string` | 标题 |
| `category` | `string` | 分类 |
| `status` | `string` | 状态码 |
| `statusLabel` | `string` | 状态中文标签 |
| `date` | `string \| null` | 日期 |
| `summary` | `string \| null` | 摘要 |
| `currentNode` | `string \| null` | 当前节点 |
| `handler` | `string \| null` | 处理人 |
| `progress` | `int \| null` | 进度百分比 |
| `url` | `string \| null` | 链接 |

---

### 5.4.4 POST /ehall/leave/preview

请假预览，根据请假日期范围生成受影响课程列表。

**请求体**（`LeavePreviewRequest`）：

```json
{
  "year": 2025,
  "term": 2,
  "startDate": "2026-06-18",
  "endDate": "2026-06-20",
  "firstWeekStart": "2026-02-24"
}
```

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `year` | `int` | 是 | 学年 |
| `term` | `int` | 是 | 学期 |
| `startDate` | `date` | 是 | 请假开始日期 |
| `endDate` | `date` | 是 | 请假结束日期 |
| `firstWeekStart` | `date \| null` | 否 | 第一周周一日期（用于计算周次） |

**响应格式**（`LeavePreviewResponse`）：

```json
{
  "status": "ok",
  "items": [
    {
      "courseName": "高等数学",
      "courseCode": "MATH101",
      "teachingClassCode": "TC001",
      "courseNature": "必修",
      "credit": "4.0",
      "classTime": "周一第1-2节",
      "classTimes": ["周一第1-2节{1-16周}"],
      "absenceCount": 2,
      "teacher": "李教授",
      "missingFields": []
    }
  ],
  "hasMissingFields": false
}
```

**LeaveCourseItem 字段**：

| 字段 | 类型 | 说明 |
|------|------|------|
| `courseName` | `string` | 课程名称 |
| `courseCode` | `string \| null` | 课程代码 |
| `teachingClassCode` | `string \| null` | 教学班代码 |
| `courseNature` | `string \| null` | 课程性质 |
| `credit` | `string \| null` | 学分 |
| `classTime` | `string` | 上课时间 |
| `classTimes` | `string[]` | 上课时间列表 |
| `absenceCount` | `int` | 缺课次数 |
| `teacher` | `string \| null` | 授课教师 |
| `missingFields` | `string[]` | 缺失字段列表 |

**错误情况**：

| 状态码 | 条件 | detail |
|--------|------|--------|
| 401 | 会话过期 | `"会话已过期，请重新登录"` |
| 400 | 参数无效 | 具体错误信息 |

---

### 5.4.5 POST /ehall/leave/fill

请假填写，自动填写请假申请表并上传附件。

**请求体**（`LeaveFillRequest`，继承 `LeavePreviewRequest`）：

```json
{
  "year": 2025,
  "term": 2,
  "startDate": "2026-06-18",
  "endDate": "2026-06-20",
  "firstWeekStart": "2026-02-24",
  "reason": "身体不适，需要休息",
  "attachmentName": "医院证明.jpg",
  "attachmentContentBase64": "/9j/4AAQSkZJRg...",
  "teacherHandlers": [
    {
      "teacher": "李教授",
      "userid": "T001",
      "cnName": "李明",
      "courseName": "高等数学"
    }
  ]
}
```

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `reason` | `string` | 是 | 请假原因 |
| `attachmentName` | `string` | 是 | 附件文件名 |
| `attachmentContentBase64` | `string` | 是 | 附件 Base64 内容 |
| `teacherHandlers` | `TeacherHandlerSelection[]` | 否 | 手动选择的教师经办人 |

**TeacherHandlerSelection 字段**：

| 字段 | 类型 | 说明 |
|------|------|------|
| `teacher` | `string` | 教师姓名 |
| `userid` | `string` | 教师工号 |
| `cnName` | `string` | 教师中文名 |
| `courseName` | `string \| null` | 课程名称 |

**响应格式**（`LeaveFillResponse`）：

```json
{
  "status": "filled",
  "message": "已生成请假单并上传附件，打开后将自动办理并停在提交前",
  "items": [...],
  "unmatchedTeachers": [],
  "matchedTeachers": [
    {
      "teacher": "李教授",
      "userid": "T001",
      "cnName": "李明",
      "courseName": "高等数学"
    }
  ],
  "teacherCandidates": [],
  "formUrl": "https://ehall.gzus.edu.cn/form/xxx",
  "fillScript": "javascript:(function(){...})()",
  "handlerScript": "javascript:(function(){...})()",
  "attachmentUploaded": true
}
```

**`status` 取值**：

| 值 | 说明 |
|------|------|
| `"filled"` | 填表成功，所有教师已匹配 |
| `"needs_manual"` | 部分教师未匹配，需手动选择 |
| `"no_ehall_session"` | 缺少一站式服务会话 |

**错误情况**：

| 状态码 | 条件 | detail |
|--------|------|--------|
| 401 | 会话过期 / ehall 认证失败 | 具体错误信息 |
| 400 | 参数无效 / 附件 Base64 无效 | 具体错误信息 |

---

### 5.4.6 POST /ehall/leave/attachment

单独上传请假附件。

**请求体**（`LeaveAttachmentUploadRequest`）：

```json
{
  "docUnid": "doc_abc123",
  "processId": "proc_001",
  "nodeName": "申请人",
  "localStore": "0",
  "attachmentName": "医院证明.jpg",
  "attachmentContentBase64": "/9j/4AAQSkZJRg..."
}
```

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `docUnid` | `string` | 是 | 文档唯一标识 |
| `processId` | `string` | 否 | 流程 ID |
| `nodeName` | `string` | 否 | 节点名称（默认 `"申请人"`） |
| `localStore` | `string` | 否 | 本地存储标识（默认 `"0"`） |
| `attachmentName` | `string` | 是 | 附件文件名 |
| `attachmentContentBase64` | `string` | 是 | 附件 Base64 内容 |

**响应格式**：

```json
{
  "status": "ok",
  "uploaded": true
}
```

**错误情况**：

| 状态码 | 条件 | detail |
|--------|------|--------|
| 401 | ehall 认证失败 | 具体错误信息 |
| 400 | 附件 Base64 无效 | `"附件内容不是有效 Base64"` |

---

### 5.4.7 GET /ehall/leave/teachers

搜索教师信息（用于请假时选择经办人）。

> 注：此接口在代码中通过 `staff_service` 模块实现教师匹配，而非独立路由端点。教师搜索通过 `leave/fill` 接口内部的 `resolve_teacher` 函数完成。

---

## 5.5 一卡通接口 (`/ecard`)

路由前缀：`/ecard`  
标签：`ecard`  
认证：所有接口需要 `X-Session-Id` 头  
数据存储：`ecard_bindings` 表（PostgreSQL）

### 5.5.1 GET /ecard/rooms

获取宿舍列表（支持搜索过滤）。

**请求参数**：

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `q` | `string \| null` | 否 | 搜索关键词（最大 50 字符） |
| `limit` | `int` | 否 | 最大返回数量（1-500，默认 100） |

**响应格式**（`EcardRoomItem[]`）：

```json
[
  {
    "id": "S1_B1_101",
    "schoolArea": "主校区",
    "building": "1栋",
    "room": "101",
    "displayName": "主校区 1栋 101"
  }
]
```

| 字段 | 类型 | 说明 |
|------|------|------|
| `id` | `string` | 房间 ID |
| `schoolArea` | `string` | 校区 |
| `building` | `string` | 楼栋 |
| `room` | `string` | 房间号 |
| `displayName` | `string` | 显示名称 |

**缓存策略**：宿舍列表约 6700 条 / 880 KB，从一卡通 API 获取约需 2.5 秒。使用服务端内存缓存，TTL 1 小时。搜索在服务端完成，客户端只接收过滤后的小数据集。

**错误情况**：

| 状态码 | 条件 | detail |
|--------|------|--------|
| 503 | 一卡通配置错误 | 具体错误信息 |
| 502 | 一卡通 API 错误 | 具体错误信息 |

---

### 5.5.2 POST /ecard/binding

绑定宿舍。

**请求体**（`EcardBindingRequest`）：

```json
{
  "roomId": "S1_B1_101",
  "roomDisplay": "主校区 1栋 101"
}
```

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `roomId` | `string` | 是 | 房间 ID |
| `roomDisplay` | `string` | 是 | 房间显示名称 |

**响应格式**（`EcardSummary`）：

```json
{
  "status": "ok",
  "studentId": "2023001001",
  "roomId": "S1_B1_101",
  "roomDisplay": "主校区 1栋 101",
  "powerBalance": 45.6,
  "powerUnit": "度",
  "powerText": "45.6度",
  "coldWaterBalance": 3.2,
  "coldWaterUnit": "吨",
  "coldWaterText": "3.2吨",
  "hotWaterBalance": 25.8,
  "hotWaterUnit": "元",
  "hotWaterText": "25.8元",
  "reminderEnabled": true,
  "lowPowerThreshold": 30.0,
  "lowColdWaterThreshold": 5.0,
  "lowHotWaterThreshold": 10.0,
  "reminderTimes": ["08:00"],
  "reminderItems": ["power", "cold_water", "hot_water"],
  "updatedAt": "2026-06-17T08:30:00"
}
```

**EcardSummary 字段**：

| 字段 | 类型 | 说明 |
|------|------|------|
| `status` | `"ok" \| "not_bound"` | 状态 |
| `studentId` | `string \| null` | 学号 |
| `roomId` | `string \| null` | 房间 ID |
| `roomDisplay` | `string \| null` | 房间显示名 |
| `powerBalance` | `float \| string \| null` | 电费余额 |
| `powerUnit` | `string` | 电费单位（默认 `"度"`） |
| `powerText` | `string \| null` | 电费文本 |
| `coldWaterBalance` | `float \| string \| null` | 冷水余额 |
| `coldWaterUnit` | `string` | 冷水单位（默认 `"吨"`） |
| `coldWaterText` | `string \| null` | 冷水文本 |
| `hotWaterBalance` | `float \| string \| null` | 热水余额 |
| `hotWaterUnit` | `string` | 热水单位（默认 `"元"`） |
| `hotWaterText` | `string \| null` | 热水文本 |
| `reminderEnabled` | `bool` | 是否启用提醒（默认 `true`） |
| `lowPowerThreshold` | `float` | 低电量阈值（默认 `30`） |
| `lowColdWaterThreshold` | `float` | 低冷水阈值（默认 `5.0`） |
| `lowHotWaterThreshold` | `float` | 低热水阈值（默认 `10.0`） |
| `reminderTimes` | `string[]` | 提醒时间（最多 2 个） |
| `reminderItems` | `string[]` | 提醒项目 |
| `updatedAt` | `string \| null` | 最后更新时间 |

**错误情况**：

| 状态码 | 条件 | detail |
|--------|------|--------|
| 400 | roomId 格式无效 | 具体错误信息 |
| 401 | 会话过期 | `"会话已过期，请重新登录"` |
| 503 | 一卡通配置错误 | 具体错误信息 |

---

### 5.5.3 GET /ecard/summary

查询余额（读取缓存，不主动刷新）。

**请求参数**：无

**响应格式**（`EcardSummary`）：

未绑定时：
```json
{
  "status": "not_bound"
}
```

已绑定时：同 [POST /ecard/binding](#552-post-ecardbinding) 响应格式。

---

### 5.5.4 POST /ecard/refresh

主动刷新余额（从一卡通 API 重新获取）。

**请求参数**：无请求体

**响应格式**（`EcardSummary`）：同上

**错误情况**：

| 状态码 | 条件 | detail |
|--------|------|--------|
| 503 | 一卡通配置错误 | 具体错误信息 |
| 502 | 一卡通 API 错误 | 具体错误信息 |

---

### 5.5.5 PATCH /ecard/reminder

修改提醒设置。

**请求体**（`EcardReminderRequest`）：

```json
{
  "enabled": true,
  "lowPowerThreshold": 20.0,
  "lowColdWaterThreshold": 3.0,
  "lowHotWaterThreshold": 8.0,
  "reminderTimes": ["08:00", "20:00"],
  "reminderItems": ["power", "hot_water"]
}
```

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `enabled` | `bool \| null` | 否 | 是否启用提醒 |
| `lowPowerThreshold` | `float \| null` | 否 | 低电量阈值（≥0） |
| `lowColdWaterThreshold` | `float \| null` | 否 | 低冷水阈值（≥0） |
| `lowHotWaterThreshold` | `float \| null` | 否 | 低热水阈值（≥0） |
| `reminderTimes` | `string[] \| null` | 否 | 提醒时间（最多 2 个） |
| `reminderItems` | `string[] \| null` | 否 | 提醒项目 |

> 所有字段均为可选，仅更新传入的字段（部分更新语义）。

**响应格式**（`EcardSummary`）：同上

---

### 5.5.6 GET /ecard/consumption

获取消费记录。

**请求参数**：

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `month` | `string \| null` | 否 | 月份（格式 `yyyy-mm`，默认当月） |

**响应格式**（`EcardConsumptionResponse`）：

```json
{
  "status": "ok",
  "message": null,
  "items": [
    {
      "title": "食堂消费",
      "amount": "12.50",
      "time": "2026-06-17 12:30"
    }
  ]
}
```

| 字段 | 类型 | 说明 |
|------|------|------|
| `status` | `"ok" \| "limited"` | 状态 |
| `message` | `string \| null` | 消息 |
| `items` | `EcardConsumptionItem[]` | 消费记录列表 |

**EcardConsumptionItem 字段**：

| 字段 | 类型 | 说明 |
|------|------|------|
| `title` | `string` | 消费标题 |
| `amount` | `string` | 金额 |
| `time` | `string` | 时间 |

**错误情况**：

| 状态码 | 条件 | detail |
|--------|------|--------|
| 400 | 月份格式错误 | `"月份格式应为 yyyy-mm"` |
| 503 | 一卡通配置错误 | 具体错误信息 |
| 502 | 一卡通 API 错误 | 具体错误信息 |

---

### 5.5.7 PATCH /ecard/summary-cache

前端余额缓存上报，允许前端将本地缓存的余额数据同步到服务端。

**请求体**（`EcardSummaryCacheRequest`）：

```json
{
  "powerBalance": 45.6,
  "powerUnit": "度",
  "powerText": "45.6度",
  "coldWaterBalance": 3.2,
  "coldWaterUnit": "吨",
  "coldWaterText": "3.2吨",
  "hotWaterBalance": 25.8,
  "hotWaterUnit": "元",
  "hotWaterText": "25.8元",
  "updatedAt": "2026-06-17T08:30:00"
}
```

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `powerBalance` | `float \| string \| null` | 否 | 电费余额 |
| `powerUnit` | `string \| null` | 否 | 电费单位 |
| `powerText` | `string \| null` | 否 | 电费文本 |
| `coldWaterBalance` | `float \| string \| null` | 否 | 冷水余额 |
| `coldWaterUnit` | `string \| null` | 否 | 冷水单位 |
| `coldWaterText` | `string \| null` | 否 | 冷水文本 |
| `hotWaterBalance` | `float \| string \| null` | 否 | 热水余额 |
| `hotWaterUnit` | `string \| null` | 否 | 热水单位 |
| `hotWaterText` | `string \| null` | 否 | 热水文本 |
| `updatedAt` | `string \| null` | 否 | 更新时间 |

> 此模型使用 `extra = "forbid"`，不允许传入未定义的字段。

**响应格式**（`EcardSummary`）：同上

**错误情况**：

| 状态码 | 条件 | detail |
|--------|------|--------|
| 404 | 未绑定宿舍 | `"请先绑定宿舍"` |

---

## 5.6 推送接口 (`/push`)

路由前缀：`/push`  
标签：`push`  
认证：大部分接口需要 `X-Session-Id` 头（`/push/web/config` 除外）

### 5.6.1 GET /push/web/config

获取 Web Push 配置（VAPID 公钥）。

| 项目 | 说明 |
|------|------|
| 认证 | 无需认证 |

**请求参数**：无

**响应格式**（`WebPushConfigResponse`）：

```json
{
  "enabled": true,
  "publicKey": "BPxxxxxxxxxxxxxxxxxxxxxxxxxxx..."
}
```

| 字段 | 类型 | 说明 |
|------|------|------|
| `enabled` | `bool` | Web Push 是否启用（取决于 VAPID 密钥是否配置） |
| `publicKey` | `string \| null` | VAPID 公钥（仅启用时返回） |

---

### 5.6.2 POST /push/web/register

注册 Web Push 订阅。

**请求体**（`WebPushSubscriptionRequest`）：

```json
{
  "endpoint": "https://fcm.googleapis.com/fcm/send/xxx",
  "keys": {
    "p256dh": "BNxxxxxxxx...",
    "auth": "xxxxxxxx..."
  },
  "expirationTime": 1735689600
}
```

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `endpoint` | `string` | 是 | 推送端点 URL |
| `keys.p256dh` | `string` | 是 | 加密公钥 |
| `keys.auth` | `string` | 是 | 认证密钥 |
| `expirationTime` | `int \| null` | 否 | 过期时间（Unix 时间戳） |

**响应格式**：

```json
{
  "status": "ok"
}
```

**内部流程**：
1. 获取当前会话的学号
2. 查询是否已存在相同 endpoint 的订阅
3. 存在 → 更新订阅信息；不存在 → 创建新订阅
4. 存储到 `web_push_subscriptions` 表

---

### 5.6.3 POST /push/web/unregister

注销 Web Push 订阅。

**请求参数**：无请求体

**响应格式**：

```json
{
  "status": "ok"
}
```

**内部流程**：删除当前学号关联的所有 Web Push 订阅。

---

### 5.6.4 POST /push/register

注册 JPush 推送（Android 原生推送）。

**请求体**（`PushRegisterRequest`）：

```json
{
  "registrationId": "1a0018970a8c5e4c68e",
  "platform": "android"
}
```

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `registrationId` | `string` | 是 | JPush 注册 ID |
| `platform` | `string` | 否 | 平台（默认 `"android"`） |

**响应格式**：

```json
{
  "status": "ok"
}
```

**内部流程**：
1. 更新会话的 `push_registration_id` 和 `push_platform`
2. 更新 PostgreSQL 会话记录
3. 更新 `push_registrations` 表（upsert）

---

### 5.6.5 POST /push/unregister

注销 JPush 推送。

**请求参数**：无请求体

**响应格式**：

```json
{
  "status": "ok"
}
```

---

### 5.6.6 POST /push/test

发送测试推送消息（仅调试模式可用）。

| 项目 | 说明 |
|------|------|
| 认证 | 需要 `X-Session-Id` |
| 可用性 | 仅 `DEBUG=true` 时可用 |

**请求体**（可选）：

```json
{
  "title": "软帮手通知",
  "body": "这是一条测试推送消息",
  "url": "",
  "type": "new_notice"
}
```

**响应格式**：

```json
{
  "status": "ok",
  "sent_to": "a1b2c3d4"
}
```

---

### 5.6.7 GET /push/poll

轮询获取离线推送消息（WebSocket 不可用时的降级方案）。

**请求参数**：无

**响应格式**：

```json
{
  "messages": [
    {
      "id": "msg_abc123",
      "type": "new_notice",
      "title": "新通知",
      "body": "你有新的通知",
      "url": "https://..."
    }
  ]
}
```

---

## 5.7 天气接口 (`/weather`)

路由前缀：`/weather`  
标签：`weather`  
认证：无需认证（公开端点）

### 5.7.1 GET /weather/current

获取当前天气数据。

**请求参数**：

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `lat` | `float \| null` | 否 | 纬度（-90 ~ 90） |
| `lon` | `float \| null` | 否 | 经度（-180 ~ 180） |

> 若不提供坐标，默认查询广州天气。

**响应格式**：

```json
{
  "province": "广东",
  "city": "广州",
  "district": "广州",
  "weather": "多云",
  "weather_icon": "116",
  "temperature": 28.0,
  "wind_direction": "南风",
  "wind_power": "3级",
  "humidity": 75,
  "temp_max": 32.0,
  "temp_min": 24.0,
  "forecast": [
    {
      "date": "2026-06-18",
      "week": "周四",
      "temp_max": 31.0,
      "temp_min": 25.0,
      "weather_day": "小雨"
    }
  ]
}
```

| 字段 | 类型 | 说明 |
|------|------|------|
| `province` | `string` | 省份 |
| `city` | `string` | 城市 |
| `district` | `string` | 区县 |
| `weather` | `string` | 天气描述（中文） |
| `weather_icon` | `string` | 天气代码 |
| `temperature` | `float` | 当前温度（°C） |
| `wind_direction` | `string` | 风向（中文） |
| `wind_power` | `string` | 风力等级 |
| `humidity` | `int` | 湿度（%） |
| `temp_max` | `float` | 今日最高温 |
| `temp_min` | `float` | 今日最低温 |
| `forecast` | `object[]` | 未来天气预报 |

### 5.7.2 天气代码中文映射

系统将 wttr.in 的天气代码映射为中文描述，主要映射如下：

| 代码 | 中文 | 代码 | 中文 | 代码 | 中文 |
|------|------|------|------|------|------|
| 113 | 晴 | 176 | 小雨 | 200 | 雷阵雨 |
| 116 | 多云 | 266 | 小雨 | 299 | 中雨 |
| 119 | 阴 | 293 | 小雨 | 305 | 大雨 |
| 122 | 阴 | 296 | 小雨 | 308 | 暴雨 |
| 143 | 雾 | 302 | 中雨 | 386 | 雷阵雨 |
| 179 | 雪 | 323 | 中雪 | 389 | 雷暴 |
| 182 | 雨夹雪 | 329 | 大雪 | 395 | 大雪 |

风向映射示例：

| 英文 | 中文 | 英文 | 中文 |
|------|------|------|------|
| N | 北风 | S | 南风 |
| NE | 东北风 | SW | 西南风 |
| E | 东风 | W | 西风 |

风力等级换算：

| 风速 (km/h) | 等级 | 风速 (km/h) | 等级 |
|-------------|------|-------------|------|
| < 6 | 1级 | 29-38 | 5级 |
| 6-11 | 2级 | 39-49 | 6级 |
| 12-19 | 3级 | 50-61 | 7级 |
| 20-28 | 4级 | ≥ 62 | 8级+ |

### 5.7.3 缓存策略

| 项目 | 说明 |
|------|------|
| 缓存位置 | 进程内存（`_cache` 字典） |
| 缓存键 | `{lat:.1f},{lon:.1f}` 或 `"default"` |
| TTL | 30 分钟 |
| 降级策略 | wttr.in 超时或错误时返回过期缓存 |

---

## 5.8 内部接口 (`/internal`)

路由前缀：`/internal`  
标签：`internal`  
认证：所有接口需要 `X-Internal-Key` 请求头（与 `INTERNAL_API_KEY` 环境变量匹配）  
调用方：Cloudflare Worker（边缘节点）

### 5.8.1 认证方式

所有内部接口通过 `X-Internal-Key` 请求头验证身份：

```
X-Internal-Key: <INTERNAL_API_KEY>
```

**验证逻辑**：
1. 检查 `INTERNAL_API_KEY` 环境变量是否已配置
2. 未配置 → 返回 503 `"Internal API key not configured"`
3. 不匹配 → 返回 403 `"Invalid internal API key"`

---

### 5.8.2 POST /internal/ocr

验证码 OCR 识别。

**请求体**（`OcrRequest`）：

```json
{
  "image": "base64_encoded_image_bytes"
}
```

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `image` | `string` | 是 | Base64 编码的验证码图片 |

**响应格式**：

```json
{
  "text": "a3b7"
}
```

| 字段 | 类型 | 说明 |
|------|------|------|
| `text` | `string` | 识别结果（失败时返回空字符串） |

**错误情况**：

| 状态码 | 条件 | detail |
|--------|------|--------|
| 403 | API Key 无效 | `"Invalid internal API key"` |
| 503 | OCR 引擎不可用 | 具体错误信息 |

---

### 5.8.3 POST /internal/decrypt-password

RSA 密码解密。

**请求体**（`DecryptPasswordRequest`）：

```json
{
  "encryptedPassword": "RSA_encrypted_base64",
  "keyId": "k1a2b3c4"
}
```

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `encryptedPassword` | `string` | 是 | RSA 加密的密码（Base64） |
| `keyId` | `string \| null` | 否 | 前端使用的密钥 ID（用于检测密钥不匹配） |

**响应格式**：

```json
{
  "password": "plaintext_password"
}
```

**密钥不匹配检测**：若前端 `keyId` 与后端当前 `keyId` 不一致（通常因 Vercel 冷启动导致密钥轮换），返回 400 错误，提示前端刷新公钥。

**错误情况**：

| 状态码 | 条件 | detail |
|--------|------|--------|
| 400 | 密钥不匹配 | `"RSA密钥不匹配: 前端keyId=..., 后端keyId=...。请刷新页面获取新公钥后重试。"` |
| 400 | 解密失败 | `"密码解密失败: ..."` |
| 403 | API Key 无效 | `"Invalid internal API key"` |

---

### 5.8.4 POST /internal/create-session

从 CAS 登录结果创建会话（Worker 调用）。

**请求体**（`CreateSessionRequest`）：

```json
{
  "account": "2023001001",
  "cookies": "JSESSIONID=abc; route=def",
  "password": "plaintext_password",
  "ehallCookies": "ehall_cookie_string",
  "studentName": "张三"
}
```

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `account` | `string` | 是 | 学号 |
| `cookies` | `string` | 是 | JWXT Cookie 字符串 |
| `password` | `string \| null` | 否 | 明文密码（用于生成 Fernet 凭证令牌） |
| `ehallCookies` | `string \| null` | 否 | 一站式服务 Cookie |
| `studentName` | `string \| null` | 否 | 学生姓名 |

**响应格式**：

```json
{
  "sessionId": "a1b2c3d4e5f6...",
  "credentialToken": "Fernet_encrypted_token..."
}
```

**内部流程**：
1. 使用 Cookie 创建 `SchoolSdkClient`（跳过验证，因为 Cookie 与 Worker IP 绑定）
2. 若提供密码，生成 Fernet 凭证令牌
3. 若提供 ehall Cookie，创建 `EhallClient`
4. 创建会话并存入 PostgreSQL
5. 若配置了 `JWXT_WORKER_PROXY_ORIGIN`，为 JWXT 客户端安装 Worker 代理

**错误情况**：

| 状态码 | 条件 | detail |
|--------|------|--------|
| 403 | API Key 无效 | `"Invalid internal API key"` |
| 503 | 会话写入数据库失败 | `"会话写入数据库失败: ..."` |

---

## 5.9 WebSocket 接口

路由：`/ws/notifications`  
协议：WebSocket  
认证：通过 `sessionId` 查询参数

### 5.9.1 连接建立

```
WS /ws/notifications?sessionId=a1b2c3d4e5f6...
```

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `sessionId` | `string` | 是 | 应用会话 ID |

**连接流程**：
1. 接受 WebSocket 连接
2. 验证 `sessionId` 是否有效
3. 无效 → 关闭连接（code=4001, reason="会话无效" 或 "会话已过期"）
4. 有效 → 注册到 `ConnectionManager`

### 5.9.2 心跳机制

| 项目 | 说明 |
|------|------|
| 心跳间隔 | 30 秒（`ws_heartbeat_seconds` 配置） |
| 心跳方式 | 客户端发送文本消息，服务端不做回复（仅保持连接活跃） |
| 断开检测 | `WebSocketDisconnect` 异常触发断开处理 |

### 5.9.3 消息格式

服务端推送消息格式：

```json
{
  "id": "msg_uuid_hex",
  "type": "new_notice",
  "title": "新通知标题",
  "body": "通知内容",
  "url": "https://...",
  "extras": {
    "type": "new_notice",
    "url": "https://...",
    "courseName": null,
    "liveUpdate": null,
    "style": null,
    "endTime": null,
    "shortCriticalText": null,
    "progressMax": null,
    "progressCurrent": null,
    "progress": null
  }
}
```

**消息类型**：

| type | 说明 |
|------|------|
| `new_notice` | 新通知 |
| `exam_reminder` | 考试提醒 |
| `grade_update` | 成绩更新 |
| `ecard_reminder` | 水电费提醒 |

**extras 字段**：从原始消息中提取的附加信息，包含 `type`、`url`、`courseName`、`liveUpdate`、`style`、`endTime`、`shortCriticalText`、`progressMax`、`progressCurrent`、`progress` 等字段。

### 5.9.4 离线消息队列

| 项目 | 说明 |
|------|------|
| 存储 | `ConnectionManager.pending`（内存字典） |
| 队列上限 | 每个会话最多 100 条消息（超出丢弃最旧的） |
| 消费方式 | WebSocket 连接时实时推送；未连接时入队等待 |
| 轮询降级 | 通过 `GET /push/poll` 接口获取离线消息 |

**`ConnectionManager` 核心方法**：

| 方法 | 说明 |
|------|------|
| `connect(websocket, session_id)` | 接受连接并注册 |
| `disconnect(session_id)` | 断开连接并清理 |
| `enqueue(session_id, message)` | 消息入队（自动分配 ID 和 extras） |
| `drain(session_id)` | 一次性取出所有离线消息 |
| `send_to_session(session_id, message)` | 发送消息（在线直接推送，离线入队） |
| `broadcast(message)` | 广播消息给所有在线连接 |

---

## 5.10 健康检查

### 5.10.1 GET /health

健康检查端点。

| 项目 | 说明 |
|------|------|
| 认证 | 无需认证 |
| Worker 边缘处理 | 是（Worker 在边缘节点直接响应） |

**请求参数**：无

**响应格式**：

```json
{
  "status": "ok"
}
```

**用途**：
- Cloudflare Worker 健康检查
- Vercel 无服务器函数冷启动检测
- 前端连接状态检测

---

## 5.11 错误处理与状态码

### 5.11.1 HTTP 状态码总览

| 状态码 | 含义 | 触发条件 |
|--------|------|----------|
| **200** | 成功 | 请求处理成功 |
| **302** | 重定向 | SSO 登录重定向 |
| **400** | 请求参数错误 | Pydantic 校验失败、密码解密失败、RSA 密钥不匹配、附件 Base64 无效 |
| **401** | 认证失败 | 会话过期、账号密码错误、凭证失效、会话被撤销（单设备登录） |
| **403** | 权限不足 | 内部 API Key 不匹配 |
| **404** | 资源不存在 | 未绑定宿舍、调试模式下的测试端点 |
| **413** | 请求体过大 | 超过 10MB 限制 |
| **422** | 参数校验失败 | FastAPI/Pydantic 自动校验 |
| **429** | 速率限制 | 超过 `slowapi` 限制（如 10/minute） |
| **500** | 服务器内部错误 | 未捕获的异常（全局异常处理器兜底） |
| **501** | 功能未实现 | `MissingProxySlotError`（需 Worker 代理但未配置） |
| **502** | 网关错误 | 一卡通 API 调用失败 |
| **503** | 服务不可用 | 一卡通配置错误、OCR 引擎不可用、数据库写入失败、内部 API Key 未配置 |

### 5.11.2 错误响应格式

所有错误响应使用统一的 JSON 格式：

```json
{
  "detail": "错误描述信息（中文）"
}
```

**Pydantic 校验错误**（422）格式：

```json
{
  "detail": [
    {
      "type": "missing",
      "loc": ["body", "account"],
      "msg": "Field required",
      "input": null
    }
  ]
}
```

### 5.11.3 速率限制

| 接口 | 限制 | 说明 |
|------|------|------|
| `POST /auth/login` | 10/minute | 防止暴力破解 |
| `POST /auth/captcha` | 10/minute | 防止验证码滥用 |
| `POST /auth/auto-login` | 10/minute | 防止自动化攻击 |
| `POST /auth/relogin` | 10/minute | 防止凭证重放 |
| 其他接口 | 默认限制 | 由 `slowapi` 全局配置 |

速率限制使用 `X-Forwarded-For` 头识别客户端 IP（由 Cloudflare Worker 注入）。

### 5.11.4 安全响应头

所有响应自动附加以下安全头（`_security_headers` 中间件）：

| 头 | 值 | 说明 |
|------|------|------|
| `X-Content-Type-Options` | `nosniff` | 防止 MIME 类型嗅探 |
| `X-Frame-Options` | `DENY` | 防止点击劫持 |
| `Referrer-Policy` | `strict-origin-when-cross-origin` | 控制 Referer 泄露 |
| `Permissions-Policy` | `camera=(), microphone=(), geolocation=()` | 禁用不必要的浏览器 API |
| `Strict-Transport-Security` | `max-age=31536000; includeSubDomains` | 强制 HTTPS（仅生产环境） |

### 5.11.5 请求体限制

| 项目 | 值 |
|------|------|
| 最大请求体 | 10 MB |
| 检查方式 | `Content-Length` 头预检 |
| 超限响应 | 413 `"请求体过大，最大支持 10MB"` |

### 5.11.6 CORS 配置

| 项目 | 说明 |
|------|------|
| 允许来源 | 配置列表 + 正则匹配 |
| 允许方法 | `GET`、`POST`、`PATCH` |
| 允许头 | `X-Session-Id`、`Content-Type`、`User-Agent` |
| 凭证 | 不允许（`allow_credentials=False`） |
| 正则匹配 | `localhost`、`127.0.0.1`、`192.168.*`、`*.pages.dev`、`*.vercel.app` |

---

## 附录：接口总览表

| 方法 | 路径 | 认证 | 速率限制 | 说明 |
|------|------|------|----------|------|
| GET | `/auth/public-key` | 无 | 无 | 获取 RSA 公钥 |
| POST | `/auth/login` | 无 | 10/min | 账号密码登录 |
| POST | `/auth/captcha` | 无 | 10/min | 提交验证码 |
| GET | `/auth/ly/start` | 无 | 无 | 发起 SSO 登录 |
| GET | `/auth/ly/callback` | 无 | 无 | CAS 回调 |
| POST | `/auth/ly/complete` | 无 | 无 | 完成 SSO 登录 |
| POST | `/auth/auto-login` | 无 | 10/min | 自动登录 |
| POST | `/auth/relogin` | 可选 | 10/min | 凭证重登录 |
| POST | `/auth/logout` | 可选 | 无 | 注销 |
| GET | `/auth/student-info` | 需要 | 无 | 获取学生信息 |
| GET | `/me` | 需要 | 无 | 学生信息 |
| GET | `/schedule` | 需要 | 无 | 课表查询 |
| GET | `/exams` | 需要 | 无 | 考试安排 |
| GET | `/grades` | 需要 | 无 | 成绩查询 |
| GET | `/attendance` | 需要 | 无 | 考勤查询 |
| GET | `/credits` | 需要 | 无 | 学分统计 |
| GET | `/notices` | 需要 | 无 | 通知列表 |
| GET | `/notices/detail` | 需要 | 无 | 通知详情 |
| GET | `/ehall/tasks` | 需要 | 无 | 待办事项 |
| GET | `/ehall/applications` | 需要 | 无 | 可申请事项 |
| GET | `/ehall/progress` | 需要 | 无 | 办事进度 |
| POST | `/ehall/leave/preview` | 需要 | 无 | 请假预览 |
| POST | `/ehall/leave/fill` | 需要 | 无 | 请假填写 |
| POST | `/ehall/leave/attachment` | 需要 | 无 | 附件上传 |
| GET | `/ecard/rooms` | 需要 | 无 | 宿舍列表 |
| POST | `/ecard/binding` | 需要 | 无 | 绑定宿舍 |
| GET | `/ecard/summary` | 需要 | 无 | 余额查询 |
| POST | `/ecard/refresh` | 需要 | 无 | 刷新余额 |
| PATCH | `/ecard/reminder` | 需要 | 无 | 提醒设置 |
| GET | `/ecard/consumption` | 需要 | 无 | 消费记录 |
| PATCH | `/ecard/summary-cache` | 需要 | 无 | 余额缓存上报 |
| GET | `/push/web/config` | 无 | 无 | Web Push 配置 |
| POST | `/push/web/register` | 需要 | 无 | 注册 Web Push |
| POST | `/push/web/unregister` | 需要 | 无 | 注销 Web Push |
| POST | `/push/register` | 需要 | 无 | 注册 JPush |
| POST | `/push/unregister` | 需要 | 无 | 注销 JPush |
| POST | `/push/test` | 需要 | 无 | 测试推送（仅调试） |
| GET | `/push/poll` | 需要 | 无 | 轮询离线消息 |
| GET | `/weather` | 无 | 无 | 天气查询 |
| POST | `/internal/ocr` | Internal Key | 无 | 验证码 OCR |
| POST | `/internal/decrypt-password` | Internal Key | 无 | 密码解密 |
| POST | `/internal/create-session` | Internal Key | 无 | 创建会话 |
| WS | `/ws/notifications` | sessionId 参数 | 无 | WebSocket 通知 |
| GET | `/health` | 无 | 无 | 健康检查 |