import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../api_client.dart';
import '../../browser_redirect.dart';
import '../../gzus_design.dart';
import '../../responsive/spacing.dart';
import '../../test_flags.dart';
import '../../widgets/icon_label.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({
    super.key,
    required this.api,
    required this.onLoggedIn,
    this.initialError,
  });

  final ApiClient api;
  final ValueChanged<LoginResult> onLoggedIn;
  final String? initialError;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage>
    with SingleTickerProviderStateMixin {
  final accountController = TextEditingController();
  final passwordController = TextEditingController();
  final passwordFocusNode = FocusNode();
  bool loading = false;
  bool rememberPassword = true;
  bool agreedToTerms = false;
  String? error;
  String _appVersion = '';
  String _appBuild = '';

  /// 当前登录模式：'sso' = 办事大厅一键登录（推荐），'password' = 教务系统账密登录
  String loginMode = 'sso';
  late final _appearController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 500),
  );
  late final _appearAnim = CurvedAnimation(
    parent: _appearController,
    curve: Curves.easeOutCubic,
  );

  @override
  void initState() {
    super.initState();
    error = widget.initialError;
    unawaited(_loadSavedLoginForm());
    unawaited(_loadAgreementState());
    unawaited(_loadVersionInfo());
    _appearController.forward();
  }

  Future<void> _loadSavedLoginForm() async {
    final prefs = await SharedPreferences.getInstance();
    final remember = prefs.getBool('auth.rememberPassword') ?? true;
    final account = prefs.getString('auth.account') ?? '';
    await prefs.remove('auth.password');
    if (!mounted) return;
    setState(() {
      rememberPassword = remember;
      accountController.text = account;
      passwordController.text = '';
    });
  }

  Future<void> _loadAgreementState() async {
    final prefs = await SharedPreferences.getInstance();
    final agreed = prefs.getBool('auth.agreedToTerms') ?? false;
    if (!mounted) return;
    setState(() => agreedToTerms = agreed);
  }

  Future<void> _loadVersionInfo() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (!mounted) return;
      setState(() {
        _appVersion = info.version;
        _appBuild = info.buildNumber;
      });
    } catch (_) {}
  }

  Future<void> _saveAgreementState() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('auth.agreedToTerms', true);
  }

  @override
  void didUpdateWidget(covariant LoginPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialError != widget.initialError) {
      error = widget.initialError;
    }
  }

  @override
  void dispose() {
    _appearController.dispose();
    accountController.dispose();
    passwordController.dispose();
    passwordFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < _mobileBreakpoint;
          return SafeArea(
            child: SingleChildScrollView(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: EdgeInsets.fromLTRB(
                compact ? 14 : 24,
                compact ? 18 : 40,
                compact ? 14 : 24,
                24 + MediaQuery.viewInsetsOf(context).bottom,
              ),
              child: FadeTransition(
                opacity: _appearAnim,
                child: SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0, 0.06),
                    end: Offset.zero,
                  ).animate(_appearAnim),
                  child: Center(
                    child: ConstrainedBox(
                      constraints:
                          BoxConstraints(maxWidth: compact ? 460 : 420),
                      child: Container(
                        decoration: BoxDecoration(
                          color: gzusSurface(context),
                          borderRadius: BorderRadius.circular(GzusRadii.xl),
                          border: Border.all(color: gzusBorder(context)),
                          boxShadow: gzusShadow(context),
                        ),
                        child: Padding(
                          padding: EdgeInsets.all(compact ? 22 : 30),
                          child: AutofillGroup(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Hero(
                                      tag: 'app-logo',
                                      child: Container(
                                        width: compact ? 48 : 56,
                                        height: compact ? 48 : 56,
                                        decoration: BoxDecoration(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .primary,
                                          borderRadius:
                                              BorderRadius.circular(16),
                                          boxShadow: [
                                            BoxShadow(
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .primary
                                                  .withValues(alpha: 0.25),
                                              blurRadius: 18,
                                              offset: const Offset(0, 8),
                                            ),
                                          ],
                                        ),
                                        child: ClipRRect(
                                          borderRadius:
                                              BorderRadius.circular(16),
                                          child: Image.asset(
                                            'assets/icon.png',
                                            fit: BoxFit.cover,
                                          ),
                                        ),
                                      ),
                                    ),
                                    SizedBox(height: compact ? 18 : 22),
                                    Text(
                                      '软帮手',
                                      style: Theme.of(context)
                                          .textTheme
                                          .headlineMedium,
                                    ),
                                    const SizedBox(height: GzusSpacing.xs),
                                    Text(
                                      '广州软件学院教务助手',
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodyMedium
                                          ?.copyWith(
                                            color: Theme.of(context)
                                                .colorScheme
                                                .onSurfaceVariant,
                                          ),
                                    ),
                                    const SizedBox(height: GzusSpacing.l),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 12,
                                        vertical: 8,
                                      ),
                                      decoration: BoxDecoration(
                                        color: gzusSurfaceSoft(context),
                                        borderRadius: BorderRadius.circular(12),
                                        border: Border.all(
                                            color: gzusBorder(context)),
                                      ),
                                      child: Row(
                                        children: [
                                          Icon(
                                            Icons.lock_outline,
                                            size: 16,
                                            color: Theme.of(context)
                                                .colorScheme
                                                .primary,
                                          ),
                                          const SizedBox(width: GzusSpacing.s),
                                          Expanded(
                                            child: Text(
                                              hideEcardOnCurrentPlatform
                                                  ? '登录后自动同步课表、考勤、成绩与通知'
                                                  : '登录后自动同步课表、考勤、成绩、通知与生活缴费',
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .bodySmall,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                                SizedBox(height: compact ? 20 : 24),
                                Row(
                                  children: [
                                    Expanded(
                                      child: SegmentedButton<String>(
                                        segments: const [
                                          ButtonSegment(
                                            value: 'sso',
                                            label: Text('一键登录'),
                                            icon: Icon(Icons.flash_on),
                                          ),
                                          ButtonSegment(
                                            value: 'password',
                                            label: Text('教务系统'),
                                            icon: Icon(Icons.password),
                                          ),
                                        ],
                                        selected: {loginMode},
                                        onSelectionChanged: (selection) {
                                          if (selection.isEmpty) return;
                                          setState(() {
                                            loginMode = selection.first;
                                            error = null;
                                          });
                                        },
                                      ),
                                    ),
                                  ],
                                ),
                                SizedBox(height: compact ? 20 : 24),
                                if (loginMode == 'sso') ...[
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 10,
                                    ),
                                    decoration: BoxDecoration(
                                      color: GzusColors.greenSoft,
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(
                                        color: GzusColors.green.withValues(
                                            alpha: 0.20),
                                      ),
                                    ),
                                    child: Row(
                                      children: [
                                        const Icon(
                                          Icons.verified_user,
                                          size: 18,
                                          color: GzusColors.green,
                                        ),
                                        const SizedBox(width: GzusSpacing.s),
                                        Expanded(
                                          child: Text(
                                            '跳转学校统一身份认证，无需在本应用输入密码',
                                            style: Theme.of(context)
                                                .textTheme
                                                .bodySmall
                                                ?.copyWith(
                                                  color: GzusColors.green,
                                                ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ] else ...[
                                  TextField(
                                    controller: accountController,
                                    decoration: const InputDecoration(
                                      hintText: '学号',
                                      prefixIcon: Icon(Icons.person),
                                    ),
                                    autofillHints: const [
                                      AutofillHints.username,
                                      AutofillHints.email,
                                    ],
                                    textInputAction: TextInputAction.next,
                                    onSubmitted: (_) =>
                                        passwordFocusNode.requestFocus(),
                                  ),
                                  const SizedBox(height: GzusSpacing.m),
                                  TextField(
                                    controller: passwordController,
                                    focusNode: passwordFocusNode,
                                    decoration: const InputDecoration(
                                      hintText: '密码',
                                      prefixIcon: Icon(Icons.lock),
                                    ),
                                    obscureText: true,
                                    autofillHints: const [
                                      AutofillHints.password
                                    ],
                                    textInputAction: TextInputAction.done,
                                    onSubmitted: _submitFromKeyboard,
                                  ),
                                ],
                                if (loginMode == 'password')
                                  InkWell(
                                    borderRadius:
                                        BorderRadius.circular(GzusRadii.sm),
                                    onTap: loading
                                        ? null
                                        : () => setState(() => rememberPassword =
                                            !rememberPassword),
                                    child: Padding(
                                      padding:
                                          const EdgeInsets.symmetric(vertical: 4),
                                      child: Row(
                                        children: [
                                          Checkbox(
                                            value: rememberPassword,
                                            onChanged: loading
                                                ? null
                                                : (value) => setState(() =>
                                                    rememberPassword =
                                                        value ?? true),
                                          ),
                                          const Text('记住学号并自动登录'),
                                        ],
                                      ),
                                    ),
                                  ),
                                InkWell(
                                  borderRadius:
                                      BorderRadius.circular(GzusRadii.sm),
                                  onTap: loading
                                      ? null
                                      : () => setState(
                                          () => agreedToTerms = !agreedToTerms),
                                  child: Padding(
                                    padding:
                                        const EdgeInsets.symmetric(vertical: 4),
                                    child: Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.center,
                                      children: [
                                        Checkbox(
                                          value: agreedToTerms,
                                          onChanged: loading
                                              ? null
                                              : (value) => setState(() =>
                                                  agreedToTerms =
                                                      value ?? false),
                                        ),
                                        Expanded(
                                          child: RichText(
                                            text: TextSpan(
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .bodySmall
                                                  ?.copyWith(
                                                    color: Theme.of(context)
                                                        .colorScheme
                                                        .onSurface,
                                                  ),
                                              children: [
                                                const TextSpan(text: '我已阅读并同意'),
                                                TextSpan(
                                                  text: '《用户服务协议》',
                                                  style: TextStyle(
                                                    color: Theme.of(context)
                                                        .colorScheme
                                                        .primary,
                                                    decoration: TextDecoration
                                                        .underline,
                                                  ),
                                                  recognizer:
                                                      TapGestureRecognizer()
                                                        ..onTap = () =>
                                                            _showAgreement(
                                                              context,
                                                              title: '用户服务协议',
                                                              type: 'terms',
                                                            ),
                                                ),
                                                const TextSpan(text: ' 和 '),
                                                TextSpan(
                                                  text: '《隐私政策》',
                                                  style: TextStyle(
                                                    color: Theme.of(context)
                                                        .colorScheme
                                                        .primary,
                                                    decoration: TextDecoration
                                                        .underline,
                                                  ),
                                                  recognizer:
                                                      TapGestureRecognizer()
                                                        ..onTap = () =>
                                                            _showAgreement(
                                                              context,
                                                              title: '隐私政策',
                                                              type: 'privacy',
                                                            ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                SizedBox(height: compact ? 16 : 18),
                                SizedBox(
                                  height: compact ? 56 : 60,
                                  child: FilledButton(
                                    onPressed: (loading || !agreedToTerms)
                                        ? null
                                        : loginMode == 'sso'
                                            ? _startSsoLogin
                                            : _login,
                                    child: IconLabel(
                                      icon: loginMode == 'sso'
                                          ? Icons.flash_on
                                          : Icons.login,
                                      label: loading
                                          ? '登录中...'
                                          : loginMode == 'sso'
                                              ? '办事大厅一键登录'
                                              : '教务系统登录',
                                      centered: true,
                                    ),
                                  ),
                                ),
                                if (error != null) ...[
                                  const SizedBox(height: GzusSpacing.l),
                                  Card(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .errorContainer,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: Padding(
                                      padding: const EdgeInsets.all(GzusSpacing.l),
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(Icons.error_outline,
                                              size: 48,
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .onErrorContainer),
                                          const SizedBox(height: GzusSpacing.m),
                                          Text(error!,
                                              textAlign: TextAlign.center,
                                              style: TextStyle(
                                                  color: Theme.of(context)
                                                      .colorScheme
                                                      .onErrorContainer)),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                                if (_appVersion.isNotEmpty) ...[
                                  const SizedBox(height: GzusSpacing.xl),
                                  Center(
                                    child: Text(
                                      'v$_appVersion (build $_appBuild)',
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.copyWith(
                                            color: Theme.of(context)
                                                .colorScheme
                                                .onSurfaceVariant
                                                .withValues(alpha: 0.45),
                                          ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _startSsoLogin() async {
    if (loading) return;
    if (!agreedToTerms) {
      setState(() => error = '请先阅读并同意《用户服务协议》和《隐私政策》');
      return;
    }
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final current = currentBrowserUrl();
      final uri = Uri.parse(current);
      final cleanQuery = Map<String, String>.from(uri.queryParameters)
        ..remove('ssoCode')
        ..remove('ssoError');
      final returnUrl = uri
          .replace(queryParameters: cleanQuery.isEmpty ? null : cleanQuery)
          .toString();
      final url = widget.api.lySsoStartUrl(returnUrl: returnUrl);
      if (kIsWeb) {
        redirectTo(url);
      } else {
        final uri = Uri.parse(url);
        await launchUrl(uri, mode: LaunchMode.inAppBrowserView);
      }
    } catch (exc) {
      setState(() => error = '无法启动统一身份认证：$exc');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _login() async {
    if (loading) return;
    if (!agreedToTerms) {
      setState(() => error = '请先阅读并同意《用户服务协议》和《隐私政策》');
      return;
    }
    final account = accountController.text.trim();
    final password = passwordController.text;
    if (account.isEmpty) {
      setState(() => error = '请输入学号');
      return;
    }
    if (password.isEmpty) {
      setState(() => error = '请输入密码');
      return;
    }
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final result = await widget.api.autoLogin(
        account,
        password,
      );
      TextInput.finishAutofillContext(shouldSave: false);
      if (rememberPassword) {
        await widget.api.rememberAccount(account);
        if (result.credentialToken != null) {
          await widget.api.saveCredentialToken(result.credentialToken);
        } else {
          await widget.api.clearSavedCredentialToken();
        }
      } else {
        await widget.api.forgetRememberedAccount();
        await widget.api.clearSavedCredentialToken();
      }
      unawaited(_saveAgreementState());
      widget.onLoggedIn(LoginResult(
        status: result.status,
        sessionId: result.sessionId,
        studentName: result.studentName,
        studentId: result.studentId,
        loginMethod: 'password',
        credentialToken: result.credentialToken,
        ehallCookies: result.ehallCookies,
        ehallAuthToken: result.ehallAuthToken,
      ));
    } on ApiException catch (exc) {
      setState(() => error = exc.message);
    } catch (exc) {
      setState(() => error = '无法连接服务器，请检查网络或确认服务已启动');
    } finally {
      setState(() => loading = false);
    }
  }

  void _showAgreement(
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
            Padding(
              padding: const EdgeInsets.symmetric(vertical: GzusSpacing.m),
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: Theme.of(context)
                      .colorScheme
                      .onSurfaceVariant
                      .withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: GzusSpacing.xl),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(title, style: Theme.of(context).textTheme.titleLarge),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(sheetContext).pop(),
                  ),
                ],
              ),
            ),
            const Divider(),
            Expanded(
              child: _AgreementContent(
                type: type,
                scrollController: scrollController,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _submitFromKeyboard(String _) {
    if (!loading) _login();
  }
}

class _AgreementContent extends StatelessWidget {
  const _AgreementContent({
    required this.type,
    required this.scrollController,
  });

  final String type;
  final ScrollController scrollController;

  static const _termsOfServiceText = '''
软帮手 用户服务协议（摘要）

重要提示：请在使用本应用前仔细阅读。使用即视为同意本协议。

一、服务说明
软帮手（OneGZUS）是一个学生自发开发的开源工具，仅供学习交流使用，聚合展示学校教务系统中的课表、成绩、考勤、水电费、通知、考试安排等数据。本应用非学校官方产品，所有数据以学校系统为准。

二、用户账号
请使用学校统一身份认证学号和密码登录，妥善保管登录凭证，不得出借账号。

三、用户行为
仅限个人学习和生活管理使用。不得逆向工程、数据抓取、商业盈利或传播他人教务信息。

四、知识产权
源代码依据 MIT 许可证开源。应用名称、Logo、界面设计归开发者团队所有。教务数据原始权属归学校教务系统。

五、免责声明
本软件为开源软件，依据 MIT 许可证按"原样"提供，不作任何明示或暗示的保证。数据以学校官方系统为准，因学校系统故障或接口变更导致的问题我们不承担责任。

六、协议修改与法律适用
我们有权修改本协议，重大修改将弹窗通知。适用中华人民共和国法律。

（完整版本请查看应用内文档或项目仓库 docs/terms-of-service.md）
''';

  static const _privacyPolicyText = '''
软帮手 隐私政策（摘要）

我们重视您的隐私。本政策说明我们如何收集、使用和保护您的信息。

一、信息收集
我们仅收集完成教务查询功能所必需的信息：学号与密码（仅用于统一身份认证）、课表、成绩、考勤、水电费余额、校园通知、请假记录、一卡通消费记录。同时收集设备型号和操作系统版本用于适配优化，IP地址仅用于服务端安全防护。

二、信息使用
信息仅用于展示课表、成绩、考勤、水电费等校内教务服务，遵循最小必要原则。

三、信息存储
密码不会以明文持久化存储。用户选择“记住学号并自动登录”后，前端安全存储会保存限时加密的自动登录凭据；学校系统Cookie保存在限时服务端会话和前端系统安全存储中，并在退出登录时清除。服务端不保存可还原的账号密码。

四、信息安全
所有通信使用HTTPS/TLS加密。日志不输出密码、Cookie等敏感信息。每位用户只能访问自己的教务数据。

五、第三方SDK
本应用集成了Bugly（腾讯崩溃监控）和Shiply（腾讯热更新与配置下发），仅收集设备型号、系统版本、崩溃日志等设备层面信息。

六、您的权利
您有权查看、更正、删除数据，可随时退出登录或卸载应用。退出登录后所有本地存储数据将被清除。

七、免责声明
本项目为学生开源项目，仅供学习交流使用，非学校官方产品。数据以学校系统为准。

（完整版本请查看应用内文档或项目仓库 docs/privacy-policy.md）
''';

  @override
  Widget build(BuildContext context) {
    final content = type == 'terms' ? _termsOfServiceText : _privacyPolicyText;

    return SingleChildScrollView(
      controller: scrollController,
      padding: const EdgeInsets.fromLTRB(
          GzusSpacing.xl, GzusSpacing.s, GzusSpacing.xl, GzusSpacing.xxl),
      child: DefaultTextStyle(
        style: Theme.of(context).textTheme.bodyMedium!.copyWith(height: 1.8),
        child: Text(content),
      ),
    );
  }
}

// 登录页自身的移动端宽度阈值（与 shell 的 _mobileBreakpoint 同值，但分属不同
// library，避免跨文件私有符号耦合；后续可统一迁到 responsive/breakpoints.dart）。
const _mobileBreakpoint = 720.0;
