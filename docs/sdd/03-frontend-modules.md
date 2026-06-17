# 第3章 前端模块设计

## 3.1 前端整体架构

### 3.1.1 技术栈与项目结构

前端应用位于 `apps/mobile_web/`，基于 **Flutter 3.x (Dart)** 构建，支持 **Web + Android + iOS** 三端跨平台部署。项目采用单仓库（monorepo）结构，前端代码集中在 `lib/` 目录下。

```
apps/mobile_web/
├── lib/                          # Dart 源码
│   ├── main.dart                 # 应用入口 + 所有页面 UI（~15716行）
│   ├── api_client.dart           # API 客户端层（~2988行）
│   ├── gzus_design.dart          # 设计系统 / 主题
│   ├── services_deferred.dart    # 延迟加载服务编排
│   ├── ws_service.dart           # WebSocket 实时通信
│   ├── push_service.dart         # JPush 推送服务
│   ├── web_push_service.dart     # Web Push 推送服务
│   ├── reminder_service.dart     # 课程提醒服务
│   ├── update_service.dart       # 应用更新检查
│   ├── background_service.dart   # 前台服务（Android）
│   ├── persistent_cache.dart     # 持久化缓存
│   ├── local_notification_service.dart  # 本地通知
│   ├── live_activity_service.dart # Live Activity (iOS)
│   ├── live_update_service.dart  # 实时更新通知
│   ├── ftp_upload_service.dart   # FTP 上传
│   ├── ics_download.dart         # ICS 日历下载
│   ├── leave_attachment.dart     # 请假附件
│   ├── mobile_sso.dart           # 移动端 SSO
│   ├── avatar_open.dart          # 头像打开
│   ├── web_pwa_cache.dart        # PWA 缓存
│   ├── location_service.dart     # 定位服务
│   ├── permission_service.dart   # 权限管理
│   ├── bugly_service.dart        # Bugly 崩溃上报
│   ├── browser_redirect.dart     # 浏览器重定向
│   ├── background_guide_page.dart # 后台引导页
│   └── *_web.dart / *_io.dart / *_stub.dart  # 平台适配层
├── web/
│   └── _worker.js                # Cloudflare Worker（~1773行）
├── android/                      # Android 原生壳
├── ios/                          # iOS 原生壳
├── assets/                       # 静态资源
├── pubspec.yaml                  # Flutter 依赖配置
└── analysis_options.yaml         # 代码分析规则
```

### 3.1.2 应用入口与生命周期

应用入口为 `main.dart` 中的 `main()` 函数，核心流程如下：

```dart
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(...);  // 设置透明状态栏
  runApp(const OneGzusApp());                  // 启动根 Widget
  unawaited(_initDeferredServices());          // 异步初始化延迟服务
}
```

**OneGzusApp** 是根 `StatefulWidget`，管理以下全局状态：

| 状态字段 | 类型 | 说明 |
|---------|------|------|
| `api` | `ApiClient` | 全局 API 客户端实例 |
| `themeMode` | `ThemeMode` | 主题模式（亮色/暗色/跟随系统） |
| `seedColor` | `Color` | 主题种子色（可自定义） |
| `loggedIn` | `bool` | 是否已登录 |
| `initializing` | `bool` | 是否正在初始化（恢复会话） |
| `studentName` | `String?` | 当前登录学生姓名 |
| `loginMethod` | `String?` | 登录方式（"password" / "sso"） |
| `_globalDataSource` | `DataSourceInfo` | 全局数据源信息（离线/缓存状态） |
| `_backgroundGuideCompleted` | `bool` | 后台推送引导是否完成 |

**应用生命周期管理**：`_OneGzusAppState` 混入 `WidgetsBindingObserver`，监听 `didChangeAppLifecycleState` 和 `didChangePlatformBrightness` 事件：

- **App Resumed**：恢复 WebSocket 连接、JPush 服务、前台服务
- **App Paused**：暂停 WebSocket 连接、通知前台服务应用进入后台
- **Platform Brightness Changed**：响应系统深色模式切换

### 3.1.3 启动与登录恢复流程

```
┌──────────────┐
│   main()     │
└──────┬───────┘
       │
       ▼
┌──────────────────┐
│ OneGzusApp       │
│ initState()      │
└──────┬───────────┘
       │
       ├── _loadThemePreference()      ← 恢复主题偏好
       ├── _loadSeedColorPreference()  ← 恢复种子色偏好
       ├── api.startWarmup()           ← 预热 API 连接（并行探测所有候选 URL）
       │
       ▼
┌──────────────────────┐
│ _bootstrapLoginState │
└──────┬───────────────┘
       │
       ├── 检查 URL 参数 ssoError/ssoCode（SSO 回调）
       │   ├── 有 ssoError → 显示登录页 + 错误提示
       │   └── 有 ssoCode → _completeSsoLogin()
       │
       └── _restoreSession()（8秒超时保护）
           ├── 从 SharedPreferences 读取 auth.sessionId
           ├── 恢复 ehallCookies / ehallAuthToken
           ├── api.useSession(savedSession)
           ├── 设置 loggedIn=true, _globalDataSource=本地缓存
           └── _tryBackgroundRefresh() → 异步刷新 /me 接口
```

### 3.1.4 API 基础 URL 配置

API 基础 URL 通过编译时参数 `--dart-define=API_BASE_URL=...` 注入，支持逗号分隔的 **fallback 列表**：

```dart
const apiBaseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: '',
);
```

**默认配置**（当编译时未指定时）：

| 优先级 | URL | 说明 |
|--------|-----|------|
| 1 | `https://onegzus.cc.cd/api` | 主域名（Cloudflare Pages + Worker） |
| 2 | `https://onegzus-onweb.pages.dev/api` | Cloudflare Pages 回退 |

**候选地址构建逻辑**（`_buildCandidates`）：

1. 解析编译时传入的 URL 列表（逗号分隔）
2. 对每个 URL 执行 `_normalizeSingle`（去除尾部斜杠、Android 模拟器 localhost 重写）
3. 追加默认候选地址（去重）
4. **过滤掉 Vercel 直连 URL**（`*.vercel.app`），因为 Cloudflare Worker 已代理所有 API 到 Vercel，Web 端直连 Vercel 会因 CORS/GFW 导致超时

### 3.1.5 延迟加载机制

项目使用 Dart 的 `deferred as` 语法对约 15 个服务模块进行延迟加载，以优化首屏加载性能。

**DeferredServices**（应用启动时初始化）：

```dart
class DeferredServices {
  Future<void> initialize() async {
    await _loadOptionalServices();  // 加载不依赖登录的服务
  }

  Future<void> _loadOptionalServices() async {
    await Future.wait([
      ftp_upload_service.loadLibrary(),
      live_activity_service.loadLibrary(),
      live_update_service.loadLibrary(),
      location_service.loadLibrary(),
      avatar_open.loadLibrary(),
      ics_download.loadLibrary(),
      leave_attachment.loadLibrary(),
    ]);
  }
}
```

**LoginRequiredServices**（登录成功后初始化）：

```dart
class LoginRequiredServices {
  static Future<void> initialize({
    required String apiBaseUrl,
    required String sessionId,
    void Function(Map<String, dynamic>)? onNotificationTap,
  }) async {
    await Future.wait([
      _initWebPushService(onTap),           // Web Push 推送
      _initLocalNotificationService(onTap),  // 本地通知
      _initPushService(onTap),               // JPush 推送
      _initPersistentCache(),                // 持久化缓存
      _initWsService(apiBaseUrl, sessionId), // WebSocket
      _initReminderService(),                // 课程提醒
      _initUpdateService(),                  // 更新检查
      _initBackgroundService(apiBaseUrl, sessionId), // 前台服务
    ]);
  }
}
```

延迟加载的服务模块列表：

| 模块 | 加载时机 | 说明 |
|------|---------|------|
| `ws_service` | 登录后 | WebSocket 实时通信 |
| `push_service` | 登录后 | JPush 推送（Android/iOS） |
| `web_push_service` | 登录后 | Web Push 推送（Web） |
| `reminder_service` | 登录后 | 课程提醒 |
| `update_service` | 登录后 | 应用更新检查 |
| `background_service` | 登录后 | Android 前台服务 |
| `persistent_cache` | 登录后 | 持久化缓存 |
| `local_notification_service` | 登录后 | 本地通知 |
| `ftp_upload_service` | 启动时 | FTP 上传 |
| `live_activity_service` | 启动时 | iOS Live Activity |
| `live_update_service` | 启动时 | 实时更新通知 |
| `location_service` | 启动时 | 定位服务 |
| `avatar_open` | 启动时 | 头像打开 |
| `ics_download` | 启动时 | ICS 日历下载 |
| `leave_attachment` | 启动时 | 请假附件 |
| `mobile_sso` | 按需 | 移动端 SSO |
| `web_pwa_cache` | 按需 | PWA 缓存 |
| `permission_service` | 按需 | 权限管理 |

---

## 3.2 API 客户端层

### 3.2.1 架构概览

`api_client.dart`（~2988行）是前端与后端通信的核心层，封装了所有 HTTP 请求、会话管理、缓存策略和错误处理逻辑。

```
┌─────────────────────────────────────────────────────┐
│                    UI 层 (main.dart)                │
└───────────────────────┬─────────────────────────────┘
                        │ 调用
                        ▼
┌─────────────────────────────────────────────────────┐
│                  ApiClient                          │
│                                                     │
│  ┌─────────────┐  ┌──────────────┐  ┌───────────┐ │
│  │ RequestCache│  │PersistentCache│  │EcardDirect│ │
│  │ (内存缓存)  │  │ (磁盘缓存)    │  │  Client   │ │
│  └─────────────┘  └──────────────┘  └───────────┘ │
│                                                     │
│  ┌────────────────────────────────────────────────┐ │
│  │ _withFallback (请求重试 + 候选切换 + relogin) │ │
│  └────────────────────────────────────────────────┘ │
│                                                     │
│  ┌──────────┐  ┌───────────┐  ┌────────────────┐  │
│  │ _get()   │  │ _post()   │  │ _patch()       │  │
│  └──────────┘  └───────────┘  └────────────────┘  │
└───────────────────────┬─────────────────────────────┘
                        │ HTTP
                        ▼
┌─────────────────────────────────────────────────────┐
│        Cloudflare Worker / Vercel Backend           │
└─────────────────────────────────────────────────────┘
```

### 3.2.2 API 基础 URL 解析与 Fallback 机制

**候选地址管理**：

```dart
class ApiClient {
  late final String baseUrl;           // 首选 URL
  late final List<String> _candidates; // 所有候选 URL
  String _currentBaseUrl = '';         // 当前活跃 URL（可能因故障切换）
}
```

**Warmup 预热**：应用启动时，`startWarmup()` 并行探测所有候选 URL 的 `/health` 端点（5秒超时），选择第一个响应成功的 URL 作为 `_currentBaseUrl`，并预取 RSA 公钥。

**Android 模拟器 localhost 重写**：

```dart
String _normalizeSingle(String url) {
  final normalized = url.endsWith('/') ? url.substring(0, url.length - 1) : url;
  if (defaultTargetPlatform == TargetPlatform.android) {
    final uri = Uri.tryParse(normalized);
    if (uri != null && (uri.host == '127.0.0.1' || uri.host == 'localhost')) {
      return uri.replace(host: '10.0.2.2').toString();
    }
  }
  return normalized;
}
```

### 3.2.3 会话管理

**会话标识**：通过 `X-Session-Id` 请求头传递，在登录成功后由服务端返回。

```dart
Map<String, String> _headers() => {
  'Content-Type': 'application/json',
  'User-Agent': 'Mozilla/5.0 (Linux; Android 16) GZUS-PRO/1.0',
  if (sessionId != null) 'X-Session-Id': sessionId!,
};
```

**会话持久化**：登录成功后，将 `sessionId`、`studentName`、`studentId`、`loginMethod`、`ehallCookies`、`ehallAuthToken`、`credentialToken` 等写入 `SharedPreferences`，下次启动时通过 `_restoreSession()` 恢复。

**自动重新登录（Relogin）**：

当 API 请求返回 401 时，`_withReloginRetry` 自动触发 relogin 流程：

1. 加载已保存的 `credentialToken`
2. 调用 `POST /auth/relogin`（携带 credentialToken）
3. 成功后重试原始请求
4. 失败时触发 `onReloginFailed` 回调，UI 层导航到登录页

**Relogin 退避策略**：

```dart
static const Duration _reloginMinInterval = Duration(seconds: 5);
static const int _reloginMaxBackoffSeconds = 120;
// 退避时间 = min(5 * 2^failures, 120) 秒
```

**5秒冷却期**：登录成功后 5 秒内的 relogin 失败会被忽略，防止因 Vercel/Neon 冷启动瞬态 401 导致误登出。

### 3.2.4 RSA 密码加密

登录时密码使用服务端公钥进行 RSA 加密，避免明文传输：

```dart
Future<void> fetchPublicKey() async {
  final response = await _http.get(Uri.parse('$url/auth/public-key'), ...);
  final pem = data['publicKey'];
  final keyId = data['keyId'];
  _rsaPublicKeyPem = pem;
  _rsaKeyId = keyId;
}

String? _rsaEncrypt(String plaintext, String publicKeyPem) {
  final publicKey = encrypt.RSAKeyParser().parse(publicKeyPem) as RSAPublicKey;
  final encrypter = encrypt.Encrypter(encrypt.RSA(
    publicKey: publicKey,
    encoding: encrypt.RSAEncoding.PKCS1,
  ));
  return encrypter.encrypt(plaintext).base64;
}
```

登录请求体结构：

```json
{
  "account": "学号",
  "encryptedPassword": "RSA加密后的Base64字符串",
  "keyId": "公钥标识"
}
```

若 RSA 加密失败或公钥未获取，则降级为明文密码传输。

### 3.2.5 数据结果封装

**DataSourceInfo** — 数据来源信息：

```dart
class DataSourceInfo {
  final bool fromCache;       // 来自内存缓存
  final bool fromLocalCache;  // 来自持久化缓存
  final DateTime? cachedAt;   // 缓存时间
  final bool isOffline;       // 是否离线
  final bool needsRelogin;    // 是否需要重新登录

  String get displayText;     // 显示文本（"离线缓存"/"本地缓存"/"更新失败，显示上次数据"等）
  bool get isStale;           // 数据是否过时（fromCache || fromLocalCache）
}
```

**DataResult\<T\>** — 统一数据返回结构：

```dart
class DataResult<T> {
  final T data;
  final DataSourceInfo source;
}
```

### 3.2.6 离线缓存与本地缓存策略

ApiClient 实现了三级缓存策略：**内存缓存 → 持久化缓存 → 网络请求**。

**RequestCache**（内存缓存）：

```dart
class RequestCache {
  final Map<String, CacheEntry<dynamic>> _cache = {};
  final Duration defaultTtl;     // 默认 TTL：5 分钟
  final int maxEntries;          // 最大条目数：128

  T? get<T>(String key);         // 获取（过期自动清除）
  void set<T>(String key, T data, [Duration? ttl]);
  void clear();
}
```

**PersistentCache**（磁盘缓存，基于 SharedPreferences）：

```dart
class PersistentCache {
  final String namespace;  // 按 studentId 或 sessionId 命名空间隔离

  Future<void> set(String key, dynamic data);
  dynamic getRaw(String key);
  DateTime? getCachedAt(String key);
  Future<void> clearForStudent(String studentId);
}
```

**缓存优先策略**（`_cacheFirstObject` / `_cacheFirstList`）：

```
┌─────────────────────────────────────────────────────┐
│ 1. 检查内存缓存                                     │
│    ├── 命中 → 直接返回 DataResult(source: fresh)    │
│    └── 未命中 ↓                                     │
│ 2. 检查持久化缓存                                   │
│    ├── 命中 → 返回 DataResult(source: fromLocalCache)│
│    │         + 触发后台刷新（_queueBackgroundRefresh）│
│    └── 未命中 ↓                                     │
│ 3. 发起网络请求                                     │
│    ├── 成功 → 写入内存缓存 + 持久化缓存 → 返回      │
│    └── 失败 → 尝试回退到任何可用缓存 → 返回离线数据  │
└─────────────────────────────────────────────────────┘
```

**后台刷新**：当从持久化缓存返回数据时，自动触发后台刷新（5分钟冷却期），用户无需手动下拉即可获取最新数据。

### 3.2.7 请求重试与候选切换

`_withFallback` 实现了带候选地址切换的请求重试机制：

```
请求失败
├── 401 (Unauthorized)
│   ├── 其他设备登录 → 清除凭证 → 触发登出
│   ├── 有 credentialToken → 自动 relogin → 重试请求
│   │   ├── relogin 成功 → 重试原始请求
│   │   └── relogin 失败 → 触发 onReloginFailed → 登出
│   └── 无 credentialToken → 抛出"登录已过期"
│
├── 5xx (Server Error)
│   └── 同一地址重试1次 → 仍失败则抛出
│
├── TimeoutException
│   └── 同一地址重试1次 → 切换到下一个候选地址 → 重试
│
├── ClientException / SocketException
│   └── 同一地址重试1次 → 切换到下一个候选地址 → 重试
│
└── 其他异常 → 直接抛出
```

### 3.2.8 所有 API 调用方法

| 方法 | 端点 | 说明 |
|------|------|------|
| `login()` | `POST /auth/login` | 教务系统账密登录 |
| `submitCaptcha()` | `POST /auth/captcha` | 提交验证码 |
| `completeLySso()` | `POST /auth/ly/complete` | 完成联奕 SSO 登录 |
| `autoLogin()` | `POST /auth/auto-login` | 自动登录（Worker 边缘处理） |
| `relogin()` | `POST /auth/relogin` | 重新登录（credentialToken） |
| `logout()` | `POST /auth/logout` | 登出 |
| `fetchPublicKey()` | `GET /auth/public-key` | 获取 RSA 公钥 |
| `me()` | `GET /me` | 获取学生个人信息 |
| `fetchStudentInfo()` | `GET /auth/student-info` | 登录后异步获取学生信息 |
| `schedule()` | `GET /schedule` | 获取课表 |
| `exams()` | `GET /exams` | 获取考试安排 |
| `grades()` | `GET /grades` | 获取成绩 |
| `attendance()` | `GET /attendance` | 获取考勤 |
| `credits()` | `GET /credits` | 获取学分统计 |
| `weather()` | `GET /weather` | 获取天气信息 |
| `notices()` | `GET /notices` | 获取通知列表 |
| `fetchNoticeDetail()` | `GET /notices/detail` | 获取通知详情 |
| `previewLeave()` | `POST /ehall/leave/preview` | 预览请假信息 |
| `fillLeave()` | `POST /ehall/leave/fill` | 自动填写请假 |
| `uploadLeaveAttachment()` | `POST /ehall/leave/attachment` | 上传请假附件 |
| `ehallAffairs()` | `GET /ehall/affairs` | 获取办事大厅事务 |
| `ehallApplications()` | `GET /ehall/applications` | 获取办事大厅应用 |
| `ehallProgressOverview()` | `GET /ehall/progress` | 获取业务进度概览 |
| `ecardRooms()` | `GET /ecard/rooms` | 获取一卡通房间列表 |
| `ecardSummary()` | `GET /ecard/summary` | 获取水电费概览 |
| `bindEcardRoom()` | `POST /ecard/binding` | 绑定房间 |
| `refreshEcard()` | `POST /ecard/refresh` | 刷新水电费 |
| `updateEcardReminder()` | `PATCH /ecard/reminder` | 更新水电费提醒设置 |
| `ecardConsumption()` | `GET /ecard/consumption` | 获取一卡通消费记录 |
| `registerPush()` | `POST /push/register` | 注册推送 |
| `unregisterPush()` | `POST /push/unregister` | 注销推送 |
| `pollPushMessages()` | `GET /push/poll` | 轮询推送消息 |
| `getWebPushConfig()` | `GET /push/web/config` | 获取 Web Push 配置 |
| `lySsoStartUrl()` | — | 生成联奕 SSO 起始 URL |
| `checkHealth()` | `GET /health` | 健康检查（探测所有候选） |

### 3.2.9 一卡通直连客户端（EcardDirectClient）

由于一卡通服务器（`ecarduser.gzus.edu.cn`）封禁了 Vercel/Cloudflare Worker 的 IP，原生移动端（Android/iOS）实现了直连客户端，绕过后端直接调用一卡通 API：

```dart
class EcardDirectClient {
  static const _base = 'https://ecarduser.gzus.edu.cn';
  static const _secret = 'greatge';     // API 签名密钥
  static const _openid = 'o6gXt5YdtSc-15PgJg0KqAXZytRc';

  // MD5 签名：参数按 key 排序拼接 + secret → MD5
  static String _sign(Map<String, String> params);

  Future<bool> login();                  // 登录获取 token
  Future<List<EcardRoomItem>> getRooms(); // 获取房间列表
  Future<Map<String, dynamic>?> getBalance(String roomId); // 获取余额
}
```

**签名算法**：参数按 key 字母序排列，拼接为 `key1=value1&key2=value2&secret`，取 MD5 大写。

**直连优先策略**：在 `ecardRooms()` 和 `ecardSummary()` 中，原生移动端优先尝试直连，失败后降级到后端缓存。

---

## 3.3 页面与 UI 设计

### 3.3.1 页面结构概览

所有页面 UI 集中在 `main.dart` 中（~15716行），采用单文件架构。主要页面/功能模块如下：

| 页面 | 类名 | tabId | 说明 |
|------|------|-------|------|
| 登录页 | `LoginPage` | — | 教务系统账密登录 + SSO 一键登录 |
| 首页 | `HomePage` | `home` | 综合信息仪表盘 |
| 个人信息页 | `InfoPage` | `info` | 学生详细信息 + 头像 |
| 通知页 | `NoticesPage` | `notices` | 教务通知列表 + 详情 |
| 业务页 | `BusinessPage` | `business` | 办事大厅业务进度 |
| 应用页 | `ApplicationsPage` | `applications` | 办事大厅应用列表 |
| 课表页 | `SchedulePage` | `schedule` | 课程表（时间表/列表视图） |
| 自动请假页 | `AutoLeavePage` | `leave` | 自动填写请假表单 |
| 考勤页 | — | `attendance` | 考勤统计 |
| 考试页 | — | `exams` | 考试安排 |
| 成绩页 | — | `grades` | 成绩查询 |
| 学分页 | — | `credits` | 学分统计 |
| 生活缴费页 | — | `ecard` | 水电费查询 + 一卡通 |
| 作业上传页 | `FtpUploadPage` | `ftpUpload` | FTP 作业上传 |
| 加载页 | `LoadingPage` | — | 启动加载动画 |
| 后台引导页 | `BackgroundGuidePage` | — | 推送通知引导 |

### 3.3.2 导航结构

**DashboardShell** 是登录后的主容器，根据屏幕宽度自适应导航方式：

- **窄屏（< 800px）**：底部导航栏（`MobileNavBar`），最多显示 5 个固定 Tab + "更多"入口
- **宽屏（≥ 800px）**：侧边导航栏（`AppSidebar`），显示所有 Tab

**NavTabConfig** 定义了所有可用的导航 Tab：

```dart
class NavTabConfig {
  final String tabId;
  final IconData icon;
  final String label;
  final String shortLabel;
  final bool isFixed;  // 是否固定显示（不可从导航栏移除）
}
```

**默认导航栏配置**：

```
首页 → 个人信息 → 应用 → 课表 → 自动请假 → 考勤 → 考试 → 成绩 → 学分 → [生活缴费] → 更多
```

> 生活缴费（ecard）仅在原生移动端显示，Web 端隐藏。

**导航栏自定义**：用户可通过 `NavPreferences` 自定义底部导航栏的 Tab 顺序和显示，配置持久化到 `SharedPreferences`。

**导航栏自动隐藏**：滚动时自动隐藏底部导航栏（可通过设置开关），通过 `ScrollNotification` 监听滚动方向实现。

**账密登录限制**：使用账密登录（`loginMethod == 'password'`）时，以下 Tab 不可用（依赖 ehall 会话）：

- `notices`（通知）
- `business`（业务）
- `applications`（应用）
- `leave`（自动请假）

### 3.3.3 登录页设计

`LoginPage` 支持两种登录方式：

1. **办事大厅一键登录（SSO）**：通过联奕 SSO 流程，跳转到学校统一认证页面
2. **教务系统账密登录**：输入学号 + 密码 + 验证码

**登录流程**：

```
┌─────────────────────────────────────┐
│           LoginPage                 │
│                                     │
│  ┌───────────────────────────────┐  │
│  │  一键登录按钮 (SSO)           │  │
│  │  → lySsoStartUrl()           │  │
│  │  → 浏览器跳转 CAS 登录       │  │
│  │  → 回调携带 ssoCode          │  │
│  │  → completeLySso(ssoCode)    │  │
│  └───────────────────────────────┘  │
│                                     │
│  ┌───────────────────────────────┐  │
│  │  账密登录表单                 │  │
│  │  学号输入框                   │  │
│  │  密码输入框                   │  │
│  │  验证码图片 + 输入框         │  │
│  │  登录按钮                     │  │
│  │  → login(account, password)  │  │
│  │  → submitCaptcha(token, code)│  │
│  └───────────────────────────────┘  │
└─────────────────────────────────────┘
```

**登录状态持久化**：支持"记住账号"功能，密码不再本地存储（安全考量）。

### 3.3.4 首页（HomePage）设计

首页是一个综合信息仪表盘，以卡片形式展示各模块摘要信息：

| 卡片 | 类名 | 说明 |
|------|------|------|
| 下一节课 | `_NextClassHomeCard` | 显示最近一节课的信息 |
| 今日时间线 | `_TodayTimelineHomeCard` | 今日课程时间线 |
| 本周课表 | `_WeekGridHomeCard` | 本周课程网格 |
| 今日课程 | `_DailyCoursesHomeCard` | 今日课程列表 |
| 水电费 | `_UtilitiesHomeCard` | 水电费余额摘要 |
| 业务进度 | `_BusinessProgressHomeCard` | 办事大厅待办/进行中 |
| 通知 | `_NotificationsHomeCard` | 最新通知 |
| 考勤 | `_AttendanceHomeCard` | 考勤统计 |
| 学分 | `_CreditsHomeCard` | 学分完成进度 |
| 个人信息 | `_ProfileHomeCard` | 头像 + 姓名 + 学号 |
| 应用 | `_AppsHomeCard` | 常用应用快捷入口 |
| 天气 | `_WeatherHomeCard` | 天气信息 |
| 成绩 | `_GradesHomeCard` | 最近成绩 |
| 考试倒计时 | `_ExamCountdownHomeCard` | 即将到来的考试 |

卡片使用 `_AsyncModuleCard<T>` 组件封装，支持异步加载、骨架屏（Shimmer）占位、错误展示。

### 3.3.5 课表页设计

`SchedulePage` 支持两种视图模式：

1. **时间表视图**（`TimetableView`）：经典周课表网格，横轴为星期、纵轴为节次
2. **可读列表视图**（`ScheduleReadableView`）：按"今天/本周/全部"分组的课程列表

**课表工具栏**：

- 学年/学期选择器
- 周次选择器（自动检测当前周）
- 视图切换按钮
- ICS 日历导出
- 课程管理（自定义课程颜色标记）

**ScheduleCourse 数据模型**：

```dart
class ScheduleCourse {
  final String name;         // 课程名称
  final String? teacher;     // 教师
  final String? classroom;   // 教室
  final int? weekday;        // 星期几 (1-7)
  final int? startSection;   // 开始节次
  final int? endSection;     // 结束节次
  final String? weeks;       // 周次规格（如 "1-16周(单)"）
  final String? kcbmc;       // 课程班名称
  final Map<String, dynamic> raw;  // 原始数据

  bool occursInWeek(int week);  // 判断某周是否有课
}
```

**周次解析**：`_weekSpecContains` 支持多种中文周次格式，如 `1-16周`、`1,3,5周`、`1-16周(单)`、`1-16周(双)` 等。

### 3.3.6 深色模式支持

应用完整支持深色模式，通过 `ThemeMode` 控制：

- `ThemeMode.system`：跟随系统
- `ThemeMode.light`：强制亮色
- `ThemeMode.dark`：强制暗色

主题偏好持久化到 `SharedPreferences`，键名为 `theme.mode`。

**种子色自定义**：用户可选择不同的主题种子色（`seedColor`），通过 `ColorScheme.fromSeed` 生成完整的 Material 3 配色方案。种子色偏好持久化到 `theme.seedColor`。

---

## 3.4 服务模块设计

### 3.4.1 WebSocket 实时通信（ws_service.dart）

**WsService** 提供与服务端的实时双向通信，用于接收即时通知推送。

**连接管理**：

```dart
class WsService {
  static WebSocketChannel? _channel;
  static String? _baseUrl;
  static String? _sessionId;
  static bool _isPaused = false;
  static int _reconnectDelay = 1;  // 指数退避重连

  static void configure({required String apiBaseUrl, required String sessionId});
  static Future<void> connect();
  static void disconnect();
  static void pause();   // 应用进入后台时调用
  static void resume();  // 应用回到前台时调用
}
```

**WebSocket URL 构建**：将 HTTP(S) 基础 URL 转换为 WS(S) URL，路径为 `/ws/notifications`：

```dart
static String _buildWsUrl(String baseUrl) {
  final uri = Uri.parse(baseUrl);
  final scheme = uri.scheme == 'https' ? 'wss' : 'ws';
  return uri.replace(scheme: scheme, path: '${uri.path}/ws/notifications')
      .toString() + '?sessionId=$_sessionId';
}
```

**消息处理流程**：

```
收到 WebSocket 消息
├── JSON 解析
├── 提取 title / body / type / extras
├── LiveActivityController.show()  → iOS Live Activity / Android 实时通知
├── 非 liveUpdate 消息 → LocalNotificationService.show() → 系统通知
└── liveUpdate 消息 → 仅更新 Live Activity，不弹通知
```

**重连策略**：指数退避（1s → 2s → 4s → ... → 最大 30s），应用暂停时断开连接，恢复时重新连接。

### 3.4.2 JPush 推送服务（push_service.dart）

**PushService** 通过平台通道（MethodChannel）与原生 JPush SDK 交互：

```dart
class PushService {
  static const _channel = MethodChannel('cn.gzus.pro/push');
  static String? _registrationId;
  static OnPushTap? _onTap;

  static Future<void> init({OnPushTap? onTap});
  static void stop();
  static void resume();
}
```

- 仅在 Android/iOS 原生平台生效，Web 端跳过
- `registrationId` 用于向服务端注册推送
- 通知点击回调通过 `_consumeNotificationOpen()` 从原生端获取

### 3.4.3 Web Push 推送服务（web_push_service.dart）

**WebPushService** 为 Web 端提供基于 W3C Push API 的推送通知：

```dart
abstract class WebPushService {
  Future<void> init({OnPushClick? onTap});
  Future<bool> isSupported();
  Future<bool> isSubscribed();
  Future<String> getPermissionStatus();  // 'granted' / 'denied' / 'default'
  Future<bool> requestPermission();
  Future<void> subscribe(String publicKey, {required String apiBaseUrl, required String sessionId});
  Future<void> unsubscribe({required String apiBaseUrl, required String sessionId});
}
```

采用条件导入模式：

```dart
import 'web_push_service_stub.dart'
    if (dart.library.html) 'web_push_service_web.dart' as impl;
```

- Web 端使用 `web_push_service_web.dart`（基于 `dart:html` 的 PushManager API）
- 非 Web 端使用 `web_push_service_stub.dart`（空实现）

### 3.4.4 课程提醒服务（reminder_service.dart）

**ReminderService** 根据课表数据自动设置课程提醒：

```dart
class ReminderService {
  static void configureCourseReminders({
    required List<ScheduleCourse> courses,
    required DateTime firstWeekStart,
    required CourseReminderSettings settings,
  });

  static void cancelCourseReminders();
  static int get pendingCourseReminderCount;
}
```

**CourseReminderSettings**：

```dart
class CourseReminderSettings {
  final bool enabled;              // 是否启用
  final int beforeStartMinutes;    // 课前提醒时间（默认 10 分钟）
  final int beforeEndMinutes;      // 课结束前提醒时间（默认 5 分钟）
}
```

**提醒触发流程**：

1. 根据课表计算所有未来课程的提醒时间点
2. 为每个提醒创建 `Timer`
3. 到时间后通过 `LiveActivityController` 和 `LocalNotificationService` 展示提醒
4. 使用签名机制避免重复设置（`_courseSignature`）

### 3.4.5 应用更新检查（update_service.dart）

**UpdateService** 基于 Shiply 渠道检查 Android 应用更新：

```dart
class UpdateService {
  Future<void> checkForUpdateIfNeeded({bool forceCheck = false});
  Future<void> forceCheckForUpdate();
  Future<Map<String, dynamic>?> getUpgradeStrategy();
  Future<bool> hasUpdate();
}
```

- 仅在 Android 原生平台生效
- 默认 24 小时检查一次（频率限制）
- 通过 `MethodChannel('cn.gzus.pro/upgrade')` 与原生 Shiply SDK 交互

### 3.4.6 前台服务（background_service.dart）

**BackgroundService** 通过 Android 前台服务保持应用在后台运行，确保推送和提醒正常工作：

```dart
class BackgroundService {
  static const _channel = MethodChannel('cn.gzus.pro/background_service');

  static Future<void> enableForegroundService({String? apiBaseUrl, String? sessionId});
  static Future<void> disableForegroundService();
  static Future<void> setHideFromRecents(bool hide);
  static Future<void> updateCourseReminders({required String coursesJson, ...});
  static Future<void> setAppForeground(bool foreground);
}
```

- 仅在 Android 平台生效
- `setAppForeground` 通知原生层应用前后台状态切换
- `updateCourseReminders` 将课表数据传递给原生层，用于原生定时提醒

### 3.4.7 持久化缓存（persistent_cache.dart）

**PersistentCache** 基于 `SharedPreferences` 实现跨会话数据持久化：

```dart
class PersistentCache {
  final String namespace;  // 按 studentId 隔离

  Future<void> init();
  Future<void> set(String key, dynamic data);
  dynamic getRaw(String key);
  DateTime? getCachedAt(String key);
  Future<void> remove(String key);
  Future<void> clearAll();
  static Future<void> clearForStudent(String studentId);
}
```

**存储格式**：

- 数据键：`pcache_{namespace}_{key}`
- 时间键：`pcache_{namespace}_{key}_at`
- 值为 JSON 编码的字符串

**版本迁移**：通过 `_cacheVersion` 和 `_versionKey` 管理缓存版本，版本升级时自动清理。

### 3.4.8 本地通知服务（local_notification_service.dart）

采用条件导入模式，Web 端使用浏览器 Notification API，原生端使用 flutter_local_notifications：

```dart
import 'local_notification_service_stub.dart'
    if (dart.library.html) 'local_notification_service_web.dart' as impl;
```

核心功能：

- `init({OnPushTap? onTap})` — 初始化通知渠道和权限
- `show({required int id, required String title, required String body, ...})` — 展示通知
- 通知点击回调通过 `onTap` 传递

### 3.4.9 Live Activity 服务（live_activity_service.dart）

**LiveActivityController** 是一个跨平台的实时活动展示控制器，支持 iOS Live Activity、Android 实时通知和 Web 端的进度条：

```dart
class LiveActivityController {
  static final LiveActivityController instance = LiveActivityController._();
  LiveActivityOpenHandler? onOpen;

  void show(LiveActivityEvent event);
  void dismiss(String id);
}
```

**LiveActivityEvent** 数据模型：

```dart
class LiveActivityEvent {
  final String id;
  final String type;          // 'course_reminder', 'ecard_reminder', 'exam_reminder' 等
  final String title;
  final String body;
  final String style;         // 'timer', 'metric', 'progress'
  final DateTime? endTime;    // 倒计时目标时间
  final String? shortText;    // 状态芯片文本
  final String? targetTab;    // 点击后跳转的 Tab
  final String? url;          // 点击后打开的 URL
  final bool ongoing;         // 是否持续显示
  final int? progress;        // 进度值
}
```

### 3.4.10 实时更新服务（live_update_service.dart）

**LiveUpdateService** 通过 MethodChannel 与 Android 原生层交互，发布实时更新通知：

```dart
class LiveUpdateService {
  static Future<bool> postLiveUpdate({
    required int id,
    required String title,
    required String body,
    String style = 'timer',
    int endTimeMillis = 0,
    String? shortCriticalText,
    Map<String, dynamic>? extras,
    bool? ongoing,
    int progressMax = 0,
    int progressCurrent = 0,
  });

  static Future<bool> postTimedProgressLiveUpdate({...});
}
```

- 仅在 Android 平台生效
- 支持 `timer`（倒计时）、`metric`（指标）、`progress`（进度条）三种样式
- 自动调度过期取消（`_scheduleCancel`）

### 3.4.11 其他服务模块

| 模块 | 文件 | 说明 |
|------|------|------|
| FTP 上传 | `ftp_upload_service.dart` | FTP 文件上传服务 |
| ICS 日历下载 | `ics_download.dart` | 导出课表/考试为 ICS 日历文件（条件导入：Web 端使用浏览器下载） |
| 请假附件 | `leave_attachment.dart` | 请假附件上传（条件导入：Web 端使用 FilePicker） |
| 移动端 SSO | `mobile_sso.dart` | 移动端 WebView SSO 登录（条件导入：仅原生端） |
| 头像打开 | `avatar_open.dart` | 头像全屏查看（条件导入：Web 端使用浏览器新窗口） |
| PWA 缓存 | `web_pwa_cache.dart` | PWA API 响应缓存（条件导入：仅 Web 端） |
| 定位服务 | `location_service.dart` | GPS 定位（条件导入：Web/IO/Stub 三端实现） |
| 权限管理 | `permission_service.dart` | 运行时权限请求 |
| 浏览器重定向 | `browser_redirect.dart` | URL 参数清理（SSO 回调后去除 URL 参数） |
| Bugly 崩溃上报 | `bugly_service.dart` | Bugly 崩溃收集 |

---

## 3.5 平台适配层

### 3.5.1 条件导入机制

项目使用 Dart 的条件导入（Conditional Imports）实现跨平台代码适配：

```dart
// 方式一：export + 条件导入（用于纯接口模块）
export 'location_service_stub.dart'
    if (dart.library.html) 'location_service_web.dart'
    if (dart.library.io) 'location_service_io.dart';

// 方式二：import + 条件导入（用于需要手动创建实例的模块）
import 'web_push_service_stub.dart'
    if (dart.library.html) 'web_push_service_web.dart' as impl;
```

### 3.5.2 三层适配模式

每个需要平台差异的功能模块通常包含三个文件：

| 文件后缀 | 运行平台 | 说明 |
|---------|---------|------|
| `*_web.dart` | Web（`dart:html`） | 基于 Web API 的实现 |
| `*_io.dart` | Android/iOS（`dart:io`） | 基于原生 API 的实现 |
| `*_stub.dart` | 所有平台 | 回退/桩实现（空操作或抛出 UnsupportedError） |

### 3.5.3 平台适配模块清单

| 模块 | Web 实现 | IO 实现 | Stub 实现 |
|------|---------|---------|----------|
| 本地通知 | `local_notification_service_web.dart` | — | `local_notification_service_stub.dart` |
| Web Push | `web_push_service_web.dart` | — | `web_push_service_stub.dart` |
| ICS 下载 | `ics_download_web.dart` | — | `ics_download_stub.dart` |
| 请假附件 | `leave_attachment_web.dart` | — | `leave_attachment_stub.dart` |
| 头像打开 | `avatar_open_web.dart` | — | `avatar_open_stub.dart` |
| PWA 缓存 | `web_pwa_cache_web.dart` | — | `web_pwa_cache_stub.dart` |
| 定位服务 | `location_service_web.dart` | `location_service_io.dart` | `location_service_stub.dart` |
| 移动端 SSO | — | `mobile_sso_io.dart` | `mobile_sso_stub.dart` |
| 浏览器重定向 | `browser_redirect_web.dart` | — | `browser_redirect_stub.dart` |

### 3.5.4 平台差异处理策略

**Web 平台特殊处理**：

- 一卡通（ecard）功能在 Web 端隐藏（`_hideEcardOnCurrentPlatform`）
- 推送服务在 Web 端使用 Web Push API 替代 JPush
- 文件下载在 Web 端使用浏览器原生下载
- SSO 登录在 Web 端使用浏览器跳转，在移动端使用 WebView

**Android 平台特殊处理**：

- `localhost`/`127.0.0.1` 自动重写为 `10.0.2.2`（模拟器访问本机服务）
- 前台服务保持后台运行
- JPush 推送集成
- Shiply 应用更新检查

**iOS 平台特殊处理**：

- Live Activity 集成（课程倒计时等）
- APNs 推送

**运行时平台检测**：

```dart
import 'package:flutter/foundation.dart';

kIsWeb                                    // 是否 Web 平台
defaultTargetPlatform == TargetPlatform.android  // 是否 Android
defaultTargetPlatform == TargetPlatform.iOS      // 是否 iOS
```

---

## 3.6 设计系统

### 3.6.1 颜色系统（GzusColors）

```dart
class GzusColors {
  // ─── 亮色模式 ───
  static const ink = Color(0xFF17191D);         // 主文字
  static const muted = Color(0xFF6B7280);        // 辅助文字
  static const canvas = Color(0xFFFAFAF8);       // 页面背景
  static const surface = Color(0xFFFFFFFF);       // 卡片/面板背景
  static const surfaceSoft = Color(0xFFF4F6FA);   // 输入框/标签背景
  static const border = Color(0xFFE5E7EB);        // 边框

  // ─── 语义色 ───
  static const blue = Color(0xFF2563EB);          // 主色
  static const blueDark = Color(0xFF1D4ED8);      // 主色深色
  static const blueSoft = Color(0xFFEAF2FF);      // 主色浅色背景
  static const green = Color(0xFF059669);          // 成功
  static const greenSoft = Color(0xFFEAFBF2);      // 成功浅色背景
  static const amber = Color(0xFFD97706);          // 警告
  static const amberSoft = Color(0xFFFFF7E6);      // 警告浅色背景
  static const red = Color(0xFFDC2626);            // 错误
  static const redSoft = Color(0xFFFFECEC);        // 错误浅色背景

  // ─── 暗色模式 ───
  static const darkCanvas = Color(0xFF0F1115);     // 暗色页面背景
  static const darkSurface = Color(0xFF181B21);    // 暗色卡片背景
  static const darkSurfaceSoft = Color(0xFF20242C);// 暗色输入框背景
  static const darkBorder = Color(0xFF2A2F3A);     // 暗色边框
}
```

### 3.6.2 圆角系统（GzusRadii）

```dart
class GzusRadii {
  static const sm = 12.0;   // 小圆角（Chip、标签）
  static const md = 16.0;   // 中圆角（输入框、按钮）
  static const lg = 20.0;   // 大圆角（卡片）
  static const xl = 24.0;   // 超大圆角（登录卡片、弹窗）
}
```

### 3.6.3 主题构建（gzusTheme）

`gzusTheme` 函数基于 `ColorScheme.fromSeed` 生成完整的 Material 3 主题：

```dart
ThemeData gzusTheme(Brightness brightness, {
  double navBarHeight = 76,
  Color seedColor = GzusColors.blue,
}) {
  final scheme = ColorScheme.fromSeed(seedColor: seedColor, brightness: brightness);
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: isDark ? darkCanvas : canvas,
    fontFamily: 'Noto Sans SC',
    textTheme: TextTheme(...),           // 完整排版系统
    cardTheme: CardThemeData(...),       // 卡片样式
    navigationBarTheme: ...,             // 底部导航栏样式
    navigationRailTheme: ...,            // 侧边导航栏样式
    inputDecorationTheme: ...,           // 输入框样式
    filledButtonTheme: ...,              // 填充按钮样式
    outlinedButtonTheme: ...,            // 描边按钮样式
    textButtonTheme: ...,                // 文本按钮样式
    chipTheme: ...,                      // 标签样式
    appBarTheme: ...,                    // 应用栏样式
    snackBarTheme: ...,                  // 提示条样式
  );
}
```

### 3.6.4 辅助函数

```dart
// 根据当前主题获取表面色
Color gzusSurface(BuildContext context);

// 根据当前主题获取柔和表面色
Color gzusSurfaceSoft(BuildContext context);

// 根据当前主题获取边框色
Color gzusBorder(BuildContext context);

// 根据当前主题获取阴影
List<BoxShadow> gzusShadow(BuildContext context);
```

### 3.6.5 Material 3 适配

- 使用 `useMaterial3: true` 启用 Material 3
- 通过 `ColorScheme.fromSeed` 自动生成完整的配色方案
- 支持 `WidgetStateProperty` 实现交互状态样式
- 导航栏使用 `NavigationBar`（Material 3 组件）替代 `BottomNavigationBar`

---

## 3.7 Cloudflare Worker

### 3.7.1 角色定位

`web/_worker.js`（~1773行）是部署在 Cloudflare Pages 上的边缘 Worker，承担两个核心职责：

1. **边缘节点 CAS SSO 登录**：直接在 Cloudflare 边缘节点执行 CAS 登录流程，降低对中国大陆用户的延迟
2. **请求代理**：将非边缘处理的 API 请求代理到 Vercel 后端，并注入 JWXT 会话 Cookie

```
┌──────────────┐     ┌──────────────────────────────┐     ┌──────────────┐
│  Flutter App │────▶│     Cloudflare Worker         │────▶│    Vercel    │
│  (前端)      │     │                              │     │   Backend    │
└──────────────┘     │  边缘处理：                    │     └──────────────┘
                     │  • POST /auth/auto-login      │           │
                     │  • POST /auth/relogin         │           │
                     │  • GET  /health               │           │
                     │  • GET  /me (学术数据)         │           │
                     │  • GET  /schedule /exams ...   │           │
                     │  • GET  /notices               │           │
                     │                               │           │
                     │  代理到 Vercel：               │           │
                     │  • /ehall/* /ecard/* /push/*   │◀──────────┘
                     │  • /auth/captcha /auth/login   │
                     │  • /auth/ly/complete           │
                     │  • 其他所有路由                 │
                     └──────────────────────────────┘
```

### 3.7.2 RSA 加密实现

Worker 内嵌了 CAS 系统的 RSA 公钥，实现了 BigInt.js 风格的 RSA 加密：

```javascript
const RSA_E = 0x010001n;
const RSA_N = BigInt('0x00b5eeb166e069920...');
const RSA_TAG = 'lyasp';

function rsaEncrypt(plaintext) {
  // 1. 将明文转为字符编码数组
  // 2. 按 chunkSize 分块，零填充
  // 3. 每块转为 BigInt
  // 4. 执行模幂运算：c = m^e mod n
  // 5. 输出十六进制字符串，空格分隔
}

function modPow(base, exp, mod) {
  // 快速模幂算法（平方-乘法）
}
```

**加密用途**：

- 加密用户密码（`rsaEncrypt(password)`）
- 生成登录令牌（`rsaEncrypt(RSA_TAG + timestamp)`）

### 3.7.3 CAS 登录流程

`casAutoLogin` 函数实现了完整的 CAS SSO 登录流程：

```
┌─────────────────────────────────────────────────────────────┐
│                    CAS Auto Login 流程                       │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  Step 1: GET CAS 登录页面                                    │
│  → 建立会话 Cookie（最多重试 3 次）                           │
│                                                             │
│  Step 2-4: 验证码循环（最多 MAX_CAPTCHA_RETRIES=15 次）      │
│  ┌──────────────────────────────────────────────────┐       │
│  │ Step 2: 下载验证码                               │       │
│  │ → GET /lyuapServer/kaptcha                      │       │
│  │ → 获取 uid + base64 图片                         │       │
│  │                                                  │       │
│  │ Step 3: OCR 识别验证码                            │       │
│  │ → POST /internal/ocr (Vercel 后端)               │       │
│  │ → solveArithmeticCaptcha() 算术验证码求解         │       │
│  │                                                  │       │
│  │ Step 4: 提交登录                                 │       │
│  │ → POST /lyuapServer/v1/tickets                  │       │
│  │ → Body: username, password(RSA加密), service,    │       │
│  │         id(kaptchaUid), code(验证码答案)          │       │
│  │ → Header: token(RSA加密的时间戳)                 │       │
│  │                                                  │       │
│  │ 成功 → 获取 ticket + TGT                         │       │
│  │ 失败 → CODEFALSE → 重试                          │       │
│  └──────────────────────────────────────────────────┘       │
│                                                             │
│  Step 5: finalizeLogin()                                    │
│  ├── fetchJwxtCookies(ticket) → JWXT 会话 Cookie            │
│  ├── fetchEhallSession(tgt) → ehall sid Cookie              │
│  ├── fetchStudentName() → 从 JWXT 信息页提取姓名             │
│  └── encryptCredentials() → AES-GCM 加密凭证               │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

**错误码处理**：

| 错误码 | 含义 | 处理 |
|--------|------|------|
| `FALSE` | 用户名或密码错误 | 返回错误 |
| `CODEFALSE` | 验证码错误 | 重试 |
| `PASSERROR` | 密码错误 | 返回错误 |
| `NOUSER` | 账号不存在 | 返回错误 |
| `USERDISABLED` | 账号禁用 | 返回错误 |
| `USERLOCK` | 账号锁定 | 返回错误 |

### 3.7.4 请求代理逻辑

Worker 对不同路由采用不同的处理策略：

**边缘处理的路由**（直接在 Worker 执行，不代理到 Vercel）：

| 路由 | 方法 | 说明 |
|------|------|------|
| `/auth/auto-login` | POST | CAS 自动登录 |
| `/auth/relogin` | POST | 凭证令牌重新登录 |
| `/health` | GET | 健康检查 |
| `/me` | GET | 学生信息（直接从 JWXT 抓取） |
| `/schedule` | GET | 课表（直接从 JWXT 抓取） |
| `/exams` | GET | 考试安排（直接从 JWXT 抓取） |
| `/grades` | GET | 成绩（直接从 JWXT 抓取） |
| `/credits` | GET | 学分（直接从 JWXT 抓取） |
| `/attendance` | GET | 考勤（直接从 JWXT 抓取） |
| `/notices` | GET | 通知（直接从 JWXT 抓取） |
| `/jwglxt/*` | * | JWXT 直接代理 |
| `/_proxy` | POST | Vercel→Worker 反向代理 |
| `/jwxt-test` | GET | JWXT 连接测试 |
| `/kv-test` | GET | KV 存储诊断 |

**代理到 Vercel 的路由**：上述以外的所有路由，包括 `/ehall/*`、`/ecard/*`、`/push/*`、`/auth/captcha`、`/auth/login`、`/auth/ly/complete` 等。

**代理流程**：

```
1. 从请求头获取 X-Session-Id
2. 查找本地会话（内存 → KV）
3. 注入 JWXT Cookie + ehall Cookie + X-Worker-Auth 标记
4. 转发请求到 Vercel
5. 5xx 重试（最多 2 次，指数退避）
6. 返回响应（附加 CORS 头）
```

**会话 Cookie 注入**（`injectSessionCookies`）：

```javascript
function injectSessionCookies(request, session) {
  const headers = new Headers(request.headers);
  headers.set('Cookie', session.cookies);           // JWXT Cookie
  headers.set('X-Ehall-Cookies', session.ehallCookies); // ehall Cookie
  headers.set('X-Student-Account', session.account);    // 学号
  headers.set('X-Worker-Auth', '1');                    // 标记来自 Worker
  return new Request(request.url, { method, headers, body });
}
```

> `X-Worker-Auth: 1` 告知 Vercel 后端跳过 JWXT Cookie 验证，因为 Cookie 是 IP 绑定的，只有 Worker 边缘节点的 IP 才能通过验证。

### 3.7.5 会话 KV 存储

Worker 使用两级会话存储：

1. **内存存储**（`localSessions`：`Map<sessionId, sessionData>`）：快速但仅在同一 Worker 实例内有效
2. **Cloudflare KV**（`SESSIONS_KV`）：跨实例持久化，TTL 为 2 小时

```javascript
const SESSION_KV_TTL = 7200; // 2 hours
const localSessions = new Map();

async function saveSessionToKV(sessionId, data, env) {
  await env.SESSIONS_KV.put(
    `session:${sessionId}`,
    JSON.stringify(data),
    { expirationTtl: SESSION_KV_TTL }
  );
}

async function getLocalSession(request, env) {
  const sessionId = request.headers.get('X-Session-Id');
  // 1. 内存查找
  let data = localSessions.get(sessionId);
  if (data) return data;
  // 2. KV 查找
  const raw = await env.SESSIONS_KV.get(`session:${sessionId}`);
  if (raw) {
    data = JSON.parse(raw);
    localSessions.set(sessionId, data); // 缓存到内存
    return data;
  }
  return null;
}
```

### 3.7.6 OCR 字符修正策略

CAS 验证码为算术题（如 `3 + 5 = ?`），OCR 识别后需要修正常见的字符混淆：

```javascript
const OCR_CHAR_FIXES = {
  'o': '0', 'O': '0',    // 字母 O → 数字 0
  'l': '1', 'I': '1', '|': '1',  // 字母 l/I → 数字 1
  'S': '5', 's': '5',    // 字母 S → 数字 5
  'b': '6', 'G': '6',    // 字母 b/G → 数字 6
  'B': '8',              // 字母 B → 数字 8
  'g': '9', 'q': '9',    // 字母 g/q → 数字 9
};
```

**算术验证码求解**（`solveArithmeticCaptcha`）：

1. 对 OCR 文本先尝试原始文本，再尝试修正后文本
2. 匹配算术表达式 `(\d+)\s*([+\-*/xX×÷])\s*(\d+)`
3. 计算结果，限制操作数 ≤ 20，结果 ≤ 82
4. 返回结果字符串

### 3.7.7 凭证加密（AES-GCM）

Worker 使用 Web Crypto API 的 AES-GCM 加密用户凭证，生成 `credentialToken` 供后续 relogin 使用：

```javascript
async function encryptCredentials(account, password, key) {
  // 1. SHA-256 派生密钥
  const keyData = await crypto.subtle.digest('SHA-256', encode(key));
  const cryptoKey = await crypto.subtle.importKey('raw', keyData, { name: 'AES-GCM' }, false, ['encrypt']);

  // 2. 生成随机 IV（12 字节）
  const iv = crypto.getRandomValues(new Uint8Array(12));

  // 3. AES-GCM 加密 "account:password"
  const encrypted = await crypto.subtle.encrypt({ name: 'AES-GCM', iv }, cryptoKey, encode(`${account}:${password}`));

  // 4. 拼接 IV + 密文，Base64 编码
  return btoa(String.fromCharCode(...iv, ...new Uint8Array(encrypted)));
}
```

**解密流程**（`decryptCredentials`）：反向操作，用于 relogin 时恢复账号密码。

### 3.7.8 编码智能解码

JWXT 历史上使用 GBK 编码，而 Cloudflare Workers 默认以 UTF-8 解码。Worker 实现了智能解码策略：

```javascript
function decodeResponse(response) {
  return response.arrayBuffer().then(buf => {
    try {
      return new TextDecoder('utf-8', { fatal: true }).decode(buf);  // 优先 UTF-8
    } catch (_) {
      return new TextDecoder('gbk').decode(buf);  // 回退 GBK
    }
  });
}
```

### 3.7.9 JWXT 直接代理

Vercel 后端可通过 Worker 代理 JWXT 请求，保持 Worker 边缘 IP 不变（JWXT Cookie 是 IP 绑定的）：

- `X-Jwxt-Session-Id` 请求头触发 JWXT 代理模式
- Worker 从会话存储中查找 Cookie，注入到对 JWXT 的请求中
- 支持路径 `/jwglxt/*` 和 `/xtgl/*`

### 3.7.10 CanvasKit 兼容性处理

Worker 对 `/canvaskit/chromium/main.dart.js` 路径返回空 JS 响应，解决 Flutter Web CanvasKit chromium 变体在 Cloudflare Pages SPA 回退下的解析错误问题。

### 3.7.11 Vercel 代理重试

`proxyToVercel` 实现了对 Vercel 后端的 5xx 重试（最多 2 次，指数退避 200ms → 400ms → 800ms），并在所有重试失败后：

- 有本地会话 → 返回 502（后端暂时不可用）
- 无本地会话 → 返回 401（会话已过期，触发前端 relogin）

### 3.7.12 边缘学术数据处理

Worker 在边缘直接处理学术数据请求（`/me`、`/schedule`、`/exams`、`/grades`、`/credits`、`/attendance`、`/notices`），避免 Vercel Hobby 计划的 10 秒超时限制：

1. 从会话存储获取 JWXT Cookie
2. 直接请求 JWXT 对应的数据页面
3. 使用 `normalizeResultList` 将 JWXT 原始字段名转换为 Flutter 端期望的格式
4. 如果边缘处理失败，降级代理到 Vercel

**字段名映射示例**（`normalizeScheduleCourse`）：

| JWXT 原始字段 | Flutter 期望字段 |
|--------------|-----------------|
| `kcmc` | `name` |
| `jsxx` / `jsxm` / `xm` | `teacher` |
| `cdmc` | `classroom` |
| `xqj` | `weekday` |
| `ksjc` / `jcs` | `startSection` / `endSection` |
| `zcd` | `weeks` |