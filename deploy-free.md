# 免费部署最小流程

目标组合：

- 后端：Vercel Python Serverless
- 数据库：Neon PostgreSQL Free
- 前端：GitHub Pages

## 1. 创建 Neon 数据库

1. 在 [Neon](https://neon.tech) 创建项目。
2. 复制连接串，优先使用 pooled connection string。
3. 确认连接串形如：

```text
postgresql://user:password@host/dbname?sslmode=require
```

## 2. 部署后端到 Vercel

在 Vercel 导入 GitHub 仓库：

- Framework Preset：`Other`
- Root Directory：`services/api`
- Build/Install：使用仓库内 `services/api/vercel.json`

添加环境变量：

```text
DATABASE_URL=postgresql://user:password@host/dbname?sslmode=require
PUBLIC_API_BASE_URL=https://<your-api>.vercel.app
FRONTEND_BASE_URL=https://<github-user>.github.io/<repo-name>
CORS_ORIGINS=https://<github-user>.github.io
CORS_ORIGIN_REGEX=
CREDENTIAL_ENCRYPTION_KEY=<随机长字符串>
DEBUG=false
DB_POOL_SIZE=1
DB_MAX_OVERFLOW=2
DB_POOL_TIMEOUT=10
DB_POOL_RECYCLE=300

JW_BASE_URL=https://jwxt.seig.edu.cn/jwglxt
EHALL_BASE_URL=https://ehall.gzus.edu.cn
CAS_LOGIN_URL=https://cas.gzus.edu.cn/lyuapServer/login
EHALL_SERVICE_URL=http://ehall.gzus.edu.cn/shiro-cas
JWXT_SSO_SERVICE_URL=https://jwxt.seig.edu.cn/sso/lyiotlogin
ECARD_BASE_URL=https://ecarduser.gzus.edu.cn
```

可选变量按需配置：

```text
JPUSH_APP_KEY=
JPUSH_MASTER_SECRET=
ECARD_OPENID=
ECARD_UNIONID=
ECARD_SECRET=
APP_LATEST_VERSION=0.0.1
APP_LATEST_BUILD=1
APP_MIN_SUPPORTED_VERSION=0.0.1
APP_DOWNLOAD_URL=
APP_RELEASE_NOTES=
```

部署后验证：

```powershell
curl https://<your-api>.vercel.app/health
```

应返回：

```json
{"status":"ok"}
```

## 3. 迁移 SQLite 数据

在本机执行：

```powershell
cd services/api
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
$env:DATABASE_URL="postgresql://user:password@host/dbname?sslmode=require"
python migrate_to_postgres.py --sqlite-path .\gzus_pro.db
```

如果目标库已有旧数据且确认覆盖：

```powershell
python migrate_to_postgres.py --sqlite-path .\gzus_pro.db --truncate-target --yes
```

## 4. 部署前端到 GitHub Pages

仓库 Settings -> Secrets and variables -> Actions -> Variables 添加：

```text
API_BASE_URL=https://<your-api>.vercel.app
```

仓库 Settings -> Pages：

- Source：`Deploy from a branch`
- Branch：`gh-pages`
- Folder：`/ (root)`

推送到 `main` 后，`.github/workflows/deploy-frontend.yml` 会构建：

```powershell
flutter build web --release --base-href "/<repo-name>/" --dart-define=API_BASE_URL=https://<your-api>.vercel.app
```

## 5. 最小上线检查

- `https://<your-api>.vercel.app/health` 返回 `ok`
- GitHub Pages 打开无 CORS 报错
- 登录回调能从 Vercel 返回到 `https://<github-user>.github.io/<repo-name>`
- 需要推送时再配置极光；不配置时推送接口会跳过发送

## 成本

| 项目 | 免费额度 |
| --- | --- |
| Vercel | Hobby 免费额度 |
| GitHub Pages | 公共仓库免费 |
| Neon | Free PostgreSQL |

