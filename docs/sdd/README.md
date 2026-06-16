# 软帮手（OneGZUS）软件设计文档 (SDD)

> 版本：1.0  
> 最后更新：2026-06-17  
> 项目仓库：GZUS-PRO

## 文档目录

| 章节 | 文件 | 内容概述 |
|------|------|----------|
| 第1章 | [01-overview.md](01-overview.md) | 系统概述、项目背景、整体架构设计、技术选型 |
| 第2章 | [02-backend-modules.md](02-backend-modules.md) | 后端模块设计、路由、客户端、服务层、后台任务 |
| 第3章 | [03-frontend-modules.md](03-frontend-modules.md) | 前端模块设计、页面架构、服务层、平台适配 |
| 第4章 | [04-data-model.md](04-data-model.md) | 数据模型、数据库表结构、缓存策略、会话持久化 |
| 第5章 | [05-api-design.md](05-api-design.md) | API 接口设计、请求/响应格式、认证流程、错误处理 |
| 第6章 | [06-security.md](06-security.md) | 安全设计、加密方案、认证授权、安全头、速率限制 |
| 第7章 | [07-deployment.md](07-deployment.md) | 部署架构、CI/CD、环境配置、监控与运维 |
| 第8章 | [08-flows.md](08-flows.md) | 关键业务流程、时序设计、数据流、Worker 边缘处理 |

## 项目简介

软帮手（OneGZUS）是广州软件学院的教务事务助手应用，覆盖课表查询、成绩查询、考勤统计、水电费查询、在线请假、考试提醒等功能。采用 Flutter 前端 + FastAPI 后端架构，通过 Cloudflare Worker 在边缘节点处理 CAS SSO 登录，其余请求代理至 Vercel 无服务器后端。

## 技术栈概览

| 层级 | 技术 | 说明 |
|------|------|------|
| 前端 | Flutter 3.x (Dart) | Web + Android + iOS 跨平台 |
| 后端 | FastAPI (Python 3.11+) | 部署到 Vercel (Serverless) |
| 边缘计算 | Cloudflare Worker | CAS SSO 登录、请求代理 |
| 数据库 | PostgreSQL (Neon) | 生产环境；测试用 SQLite 内存库 |
| 推送 | JPush + Web Push (VAPID) | Android 原生推送 + Web 推送 |
| CI/CD | GitHub Actions | 自动构建部署前端和后端 |