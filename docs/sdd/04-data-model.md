# 第4章 数据模型与存储设计

## 4.1 数据库架构概述

### 4.1.1 环境差异

软帮手（OneGZUS）后端采用 SQLAlchemy ORM（声明式基类 `DeclarativeBase`）进行数据访问，根据运行环境选择不同的数据库引擎：

| 维度 | 生产环境 | 测试环境 |
|------|----------|----------|
| 数据库 | PostgreSQL（Neon 无服务器） | SQLite 内存库 |
| 连接字符串 | `postgresql://user:pass@host/dbname` | `sqlite:///:memory:` |
| 环境变量 | `DATABASE_URL` | `conftest.py` 通过 monkeypatch 注入 |
| 连接池 | 支持（`pool_size` / `max_overflow`） | `StaticPool`（单连接） |
| 持久化 | 永久存储 | 进程结束即丢失 |
| 文件型 SQLite | **严格禁止** | 仅允许 `:memory:` |

生产环境使用 Neon PostgreSQL 的原因在于：Vercel 无服务器部署中，每次冷启动可能落在不同的计算实例上，文件型数据库无法跨实例共享状态。PostgreSQL 提供了可靠的网络访问和事务一致性，确保会话数据在无服务器环境中可被恢复。

### 4.1.2 连接池配置

生产环境 PostgreSQL 连接池参数通过 `pydantic-settings` 从环境变量读取，定义于 `app/config.py`：

| 参数 | 环境变量 | 默认值 | 说明 |
|------|----------|--------|------|
| `pool_size` | `DB_POOL_SIZE` | 3 | 连接池保持的常驻连接数 |
| `max_overflow` | `DB_MAX_OVERFLOW` | 5 | 超出 `pool_size` 后允许的最大溢出连接数 |
| `pool_recycle` | `DB_POOL_RECYCLE` | 300（秒） | 连接被回收前的最大存活时间，防止 Neon 挂起空闲连接 |
| `pool_timeout` | `DB_POOL_TIMEOUT` | 10（秒） | 获取连接的最大等待时间 |

此外，引擎创建时始终启用 `pool_pre_ping=True`，在每次从池中取出连接前先执行轻量级探测，避免使用已被服务端关闭的连接。

对于 SQLite 内存库，使用 `StaticPool` 保证所有请求共享同一个底层连接（否则每个连接会创建独立的内存数据库），并设置 `check_same_thread=False` 允许跨线程访问。

### 4.1.3 引擎管理

数据库引擎采用模块级单例模式，通过 `get_sync_engine()` 和 `get_async_engine()` 延迟创建：

```
_engine: Engine | None          # 同步引擎单例
_async_engine: AsyncEngine | None  # 异步引擎单例
_session_factory: sessionmaker | None
_async_session_factory: async_sessionmaker | None
_db_initialized: bool = False   # 防止重复初始化
```

**同步引擎** `get_sync_engine()`：
- 首次调用时创建，后续直接返回缓存实例
- PostgreSQL：使用 `create_engine()` + 连接池参数
- SQLite 内存库：使用 `create_engine()` + `StaticPool`
- 其他 SQLite：使用 `create_engine()` + `check_same_thread=False` + `pool_pre_ping=True`

**异步引擎** `get_async_engine()`：
- 与同步引擎逻辑对称，使用 `create_async_engine()`
- PostgreSQL 驱动：`postgresql+asyncpg://`
- SQLite 驱动：`sqlite+aiosqlite://`

**会话工厂**：
- `get_sync_session_factory()`：首次调用时触发 `init_db()`，返回绑定引擎的 `sessionmaker`，设置 `expire_on_commit=False`
- `get_async_session_factory()`：返回绑定异步引擎的 `async_sessionmaker`

**重置**：`reset_engine()` 清空所有全局单例，主要用于测试场景中隔离测试用例。

### 4.1.4 URL 解析与验证

#### `_resolve_sync_url(raw_url: str) -> str`

将用户配置的 `DATABASE_URL` 转换为同步引擎可用的格式：

| 输入前缀 | 转换后缀 | 说明 |
|----------|----------|------|
| `postgres://` | `postgresql://` | SQLAlchemy 要求 `postgresql://` |
| `sqlite+aiosqlite://` | `sqlite://` | 异步驱动前缀替换为同步 |
| `postgresql+asyncpg://` | `postgresql://` | 异步驱动前缀替换为同步 |
| 其他 | 原样返回 | — |

#### `_resolve_async_url(raw_url: str) -> str`

将 `DATABASE_URL` 转换为异步引擎可用的格式：

| 输入前缀 | 转换后缀 | 说明 |
|----------|----------|------|
| `postgres://` | `postgresql+asyncpg://` | 注入 asyncpg 驱动 |
| `postgresql://` | `postgresql+asyncpg://` | 注入 asyncpg 驱动 |
| `sqlite://`（不含 aiosqlite） | `sqlite+aiosqlite://` | 注入 aiosqlite 驱动 |
| 其他 | 原样返回 | — |

#### `_validate_database_url(raw_url: str) -> None`

在引擎创建前执行安全校验：

1. **空值检查**：`DATABASE_URL` 为空时抛出 `RuntimeError`，提示示例格式
2. **PostgreSQL 合法前缀**：`postgres://`、`postgresql://`、`postgresql+asyncpg://` → 通过
3. **SQLite 合法前缀**：仅允许 `sqlite:///:memory:` 或 `sqlite+aiosqlite:///:memory:` → 通过
4. **文件型 SQLite 拒绝**：非 `:memory:` 的 SQLite URL 抛出 `RuntimeError`，明确提示"SQLite file databases are not supported because they can contain local user data"
5. **未知协议**：其他前缀抛出 `RuntimeError`

### 4.1.5 SQLite PRAGMA 优化

当检测到 SQLite 引擎时，`init_db()` 调用 `_apply_sqlite_pragmas()` 设置以下 PRAGMA：

| PRAGMA | 值 | 说明 |
|--------|----|------|
| `journal_mode` | WAL | 写前日志模式，允许读写并发 |
| `synchronous` | NORMAL | 平衡安全性与性能 |
| `cache_size` | -64000 | 64MB 页面缓存 |
| `busy_timeout` | 5000 | 锁等待超时 5 秒 |

PRAGMA 同时通过 SQLAlchemy `event.listens_for(engine, "connect")` 钩子和直接执行两种方式设置，确保新连接和已有连接均生效。

---

## 4.2 数据模型详细设计

### 4.2.1 EhallSession（ehall_sessions 表）

ehall 会话存储，保存一站式服务平台（ehall）的 Cookie 信息，用于后台定时任务（如通知同步、教职工数据同步）免登录访问 ehall API。

| 字段 | 类型 | 约束 | 说明 |
|------|------|------|------|
| `id` | `Integer` | PK, 自增 | 主键 |
| `account` | `String(100)` | 非空, 索引 | 学号/工号，用于快速查找某用户的 ehall 会话 |
| `cookies_json` | `Text` | 非空 | 序列化为 JSON 的 Cookie 字典，包含 ehall 认证所需的全部 Cookie |
| `created_at` | `DateTime` | 默认 `utcnow` | 会话创建时间 |
| `expires_at` | `DateTime` | 非空, 索引 | 会话过期时间，用于定时清理过期会话 |
| `last_used_at` | `DateTime` | 默认 `utcnow` | 最后使用时间，用于滑动过期判定 |

**索引设计**：
- `account` 上的索引：支持按学号快速查询活跃会话
- `expires_at` 上的索引：支持批量清理过期会话

**业务规则**：
- 会话 TTL 由 `ehall_session_ttl_hours`（默认 24 小时）配置
- 后台任务在每次使用会话时更新 `last_used_at`
- 过期会话由定时清理任务删除

---

### 4.2.2 EcardBinding（ecard_bindings 表）

一卡通绑定配置，存储用户绑定的宿舍房间及水电费提醒偏好。

| 字段 | 类型 | 约束 | 说明 |
|------|------|------|------|
| `id` | `Integer` | PK, 自增 | 主键 |
| `student_id` | `String(100)` | 非空, 唯一, 索引 | 学号，每个学生只能绑定一个房间 |
| `room_id` | `String(200)` | 非空 | 房间 ID（ecard 系统内部标识） |
| `room_display` | `String(200)` | 非空 | 房间显示名称（如"6栋-301"） |
| `reminder_enabled` | `Boolean` | 非空, 默认 `True` | 是否启用水电费提醒 |
| `low_power_threshold` | `Float` | 非空, 默认 `30.0` | 电量低预警阈值（度） |
| `last_summary_json` | `Text` | 可空 | 最近一次水电余额摘要的 JSON 快照 |
| `last_checked_at` | `DateTime` | 可空 | 最近一次检查水电余额的时间 |
| `last_reminded_date` | `String(20)` | 可空 | 最近一次发送提醒的日期（格式 `YYYY-MM-DD`），防止同日重复提醒 |
| `reminder_times` | `Text` | 非空, 默认 `'["08:00"]'` | 每日提醒时间列表（JSON 数组） |
| `reminder_items` | `Text` | 非空, 默认 `'["power","cold_water","hot_water"]'` | 提醒项目列表（JSON 数组） |
| `low_cold_water_threshold` | `Float` | 非空, 默认 `5.0` | 冷水余额低预警阈值（吨） |
| `low_hot_water_threshold` | `Float` | 非空, 默认 `10.0` | 热水余额低预警阈值（吨） |
| `last_reminded_times` | `Text` | 可空, 默认 `'{}'` | 每个提醒时间点是否已发送的记录（JSON 对象），防止同日同时间重复推送 |
| `created_at` | `DateTime` | 默认 `utcnow` | 记录创建时间 |
| `updated_at` | `DateTime` | 默认 `utcnow`, `onupdate=utcnow` | 记录更新时间 |

**索引设计**：
- `student_id` 上的唯一索引：保证一个学生只有一条绑定记录，同时加速按学号查询

**JSON 字段说明**：
- `reminder_times`：如 `["08:00", "20:00"]`，支持多个提醒时间
- `reminder_items`：可选值 `power`（电）、`cold_water`（冷水）、`hot_water`（热水）
- `last_reminded_times`：如 `{"08:00": true, "20:00": false}`，记录当日各时间点是否已发送
- `last_summary_json`：缓存最近一次水电查询结果，避免频繁请求 ecard API

---

### 4.2.3 PushRegistration（push_registrations 表）

极光推送（JPush）设备注册记录，用于向移动端 App 发送推送通知。

| 字段 | 类型 | 约束 | 说明 |
|------|------|------|------|
| `id` | `Integer` | PK, 自增 | 主键 |
| `student_id` | `String(100)` | 非空, 索引 | 学号 |
| `registration_id` | `String(300)` | 非空, 唯一 | JPush 设备注册 ID，全局唯一标识一台设备 |
| `platform` | `String(50)` | 默认 `"android"` | 设备平台（`android` / `ios`） |
| `created_at` | `DateTime` | 默认 `utcnow` | 注册时间 |
| `updated_at` | `DateTime` | 默认 `utcnow`, `onupdate=utcnow` | 更新时间 |

**索引设计**：
- `student_id` 上的索引：支持按学号查询该用户的所有设备
- `registration_id` 上的唯一索引：保证设备不重复注册

**业务规则**：
- 一个学生可以有多台设备（多行记录）
- 同一 `registration_id` 只能注册一次
- 后台推送时，按 `student_id` 查找所有设备进行推送

---

### 4.2.4 WebPushSubscription（web_push_subscriptions 表）

Web Push 订阅记录，用于向浏览器端发送推送通知（基于 VAPID 协议）。

| 字段 | 类型 | 约束 | 说明 |
|------|------|------|------|
| `id` | `Integer` | PK, 自增 | 主键 |
| `student_id` | `String(100)` | 非空, 索引 | 学号 |
| `endpoint` | `String(500)` | 非空, 唯一 | 推送服务端点 URL（浏览器 Push API 返回） |
| `p256dh` | `String(300)` | 非空 | 客户端公钥（ECDH P-256），用于消息加密 |
| `auth` | `String(100)` | 非空 | 认证密钥，用于消息加密 |
| `expiration_time` | `DateTime` | 可空 | 订阅过期时间（浏览器可能设置） |
| `user_agent` | `String(500)` | 可空 | 浏览器 User-Agent，用于调试和统计 |
| `created_at` | `DateTime` | 默认 `utcnow` | 订阅时间 |
| `updated_at` | `DateTime` | 默认 `utcnow`, `onupdate=utcnow` | 更新时间 |

**索引设计**：
- `student_id` 上的索引：支持按学号查询所有浏览器订阅
- `endpoint` 上的唯一索引：保证同一推送端点不重复订阅

**安全说明**：
- `p256dh` 和 `auth` 是 Web Push 加密所需的关键参数，必须妥善存储
- 推送消息在发送前使用这两个值进行 ECDH 加密，确保只有目标浏览器能解密

---

### 4.2.5 DataCache（data_cache 表）

服务端持久化缓存，存储从教务系统/ehall 获取的数据快照，用于离线回退和减少对上游系统的请求压力。

| 字段 | 类型 | 约束 | 说明 |
|------|------|------|------|
| `id` | `Integer` | PK, 自增 | 主键 |
| `cache_key` | `String(500)` | 非空, 唯一, 索引 | 缓存键，格式 `{student_id}:{resource}:{params_hash}` |
| `student_id` | `String(100)` | 非空, 索引 | 学号，支持按用户批量清理 |
| `resource` | `String(100)` | 非空, 索引 | 资源类型（如 `me`、`schedule`、`grades`、`attendance`、`notices`） |
| `params_hash` | `String(64)` | 非空, 默认 `""` | 请求参数的 SHA-256 哈希前 16 位，区分同一资源不同参数的缓存 |
| `response_json` | `Text` | 非空 | 序列化为 JSON 的响应数据 |
| `cached_at` | `DateTime` | 默认 `utcnow` | 缓存写入时间 |

**索引设计**：
- `cache_key` 上的唯一索引：缓存键全局唯一，支持快速查找和 upsert
- `student_id` 上的索引：支持按用户批量清理缓存
- `resource` 上的索引：支持按资源类型查询

**缓存键生成规则**：
```
cache_key = f"{student_id}:{resource}:{params_hash}"
```
其中 `params_hash` 的计算方式：
1. 将请求参数 `params` 字典按 key 排序后序列化为 JSON
2. 对 JSON 字符串计算 SHA-256 哈希
3. 取前 16 个字符作为 `params_hash`

**使用模式**：
- `save_cache()`：写入缓存，若键已存在则更新 `response_json` 和 `cached_at`
- `load_cache()`：读取缓存数据，自动反序列化 JSON
- `load_and_get_cached_at()`：单次查询同时获取数据和缓存时间
- `clear_cache_for_student()`：删除某用户的所有缓存

---

### 4.2.6 StaffMember（staff_members 表）

教职工信息，从 ehall 同步的教职工通讯录数据。

| 字段 | 类型 | 约束 | 说明 |
|------|------|------|------|
| `userid` | `String(100)` | PK | 教职工工号，作为主键 |
| `cn_name` | `String(100)` | 非空, 索引 | 中文姓名 |
| `job_title` | `String(100)` | 可空, 索引 | 职务/职称 |
| `folder_name` | `String(300)` | 可空, 索引 | 所属部门/文件夹路径 |
| `wf_or_unid` | `String(100)` | 可空 | 工作流标识（ehall 系统内部） |
| `wf_last_modified` | `String(100)` | 可空 | 工作流最后修改时间 |
| `sort_number` | `Integer` | 可空 | 排序序号 |
| `updated_at` | `DateTime` | 默认 `utcnow`, `onupdate=utcnow` | 记录更新时间 |

**索引设计**：
- `cn_name` 上的索引：支持按姓名搜索
- `job_title` 上的索引：支持按职务筛选
- `folder_name` 上的索引：支持按部门筛选

**数据来源**：
- 通过 ehall API 定期同步（`ehall_staff_sync_url` 配置）
- 同步时按 `userid` 进行 upsert（存在则更新，不存在则插入）

---

### 4.2.7 AppSessionModel（app_sessions 表）

应用会话持久化模型，专为无服务器部署（Vercel）设计。在冷启动后，从数据库中恢复会话状态并重建客户端对象。

| 字段 | 类型 | 约束 | 说明 |
|------|------|------|------|
| `id` | `String(64)` | PK | 会话 ID（UUID hex），由 `uuid.uuid4().hex` 生成 |
| `student_name` | `String(100)` | 可空 | 学生姓名 |
| `student_account` | `String(100)` | 可空 | 学号/账号，用于单设备登录检测 |
| `created_at` | `DateTime` | 非空, 索引, 默认 `utcnow` | 会话创建时间 |
| `last_active_at` | `DateTime` | 非空, 默认 `utcnow` | 最后活跃时间，用于滑动 TTL 判定 |
| `push_registration_id` | `String(300)` | 可空 | 关联的推送注册 ID |
| `push_platform` | `String(50)` | 非空, 默认 `"android"` | 推送平台 |
| `jwxt_cookies` | `Text` | 可空 | 教务系统 Cookie 字符串，用于重建 `SchoolSdkClient` |
| `ehall_cookies` | `Text` | 可空 | ehall Cookie 字符串，用于重建 `EhallClient` |
| `ehall_auth_token` | `Text` | 可空 | ehall 认证令牌 |
| `encrypted_credentials` | `Text` | 可空 | Fernet 加密的账号密码凭据，用于自动重登录 |
| `revoked_at` | `DateTime` | 可空, 索引 | 会话吊销时间，非空表示已被吊销 |
| `revoked_reason` | `String(100)` | 可空 | 吊销原因（如 `single_device_login`） |

**索引设计**：
- `created_at` 上的索引：支持按创建时间排序和批量清理
- `revoked_at` 上的索引：支持快速查找被吊销的会话

**会话生命周期**：
1. **创建**：用户登录成功后，`SessionStore.create()` 生成 UUID，提取客户端 Cookie 写入数据库
2. **活跃**：每次请求通过 `SessionStore.get()` 恢复会话，调用 `touch()` 更新 `last_active_at`
3. **过期**：`last_active_at` 超过 TTL（默认 7200 秒）后，会话被自动清理
4. **吊销**：同一账号在新设备登录时，旧会话的 `revoked_at` 被标记为当前时间，`revoked_reason` 设为 `single_device_login`

**凭据加密**：
- `encrypted_credentials` 使用 Fernet 对称加密（基于 `CREDENTIAL_ENCRYPTION_KEY`）
- 加密流程：`SHA-256(key)` → `base64url` → `Fernet` 实例 → 加密 `account:password`
- 生产环境必须在 `.env` 中设置 `CREDENTIAL_ENCRYPTION_KEY`，否则 API 拒绝启动

---

## 4.3 会话持久化设计

### 4.3.1 双层会话架构

系统采用内存会话（`AppSession` dataclass）与持久化会话（`AppSessionModel` ORM 模型）双层架构：

```
┌──────────────────────────────────────────────────────┐
│                   SessionStore                        │
│                                                       │
│  ┌─────────────────┐    ┌──────────────────────────┐ │
│  │  _sessions: dict │    │  AppSessionModel (PostgreSQL) │ │
│  │  (内存缓存层)     │    │  (持久化层)                │ │
│  │                  │    │                            │ │
│  │  AppSession      │    │  id, student_name,        │ │
│  │  ├─ client       │    │  student_account,         │ │
│  │  ├─ ehall_client │    │  jwxt_cookies,            │ │
│  │  └─ ...          │    │  ehall_cookies,           │ │
│  │                  │    │  encrypted_credentials    │ │
│  └─────────────────┘    └──────────────────────────┘ │
└──────────────────────────────────────────────────────┘
```

**AppSession（内存 dataclass）**：

```python
@dataclass
class AppSession:
    id: str                           # 会话 ID
    client: Any                       # SchoolSdkClient 实例（内存中存活）
    student_name: str | None          # 学生姓名
    ehall_client: Any | None          # EhallClient 实例
    created_at: datetime              # 创建时间
    last_active_at: datetime          # 最后活跃时间
    push_registration_id: str | None  # 推送注册 ID
    push_platform: str                # 推送平台
    encrypted_credentials: str | None # 加密凭据
    revoked_at: datetime | None       # 吊销时间
    revoked_reason: str | None        # 吊销原因
    student_account: str | None       # 学号
```

**AppSessionModel（数据库 ORM 模型）**：存储可序列化的会话元数据，不存储客户端对象本身。

### 4.3.2 冷启动恢复流程

在 Vercel 无服务器环境中，每次冷启动都会丢失内存状态。恢复流程如下：

```
1. 请求到达 → SessionStore.get(session_id)
2. 查找内存缓存 _sessions[session_id]
   ├─ 命中 → 直接返回 AppSession
   └─ 未命中 → 查询 PostgreSQL
3. 从 AppSessionModel 读取行
   ├─ 不存在 → 重试 3 次（Neon 读后写延迟）
   │   └─ 仍不存在 → 返回 None（401）
   ├─ 已过期（last_active_at + TTL < now）→ 删除行 → 返回 None
   └─ 有效 → 重建客户端对象
4. 重建 SchoolSdkClient
   ├─ 从 jwxt_cookies 调用 login_with_cookies()
   ├─ 不验证 Cookie 有效性（IP 绑定限制）
   └─ 失败时 client=None，等待 Worker 注入新 Cookie
5. 重建 EhallClient
   ├─ 从 ehall_cookies + ehall_auth_token 构造
   └─ 失败时 ehall_client=None
6. 组装 AppSession → 存入 _sessions → 返回
```

**关键设计决策**：
- **不验证 Cookie**：从数据库恢复的 JWXT Cookie 可能已过期或 IP 不匹配，但 `login_with_cookies(validate=False)` 允许先恢复，由实际 API 调用触发认证错误时再处理
- **容许 client=None**：如果 Cookie 恢复失败，不直接返回 401，而是允许 Cloudflare Worker 在后续请求中注入新鲜 Cookie 进行恢复
- **读后写重试**：Neon PostgreSQL 在跨实例场景下可能有短暂的读后写延迟，最多重试 3 次，每次间隔递增（0.3s、0.6s、0.9s）

### 4.3.3 Worker KV 与 PostgreSQL 双重持久化

系统在边缘层和服务器层分别维护会话缓存：

```
┌─────────────────────────────────────────────────────┐
│  Cloudflare Worker（边缘层）                          │
│  ┌────────────────────┐                              │
│  │ SESSIONS_KV        │ ← 会话 Cookie 缓存           │
│  │ (Cloudflare KV)    │   TTL: 与后端一致             │
│  └────────────────────┘                              │
│  Worker 拦截请求 → 注入 X-Worker-Auth + Cookie 头    │
└─────────────────────────────────────────────────────┘
         │
         │ HTTP 代理
         ▼
┌─────────────────────────────────────────────────────┐
│  Vercel Backend（服务器层）                           │
│  ┌────────────────────┐  ┌────────────────────────┐ │
│  │ _sessions (内存)    │  │ AppSessionModel (PG)   │ │
│  │ AppSession 对象     │  │ 会话元数据 + Cookie     │ │
│  └────────────────────┘  └────────────────────────┘ │
└─────────────────────────────────────────────────────┘
```

**Worker KV 的作用**：
- 在边缘层缓存会话 Cookie，减少对后端的请求
- 处理 CAS SSO 登录流程（含验证码 OCR、RSA 解密），避免将敏感操作暴露到公网
- 通过 `X-Worker-Auth` 头向 API 传递认证信息

**PostgreSQL 的作用**：
- 作为会话的权威持久化存储
- 在 Worker KV 缓存未命中或冷启动时提供恢复
- 支持跨 Vercel 实例的会话共享

### 4.3.4 会话清理策略

**滑动 TTL 过期**：
- 默认 TTL：7200 秒（2 小时），由 `session_ttl_seconds` 配置
- 每次请求通过 `touch()` 更新 `last_active_at`，实现滑动过期
- 过期判定：`now - last_active_at > TTL`

**定时清理任务**：
- `SessionStore.start_cleanup_task()` 启动异步清理循环
- 每 300 秒（5 分钟）执行一次 `_purge_expired()`
- 批量删除 `last_active_at < cutoff` 的 `AppSessionModel` 行
- 同步清理内存缓存 `_sessions` 中的过期条目

**单设备登录吊销**：
- 新会话创建时，若 `student_account` 非空，则将该账号下所有未吊销的会话标记为 `revoked_at = now`、`revoked_reason = "single_device_login"`
- 被吊销的会话在 `get()` 时返回带 `revoked_at` 标记的 `AppSession`，由上层路由返回 401

---

## 4.4 缓存策略

系统采用多级缓存架构，从服务端持久化到前端本地存储，形成完整的缓存链路：

### 4.4.1 服务端持久化缓存（cache_service.py → DataCache 表）

**位置**：`app/cache_service.py` + `data_cache` 表

**机制**：基于 PostgreSQL 的持久化缓存，数据在数据库重启后仍然存在。

**缓存键格式**：`{student_id}:{resource}:{params_hash}`

**支持的操作**：

| 操作 | 函数 | 说明 |
|------|------|------|
| 写入 | `save_cache()` | Upsert 语义：键存在则更新，不存在则插入 |
| 读取 | `load_cache()` | 反序列化 JSON，校验数据类型 |
| 读取+时间 | `load_and_get_cached_at()` | 单次查询获取数据和缓存时间 |
| 清理 | `clear_cache_for_student()` | 删除某用户的所有缓存 |

**使用场景**（`routes/academic.py` 中的 `_run_with_cache_fallback`）：
1. 先尝试从上游系统获取实时数据
2. 成功时写入缓存并返回
3. 失败时读取缓存作为降级数据
4. 缓存也失败时返回错误

**缓存资源类型**：

| resource | 说明 |
|----------|------|
| `me` | 学生个人信息 |
| `schedule` | 课表 |
| `grades` | 成绩 |
| `attendance` | 考勤 |
| `credits` | 学分 |
| `notices` | 通知列表 |
| `notice_detail` | 通知详情 |

### 4.4.2 内存缓存（school_client.py → simple_cache 装饰器）

**位置**：`app/school_client.py`

**机制**：基于 Python 闭包的进程内缓存，使用函数参数作为缓存键。

**TTL**：10 分钟（`CACHE_TTL = timedelta(minutes=10)`）

**实现**：
```python
def simple_cache(ttl: timedelta):
    def decorator(func):
        cache = {}  # {(args, frozenset(kwargs)): (result, expiry)}
        def wrapper(*args, **kwargs):
            key = (args, frozenset(kwargs.items()))
            now = datetime.now()
            if key in cache:
                cached_value, expiry = cache[key]
                if now < expiry:
                    return cached_value
            result = func(*args, **kwargs)
            cache[key] = (result, now + ttl)
            return result
        return wrapper
    return decorator
```

**特点**：
- 无线程安全保护（单线程事件循环场景下安全）
- 缓存键包含 `self`（SchoolSdkClient 实例），不同会话的缓存互不干扰
- 过期后惰性清除（下次访问时覆盖）

### 4.4.3 房间列表缓存（routes/ecard.py）

**位置**：`app/routes/ecard.py`

**机制**：线程安全的进程内缓存，使用 `threading.Lock` 保护。

**TTL**：1 小时（`_ROOMS_CACHE_TTL = 3600`）

**数据规模**：约 6700 条房间记录，约 880 KB

**实现**：
```python
_rooms_cache_lock = threading.Lock()
_rooms_cache: list[dict[str, str]] = []
_rooms_cache_at: float = 0.0
```

**刷新策略**：
1. 加锁检查缓存是否过期
2. 未过期 → 直接返回缓存
3. 过期 → 释放锁后请求 ecard API
4. 获取成功 → 加锁更新缓存
5. 获取失败 → 返回过期缓存（stale-while-error）

**设计考量**：
- 房间列表数据量大且变化极少（宿舍调整频率很低），1 小时 TTL 合理
- 使用双重检查锁定（double-checked locking）避免持锁请求 API 导致阻塞
- stale-while-error 策略确保 ecard API 不可用时仍可提供服务

### 4.4.4 天气缓存（routes/weather.py）

**位置**：`app/routes/weather.py`

**机制**：进程内字典缓存，按地理坐标分区。

**TTL**：30 分钟（`_CACHE_TTL = 30 * 60`）

**缓存键**：`{lat:.1f},{lon:.1f}`（精度到 0.1 度约 11km，同一区域共享缓存）

**实现**：
```python
_cache: dict[str, tuple[dict[str, Any], float]] = {}
```

**降级策略**：
- wttr.in 超时 / HTTP 错误 / 解析失败 → 返回过期缓存（stale-while-error）
- 无过期缓存 → 抛出异常

### 4.4.5 前端本地缓存（persistent_cache.dart）

**位置**：`apps/mobile_web/lib/persistent_cache.dart`

**机制**：基于 `SharedPreferences` 的本地持久化缓存。

**存储格式**：
- 数据键：`pcache_{namespace}_{key}` → JSON 字符串
- 时间键：`pcache_{namespace}_{key}_at` → ISO 8601 时间戳

**核心 API**：

| 方法 | 说明 |
|------|------|
| `set(key, data)` | 写入缓存（自动序列化为 JSON + 记录时间） |
| `get<T>(key, fromJson)` | 读取并反序列化为指定类型 |
| `getList<T>(key, fromJson)` | 读取列表类型缓存 |
| `getRaw(key)` | 读取原始 JSON |
| `getCachedAt(key)` | 获取缓存时间 |
| `remove(key)` | 删除单条缓存 |
| `clearAll()` | 清空当前命名空间的所有缓存 |
| `clearForStudent(studentId)` | 静态方法，清空指定学生的所有缓存 |

**缓存版本控制**：
- `_cacheVersion = 1`，存储在 `cache_version` 键中
- `_migrateIfNeeded()` 在初始化时检查版本号，未来可扩展迁移逻辑

**命名空间设计**：
- 每个功能模块使用不同的 `namespace`（通常为学号）
- 支持按命名空间批量清理

### 4.4.6 缓存层级总结

| 层级 | 位置 | 存储 | TTL | 线程安全 | 降级策略 |
|------|------|------|-----|----------|----------|
| L1: 进程内缓存 | school_client.py | Python dict | 10 min | 否（单线程） | 过期后重新获取 |
| L2: 进程内缓存 | ecard.py | Python dict + Lock | 60 min | 是 | stale-while-error |
| L3: 进程内缓存 | weather.py | Python dict | 30 min | 否 | stale-while-error |
| L4: 服务端持久化 | cache_service.py | PostgreSQL | 无固定 TTL | 是（DB 事务） | 上游失败时降级读取 |
| L5: 前端本地 | persistent_cache.dart | SharedPreferences | 无固定 TTL | N/A | 离线时读取 |

---

## 4.5 迁移策略

### 4.5.1 轻量级迁移设计

项目不使用 Alembic 等迁移框架，而是采用 `_ensure_columns()` 方法实现轻量级数据库迁移：

```python
def _ensure_columns(engine, table: str, columns: dict[str, str]) -> None:
    """Add columns to an existing table if they don't already exist.

    This is a lightweight, idempotent migration helper for serverless
    deployments where a full migration framework is overkill.
    """
    try:
        with engine.connect() as conn:
            for col_name, col_type in columns.items():
                try:
                    conn.exec_driver_sql(
                        f"ALTER TABLE {table} ADD COLUMN {col_name} {col_type}"
                    )
                    conn.commit()
                    _logger.info("Migrated: added column %s to %s", col_name, table)
                except Exception:
                    # Column likely already exists — safe to ignore
                    conn.rollback()
    except Exception:
        # Table might not exist yet (fresh DB created by create_all above)
        pass
```

### 4.5.2 幂等性保证

`_ensure_columns()` 的幂等性通过以下机制保证：

1. **列已存在时静默忽略**：`ALTER TABLE ADD COLUMN` 在列已存在时会抛出异常，捕获后 `rollback()` 并继续处理下一列
2. **表不存在时静默忽略**：外层 `try/except` 捕获表不存在的异常（此时 `Base.metadata.create_all()` 已创建完整表结构）
3. **每次冷启动安全执行**：`init_db()` 在每次应用启动时调用，`_ensure_columns()` 作为其中一部分自动执行

### 4.5.3 初始化流程

```
init_db()
  ├─ Base.metadata.create_all(engine)    # 创建所有表（如不存在）
  ├─ _ensure_columns(engine, "app_sessions", {
  │     "student_account": "VARCHAR(100)",
  │     "revoked_at": "TIMESTAMP",
  │     "revoked_reason": "VARCHAR(100)",
  │  })
  └─ _apply_sqlite_pragmas(engine)       # SQLite 专用优化
```

`create_all()` 创建完整表结构（包含所有已定义的列），`_ensure_columns()` 处理已有数据库缺少新增列的情况。两者互补，确保新部署和升级部署均能正常工作。

### 4.5.4 已有迁移记录

| 迁移 | 目标表 | 新增列 | 类型 | 说明 |
|------|--------|--------|------|------|
| M001 | `app_sessions` | `student_account` | `VARCHAR(100)` | 学号字段，用于单设备登录检测 |
| M002 | `app_sessions` | `revoked_at` | `TIMESTAMP` | 会话吊销时间戳 |
| M003 | `app_sessions` | `revoked_reason` | `VARCHAR(100)` | 会话吊销原因 |

### 4.5.5 迁移策略的适用边界

**适用场景**：
- 新增列（`ALTER TABLE ADD COLUMN`）
- 无服务器部署，无法运行交互式迁移命令
- 表结构变更频率低

**不适用场景**：
- 删除列（需要数据迁移）
- 修改列类型（需要数据转换）
- 重命名列（需要数据迁移）
- 复杂的数据迁移逻辑

若未来需要复杂迁移，建议引入 Alembic 框架，但需注意 Vercel 部署中迁移的自动执行机制。

---

## 4.6 ER 图

```mermaid
erDiagram
    app_sessions {
        String id PK "会话ID (UUID hex, 64字符)"
        String student_name "学生姓名"
        String student_account "学号/账号"
        DateTime created_at "创建时间 (非空, 索引)"
        DateTime last_active_at "最后活跃时间 (非空)"
        String push_registration_id "推送注册ID"
        String push_platform "推送平台 (默认android)"
        Text jwxt_cookies "教务系统Cookie"
        Text ehall_cookies "ehall Cookie"
        Text ehall_auth_token "ehall认证令牌"
        Text encrypted_credentials "加密凭据 (Fernet)"
        DateTime revoked_at "吊销时间 (索引)"
        String revoked_reason "吊销原因"
    }

    ehall_sessions {
        Integer id PK "自增主键"
        String account "学号/工号 (非空, 索引)"
        Text cookies_json "Cookie JSON (非空)"
        DateTime created_at "创建时间"
        DateTime expires_at "过期时间 (非空, 索引)"
        DateTime last_used_at "最后使用时间"
    }

    ecard_bindings {
        Integer id PK "自增主键"
        String student_id "学号 (非空, 唯一, 索引)"
        String room_id "房间ID (非空)"
        String room_display "房间显示名 (非空)"
        Boolean reminder_enabled "启用提醒 (默认True)"
        Float low_power_threshold "电量低阈值 (默认30.0)"
        Text last_summary_json "最近摘要JSON"
        DateTime last_checked_at "最近检查时间"
        String last_reminded_date "最近提醒日期"
        Text reminder_times "提醒时间列表 (默认[08:00])"
        Text reminder_items "提醒项目 (默认[power,cold_water,hot_water])"
        Float low_cold_water_threshold "冷水低阈值 (默认5.0)"
        Float low_hot_water_threshold "热水低阈值 (默认10.0)"
        Text last_reminded_times "提醒记录 (默认{})"
        DateTime created_at "创建时间"
        DateTime updated_at "更新时间"
    }

    push_registrations {
        Integer id PK "自增主键"
        String student_id "学号 (非空, 索引)"
        String registration_id "JPush注册ID (非空, 唯一)"
        String platform "平台 (默认android)"
        DateTime created_at "创建时间"
        DateTime updated_at "更新时间"
    }

    web_push_subscriptions {
        Integer id PK "自增主键"
        String student_id "学号 (非空, 索引)"
        String endpoint "推送端点 (非空, 唯一)"
        String p256dh "客户端公钥 (非空)"
        String auth "认证密钥 (非空)"
        DateTime expiration_time "订阅过期时间"
        String user_agent "浏览器UA"
        DateTime created_at "创建时间"
        DateTime updated_at "更新时间"
    }

    data_cache {
        Integer id PK "自增主键"
        String cache_key "缓存键 (非空, 唯一, 索引)"
        String student_id "学号 (非空, 索引)"
        String resource "资源类型 (非空, 索引)"
        String params_hash "参数哈希 (默认空)"
        Text response_json "响应JSON (非空)"
        DateTime cached_at "缓存时间"
    }

    staff_members {
        String userid PK "教职工工号"
        String cn_name "中文姓名 (非空, 索引)"
        String job_title "职务 (索引)"
        String folder_name "部门 (索引)"
        String wf_or_unid "工作流标识"
        String wf_last_modified "工作流修改时间"
        Integer sort_number "排序号"
        DateTime updated_at "更新时间"
    }

    app_sessions ||--o| push_registrations : "push_registration_id"
    app_sessions ||--o| ecard_bindings : "student_account = student_id"
    ecard_bindings ||--o{ push_registrations : "student_id"
    ecard_bindings ||--o{ web_push_subscriptions : "student_id"
    ehall_sessions ||--o| app_sessions : "account = student_account"
```

**关系说明**：

| 关系 | 说明 |
|------|------|
| `app_sessions` ↔ `push_registrations` | 一个会话可关联一个推送注册（通过 `push_registration_id`），但一个学生可有多条推送注册 |
| `app_sessions` ↔ `ecard_bindings` | 通过 `student_account` 与 `student_id` 逻辑关联，同一学生只有一个房间绑定 |
| `ecard_bindings` ↔ `push_registrations` | 通过 `student_id` 逻辑关联，水电费提醒推送到该学生的所有设备 |
| `ecard_bindings` ↔ `web_push_subscriptions` | 通过 `student_id` 逻辑关联，水电费提醒推送到该学生的所有浏览器 |
| `ehall_sessions` ↔ `app_sessions` | 通过 `account` 与 `student_account` 逻辑关联，同一用户的 ehall 会话和应用会话 |

> **注意**：以上关系均为逻辑关联，未使用外键约束。这是无服务器部署的刻意设计——避免跨表外键导致的删除级联问题和迁移复杂性。