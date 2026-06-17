# 第6章 安全设计

## 6.1 安全架构概览

软帮手（OneGZUS）作为学校教务系统的中间代理层，其安全设计的核心挑战在于：**在代理用户访问学校系统（JWXT/ehall/CAS）的同时，必须保护用户的登录凭证和学校系统会话 Cookie 不被泄露或滥用**。系统的安全架构跨越三个部署层：

```
┌─────────────────────────────────────────────────────────────────┐
│                      Flutter 前端 (客户端)                        │
│  · RSA 公钥加密密码传输                                           │
│  · credentialToken 本地存储（AES-GCM 加密令牌）                    │
│  · X-Session-Id 会话标识                                          │
└──────────────────────────┬──────────────────────────────────────┘
                           │ HTTPS
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│                Cloudflare Worker (边缘节点)                       │
│  · CAS SSO 登录（密码用学校 CAS RSA 公钥加密）                     │
│  · 会话 Cookie 存储（内存 + KV）                                   │
│  · X-Worker-Auth 标记 + Cookie 注入                               │
│  · AES-GCM 凭证加密/解密                                           │
│  · INTERNAL_API_KEY 认证内部 API 调用                              │
└──────────────────────────┬──────────────────────────────────────┘
                           │ HTTPS (X-Internal-Key)
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│                  Vercel 后端 (FastAPI)                            │
│  · Fernet 对称加密凭证存储                                         │
│  · PostgreSQL 会话持久化（JWXT/ehall Cookie 不暴露给前端）          │
│  · RSA 密钥管理（密码解密）                                         │
│  · 安全响应头 / 速率限制 / CORS 策略                                │
│  · 请求体大小限制                                                  │
└─────────────────────────────────────────────────────────────────┘
```

**关键安全边界**：

| 边界 | 保护对象 | 威胁模型 |
|------|---------|---------|
| 前端 → Worker | 用户密码 | 中间人窃听、XSS 窃取 |
| Worker → 学校系统 | CAS 密码、JWXT Cookie | 凭证泄露、会话劫持 |
| Worker → Vercel | 内部 API 密钥、Cookie | 未授权访问、密钥泄露 |
| Vercel → 数据库 | 加密凭证、会话 Cookie | 数据库泄露、SQL 注入 |
| Vercel → 前端 | 会话 ID | 会话固定、CSRF |

---

## 6.2 安全设计原则

### 6.2.1 最小权限原则

系统各组件仅拥有完成其职责所需的最小权限：

- **Cloudflare Worker**：仅能访问 `SESSIONS_KV` 命名空间和内部 API 端点，无法直接访问 PostgreSQL 数据库。
- **Vercel 后端**：仅通过 `X-Worker-Auth` 头识别 Worker 注入的 Cookie，不直接操作 Worker 的内存或 KV 存储。
- **前端**：仅持有 `X-Session-Id` 和 `credentialToken`，永远无法获取学校系统的原始 Cookie。
- **内部 API 端点**（`/internal/*`）：仅响应携带正确 `X-Internal-Key` 的请求，不对外暴露。

### 6.2.2 纵深防御

安全防护在多个层次实施，任何单点失效不会导致整体安全崩溃：

1. **传输层**：HTTPS 强制加密（生产环境 `PUBLIC_API_BASE_URL` 和 `FRONTEND_BASE_URL` 必须使用 HTTPS）。
2. **应用层**：安全响应头（HSTS、X-Frame-Options 等）、速率限制、请求体大小限制。
3. **认证层**：会话 ID 验证、Worker 认证标记、内部 API 密钥三重认证机制。
4. **数据层**：凭证 Fernet 加密存储、数据库拒绝文件型 SQLite、敏感参数日志脱敏。

### 6.2.3 不存储明文密码

系统在任何持久化存储中均不保存用户明文密码：

- **前端**：密码使用服务端 RSA 公钥加密后传输，前端不保存明文密码。
- **Worker**：密码仅在 CAS 登录流程中短暂存在于内存，登录完成后立即释放。
- **Vercel 后端**：密码经 RSA 解密后仅用于 CAS 登录，随后通过 Fernet 加密为 `credentialToken` 存储，原始明文不落盘。
- **数据库**：`encrypted_credentials` 字段存储 Fernet 加密令牌，无法逆向还原明文密码。

### 6.2.4 安全默认值

系统在未显式配置安全参数时，默认采用最安全的策略：

- `DEBUG=false` 时，`CREDENTIAL_ENCRYPTION_KEY` 未设置则拒绝启动。
- `DEBUG=false` 时，`PUBLIC_API_BASE_URL` 和 `FRONTEND_BASE_URL` 必须使用 HTTPS。
- 文件型 SQLite 数据库被显式拒绝，仅允许 PostgreSQL 或内存型 SQLite（测试用）。
- CORS 默认不允许携带凭证（`allow_credentials=False`）。
- 安全响应头默认应用于所有响应。

---

## 6.3 认证与授权

### 6.3.1 会话认证机制

系统使用基于 `X-Session-Id` 请求头的无状态会话认证。前端在每次 API 请求中携带此头部，后端通过 `require_session` 依赖注入进行验证。

```python
# services/api/app/routes/deps.py
def require_session(
    request: Request,
    x_session_id: str | None = Header(default=None, alias="X-Session-Id"),
) -> AppSession:
```

**认证流程**：

```
前端请求 → X-Session-Id 头 → SessionStore.get() → 会话验证 → 注入 Worker Cookie → 返回 AppSession
                                    ↓
                            会话不存在/过期 → HTTP 401
```

### 6.3.2 会话生命周期

会话的完整生命周期管理如下：

| 阶段 | 触发条件 | 处理逻辑 |
|------|---------|---------|
| **创建** | 登录成功（`/auth/login`、`/auth/auto-login`、`/internal/create-session`） | 生成 UUID 会话 ID，提取 JWXT/ehall Cookie 写入 PostgreSQL，存入内存缓存 |
| **使用** | 每次 API 请求 | `SessionStore.get()` 从 DB 加载，重建客户端对象，`touch()` 更新 `last_active_at` |
| **过期** | `last_active_at` 超过 `session_ttl_seconds`（默认 7200 秒 = 2 小时） | 滑动 TTL 检测，过期会话从 DB 删除 |
| **注销** | `/auth/logout` 或前端主动调用 | `SessionStore.remove()` 从 DB 和内存中删除 |
| **撤销** | 同一账号在新设备登录 | 旧会话标记 `revoked_at` + `revoked_reason="single_device_login"` |

**单设备登录机制**：当同一学号创建新会话时，系统自动撤销该学号的所有现有会话：

```python
# services/api/app/sessions.py — SessionStore.create()
if resolved_student_account:
    # 撤销内存中的旧会话
    for existing in self._sessions.values():
        if existing.student_account == resolved_student_account and existing.revoked_at is None:
            existing.revoked_at = datetime.now(timezone.utc).replace(tzinfo=None)
            existing.revoked_reason = "single_device_login"
    # 撤销数据库中的旧会话
    revoked = db.query(AppSessionModel).filter(
        AppSessionModel.student_account == resolved_student_account,
        AppSessionModel.revoked_at.is_(None)
    ).update({"revoked_at": revoked_at, "revoked_reason": "single_device_login"})
```

### 6.3.3 会话过期检测

由于 JWXT 会话通常在约 30 分钟不活动后过期，系统实现了主动过期检测机制，避免用户遭遇缓慢的失败请求：

```python
# services/api/app/routes/deps.py
SESSION_IDLE_STALE_THRESHOLD = timedelta(minutes=25)
```

**检测逻辑**：

1. 计算会话空闲时间：`idle_time = now - session.last_active_at`
2. 尝试从 Worker 注入新鲜 Cookie（`_inject_worker_cookies()`）
3. 若 Worker 未注入 Cookie **且**空闲时间超过 25 分钟，则返回 HTTP 401
4. 前端收到 401 后触发 Worker 端的重新登录（`/auth/relogin`），利用边缘节点低延迟优势快速恢复

此设计确保了：
- 有 Worker Cookie 注入时会话持续有效（Cookie 由 Worker 边缘节点维护）
- 无 Worker Cookie 时提前返回 401，避免用户等待缓慢的 JWXT 超时

### 6.3.4 Worker Cookie 注入机制

Cloudflare Worker 在每次代理请求中注入学校系统的会话 Cookie，这是系统的核心安全机制之一：

```
前端请求 (X-Session-Id) → Worker 查找本地/KV Cookie → 注入 Cookie + X-Worker-Auth:1 → 转发至 Vercel
```

**注入流程**（`_worker.js` → `injectSessionCookies()`）：

1. Worker 从请求头获取 `X-Session-Id`
2. 查找本地内存 `localSessions`，未命中则查询 Cloudflare KV
3. 设置 `Cookie` 头为 JWXT Cookie
4. 设置 `X-Ehall-Cookies` 头为 ehall Cookie
5. 设置 `X-Student-Account` 头为学号
6. 设置 `X-Worker-Auth: 1` 标记

**Vercel 端处理**（`deps.py` → `_inject_worker_cookies()`）：

1. 检测 `X-Worker-Auth` 头是否存在
2. 若存在，将 Worker 传来的 Cookie 注入到会话的客户端对象
3. 若会话客户端为 `None`（DB 中 Cookie 已过期），则从 Worker Cookie 重建客户端（恢复机制）

**安全意义**：
- JWXT Cookie 始终由 Worker 边缘节点持有，不直接暴露给前端
- Cookie 与 Worker 的边缘 IP 绑定，Vercel 无法直接使用这些 Cookie 访问 JWXT
- Worker 作为可信中间层，确保 Cookie 仅用于合法的 API 代理请求

### 6.3.5 内部 API 认证

Worker 与 Vercel 之间的内部 API 端点（`/internal/*`）使用共享密钥认证：

```python
# services/api/app/routes/internal.py
def _verify_internal_key(key: str | None) -> None:
    settings = get_settings()
    expected = settings.internal_api_key
    if not expected:
        raise HTTPException(status_code=503, detail="Internal API key not configured")
    if not key or key != expected:
        raise HTTPException(status_code=403, detail="Invalid internal API key")
```

**受保护的内部端点**：

| 端点 | 用途 | Worker 调用方式 |
|------|------|----------------|
| `POST /internal/ocr` | 验证码 OCR 识别 | `X-Internal-Key` 头 |
| `POST /internal/decrypt-password` | RSA 密码解密 | `X-Internal-Key` 头 |
| `POST /internal/create-session` | 创建服务端会话 | `X-Internal-Key` 头 |

**密钥管理**：
- `INTERNAL_API_KEY` 在 Cloudflare Worker 环境变量和 Vercel 环境变量中配置
- 两端密钥必须一致，否则内部 API 调用返回 403
- 密钥未配置时返回 503（服务不可用），而非 403，避免误判为攻击

---

## 6.4 密码安全

### 6.4.1 RSA 加密传输

用户密码在前端使用服务端 RSA 公钥加密后传输，确保密码在传输过程中不被窃取。

**密钥管理**（`services/api/app/rsa_keys.py` — `RsaKeyManager`）：

```python
class RsaKeyManager:
    def __init__(self) -> None:
        # 优先从配置加载持久化密钥，否则生成临时密钥
        pem = get_settings().rsa_private_key_pem.strip() or os.environ.get("RSA_PRIVATE_KEY", "")
        if pem:
            self._private_key = serialization.load_pem_private_key(pem.encode(), password=None)
        else:
            self._private_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        # 生成密钥 ID（公钥 DER 的 SHA-256 前 12 位十六进制）
        self._key_id = hashlib.sha256(pub_der).hexdigest()[:12]
```

**公钥分发**：

```python
# services/api/app/routes/auth.py
@router.get("/public-key")
def get_public_key() -> dict:
    return {
        "publicKey": rsa_key_manager.get_public_key_pem(),
        "keyId": rsa_key_manager.get_key_id(),
    }
```

前端通过 `GET /auth/public-key` 获取 PEM 格式公钥和密钥 ID，使用 PKCS#1 v1.5 填充方案加密密码。

**密钥 ID 机制**：为防止密钥不匹配（例如 Vercel 冷启动时未配置 `RSA_PRIVATE_KEY_PEM` 导致生成新密钥），系统实现了密钥 ID 校验：

```python
# services/api/app/routes/internal.py — decrypt-password 端点
if payload.key_id and payload.key_id != current_key_id:
    raise HTTPException(
        status_code=400,
        detail=f"RSA密钥不匹配: 前端keyId={payload.key_id}, 后端keyId={current_key_id}. "
               "请刷新页面获取新公钥后重试。",
    )
```

**生产环境建议**：应在 Vercel 环境变量中配置 `RSA_PRIVATE_KEY_PEM`，避免冷启动时密钥轮换导致前端缓存的公钥失效。

### 6.4.2 密码解密流程

密码解密发生在两个位置：

1. **Vercel 后端直接解密**（`/auth/login`、`/auth/auto-login`）：

```python
# services/api/app/schemas.py — LoginRequest.resolve_password()
def resolve_password(self) -> str:
    if self.encrypted_password is not None:
        return rsa_key_manager.decrypt(self.encrypted_password)
    if self.password is not None:
        return self.password
    raise ValueError("必须提供 password 或 encryptedPassword")
```

2. **Worker 通过内部 API 解密**（`/auth/auto-login` 边缘处理）：

```
前端 encryptedPassword + keyId → Worker → POST /internal/decrypt-password → Vercel RSA 解密 → 返回明文密码
```

Worker 在边缘处理登录时，需要明文密码用于 CAS RSA 加密。此时 Worker 调用 Vercel 的 `/internal/decrypt-password` 端点，由 Vercel 使用私钥解密后返回。

### 6.4.3 CAS RSA 加密

登录学校 CAS 系统时，密码需要使用 CAS 系统自身的 RSA 公钥加密。这与上述的"前端→后端"RSA 加密是独立的加密层：

```python
# services/api/app/cas_auto_login.py
_RSA_PUBLIC_EXPONENT = 0x010001
_RSA_MODULUS = int("00b5eeb166e069920e80bebd1fea4829d3d1f3216f2aabe79b6c47a3c18dcee5...", 16)
_RSA_TAG = "lyasp"

def _rsa_encrypt(plaintext: str) -> str:
    """使用 BigInt.js 风格的 RSA 加密（零填充，非标准 PKCS#1）"""
    # 1. 将每个字符转为 charCode
    # 2. 零填充至 chunkSize 边界
    # 3. 每 2 字节打包为一个 BigInt 数字（小端序）
    # 4. RSA 加密每个块：c = m^e mod n
    # 5. 转换为零填充的十六进制字符串
    # 6. 用空格连接各块
```

此加密算法与 CAS 前端 JavaScript 的 `encryptedString` 函数完全一致，使用自定义零填充而非标准 PKCS#1 v1.5 填充。Worker 端（`_worker.js`）实现了相同的算法。

### 6.4.4 密码日志脱敏

系统在日志中严格避免输出密码等敏感信息：

```python
# services/api/app/cas_auto_login.py
_SENSITIVE_QUERY_KEYS = {"ticket", "token", "tgt", "password"}

def _redact_url(url: str) -> str:
    """将 URL 中的敏感查询参数替换为 [REDACTED]"""
    query = [
        (key, "[REDACTED]" if key.lower() in _SENSITIVE_QUERY_KEYS else value)
        for key, value in parse_qsl(parsed.query, keep_blank_values=True)
    ]
    return urlunparse(parsed._replace(query=urlencode(query)))
```

所有 CAS 登录相关的 URL 日志均通过 `_redact_url()` 脱敏处理，确保 `ticket`、`token`、`tgt`、`password` 等参数不会出现在日志中。

---

## 6.5 凭证加密存储

### 6.5.1 Fernet 对称加密

用户凭证（账号:密码）在 Vercel 后端使用 Fernet 对称加密后存储于 PostgreSQL 数据库中。

**加密实现**（`services/api/app/sessions.py`）：

```python
from cryptography.fernet import Fernet

def _get_fernet(key: str) -> Fernet:
    """从配置密钥字符串创建 Fernet 实例"""
    raw = hashlib.sha256(key.encode("utf-8")).digest()
    return Fernet(base64.urlsafe_b64encode(raw))

def encrypt_credentials(account: str, password: str, key: str) -> str:
    """将 account:password 加密为单个令牌"""
    f = _get_fernet(key)
    return f.encrypt(f"{account}:{password}".encode("utf-8")).decode("ascii")

def decrypt_credentials(token: str, key: str, ttl_seconds: int | None = None) -> tuple[str, str]:
    """将令牌解密为 (account, password)"""
    f = _get_fernet(key)
    plain = f.decrypt(token.encode("ascii"), ttl=ttl_seconds).decode("utf-8")
    account, password = plain.split(":", 1)
    return account, password
```

**密钥派生**：`CREDENTIAL_ENCRYPTION_KEY` 配置值通过 SHA-256 哈希后，再 Base64 URL-safe 编码为 Fernet 所需的 32 字节密钥。这种派生方式确保：
- 即使配置值长度不规则，也能生成合法的 Fernet 密钥
- SHA-256 单向哈希增加了从 Fernet 密钥反推原始配置值的难度

### 6.5.2 凭证令牌（credential_token）

凭证令牌用于实现自动重新登录功能，其生命周期如下：

```
登录成功 → encrypt_credentials() 生成 Fernet 令牌 → 返回给前端
                                                          ↓
前端存储 credentialToken → 会话过期时发送 /auth/relogin → decrypt_credentials() 解密
                                                          ↓
                                                CAS 自动登录恢复会话
```

**TTL 限制**：`decrypt_credentials()` 支持 `ttl_seconds` 参数，用于限制令牌的有效期。在 `/auth/relogin` 中，TTL 设置为 `ehall_session_ttl_hours * 3600`（默认 24 小时），超过此时间的凭证令牌将无法解密。

### 6.5.3 Worker 端凭证加密

Worker 端使用 Web Crypto API 的 AES-GCM 算法加密凭证，与 Vercel 端的 Fernet 加密相互独立：

```javascript
// apps/mobile_web/web/_worker.js
async function encryptCredentials(account, password, key) {
    const keyData = await crypto.subtle.digest('SHA-256', encoder.encode(key));
    const cryptoKey = await crypto.subtle.importKey('raw', keyData, { name: 'AES-GCM' }, false, ['encrypt']);
    const iv = crypto.getRandomValues(new Uint8Array(12));  // 随机 IV
    const encrypted = await crypto.subtle.encrypt({ name: 'AES-GCM', iv }, cryptoKey, encoder.encode(`${account}:${password}`));
    // 拼接 IV + 密文，Base64 编码返回
    const combined = new Uint8Array(iv.length + encrypted.byteLength);
    combined.set(iv);
    combined.set(new Uint8Array(encrypted), iv.length);
    return btoa(String.fromCharCode(...combined));
}
```

**双加密体系**：

| 属性 | Worker (AES-GCM) | Vercel (Fernet) |
|------|-------------------|------------------|
| 算法 | AES-256-GCM | Fernet (AES-128-CBC + HMAC-SHA256) |
| 密钥来源 | `CREDENTIAL_ENCRYPTION_KEY` 环境变量 | `CREDENTIAL_ENCRYPTION_KEY` 配置项 |
| 密钥派生 | SHA-256 → AES-256 密钥 | SHA-256 → Base64 URL-safe → Fernet 密钥 |
| IV/Nonce | 随机 12 字节 IV | Fernet 内置时间戳 + IV |
| 用途 | 前端 credentialToken（Worker 解密） | 服务端 encrypted_credentials（Vercel 解密） |
| 存储 | 前端本地存储 | PostgreSQL 数据库 |

两端使用相同的 `CREDENTIAL_ENCRYPTION_KEY` 值，但加密算法不同。Worker 的 AES-GCM 令牌用于前端存储和 Worker 端重新登录；Vercel 的 Fernet 令牌用于服务端会话恢复。

### 6.5.4 CREDENTIAL_ENCRYPTION_KEY 生产环境强制配置

```python
# services/api/app/config.py
@lru_cache
def get_settings() -> Settings:
    settings = Settings()
    if not settings.debug:
        if not settings.credential_encryption_key:
            raise RuntimeError(
                "CREDENTIAL_ENCRYPTION_KEY must be set to a random key in production. "
                "Generate one with: python -c \"import secrets; print(secrets.token_urlsafe(32))\""
            )
```

生产环境（`DEBUG=false`）下，若 `CREDENTIAL_ENCRYPTION_KEY` 未配置，应用将拒绝启动。推荐使用以下命令生成：

```bash
python -c "import secrets; print(secrets.token_urlsafe(32))"
```

---

## 6.6 安全头与传输安全

### 6.6.1 安全响应头

系统在所有 HTTP 响应中注入以下安全头：

```python
# services/api/app/main.py
def _security_headers(settings) -> dict[str, str]:
    headers = {
        "X-Content-Type-Options": "nosniff",
        "X-Frame-Options": "DENY",
        "Referrer-Policy": "strict-origin-when-cross-origin",
        "Permissions-Policy": "camera=(), microphone=(), geolocation=()",
    }
    if not settings.debug:
        headers["Strict-Transport-Security"] = "max-age=31536000; includeSubDomains"
    return headers
```

**各头部说明**：

| 安全头 | 值 | 作用 |
|--------|-----|------|
| `X-Content-Type-Options` | `nosniff` | 防止浏览器 MIME 类型嗅探，避免将非可执行文件当作脚本执行 |
| `X-Frame-Options` | `DENY` | 禁止页面被嵌入 iframe，防止点击劫持攻击 |
| `Referrer-Policy` | `strict-origin-when-cross-origin` | 跨域请求仅发送 Origin，不泄露完整 URL 和查询参数（含 ticket/token） |
| `Permissions-Policy` | `camera=(), microphone=(), geolocation=()` | 禁用摄像头、麦克风、地理位置等敏感浏览器 API |
| `Strict-Transport-Security` | `max-age=31536000; includeSubDomains` | 强制浏览器在一年内仅使用 HTTPS 访问（仅生产环境） |

### 6.6.2 HTTPS 强制

生产环境下，系统强制要求 API 和前端均使用 HTTPS：

```python
# services/api/app/config.py
if not settings.debug:
    if settings.public_api_base_url.startswith("http://"):
        raise RuntimeError(
            f"PUBLIC_API_BASE_URL must use HTTPS in production, got: {settings.public_api_base_url}"
        )
    if settings.frontend_base_url.startswith("http://"):
        raise RuntimeError(
            f"FRONTEND_BASE_URL must use HTTPS in production, got: {settings.frontend_base_url}"
        )
```

此检查在应用启动时执行，确保生产环境不会以 HTTP 方式暴露服务。

---

## 6.7 速率限制

### 6.7.1 slowapi 中间件

系统使用 `slowapi` 库实现基于 IP 的速率限制：

```python
# services/api/app/rate_limit.py
from slowapi import Limiter
from slowapi.util import get_remote_address

limiter = Limiter(key_func=get_remote_address, default_limits=[])
```

**受限制的端点**：

| 端点 | 限制 | 说明 |
|------|------|------|
| `POST /auth/login` | 10 次/分钟 | 防止暴力破解密码 |
| `POST /auth/captcha` | 10 次/分钟 | 防止验证码滥用 |
| `POST /auth/auto-login` | 10 次/分钟 | 防止自动化登录攻击 |
| `POST /auth/relogin` | 10 次/分钟 | 防止凭证令牌暴力破解 |

### 6.7.2 X-Forwarded-For 支持

由于所有请求经过 Cloudflare Worker 代理，`slowapi` 的 `get_remote_address` 函数需要正确识别真实客户端 IP。系统在中间件层面确保 `X-Forwarded-For` 头被正确传递和解析，使速率限制基于真实客户端 IP 而非 Worker 的边缘 IP。

### 6.7.3 请求体大小限制

系统在中间件层面实施请求体大小限制：

```python
# services/api/app/main.py
MAX_BODY_BYTES = 10 * 1024 * 1024  # 10MB

@app.middleware("http")
async def security_and_body_limits(request: Request, call_next):
    content_length = request.headers.get("content-length")
    if content_length:
        size = int(content_length)
        if size > MAX_BODY_BYTES:
            return JSONResponse(status_code=413, content={"detail": "请求体过大，最大支持 10MB"})
```

此限制防止大体积请求体导致的拒绝服务攻击。

---

## 6.8 CORS 策略

### 6.8.1 白名单 + 正则匹配

系统采用白名单与正则表达式相结合的 CORS 策略：

```python
# services/api/app/main.py
app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.cors_origin_list,       # 白名单
    allow_origin_regex=settings.cors_origin_regex_value,  # 正则匹配
    allow_credentials=False,                        # 不允许携带凭证
    allow_methods=["GET", "POST", "PATCH"],        # 仅允许必要方法
    allow_headers=["X-Session-Id", "Content-Type", "User-Agent"],  # 仅允许必要头部
)
```

### 6.8.2 允许的来源

**白名单来源**（`cors_origins` 配置项）：

```
http://localhost:3000
http://localhost:5173
http://localhost:8080
http://127.0.0.1:8080
http://192.168.6.230:8080
```

**正则匹配来源**（`cors_origin_regex` 配置项）：

```
^https?://(localhost|127\.0\.0\.1|192\.168\.\d{1,3}\.\d{1,3})(:\d+)?$
```

此正则允许：
- `localhost` 和 `127.0.0.1` 的任意端口（本地开发）
- `192.168.*.*` 的任意端口（局域网开发）

**动态添加**：`FRONTEND_BASE_URL` 的 Origin 会被自动添加到白名单：

```python
# services/api/app/config.py
@property
def cors_origin_list(self) -> list[str]:
    origins = [origin.strip().rstrip("/") for origin in self.cors_origins.split(",") if origin.strip()]
    frontend_origin = self.frontend_origin
    if frontend_origin:
        origins.append(frontend_origin)
    return list(dict.fromkeys(origins))  # 去重
```

### 6.8.3 CORS 安全配置

- **`allow_credentials=False`**：不允许跨域请求携带 Cookie，降低 CSRF 风险。
- **`allow_methods`** 仅包含 `GET`、`POST`、`PATCH`，不暴露 `DELETE`、`PUT` 等危险方法。
- **`allow_headers`** 仅包含 `X-Session-Id`、`Content-Type`、`User-Agent`，不暴露自定义内部头部。

---

## 6.9 数据安全

### 6.9.1 数据库安全

系统在数据库层面实施了严格的安全策略：

**拒绝文件型 SQLite**：

```python
# services/api/app/database.py
def _validate_database_url(raw_url: str) -> None:
    if not raw_url:
        raise RuntimeError("DATABASE_URL must be set to a PostgreSQL connection string.")
    if raw_url.startswith(("sqlite://", "sqlite+aiosqlite://")):
        if ":memory:" in raw_url:
            return  # 内存型 SQLite 仅用于测试
        raise RuntimeError(
            "SQLite file databases are not supported because they can contain local user data. "
            "Use PostgreSQL for deployment or sqlite:///:memory: for tests."
        )
```

此限制确保：
- 生产环境必须使用 PostgreSQL（如 Neon），数据存储在远程安全的服务器上
- 文件型 SQLite 数据库（`.db`/`.sqlite` 文件）被显式拒绝，防止本地数据泄露
- 内存型 SQLite 仅用于自动化测试（`conftest.py` 设置 `DATABASE_URL=sqlite:///:memory:`）

**数据库文件 gitignore**：

```gitignore
# .gitignore
*.db
*.sqlite
*.sqlite3
*.db-wal
*.db-shm
*.sqlite-wal
*.sqlite-shm
*.sqlite3-wal
*.sqlite3-shm
```

所有数据库文件格式均被 `.gitignore` 排除，防止意外提交到版本控制。

### 6.9.2 Cookie 安全

学校系统的 JWXT/ehall Cookie 是最敏感的数据之一，系统采取了多层保护：

**不暴露给前端**：前端仅持有 `X-Session-Id`，永远无法获取学校系统的原始 Cookie。所有 API 响应中不包含 Cookie 值。

**PostgreSQL 加密存储**：Cookie 存储在 `app_sessions` 表的 `jwxt_cookies`、`ehall_cookies`、`ehall_auth_token` 字段中，受 PostgreSQL 的访问控制保护。

**Worker 边缘注入**：Cookie 由 Worker 边缘节点在每次请求时注入，Vercel 后端仅临时使用，不持久化到前端可访问的位置。

**IP 绑定感知**：JWXT Cookie 与 Worker 的边缘 IP 绑定，Vercel 后端在 `create-session` 时跳过 Cookie 验证（`validate=False`），因为 Vercel 的 IP 无法通过 JWXT 验证：

```python
# services/api/app/routes/internal.py
# Skip JWXT validation — cookies are IP-bounded to the Worker's edge IP.
client.login_with_cookies(payload.cookies, payload.account, validate=False)
```

### 6.9.3 敏感环境变量

**`.env` 文件安全**：

```gitignore
# .gitignore
.env
```

`.env` 文件被 `.gitignore` 排除，不会提交到版本控制。系统提供 `.env.example` 作为模板，其中不含实际密钥值：

```
# services/api/.env.example
CREDENTIAL_ENCRYPTION_KEY=change-this-to-a-random-32-byte-string
```

**关键环境变量**：

| 变量名 | 用途 | 安全要求 |
|--------|------|---------|
| `CREDENTIAL_ENCRYPTION_KEY` | Fernet/AES-GCM 凭证加密密钥 | 生产环境必须配置，32 字节随机字符串 |
| `INTERNAL_API_KEY` | Worker↔Vercel 内部 API 认证 | 两端必须一致，定期轮换 |
| `RSA_PRIVATE_KEY_PEM` | RSA 私钥（密码解密） | 生产环境建议配置，避免冷启动密钥轮换 |
| `DATABASE_URL` | PostgreSQL 连接串 | 含数据库凭证，不提交到版本控制 |
| `JPUSH_MASTER_SECRET` | 推送服务密钥 | 第三方服务密钥，不提交到版本控制 |

### 6.9.4 URL 脱敏

系统在日志中对包含敏感参数的 URL 进行脱敏处理：

```python
# services/api/app/cas_auto_login.py
_SENSITIVE_QUERY_KEYS = {"ticket", "token", "tgt", "password"}

def _redact_url(url: str) -> str:
    parsed = urlparse(url)
    if not parsed.query:
        return url
    query = [
        (key, "[REDACTED]" if key.lower() in _SENSITIVE_QUERY_KEYS else value)
        for key, value in parse_qsl(parsed.query, keep_blank_values=True)
    ]
    return urlunparse(parsed._replace(query=urlencode(query)))
```

**脱敏效果示例**：

```
原始: https://cas.gzus.edu.cn/lyuapServer/login?service=...&ticket=ST-12345
脱敏: https://cas.gzus.edu.cn/lyuapServer/login?service=...&ticket=[REDACTED]
```

所有 CAS 登录相关的 URL 日志（`_follow_service_ticket`、`_get_ehall_session` 等）均通过此函数脱敏。

---

## 6.10 Worker 安全

### 6.10.1 INTERNAL_API_KEY 双端一致验证

Worker 与 Vercel 之间的所有内部 API 调用均通过 `X-Internal-Key` 头认证：

**Worker 端**（调用方）：

```javascript
// apps/mobile_web/web/_worker.js
const res = await fetch(`${vercelOrigin}/internal/ocr`, {
    method: 'POST',
    headers: {
        'Content-Type': 'application/json',
        'X-Internal-Key': env.INTERNAL_API_KEY || '',
    },
    body: JSON.stringify({ image: b64 }),
});
```

**Vercel 端**（验证方）：

```python
# services/api/app/routes/internal.py
def _verify_internal_key(key: str | None) -> None:
    settings = get_settings()
    expected = settings.internal_api_key
    if not expected:
        raise HTTPException(status_code=503, detail="Internal API key not configured")
    if not key or key != expected:
        raise HTTPException(status_code=403, detail="Invalid internal API key")
```

**密钥一致性保障**：
- `INTERNAL_API_KEY` 必须在 Cloudflare Worker 环境变量和 Vercel 环境变量中配置相同的值
- 密钥不匹配时，Worker 的 OCR、密码解密、会话创建等功能将全部失败
- 密钥未配置时返回 503（服务不可用），明确提示配置问题

### 6.10.2 Worker 不直接暴露后端凭证

Worker 作为边缘代理层，遵循以下安全原则：

- **密码不落盘**：明文密码仅在 CAS 登录流程中短暂存在于 Worker 内存，登录完成后由垃圾回收释放
- **Cookie 不回传前端**：JWXT/ehall Cookie 仅在 Worker 内部使用，API 响应中不包含原始 Cookie 值
- **内部 API 密钥隔离**：`INTERNAL_API_KEY` 仅用于 Worker→Vercel 的服务端调用，不暴露给前端

### 6.10.3 KV 存储的会话数据安全

Worker 使用 Cloudflare KV 命名空间 `SESSIONS_KV` 存储会话数据，用于跨实例持久化：

```toml
# wrangler.toml
[[env.production.kv_namespaces]]
id = "09627cf70d7a493f87d8a95f20e682a0"
binding = "SESSIONS_KV"
```

**KV 数据结构**：

```javascript
// Key: session:{sessionId}
// Value: JSON.stringify({ account, cookies, ehallCookies, studentName })
// TTL: 7200 秒（2 小时，与 Vercel 会话 TTL 一致）
```

**安全特性**：
- KV 数据通过 Cloudflare 内部网络传输，不经过公共互联网
- KV 条目设置 `expirationTtl`，过期后自动删除
- KV 仅可通过 Worker 代码访问，外部无法直接读取
- 会话数据包含 Cookie，但仅 Worker 代码可读取，前端无法获取

**双层存储架构**：

```
Worker 内存 (localSessions) ← 快速访问，单实例
         ↕ 同步
Cloudflare KV (SESSIONS_KV) ← 跨实例持久化，冷启动恢复
         ↕ 同步（通过 /internal/create-session）
PostgreSQL (app_sessions) ← Vercel 端持久化，冷启动恢复
```

---

## 6.11 已知安全考量与改进方向

### 6.11.1 JWT vs 当前 Session-ID 方案

**当前方案**：使用随机 UUID 作为会话 ID，会话状态存储在 PostgreSQL 中。

**优势**：
- 会话可即时撤销（删除数据库记录或标记 `revoked_at`）
- 无需处理 JWT 的密钥轮换和分发问题
- 服务端完全控制会话生命周期

**不足**：
- 每次请求需查询数据库（已有内存缓存缓解）
- 水平扩展时需共享数据库连接

**JWT 改进方向**：
- 可考虑使用短期 JWT + 长期刷新令牌的方案
- JWT 可减少数据库查询，但撤销需额外机制（如黑名单）
- 当前方案在可预见的用户规模下性能足够，暂无迫切需求

### 6.11.2 CSRF 防护

**当前状态**：系统通过以下机制部分缓解 CSRF 风险：
- CORS 策略限制跨域请求来源
- `allow_credentials=False` 阻止跨域请求携带 Cookie
- 会话 ID 通过 `X-Session-Id` 自定义头传递，而非 Cookie

**改进方向**：
- 添加 CSRF Token 机制（如双重提交 Cookie 模式）
- 对状态变更操作（POST/PATCH）添加 `Origin`/`Referer` 校验
- 考虑使用 `SameSite=Strict` Cookie 属性（若将来改用 Cookie 传递会话 ID）

### 6.11.3 审计日志

**当前状态**：系统使用 Python `logging` 模块记录操作日志，但未实现结构化审计日志。

**改进方向**：
- 实现结构化审计日志，记录关键操作（登录、会话创建/撤销、凭证解密等）
- 添加操作者 IP、时间戳、操作类型等字段
- 将审计日志发送到独立的日志服务（如 Cloudflare Logpush 或第三方 SIEM）
- 实现日志不可篡改机制（如追加写入存储）

### 6.11.4 会话固定攻击防护

**当前状态**：系统在登录成功后生成新的随机会话 ID，不会复用旧的会话 ID。同一账号在新设备登录时，旧会话被标记为 `revoked`。

**改进方向**：
- 在认证状态变更时（如权限提升）强制重新生成会话 ID
- 实现会话 ID 轮换机制（定期更换活跃会话的 ID）
- 添加会话绑定信息（如 IP、User-Agent 指纹），检测异常会话使用

### 6.11.5 其他改进方向

| 方向 | 说明 | 优先级 |
|------|------|--------|
| **密钥轮换** | 支持在线轮换 `CREDENTIAL_ENCRYPTION_KEY` 和 `INTERNAL_API_KEY`，无需停机 | 中 |
| **密码重试锁定** | 对连续登录失败的账号实施临时锁定，防止暴力破解 | 高 |
| **WebSocket 认证增强** | 当前 WebSocket 连接仅验证 `sessionId`，可添加 Origin 校验 | 中 |
| **请求签名** | 对 Worker→Vercel 的内部请求添加时间戳+签名，防止重放攻击 | 低 |
| **安全扫描 CI** | 在 CI 流水线中集成依赖漏洞扫描（如 `pip-audit`、`safety`） | 中 |
| **渗透测试** | 定期进行安全渗透测试，验证安全机制的有效性 | 高 |