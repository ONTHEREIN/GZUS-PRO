# 开源组件与致谢

软帮手（OneGZUS）由学生开发和维护，感谢以下开源项目、平台生态和服务提供者为项目提供的基础能力。依赖版本以各目录下的 `pubspec.yaml`、`pyproject.toml`、锁文件和原生工程配置为准。

## 客户端与跨平台生态

| 组件/项目 | 用途 |
| --- | --- |
| [Flutter](https://flutter.dev/) / [Dart](https://dart.dev/) | 跨平台 UI、编译和运行时 |
| [Riverpod](https://riverpod.dev/) | Flutter 状态管理 |
| `http`、`web_socket_channel`、`web` | HTTP、WebSocket 和 Web 平台 API |
| `shared_preferences`、`flutter_secure_storage` | 普通偏好、本地缓存和敏感凭据存储 |
| `webview_flutter`、`url_launcher`、`share_plus` | SSO 页面、外部链接和系统分享 |
| `flutter_local_notifications`、`timezone` | Android/iOS 本地通知和定时提醒 |
| `file_picker`、`image_picker`、`path_provider` | 文件、图片选择和本地路径处理 |
| `flutter_web_auth_2` | 移动端 Web 认证回调 |
| `package_info_plus` | 应用版本和构建信息 |
| `encrypt`、`pointycastle`、`gbk_codec` | 加密、编码和部分平台数据处理 |
| [WidgetKit](https://developer.apple.com/documentation/widgetkit)、[ActivityKit](https://developer.apple.com/documentation/activitykit) | iOS 桌面组件和 Live Activities |
| Android SDK / Jetpack、CocoaPods | Android/iOS 原生构建和系统能力 |

## 服务端与工具链

| 组件/项目 | 用途 |
| --- | --- |
| [FastAPI](https://fastapi.tiangolo.com/)、[Uvicorn](https://www.uvicorn.org/) | API 服务和 ASGI 运行时 |
| [SQLAlchemy](https://www.sqlalchemy.org/)、[Pydantic](https://docs.pydantic.dev/) | 数据库访问、模型和请求校验 |
| [httpx](https://www.python-httpx.org/) | 上游 HTTP/HTTP2 请求 |
| [asyncpg](https://github.com/MagicStack/asyncpg)、[psycopg2](https://www.psycopg.org/)、[aiosqlite](https://github.com/omnilib/aiosqlite) | PostgreSQL、SQLite 数据库连接 |
| [cryptography](https://cryptography.io/)、[rsa](https://stuvel.eu/python-rsa/) | 服务端凭据和密钥处理 |
| [Pillow](https://python-pillow.org/)、[ddddocr](https://github.com/sml2h3/ddddocr) | 图片处理和验证码识别 |
| [pywebpush](https://github.com/web-push-libs/pywebpush) | Web Push 推送 |
| [slowapi](https://github.com/laurentS/slowapi) | API 访问频率限制 |
| [uv](https://docs.astral.sh/uv/)、[Ruff](https://docs.astral.sh/ruff/)、[pytest](https://pytest.org/) | Python 依赖、检查和测试 |

## 项目内置或经审查的组件

- `third_party/reshub_flutter`：腾讯 Shiply/ResHub Flutter 插件的项目内副本，用于 Android/iOS 公共资源下发；其目录包含独立许可证文件。
- `services/api/app/vendor/school_sdk`：经项目维护者审查和修补的学校系统 SDK。项目不会在未审查的情况下直接覆盖其中的补丁。
- 学校官方教务系统、办事大厅、一卡通系统：数据和业务服务来源；软帮手仅作为个人信息聚合和展示工具。
- `wttr.in`：天气数据来源，仅在天气功能请求时使用默认城市或用户授权的近似位置。
- Apple APNs、浏览器 Push 服务：仅在用户授权通知且服务配置可用时用于投递提醒。

## 许可证说明

软帮手自身代码按仓库根目录的 [MIT License](../LICENSE) 发布。上表列出的第三方项目不因此改变其原有许可证；重新分发或修改第三方代码时，请同时遵守对应项目的许可证和版权声明。Flutter/Dart、Python、Android、iOS 及各依赖维护者的持续贡献，为本项目提供了可靠的基础，谨此致谢。

如果发现致谢遗漏或许可证信息需要修正，欢迎通过 [GitHub Issues](https://github.com/ONTHEREIN/GZUS-PRO/issues) 反馈。
