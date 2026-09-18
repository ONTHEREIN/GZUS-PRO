# 软帮手（OneGZUS）Flutter 客户端

这是软帮手（OneGZUS）的 Flutter 客户端，支持 Web、Android 和 iOS。项目面向广州市大学生，提供教务查询、通知提醒和校园常用服务；它是非官方、非营利的校园工具，不代表学校或任何学校系统。

## 开发环境

- Flutter 3.x（CI 当前使用 Flutter 3.44.0）
- Dart 3.x
- Android Studio 或 Xcode（按目标平台安装对应 SDK）
- 后端 API：默认使用 `https://onegzus.onrein.top/api`

在 `apps/mobile_web/` 目录执行：

```bash
flutter pub get
flutter test
flutter analyze
flutter run -d chrome
```

本地联调时，通过编译期变量指定 API：

```bash
flutter run -d chrome --dart-define=API_BASE_URL=http://127.0.0.1:8000
```

构建发布包：

```bash
flutter build web --dart-define=API_BASE_URL=https://onegzus.onrein.top/api --no-web-resources-cdn
flutter build apk --dart-define=API_BASE_URL=https://onegzus.onrein.top/api
```

版本遵循 `pubspec.yaml` 中的语义版本与递增构建号约定。仅文档、检查或测试不应递增版本号；实际功能或修复交付时才更新对应版本。

## 目录结构

```text
lib/
├── main.dart                  # 应用入口与导航接线
├── api_client.dart             # API 客户端与模型导出
├── api_models.dart             # API 数据模型
├── auth_storage.dart           # 登录状态与敏感凭据存储
├── gzus_design.dart             # 主题和共享视觉组件
├── pages/                      # 各业务页面
├── shell/                      # 桌面/移动导航壳
├── widgets/                    # 跨页面共享组件
├── models/                     # 业务模型与偏好设置
└── *_service.dart              # 推送、WebSocket、桌面组件等服务
```

主要页面模块包括首页、课表、成绩、考勤、考试、学分、通知、一卡通/水电费、请假、作业上传、个人信息、更多和管理后台。

## 平台能力与隐私边界

- Web：支持教务查询、通知、天气、反馈、浏览器 Push 和响应式布局。
- Android：支持本地课程提醒、通知、桌面组件、文件/图片选择和后台通知服务。
- iOS：支持 APNs、桌面组件、Live Activities、日历导出及系统认证回调；真机分发需要正确的签名、推送和 WidgetKit 配置。
- 天气功能仅在用户授权定位后使用近似位置；定位、通知、相册/相机和日历权限均按功能需要申请。
- 选择“记住密码并自动登录”后，账号密码和认证材料使用 `flutter_secure_storage` 等本机安全存储；普通偏好和非敏感缓存使用 `shared_preferences`。用户主动开启后台持续通知后，服务端才会保存加密的后台授权凭据。

详细说明见根目录的[隐私政策](../../docs/privacy-policy.md)、[服务协议](../../docs/terms-of-service.md)和[开源致谢](../../docs/acknowledgements.md)。

## 代码约定

- 面向用户的文字和注释以简体中文为主。
- 优先使用纯函数、不可变数据和现有共享组件，避免重复实现。
- 新增 API 数据先在 `api_models.dart` 建立强类型模型，再接入页面。
- 平台差异放入 `_web.dart`、`_stub.dart` 或 `_io.dart` 文件，并保持 Web 构建可用。
- 认证、推送和本地存储相关改动应同步补充测试，并检查退出登录和权限撤销路径。
- 不要在日志、测试数据或反馈附件中写入密码、验证码、Cookie 或完整令牌。

## 相关文档

- [项目总览](../../README.md)
- [文档索引](../../docs/README.md)
- [API 概览](../../docs/api.md)
- [本地数据访问边界](../../docs/scraping-boundaries.md)
- [登录协议集成记录](../../docs/login-agreement-integration.md)

后端开发、部署和配置说明见 [`services/api/`](../../services/api/) 及其 `.env.example`。
