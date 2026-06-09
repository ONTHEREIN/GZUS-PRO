# 成本优化

免费部署默认策略：

- 数据库用 Neon pooled connection string。
- Vercel 后端连接池保持小值：`DB_POOL_SIZE=1`、`DB_MAX_OVERFLOW=2`。
- 前端放 GitHub Pages，只在构建时注入 `API_BASE_URL`。
- `JPUSH_APP_KEY` / `JPUSH_MASTER_SECRET` 留空即可关闭实际推送发送。
- 只把 `DATABASE_URL`、`CREDENTIAL_ENCRYPTION_KEY`、三方密钥放平台环境变量，不写入仓库。

上线后优先观察：

- Neon 连接数是否接近上限。
- Vercel 函数是否频繁超时。
- 登录、课表、通知这类慢接口是否需要前端缓存兜底。

迁移数据前先跑普通迁移；只有确认覆盖目标库时才使用：

```powershell
python services/api/migrate_to_postgres.py --sqlite-path services/api/gzus_pro.db --truncate-target --yes
```

