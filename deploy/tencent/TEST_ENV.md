# 小程序 MVP 分层测试环境手册

面向 `/Users/decrein/WeChatProjects/miniprogram-2` 的分层验收：**接口层（pytest）→ 开发者工具页面回归（miniprogram-automator）→ 真机验收（iOS / Android）**。

测试环境与生产环境**共用同一台腾讯云主机**，但使用独立子域名、独立端口、独立数据库与独立 systemd 服务。任何一个环节都不允许把测试流量导向生产。

| 项目         | 生产                                          | 测试                                              |
| ---------- | ------------------------------------------- | ----------------------------------------------- |
| 域名         | `onegzus.onrein.top`                        | `test-api.onrein.top`                   |
| 后端服务       | `onegzus-api`（127.0.0.1:8000）               | `onegzus-test-api`（127.0.0.1:8001）              |
| 目录         | `/opt/onegzus`                              | `/opt/onegzus-test`                             |
| 数据库        | `onegzus`（PostgreSQL）                       | `onegzus_test`（PostgreSQL，独立库）                  |
| `DEBUG`    | `false`                                     | `true`                                          |
| 演示账号       | 关闭                                          | `DEMO_ACCOUNT_ENABLED=true`                     |
| 小程序接口地址    | `develop`/`trial`→测试，`release`→生产（见下）       | 同左                                              |

小程序按 `envVersion` 自动分流（`utils/config.ts`）：开发者工具（`develop`）与体验版（`trial`）打测试 API，正式版（`release`）打生产 API。**两个域名都必须加入 request 合法域名**，否则真机验收会直接报 `url not in domain list`。

---

## 0. 当前状态（2026-09-19 实测）

| 环节 | 状态 |
| --- | --- |
| 目标主机 | ✅ `106.55.2.248`，OpenCloudOS 9.6，SELinux 已禁用、firewalld 未启用 |
| 独立数据库 | ✅ 角色 `onegzus_test` + 库 `onegzus_test`（与生产隔离） |
| 独立服务 | ✅ `onegzus-test-api` active，监听 `127.0.0.1:8001`（生产 `onegzus-api` 仍监听 8000，未受影响） |
| 测试 release | ✅ `/opt/onegzus-test/releases/api/test-mvp-wt-20260919`（独立 venv） |
| nginx 反代 | ✅ 已装 `conf.d/test-api.conf`（**阶段 B：完整 HTTPS**），`/api/…` → 8001 链路已验证 |
| 接口冒烟 | ✅ `smoke_test_api.sh` **公网 HTTPS 10/10 通过**（登录 + 六个只读接口 + 无凭据字段 + 退出后 401） |
| DNS | ✅ `test-api.onrein.top` → `106.55.2.248`（注意：**不是** `test-api.onegzus.onrein.top`，见下方说明） |
| HTTPS 证书 | ✅ Let's Encrypt，CN=`test-api.onrein.top`，有效期至 2026-12-18，外部校验 `Verify return code: 0 (ok)`，已挂自动续期 |
| 微信合法域名 | ✅ **已添加 `https://test-api.onrein.top`**，并在开启域名校验的情况下用真实链路脚本验证通过 |
| 真实链路（演示账号） | ✅ `npm run test:live`（`MINI_EXPECT=demo`）**10/10 通过** |
| 模拟器验收（真实账号） | ✅ `MINI_EXPECT=real` **10/10 通过**，详见下方观测记录 |
| 真机验收 | ⬜ 待人工执行（iOS / Android 各一次） |

### 模拟器真实账号验收观测记录（2026-09-19）

用真实学生账号在开发者工具模拟器走完整个核心流程，`https://test-api.onrein.top` 真实接口，开启域名校验：

| 页面 | 观测结果 |
| --- | --- |
| 登录 | ✅ 真实 CAS 认证通过 |
| 本地存储 | ✅ 只有 `auth.sessionId` / `auth.studentName` / `auth.studentId` 三个键，无 Cookie/Token 落盘 |
| 首页 | 近期课程 3 条（自课表截取）、考试提醒 1 条 |
| 课表 | 20 条 |
| 成绩 | 1 条 |
| 考试 | 1 条 |
| 通知 | 38 条 |
| 生活缴费 | **页面显示空态**（`#ecard-not-bound`）——该账号未绑定宿舍，属预期行为 |
| 个人信息 | ✅ 正常加载 |
| 退出登录 | ✅ 回到登录页且本地会话已清空 |

两点说明：

- **生活缴费显示空态是正确行为**，不是缺陷：真实账号未绑定宿舍，页面提示「暂未绑定宿舍，请先在原生 App 或 Web 端完成绑定」。
  一卡通绑定按计划不在本次范围内。
- 真实账号数据量随人而异（课表 20 条 vs 演示 7 条），所以 `real` 档位只做结构性断言；
  脚本会打印实际观测条数，避免「空列表也算通过」这种假绿。

### 域名与计划的差异

计划里假设的是 `test-api.onegzus.onrein.top`，实际创建的是 **`test-api.onrein.top`**（主机记录
`test-api` 直接加在 `onrein.top` 区域下，而不是 `onegzus.onrein.top` 子域）。按计划的既有约定
（「若 DNS 命名不同，同步修改小程序测试接口地址和微信合法域名」），全部配置已按**实际记录名**对齐：

- 小程序 `utils/config.ts` 的 `TEST_API_BASE_URL`
- 服务器 `/opt/onegzus-test/shared/api.env` 的 `PUBLIC_API_BASE_URL` / `FRONTEND_BASE_URL` / `CORS_ORIGINS`
- `deploy/tencent/nginx/test-api.conf`、`test-api-http.conf` 的 `server_name`
- `setup_test_env.sh` 的 `TEST_DOMAIN` 默认值

若要改回嵌套域名，需要新增 `test-api.onegzus` 的 A 记录、为该名字重新签发证书，并同步上述四处配置。
| 真机验收 | ⬜ 待人工执行 |

### 关于代码来源（重要）

生产 release `multi-album-20260919-1212` **不包含小程序后端支持**：没有
`app/routes/mini_program.py`、没有 `app/demo_data.py`、`config.py` 里也没有
`DEMO_ACCOUNT_*` 字段（pydantic 会以 `extra_forbidden` 直接报错）。

也就是说：**`/mini/auth/login` 与演示账号功能目前只存在于工作区未提交的改动中，从未上线。**
因此测试环境必须用工作区代码构建，而不是复用生产 release：

```bash
# 本机打包工作区后端（排除虚拟环境与密钥）
tar czf /tmp/onegzus-test-src.tar.gz -C services/api \
  --exclude=.venv --exclude=.env --exclude=__pycache__ --exclude=.pytest_cache .
scp /tmp/onegzus-test-src.tar.gz root@106.55.2.248:/tmp/
ssh root@106.55.2.248 'rm -rf /tmp/onegzus-test-src && mkdir -p /tmp/onegzus-test-src \
  && tar xzf /tmp/onegzus-test-src.tar.gz -C /tmp/onegzus-test-src'

# 在服务器上用工作区代码构建测试 release
TEST_CODE_SRC=/tmp/onegzus-test-src TEST_RELEASE_TAG=test-mvp-wt-$(date +%Y%m%d) \
  bash deploy/tencent/scripts/setup_test_env.sh
```

> 这也意味着小程序 MVP 上线前必须先把 `mini_program.py`、`demo_data.py` 与
> `DEMO_ACCOUNT_*` 配置**提交并部署到生产**，否则正式版小程序调用 `/mini/auth/login` 会 404。

一键初始化脚本（幂等，可重复执行；绝不修改生产目录/服务/站点）：
`deploy/tencent/scripts/setup_test_env.sh`；接口冒烟：`deploy/tencent/scripts/smoke_test_api.sh`。

---

## 1. 前置条件

- [ ] DNS 已添加 `test-api.onrein.top` 的 A 记录，指向同一台腾讯云主机
- [ ] 服务器 SSH 可用（`deploy/tencent/.ssh/`）
- [ ] 演示账号密码已确定（只写进服务器环境文件，不进仓库、不进 IM、不进日志）
- [ ] 微信公众平台管理员权限（配置 request 合法域名）

验证 DNS 与 80 端口已通：

```bash
dig +short test-api.onrein.top
curl -I http://test-api.onrein.top/.well-known/acme-challenge/probe
```

## 2. 部署测试后端

```bash
# 2.1 独立数据库（不要复用生产库）
sudo -u postgres psql -c "CREATE USER onegzus WITH PASSWORD '<TEST_PG_PASSWORD>';"   # 已存在则跳过
sudo -u postgres createdb onegzus_test -O onegzus

# 2.2 独立目录
sudo mkdir -p /opt/onegzus-test/{shared,releases,backups}
sudo chown -R onegzus:onegzus /opt/onegzus-test

# 2.3 环境文件：由模板派生，权限 600，绝不提交
sudo cp deploy/tencent/env/onegzus-test.env.example /opt/onegzus-test/shared/api.env
sudo chmod 600 /opt/onegzus-test/shared/api.env
sudo $EDITOR /opt/onegzus-test/shared/api.env

# 2.4 首次 release：复用生产的 release 激活脚本模式
#     （activate_release.sh 以 /opt/onegzus 为根；测试环境请先复制一份并把根路径改成
#      /opt/onegzus-test，避免误切生产版本）
sudo cp deploy/tencent/scripts/activate_release.sh /opt/onegzus-test/activate_release.sh
sudo sed -i 's#/opt/onegzus#/opt/onegzus-test#g' /opt/onegzus-test/activate_release.sh

# 2.5 systemd
sudo cp deploy/tencent/systemd/onegzus-test-api.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now onegzus-test-api
systemctl status onegzus-test-api --no-pager
```

**密钥必须与生产不同**：`CREDENTIAL_ENCRYPTION_KEY`、`INTERNAL_API_KEY` 单独生成。复用生产密钥会让测试库中的密文具备被生产密钥解开的可能。

## 3. 配置 nginx 与证书

```bash
# 3.1 先签证书（需要 80 端口可访问）
sudo mkdir -p /etc/nginx/ssl/onegzus-test /var/www/certbot
sudo certbot certonly --webroot -w /var/www/certbot \
  -d test-api.onrein.top --non-interactive --agree-tos -m <你的邮箱>
sudo cp /etc/letsencrypt/live/test-api.onrein.top/fullchain.pem /etc/nginx/ssl/onegzus-test/
sudo cp /etc/letsencrypt/live/test-api.onrein.top/privkey.pem   /etc/nginx/ssl/onegzus-test/

# 3.2 站点（目标主机是 OpenCloudOS / RHEL 系，nginx 用 conf.d，没有 sites-available）
#     分两阶段：
#       阶段 A（证书签发前）：只装 HTTP 版本，让 ACME 校验与反代链路先可用
sudo cp deploy/tencent/nginx/test-api-http.conf /etc/nginx/conf.d/test-api.conf
sudo nginx -t && sudo systemctl reload nginx

#       阶段 B（证书签发后）：换成完整 HTTPS 版本
sudo cp deploy/tencent/nginx/test-api.conf /etc/nginx/conf.d/test-api.conf
sudo nginx -t && sudo systemctl reload nginx
```

> **不要在证书签发前安装 `test-api.conf`**：它含 `ssl_certificate` 指令，证书文件不存在时
> `nginx -t` 会失败；在生产主机上做一次失败的 nginx 配置校验是有风险的。
> 阶段 A 的 `test-api-http.conf` 不含任何 TLS 指令，因此可以安全先装。

> 现状核对（2026-09）：目标主机 `106.55.2.248` 为 OpenCloudOS 9.6，SELinux 已禁用、
> firewalld 未启用，nginx 站点目录为 `/etc/nginx/conf.d/`，生产站点文件是 `onegzus.conf`。
> 证书为 certbot 2.8.0 签发，`onegzus.onrein.top` 有效期至 2026-11-26。**不要改动 `onegzus.conf`。**

## 4. 环境自检

```bash
# 4.0 一键接口冒烟（本机 8001，或换成为公网测试域名）
bash deploy/tencent/scripts/smoke_test_api.sh
bash deploy/tencent/scripts/smoke_test_api.sh https://test-api.onrein.top/api

# 4.1 证书与跳转
curl -sI https://test-api.onrein.top/ | head -3          # 期望 200 + "onegzus TEST api"
curl -s  https://test-api.onrein.top/                    # 期望 onegzus TEST api

# 4.2 就绪探针（确认连的是测试库）
curl -s https://test-api.onrein.top/api/health/ready

# 4.3 确认没有打到生产：测试站点根路径返回 "onegzus TEST api"，
#     且生产库不应出现演示账号会话：
#     sudo -u postgres psql onegzus -c "select count(*) from app_sessions;"

# 4.4 演示账号登录（凭据只从环境文件读取，不要写进 shell history）
set -a; . /opt/onegzus-test/shared/api.env; set +a
curl -s -X POST https://test-api.onrein.top/api/mini/auth/login \
  -H 'Content-Type: application/json' \
  -d "{\"account\":\"$DEMO_ACCOUNT\",\"password\":\"$DEMO_PASSWORD\"}" | head -c 400
# 期望只返回 status / sessionId / studentName / studentId 四个字段
```

## 5. 微信公众平台配置

在 **微信公众平台 → 开发管理 → 开发设置 → 服务器域名** 中：

- [ ] `request 合法域名` 增加 `https://test-api.onrein.top`
- [ ] 确认 `https://onegzus.onrein.top` 仍在列表中（正式版依赖它）
- [ ] **不要**在开发者工具里关闭「不校验合法域名」来完成验收——关闭校验会掩盖真实问题

> 实测：域名未加入白名单时，开发者工具会直接报 `request:fail url not in domain list`，请求根本不会发出。

## 6. 自动检查（本地 / CI）

在 `miniprogram-2`：

```bash
npm run typecheck     # TypeScript 类型检查
npm test              # typecheck + 逻辑单测（34 例，零外部依赖）
npm run test:pages    # 开发者工具页面回归（10 例，全程 mock，需开发者工具）
npm run test:live     # 真实链路检查（9 例，不 mock，打测试域名真实接口）
npm run test:all      # test + test:pages
npm run auto-preview  # CLI 自动预览，推送真机验收包
```

`test:live` 需要演示账号，凭据只从环境变量读（密码可在服务器上取，别写进文件或命令行参数）：

```bash
PW=$(ssh root@106.55.2.248 'grep -m1 "^DEMO_PASSWORD=" /opt/onegzus-test/shared/api.env | cut -d= -f2-')
MINI_DEMO_ACCOUNT=demo_mini_2026 MINI_DEMO_PASSWORD="$PW" npm run test:live
```

在 `services/api`：

```bash
PYTHONPATH=. uv run pytest      # 全量 356 例
PYTHONPATH=. uv run pytest tests/test_mini_program.py -v   # 小程序接口专项
uv run ruff check .
```

### 开发者工具前置条件

页面回归与自动预览都要求：

1. 已安装微信开发者工具（macOS 默认 `/Applications/wechatwebdevtools.app`，可用 `WECHAT_DEVTOOLS_CLI` 覆盖）；
2. **设置 → 安全设置 → 开启服务端口**；
3. 开发者工具已登录（`cli islogin` 返回 `login=true`）；未登录时先 `cli login` 扫码；
4. 自动化端口默认 9420，可用 `WECHAT_AUTO_PORT` 覆盖。

页面回归的失败现场（截图 + 控制台日志）默认写到**项目目录之外**：

```
<miniprogram-2>/../onegzus-miniprogram-test-artifacts/
```

> 必须写在项目外：开发者工具监听项目目录，往项目里写文件会触发重新编译，AppService 重载后注入的 `wx.request` mock 会失效，回归会成片假失败。可用 `WECHAT_TEST_ARTIFACT_DIR` 覆盖。

### 分层职责

| 层      | 覆盖内容                                                                   | 不覆盖                          |
| ------ | ---------------------------------------------------------------------- | ---------------------------- |
| 逻辑单测   | 解析器字段校验与凭据过滤、`envVersion` 分流、请求层 401/错误文案/网络失败、`requireSession` | 真实网络、真实页面                    |
| 页面回归   | 空输入、错误密码、登录、六个页面加载、401 清理会话、下拉刷新、退出登录、5xx 错误态、无会话跳转                    | 真实接口、真实域名、真机渲染               |
| 真实链路   | 真实 HTTPS 域名登录 + 六个页面真实数据、**request 合法域名白名单是否生效**                       | 真机渲染、真机网络环境                 |
| 后端集成测试 | 演示账号走通六个接口、错误密码、缺失/失效会话、退出后失效、响应无凭据字段                                  | 小程序侧展示逻辑                     |
| 真机验收   | 真实域名 + 真实微信客户端 + iOS/Android                                          | 需要人工执行，见第 7 节                |

页面回归全程 mock `wx.request`，因此**不需要**演示账号密码，日志里也不会出现任何真实凭据。

## 7. 真机验收（人工）

对 iOS 与 Android 各做一次。用 `npm run auto-preview` 出包（自动预览不需要扫码，直接推送到已开启该功能的微信客户端）。

| 步骤 | 操作                             | 期望                                             |
| -- | ------------------------------ | ---------------------------------------------- |
| 1  | 手机微信打开自动预览的小程序                 | 正常启动，无「不在以下 request 合法域名列表中」提示                 |
| 2  | 登录页留空直接点登录                     | 提示「请输入学号和密码」，不发起请求                             |
| 3  | 输入演示账号 + 错误密码                  | 提示「演示账号或密码错误」（服务端文案），不写入会话                     |
| 4  | 输入演示账号 + 正确密码                  | 进入首页，问候语显示学生姓名                                 |
| 5  | 首页                           | 近期课程、考试提醒有数据，无错误卡片                             |
| 6  | 依次进入 课表 / 成绩 / 考试 / 通知 / 生活缴费 | 均加载成功，无错误提示                                    |
| 7  | 课表页下拉刷新                        | 触发刷新并回到正常列表（首页同样支持下拉刷新）                        |
| 8  | 我的页                          | 展示姓名、学号、学院等个人信息                                |
| 9  | 点退出登录                          | 回到登录页；再次进入首页应被弹回登录页                            |
| 10 | 杀进程重开                          | 会话仍有效则直接进首页；失效则回登录页并提示重新登录                     |

### 记录表

| 项        | iOS | Android |
| -------- | --- | ------- |
| 机型       |     |         |
| 系统版本     |     |         |
| 微信版本     |     |         |
| 网络类型（4G/WiFi） |     |         |
| 结果（通过/失败） |     |         |
| 失败现象与截图  |     |         |

## 8. 观测与安全复核

```bash
# 测试服务日志：4xx/5xx、登录失败、接口耗时
sudo journalctl -u onegzus-test-api -f
sudo journalctl -u onegzus-test-api --since "1 hour ago" | grep -E "request_completed|unhandled_exception"

# 确认响应与日志不含敏感字段
sudo journalctl -u onegzus-test-api --since "1 hour ago" \
  | grep -iE "credentialToken|jwxtCookies|ehallAuthToken|password" || echo "无敏感字段"
```

- [ ] 小程序登录响应只有 4 个安全字段（后端测试已断言）
- [ ] 日志中不出现密码、Cookie、会话 ID
- [ ] 测试库中不出现真实学生账号
- [ ] 未执行任何写操作、一卡通绑定、订阅消息、自动请假

## 9. 范围说明（已变更）

原计划把下列内容排除在 MVP 验收外，其中**一卡通绑定已改为在范围内**：

| 项 | 状态 |
| --- | --- |
| 一卡通/宿舍绑定 | ✅ **已实现**在小程序「生活缴费」页（见第 10 节），后端无需改动 |
| 真实学生账号 | ⚠️ 已用于**只读**验收（模拟器验收见第 0 节）。真实账号等同学校凭据，用完请改密码 |
| 写操作 | ⚠️ 宿舍绑定是写操作，但**只写我们自己的库**，不向学校系统写入 |
| 订阅消息 / 自动请假 / FTP / 微信身份绑定 | ⬜ 仍不在范围内 |

## 10. 小程序内宿舍绑定

后端无需改动，复用已有接口：

- `GET /ecard/rooms?q=<关键词>&limit=<n>` —— 全量约 6700 条（~880KB），**必须带关键词**；返回 `{id, schoolArea, building, room, displayName}`
- `POST /ecard/binding`，body `{roomId, roomDisplay}` → `EcardSummary`；`roomId` 形如 `<implType>|<校区>|<楼栋>|<房间号>`，必须是 4 段

**绑定是本地操作**：只 upsert `EcardBinding` 表，随后 `client.balance()` 是**读**上游余额。改绑只是改一行，不向学校系统写入任何东西。

### 测试环境的一个必要配置

真实账号查询宿舍需要 `ECARD_OPENID` 与 `ECARD_SECRET`（应用级集成凭据，不是学生数据）。
测试环境初建时为空，导致真实账号搜索报 `未配置 ECARD_OPENID`（演示账号走硬编码分支掩盖了这个问题）。
已从 `/opt/onegzus/shared/api.env` 同步这两项到 `/opt/onegzus-test/shared/api.env`（`ECARD_UNIONID` 两边都刻意留空 —— 有回归测试要求不得携带 unionid）。

若要收回：把测试环境这两项置空并 `systemctl restart onegzus-test-api` 即可，代价是真实账号无法在测试环境查询/绑定宿舍。

### 覆盖情况

| 层 | 覆盖 |
| --- | --- |
| 逻辑单测 | `parseEcardRooms` 的必填字段、展示字段降级、空列表 |
| 页面回归（mock） | 未绑定→搜索→绑定成功、重新绑定入口、空关键词不发请求、绑定失败文案 |
| 后端 pytest | `POST /ecard/binding` 路由级测试（创建/非法 roomId/改绑不新增行/余额不可用仍落库/演示账号 403） |
| 真实链路 | 真实账号搜索命中 50 条真实宿舍（只查询、不绑定） |
| **真实绑定** | ✅ 已用真实账号绑定 `A2-932` 并校验首页模块，见下 |

#### 真实绑定验收记录（2026-09-19）

脚本用 `MINI_BIND_ROOM_KEYWORD=a2-932` 显式触发（默认不跑），结果：

```
即将绑定：江门校区 西苑A2栋 A2-932
绑定后余额：电费 128.30 度   冷水 16.51 吨   热水 14.504 元
首页水电模块：江门校区 西苑A2栋 A2-932 / 电费 128.30 度 / 冷水 16.51 吨 / 热水 14.504 元
```

脚本在匹配到多个宿舍时会**直接中止**而不是随便挑一个——绑错房间会展示别人房间的读数。

**环境隔离已用证据确认**（不只是"应该是"）：

| | created_at | 结论 |
| --- | --- | --- |
| 测试库 `onegzus_test` | `2026-09-19 08:01:00 UTC` | 本次测试写入 |
| 生产库 `onegzus` | `2026-08-18 01:28:25` | 一个月前，学生自己绑的，与本次测试无关 |

两库连接串也分别使用独立角色：测试 `onegzus_test`，生产 `onegzus`。

> 观测：热水显示 `14.504 元`（三位小数）。这是**学校上游原样返回**的（`ecard_client.py` 优先透传上游
> `hotWaterText`，仅在上游缺失时才本地格式化为两位），不是本次改动引入的问题，但如果你希望统一成两位小数，
> 需要改后端而不是小程序。

## 11. 清理

```bash
sudo systemctl disable --now onegzus-test-api
sudo rm -f /etc/nginx/conf.d/test-api.conf
sudo nginx -t && sudo systemctl reload nginx
sudo -u postgres dropdb onegzus_test
sudo -u postgres dropuser onegzus_test
sudo rm -rf /opt/onegzus-test
# 微信公众平台移除 test-api 合法域名；DNS 记录按需保留或删除
```

## 12. 常见故障

### `/mini/auth/login` 返回 500「服务器内部错误」

**现象**：小程序登录时提示「服务器内部错误」。

**定位**：

```bash
sudo journalctl -u onegzus-test-api --since "30 min ago" -o cat | grep -A 25 "Traceback"
```

若看到 `RuntimeError: 学校登录成功但未返回学生姓名` 即为此问题。

**根因**：`SchoolSdkClient.login_with_cookies` 的签名是 `str | None` —— **拿不到姓名是上游正常情况**。
该方法用 4 种策略尽力提取姓名（SDK 返回值 → `get_info()` → 抓 JWXT 首页 → 再试 client `get_info()`），
每种都 `except Exception: pass`，全失败就返回 `None`。它**不影响会话有效性**：会话在更早的
`user_login_with_cookies(cookie, account=...)` 就已验证，失败会抛 `AuthenticationError`。

旧代码把这种情况当成致命错误抛**裸 `RuntimeError`**，被全局异常处理器变成 500 + 通用文案，
用户既拿不到有用信息、也没法自行判断。

**副作用**：`auto_login` 内部已经执行过 `sessions.create()`，一旦抛错，会话就被创建却发不出去
（客户端没有 `sessionId`，无法复用）——每次失败泄漏一个会话，只能等 TTL 清理。

**修复**（已上线）：

- 只有「没有任何 `sessionId`」才算致命，且改用 `HTTPException(502)` 返回可读文案，不再是 500；
- 姓名/学号归一化为字符串，缺失时返回空串并记 `warning`，登录照常成功。

小程序**不显示**这两个字段（`auth.studentName` 只写不读），姓名与学号以 `/me` 的返回为准，
所以缺失不影响用户体验。

**复查**：

```bash
# 该情况已被降级处理（出现即为上游未返回姓名，但用户不受影响）
sudo journalctl -u onegzus-test-api --since "1 hour ago" -o cat | grep "身份字段缺失"
# 不应再有未捕获异常
sudo journalctl -u onegzus-test-api --since "1 hour ago" -o cat | grep -cE "unhandled_exception|Traceback"
```

> 教训：把「上游尽力而为的字段」当成硬性契约会让整条链路变得脆弱。判断某个字段是否可选时，
> 先看它的类型签名与调用方是否真的使用它。
