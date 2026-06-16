# 软帮手 登录页协议集成方案

> **状态**: ✅ 已实现（2026-06-09）  
> **目标**: 在登录页面展示《用户服务协议》和《隐私政策》，要求用户勾选同意后才能进行登录操作。  
> **技术栈**: Flutter 3.x + Dart  
> **修改文件**: `apps/mobile_web/lib/main.dart`

---

## 📋 方案概述

| 需求点 | 方案 |
|--------|------|
| 协议展示 | 登录表单底部添加协议文本（可点击查看全文） |
| 勾选确认 | Checkbox 勾选框 + "我已阅读并同意" 文案 |
| 强制同意 | 未勾选时登录按钮不可点击（或点击时弹出提示） |
| 协议全文 | 点击协议名称弹出 BottomSheet 或新页面展示全文 |
| 持久化 | 用户同意后存储到 SharedPreferences，下次自动勾选 |
| Web版 | 协议全文渲染为静态 HTML 页面，支持浏览器访问 |

---

## 🔧 代码修改步骤

### 第一步：在 `_LoginPageState` 中添加状态变量

找到 `_LoginPageState` 类（约第 586 行），在现有变量下方添加：

```dart
class _LoginPageState extends State<LoginPage>
    with SingleTickerProviderStateMixin {
  final accountController = TextEditingController();
  final passwordController = TextEditingController();
  final passwordFocusNode = FocusNode();
  bool loading = false;
  bool rememberPassword = true;
  String? error;
  // ===== 👇 新增：协议勾选状态 =====
  bool agreedToTerms = false;
  // ===== 👆 新增结束 =====
  late final _appearController = AnimationController(/* ... */);
  // ...
}
```

### 第二步：在 `initState` 中加载协议同意记录

在 `initState` 方法（约第 604 行）的 `_loadSavedLoginForm()` 调用后，添加协议状态加载：

```dart
@override
void initState() {
  super.initState();
  error = widget.initialError;
  unawaited(_loadSavedLoginForm());
  unawaited(_loadAgreementState());  // 👈 新增
  _appearController.forward();
}

// ===== 👇 新增方法 =====
Future<void> _loadAgreementState() async {
  final prefs = await SharedPreferences.getInstance();
  final agreed = prefs.getBool('auth.agreedToTerms') ?? false;
  if (!mounted) return;
  setState(() => agreedToTerms = agreed);
}

Future<void> _saveAgreementState() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool('auth.agreedToTerms', true);
}
// ===== 👆 新增方法结束 =====
```

### 第三步：在登录表单中添加协议勾选行

在 `build()` 方法的 Column children 中，找到"记住密码"行和登录按钮之间（约第 810 行），插入协议勾选组件：

```dart
// ... 记住密码 Row 保持不变 ...

// ===== 👇 新增：协议勾选区域 =====
const SizedBox(height: 8),
InkWell(
  borderRadius: BorderRadius.circular(GzusRadii.sm),
  onTap: loading
      ? null
      : () => setState(() => agreedToTerms = !agreedToTerms),
  child: Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Checkbox(
          value: agreedToTerms,
          onChanged: loading
              ? null
              : (value) => setState(() => agreedToTerms = value ?? false),
        ),
        Expanded(
          child: GestureDetector(
            onTap: loading
                ? null
                : () => setState(() => agreedToTerms = !agreedToTerms),
            child: RichText(
              text: TextSpan(
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                children: [
                  const TextSpan(text: '我已阅读并同意'),
                  TextSpan(
                    text: '《用户服务协议》',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.primary,
                      decoration: TextDecoration.underline,
                    ),
                    recognizer: TapGestureRecognizer()
                      ..onTap = () => _showAgreementDialog(
                            context,
                            title: '用户服务协议',
                            type: 'terms',
                          ),
                  ),
                  const TextSpan(text: ' 和 '),
                  TextSpan(
                    text: '《隐私政策》',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.primary,
                      decoration: TextDecoration.underline,
                    ),
                    recognizer: TapGestureRecognizer()
                      ..onTap = () => _showAgreementDialog(
                            context,
                            title: '隐私政策',
                            type: 'privacy',
                          ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    ),
  ),
),
// ===== 👆 新增结束 =====

// ... 登录按钮 FilledButton 保持不变 ...
```

### 第四步：修改登录按钮逻辑

将登录按钮的 `onPressed` 修改为根据协议勾选状态决定：

```dart
// 原代码：
// SizedBox(
//   height: compact ? 56 : 60,
//   child: FilledButton(
//     onPressed: loading ? null : _login,
//     child: /* ... */,
//   ),
// ),

// ===== 👇 修改为 =====
SizedBox(
  height: compact ? 56 : 60,
  child: FilledButton(
    onPressed: (loading || !agreedToTerms) ? null : _login,
    child: _IconLabel(
      icon: Icons.login,
      label: loading ? '登录中...' : '办事大厅统一登录',
      centered: true,
    ),
  ),
),
// ===== 👆 修改结束 =====
```

### 第五步（可选）：在 `_login()` 方法中添加双重校验

虽然按钮已经禁用了，但作为安全措施，在 `_login()` 开头加一道保险：

```dart
Future<void> _login() async {
  if (loading) return;

  // ===== 👇 新增：协议检查 =====
  if (!agreedToTerms) {
    setState(() => error = '请先阅读并同意《用户服务协议》和《隐私政策》');
    return;
  }
  // ===== 👆 新增结束 =====

  final account = accountController.text.trim();
  final password = passwordController.text;
  // ... 后续登录逻辑保持不变 ...
}
```

### 第六步：登录成功后保存协议状态

找到 `_login()` 方法中 `widget.onLoggedIn(...)` 调用处（约第 901 行），在调用之前保存协议状态：

```dart
try {
  // ... 登录逻辑 ...

  // ===== 👇 新增：登录成功后保存同意状态 =====
  await _saveAgreementState();
  // ===== 👆 新增结束 =====

  widget.onLoggedIn(LoginResult(/* ... */));
}
```

### 第七步：添加协议查看弹窗方法

在 `_LoginPageState` 类中添加协议弹窗方法：

```dart
// ===== 👇 新增方法：协议弹窗 =====
void _showAgreementDialog(
  BuildContext context, {
  required String title,
  required String type,
}) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (sheetContext) => DraggableScrollableSheet(
      initialChildSize: 0.85,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (_, scrollController) => Column(
        children: [
          // 拖拽指示条
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: Theme.of(context)
                    .colorScheme
                    .onSurfaceVariant
                    .withOpacity(0.3),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          // 标题栏
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(sheetContext).pop(),
                ),
              ],
            ),
          ),
          const Divider(),
          // 协议正文
          Expanded(
            child: _AgreementContentView(
              type: type,
              scrollController: scrollController,
            ),
          ),
        ],
      ),
    ),
  );
}
// ===== 👆 新增方法结束 =====
```

### 第八步：添加协议内容渲染组件

在文件末尾（或`_LoginPageState` 类之前）添加协议内容组件：

```dart
// ===== 👇 新增组件 =====
class _AgreementContentView extends StatelessWidget {
  const _AgreementContentView({
    required this.type,
    required this.scrollController,
  });

  final String type;
  final ScrollController scrollController;

  @override
  Widget build(BuildContext context) {
    // 根据 type 加载对应协议内容
    final content = type == 'terms' ? _termsOfServiceText : _privacyPolicyText;

    return SingleChildScrollView(
      controller: scrollController,
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
      child: DefaultTextStyle(
        style: Theme.of(context).textTheme.bodyMedium!.copyWith(
              height: 1.8,
            ),
        child: Text(content),
      ),
    );
  }
}

// 用户服务协议摘要（完整版请见 docs/terms-of-service.md）
const _termsOfServiceText = '''
软帮手 用户服务协议（摘要）

重要提示：请在使用本应用前仔细阅读。使用即视为同意本协议。

一、服务说明
软帮手（OneGZUS）是一个学生自发开发的开源工具……(完整内容请参阅文档)

二、用户账号
请使用学校统一身份认证学号和密码登录，妥善保管登录凭证。

三、用户行为
仅限个人学习使用，不得进行逆向工程、数据抓取等违规操作。

四、免责声明
本应用非学校官方产品，数据以学校官方系统为准。本软件按 MIT 许可证提供。

（完整版本请查看应用内文档或项目仓库 docs/terms-of-service.md）
''';

// 隐私政策摘要（完整版请见 docs/privacy-policy.md）
const _privacyPolicyText = '''
软帮手 隐私政策（摘要）

我们重视您的隐私。本政策说明我们如何收集、使用和保护您的信息。

一、信息收集
我们仅收集完成教务查询功能所必需的信息……(完整内容请参阅文档)

二、信息使用
信息仅用于展示课表、成绩、考勤、水电费等校内教务服务。

三、信息存储
密码不持久化存储，学校系统 Cookie 仅保存在服务端内存中。

四、信息安全
所有通信使用 HTTPS 加密，日志不记录密码等敏感信息。

五、您的权利
您有权查看、更正、删除您的数据，可随时退出登录或卸载应用。

（完整版本请查看应用内文档或项目仓库 docs/privacy-policy.md）
''';
// ===== 👆 新增组件结束 =====
```

---

## 🔄 完整版的协议内容策略

由于在 Flutter 应用中内嵌完整协议文本会使包体积显著增大，推荐以下分层策略：

| 展现形式 | 适用场景 | 实现方式 |
|---------|---------|---------|
| **摘要版**（弹窗内） | 首次登录快速阅读 | 上述 `_AgreementContentView` 中硬编码摘要 |
| **完整版**（新页面） | 需要细读时 | Navigator.push 到新页面，通过 Markdown 解析或网络加载 |
| **Web版**（外部链接） | 浏览器访问 | 发布到项目网站 /privacy 和 /terms 路径 |
| **文档文件** | 离线分发 | 随 APK 打包或放在 GitHub 仓库 docs/ 目录 |

### Web 版完整协议页面

在 `website/` 目录创建协议页面，将 Markdown 渲染为 HTML：

```
website/
├── privacy.html       ← 隐私政策（从 docs/privacy-policy.md 转换）
├── terms.html         ← 用户服务协议（从 docs/terms-of-service.md 转换）
├── index.html
├── v1-bento.html
├── ...
```

---

## ✅ 验收清单

| 检查项 | 预期行为 |
|--------|---------|
| 首次安装打开 | 协议复选框未勾选，登录按钮灰色不可用 |
| 点击协议链接 | 弹出 BottomSheet 显示协议内容摘要 |
| 勾选同意后 | 登录按钮恢复可点击状态 |
| 未勾选点登录 | 按钮不可用，无响应 |
| 登录成功后 | 协议同意状态保存到本地 |
| 下次打开应用 | 自动勾选协议（已同意过） |
| 退出登录再登录 | 协议保持已同意状态 |
| 卸载重装 | 协议状态重置，需重新勾选 |
| 暗色模式 | 协议文本颜色适配深色主题 |
| 小屏手机 | 协议文本行不溢出，自动换行 |
| Web 版 | 可直接访问 /privacy.html 和 /terms.html |

---

## 📦 补充：APK 打包时包含协议文件

如需将完整协议随 APK 分发，可在 `pubspec.yaml` 中添加 assets：

```yaml
flutter:
  assets:
    - assets/agreements/privacy-policy.md
    - assets/agreements/terms-of-service.md
```

然后在 Flutter 代码中通过 `rootBundle.loadString()` 加载：

```dart
import 'package:flutter/services.dart';

Future<String> _loadAgreementContent(String filename) async {
  return await rootBundle.loadString('assets/agreements/$filename');
}
```

---

## 🔗 相关文件索引

| 文件 | 说明 |
|------|------|
| `docs/privacy-policy.md` | 隐私政策完整版（Markdown） |
| `docs/terms-of-service.md` | 用户服务协议完整版（Markdown） |
| `docs/privacy.md` | 开发团队内部隐私规范（技术视角） |
| `apps/mobile_web/lib/main.dart` | 登录页面源代码（需按本方案修改） |
| `website/privacy.html` | 隐私政策 Web 版 |
| `website/terms.html` | 用户服务协议 Web 版 |
| [GitHub 仓库](https://github.com/ONTHEREIN/GZUS-PRO) | 项目源码与完整文档 |

---

<p align="center">
  <sub>软帮手（OneGZUS）— 合规先行，信任为本</sub>
</p>
