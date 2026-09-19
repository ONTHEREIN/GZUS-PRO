import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../api_client.dart';
import '../../app_logger.dart';
import '../../gzus_design.dart';
import '../../responsive/spacing.dart';
import '../../shiply_image.dart';
import '../../shiply_platform.dart';
import '../../test_flags.dart';
import '../../widgets/icon_label.dart';
import '../../widgets/liquid_glass.dart';

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
  static const _casPasswordRecoveryUrl =
      'https://cas.gzus.edu.cn/aqzx/#/password/passwordFound';
  static const _casFreshmanPasswordChangeUrl =
      'https://cas.gzus.edu.cn/lyuapServer/login';

  final accountController = TextEditingController();
  final passwordController = TextEditingController();
  final passwordFocusNode = FocusNode();
  final _carouselController = PageController();
  bool loading = false;
  bool rememberPassword = true;
  bool agreedToTerms = false;
  bool passwordVisible = false;
  String? error;
  String? passwordChangeUrl;
  String _appVersion = '';
  String _appBuild = '';
  int _carouselIndex = 0;
  int _carouselSlideCount = 0;
  Timer? _carouselTimer;
  late final Future<List<LoginCarouselSlide>> _carouselSlidesFuture;

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
    _carouselSlidesFuture = widget.api.loginCarouselSlides();
    _appearController.forward();
  }

  Future<void> _loadSavedLoginForm() async {
    final prefs = await SharedPreferences.getInstance();
    final remember = prefs.getBool('auth.rememberPassword') ?? true;
    final account = prefs.getString('auth.account') ?? '';
    final String? rememberedPassword;
    if (remember) {
      rememberedPassword = await widget.api.loadRememberedPassword();
    } else {
      await widget.api.clearRememberedPassword();
      rememberedPassword = null;
    }
    await prefs.remove('auth.password');
    if (!mounted) return;
    setState(() {
      rememberPassword = remember;
      accountController.text = account;
      passwordController.text = rememberedPassword ?? '';
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
    _carouselTimer?.cancel();
    _carouselController.dispose();
    accountController.dispose();
    passwordController.dispose();
    passwordFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _buildRedesignedLogin(context);

  Widget buildLegacyLogin(BuildContext context) {
    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            child: LiquidGlassAmbientBackdrop(
              seedColor: Theme.of(context).colorScheme.primary,
              background: null,
            ),
          ),
          LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < _mobileBreakpoint;
              return SafeArea(
                child: SingleChildScrollView(
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
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
                          child: LiquidGlassSurface(
                            padding: EdgeInsets.all(compact ? 22 : 30),
                            borderRadius: BorderRadius.circular(GzusRadii.xl),
                            material: LiquidGlassMaterial.regular,
                            semanticsLabel: '登录卡片',
                            child: AutofillGroup(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
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
                                          borderRadius:
                                              BorderRadius.circular(12),
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
                                            const SizedBox(
                                                width: GzusSpacing.s),
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
                                  InkWell(
                                    borderRadius:
                                        BorderRadius.circular(GzusRadii.sm),
                                    onTap: loading
                                        ? null
                                        : () => setState(() =>
                                            rememberPassword =
                                                !rememberPassword),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                          vertical: 4),
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
                                          const Text('记住密码并自动登录'),
                                        ],
                                      ),
                                    ),
                                  ),
                                  InkWell(
                                    borderRadius:
                                        BorderRadius.circular(GzusRadii.sm),
                                    onTap: loading
                                        ? null
                                        : () => setState(() =>
                                            agreedToTerms = !agreedToTerms),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                          vertical: 4),
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
                                                  const TextSpan(
                                                      text: '我已阅读并同意'),
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
                                          : _login,
                                      child: IconLabel(
                                        icon: Icons.login,
                                        label: loading ? '登录中...' : '账号密码登录',
                                        centered: true,
                                      ),
                                    ),
                                  ),
                                  _buildAccountHelpLinks(context),
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
                                        padding:
                                            const EdgeInsets.all(GzusSpacing.l),
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(Icons.error_outline,
                                                size: 48,
                                                color: Theme.of(context)
                                                    .colorScheme
                                                    .onErrorContainer),
                                            const SizedBox(
                                                height: GzusSpacing.m),
                                            Text(error!,
                                                textAlign: TextAlign.center,
                                                style: TextStyle(
                                                    color: Theme.of(context)
                                                        .colorScheme
                                                        .onErrorContainer)),
                                            if (passwordChangeUrl != null) ...[
                                              const SizedBox(
                                                  height: GzusSpacing.s),
                                              TextButton.icon(
                                                onPressed: loading
                                                    ? null
                                                    : _openPasswordChangePage,
                                                icon: const Icon(
                                                    Icons.open_in_new),
                                                label: const Text('去学校修改密码'),
                                              ),
                                            ],
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
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildRedesignedLogin(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBody: true,
      body: Stack(
        key: const ValueKey('login-background-stack'),
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    scheme.primary.withValues(alpha: dark ? 0.26 : 0.12),
                    Theme.of(context).scaffoldBackgroundColor,
                    scheme.tertiary.withValues(alpha: dark ? 0.18 : 0.08),
                  ],
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: LiquidGlassAmbientBackdrop(
              seedColor: Theme.of(context).colorScheme.primary,
              background: null,
            ),
          ),
          LayoutBuilder(
            builder: (context, constraints) {
              final split = constraints.maxWidth >= _splitLoginBreakpoint;
              final compact = constraints.maxWidth < _mobileBreakpoint;
              final mobileCarouselHeight = MediaQuery.textScalerOf(context)
                  .scale(164)
                  .clamp(164.0, 240.0)
                  .toDouble();
              final form = LiquidGlassSurface(
                padding: EdgeInsets.all(compact ? 22 : 30),
                borderRadius: BorderRadius.circular(GzusRadii.xl),
                material: LiquidGlassMaterial.regular,
                semanticsLabel: '登录表单',
                child: _buildLoginForm(context, compact),
              );
              return SafeArea(
                child: SingleChildScrollView(
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
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
                          constraints: BoxConstraints(
                            maxWidth: split ? 1160 : 480,
                          ),
                          child: split
                              ? SizedBox(
                                  key: const ValueKey('login-split-layout'),
                                  height: 620,
                                  child: Row(
                                    children: [
                                      Expanded(
                                        flex: 13,
                                        child: _buildCarousel(
                                          context,
                                          compact: false,
                                        ),
                                      ),
                                      const SizedBox(width: GzusSpacing.l),
                                      SizedBox(width: 410, child: form),
                                    ],
                                  ),
                                )
                              : Column(
                                  key: const ValueKey('login-stacked-layout'),
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    SizedBox(
                                      height:
                                          compact ? mobileCarouselHeight : 196,
                                      child: _buildCarousel(
                                        context,
                                        compact: true,
                                      ),
                                    ),
                                    const SizedBox(height: GzusSpacing.l),
                                    form,
                                  ],
                                ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildCarousel(BuildContext context, {required bool compact}) {
    return ClipRRect(
      key: const ValueKey('login-carousel'),
      borderRadius: BorderRadius.circular(GzusRadii.xl),
      child: FutureBuilder<List<LoginCarouselSlide>>(
        future: _carouselSlidesFuture,
        builder: (context, snapshot) {
          final slides = snapshot.data ?? const <LoginCarouselSlide>[];
          _configureCarousel(slides.length);
          if (snapshot.hasError) {
            return shiplyPublicContentSupported
                ? _buildCarouselUnavailable(context, compact)
                : _buildCarouselFallback(context, compact);
          }
          if (slides.isEmpty) {
            return _buildCarouselFallback(context, compact);
          }
          return Stack(
            fit: StackFit.expand,
            children: [
              PageView.builder(
                controller: _carouselController,
                itemCount: slides.length,
                onPageChanged: (index) =>
                    setState(() => _carouselIndex = index),
                itemBuilder: (context, index) => _buildSlide(
                  context,
                  slide: slides[index],
                  compact: compact,
                ),
              ),
              Positioned(
                right: compact ? 14 : 22,
                bottom: compact ? 12 : 20,
                child: Row(
                  children: [
                    for (var index = 0; index < slides.length; index++)
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 180),
                        width: index == _carouselIndex ? 18 : 6,
                        height: 6,
                        margin: const EdgeInsets.only(left: 6),
                        decoration: BoxDecoration(
                          color: index == _carouselIndex
                              ? Colors.white
                              : Colors.white.withValues(alpha: 0.48),
                          borderRadius: BorderRadius.circular(99),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildSlide(
    BuildContext context, {
    required LoginCarouselSlide slide,
    required bool compact,
  }) {
    final primary = Theme.of(context).colorScheme.primary;
    return Stack(
      fit: StackFit.expand,
      children: [
        Image(
          image: slide.localImagePath == null
              ? NetworkImage(widget.api.resolveMediaUrl(slide.imageUrl))
              : shiplyLocalImageProvider(slide.localImagePath!),
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => ColoredBox(color: primary),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.black.withValues(alpha: 0.05),
                Colors.black.withValues(alpha: 0.72),
              ],
            ),
          ),
        ),
        Positioned(
          left: compact ? 18 : 36,
          right: compact ? 18 : 36,
          bottom: compact ? 28 : 46,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                slide.title,
                maxLines: compact ? 1 : 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      color: Colors.white,
                      fontSize: compact ? 19 : 29,
                    ),
              ),
              if (slide.description case final description?) ...[
                const SizedBox(height: GzusSpacing.xs),
                Text(
                  description,
                  maxLines: compact ? 2 : 3,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Colors.white.withValues(alpha: 0.88),
                      ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildCarouselFallback(BuildContext context, bool compact) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      key: const ValueKey('login-carousel-fallback'),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [scheme.primary, scheme.primaryContainer],
        ),
      ),
      child: Padding(
        padding: EdgeInsets.all(compact ? 18 : 36),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.asset('assets/icon.png', width: 38, height: 38),
                ),
                const SizedBox(width: GzusSpacing.s),
                Text(
                  '软帮手',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: Colors.white,
                      ),
                ),
              ],
            ),
            const SizedBox(height: GzusSpacing.m),
            Text(
              '让校园信息，更有条理。',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    color: Colors.white,
                    fontSize: compact ? 20 : 30,
                  ),
            ),
            const SizedBox(height: GzusSpacing.xs),
            Text(
              hideEcardOnCurrentPlatform
                  ? '课表、考勤、成绩与通知，一处查看。'
                  : '课表、考勤、成绩、通知与生活缴费，一处查看。',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Colors.white.withValues(alpha: 0.86),
                  ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCarouselUnavailable(BuildContext context, bool compact) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      key: const ValueKey('login-carousel-unavailable'),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [scheme.surfaceContainerHighest, scheme.surface],
        ),
      ),
      child: Padding(
        padding: EdgeInsets.all(compact ? 18 : 36),
        child: const Align(
          alignment: Alignment.bottomLeft,
          child: Text('公共资源暂不可用，请稍后重试'),
        ),
      ),
    );
  }

  Widget _buildLoginForm(BuildContext context, bool compact) {
    final scheme = Theme.of(context).colorScheme;
    return AutofillGroup(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.asset('assets/icon.png', width: 42, height: 42),
              ),
              const SizedBox(width: GzusSpacing.s),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('软帮手', style: Theme.of(context).textTheme.titleMedium),
                    Text('广州软件学院教务助手',
                        style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: GzusSpacing.l),
          Text('登录账户', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: GzusSpacing.xs),
          Text(
            '使用学校统一身份认证账号与密码登录。',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
          ),
          const SizedBox(height: GzusSpacing.l),
          TextField(
            controller: accountController,
            decoration: const InputDecoration(
              labelText: '学号',
              hintText: '请输入学号',
              prefixIcon: Icon(Icons.person_outline),
            ),
            autofillHints: const [AutofillHints.username, AutofillHints.email],
            textInputAction: TextInputAction.next,
            onSubmitted: (_) => passwordFocusNode.requestFocus(),
          ),
          const SizedBox(height: GzusSpacing.m),
          TextField(
            controller: passwordController,
            focusNode: passwordFocusNode,
            decoration: InputDecoration(
              labelText: '教务系统密码',
              hintText: '请输入密码',
              prefixIcon: const Icon(Icons.lock_outline),
              suffixIcon: IconButton(
                key: const ValueKey('login-password-visibility'),
                tooltip: passwordVisible ? '隐藏密码' : '显示密码',
                onPressed: () =>
                    setState(() => passwordVisible = !passwordVisible),
                icon: Icon(passwordVisible
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined),
              ),
            ),
            obscureText: !passwordVisible,
            autofillHints: const [AutofillHints.password],
            textInputAction: TextInputAction.done,
            onSubmitted: _submitFromKeyboard,
          ),
          InkWell(
            borderRadius: BorderRadius.circular(GzusRadii.sm),
            onTap: loading
                ? null
                : () => setState(() => rememberPassword = !rememberPassword),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Checkbox(
                    value: rememberPassword,
                    onChanged: loading
                        ? null
                        : (value) =>
                            setState(() => rememberPassword = value ?? true),
                  ),
                  const Expanded(child: Text('记住密码并自动登录')),
                ],
              ),
            ),
          ),
          InkWell(
            borderRadius: BorderRadius.circular(GzusRadii.sm),
            onTap: loading
                ? null
                : () => setState(() => agreedToTerms = !agreedToTerms),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Checkbox(
                    value: agreedToTerms,
                    onChanged: loading
                        ? null
                        : (value) =>
                            setState(() => agreedToTerms = value ?? false),
                  ),
                  Expanded(child: _buildAgreementText(context)),
                ],
              ),
            ),
          ),
          SizedBox(height: compact ? 16 : 18),
          SizedBox(
            height: compact ? 56 : 60,
            child: FilledButton(
              onPressed: loading || !agreedToTerms ? null : _login,
              child: IconLabel(
                icon: Icons.login,
                label: loading ? '登录中...' : '账号密码登录',
                centered: true,
              ),
            ),
          ),
          _buildAccountHelpLinks(context),
          if (error != null) ...[
            const SizedBox(height: GzusSpacing.m),
            Semantics(
              liveRegion: true,
              child: Container(
                padding: const EdgeInsets.all(GzusSpacing.m),
                decoration: BoxDecoration(
                  color: scheme.errorContainer,
                  borderRadius: BorderRadius.circular(GzusRadii.md),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      error!,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: scheme.onErrorContainer),
                    ),
                    if (passwordChangeUrl != null) ...[
                      const SizedBox(height: GzusSpacing.xs),
                      TextButton.icon(
                        onPressed: loading ? null : _openPasswordChangePage,
                        icon: const Icon(Icons.open_in_new),
                        label: const Text('去学校修改密码'),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
          if (_appVersion.isNotEmpty) ...[
            const SizedBox(height: GzusSpacing.l),
            Center(
              child: Text(
                'v$_appVersion (build $_appBuild)',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant.withValues(alpha: 0.45),
                    ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildAccountHelpLinks(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: GzusSpacing.xs),
      child: Column(
        children: [
          Text(
            '新生首次登录请先在学校官网登录并修改默认密码。',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
          ),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: GzusSpacing.xs,
            children: [
              TextButton.icon(
                key: const ValueKey('login-forgot-password'),
                onPressed: loading ? null : _openPasswordRecoveryPage,
                icon: const Icon(Icons.help_outline, size: 18),
                label: const Text('忘记密码'),
              ),
              TextButton.icon(
                key: const ValueKey('login-freshman-password-change'),
                onPressed: loading ? null : _openFreshmanPasswordChangePage,
                icon: const Icon(Icons.lock_reset, size: 18),
                label: const Text('新生修改默认密码'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildAgreementText(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurface,
        );
    final linkStyle = TextStyle(
      color: Theme.of(context).colorScheme.primary,
      decoration: TextDecoration.underline,
    );
    return RichText(
      text: TextSpan(
        style: style,
        children: [
          const TextSpan(text: '我已阅读并同意'),
          TextSpan(
            text: '《用户服务协议》',
            style: linkStyle,
            recognizer: TapGestureRecognizer()
              ..onTap = () => _showAgreement(
                    context,
                    title: '用户服务协议',
                    type: 'terms',
                  ),
          ),
          const TextSpan(text: ' 和 '),
          TextSpan(
            text: '《隐私政策》',
            style: linkStyle,
            recognizer: TapGestureRecognizer()
              ..onTap = () => _showAgreement(
                    context,
                    title: '隐私政策',
                    type: 'privacy',
                  ),
          ),
        ],
      ),
    );
  }

  void _configureCarousel(int slideCount) {
    if (_carouselSlideCount == slideCount) return;
    _carouselSlideCount = slideCount;
    _carouselIndex = 0;
    _carouselTimer?.cancel();
    if (slideCount < 2) return;
    _carouselTimer = Timer.periodic(const Duration(seconds: 6), (_) {
      if (!mounted || !_carouselController.hasClients) return;
      final nextIndex = (_carouselIndex + 1) % slideCount;
      _carouselController.animateToPage(
        nextIndex,
        duration: const Duration(milliseconds: 420),
        curve: Curves.easeOutCubic,
      );
    });
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
      passwordChangeUrl = null;
    });
    try {
      final result = await widget.api.autoLogin(
        account,
        password,
      );
      TextInput.finishAutofillContext(shouldSave: false);
      // 服务端登录已经成功，本地凭据持久化失败不能把成功误报成网络失败。
      // 例如浏览器禁用 WebCrypto 或本地存储空间异常时，仍应允许用户进入应用。
      Object? localStorageError;
      StackTrace? localStorageStackTrace;
      try {
        if (rememberPassword) {
          await widget.api.rememberAccount(account);
          await widget.api.saveRememberedPassword(password);
          if (result.credentialToken != null) {
            await widget.api.saveCredentialToken(result.credentialToken);
          } else {
            await widget.api.clearSavedCredentialToken();
          }
        } else {
          await widget.api.forgetRememberedAccount();
          await widget.api.clearSavedCredentialToken();
        }
      } catch (exception, stackTrace) {
        localStorageError = exception;
        localStorageStackTrace = stackTrace;
      }
      if (localStorageError != null) {
        AppLogger.error(
          '登录成功但本地登录信息保存失败',
          localStorageError,
          localStorageStackTrace!,
        );
      }
      unawaited(_saveAgreementState());
      widget.onLoggedIn(LoginResult(
        status: result.status,
        sessionId: result.sessionId,
        studentName: result.studentName,
        studentId: result.studentId,
        credentialToken: result.credentialToken,
        ehallCookies: result.ehallCookies,
        ehallAuthToken: result.ehallAuthToken,
      ));
      if (localStorageError != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('登录成功，但本地记住登录信息失败，下次需重新输入密码')),
        );
      }
    } on ApiException catch (exc) {
      if (!mounted) return;
      setState(() {
        error = exc.message;
        passwordChangeUrl =
            exc.code == 'password_change_required' ? exc.actionUrl : null;
      });
    } catch (_) {
      if (mounted) {
        setState(() => error = '无法连接服务器，请检查网络或确认服务已启动');
      }
    } finally {
      if (mounted) {
        setState(() => loading = false);
      }
    }
  }

  Future<void> _openPasswordChangePage() async {
    final url = passwordChangeUrl;
    if (url == null || url.isEmpty) {
      throw StateError('学校改密链接为空');
    }
    await _openExternalSchoolPage(
      url: url,
      failureMessage: '无法打开学校统一认证安全中心',
    );
  }

  Future<void> _openPasswordRecoveryPage() async {
    await _openExternalSchoolPage(
      url: _casPasswordRecoveryUrl,
      failureMessage: '无法打开学校统一认证找回密码页面',
    );
  }

  Future<void> _openFreshmanPasswordChangePage() async {
    await _openExternalSchoolPage(
      url: _casFreshmanPasswordChangeUrl,
      failureMessage: '无法打开学校统一认证官网登录页面',
    );
  }

  Future<void> _openExternalSchoolPage({
    required String url,
    required String failureMessage,
  }) async {
    final opened = await launchUrl(
      Uri.parse(url),
      mode: LaunchMode.externalApplication,
    );
    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(failureMessage)),
      );
    }
  }

  void _showAgreement(
    BuildContext context, {
    required String title,
    required String type,
  }) {
    showLiquidGlassModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => DraggableScrollableSheet(
        initialChildSize: 0.85,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        expand: false,
        builder: (_, scrollController) => LiquidGlassSurface(
          padding: EdgeInsets.zero,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          material: LiquidGlassMaterial.regular,
          semanticsLabel: title,
          child: Column(
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
密码不会以明文持久化存储。用户选择“记住密码并自动登录”后，密码和自动登录凭据保存在本设备系统安全存储区，用于下次填充和恢复登录；学校系统 Cookie 和认证令牌会在本机安全存储，并由服务端加密保存账号级学校会话。用户主动开启“后台持续通知”后，服务端还会保存加密的自动登录凭据和提醒配置；关闭该功能即可撤销并删除后台授权。

四、信息安全与权限
所有生产通信使用HTTPS/TLS加密。日志不输出密码、Cookie等敏感信息。每位用户只能访问自己的教务数据。通知、定位、相册/相机、日历等权限仅在对应功能需要时申请，可在系统设置中关闭。

五、第三方服务
本应用可能使用腾讯Shiply/ResHub、浏览器 Push、Apple APNs 和 wttr.in。天气功能只在授权后使用近似位置；推送服务只用于投递提醒。

六、您的权利
您可以关闭记住密码、后台持续通知、通知和定位权限。退出登录会清除本机认证材料、账号缓存、推送注册并撤销当前应用会话；若已开启后台持续通知，请在通知设置中关闭以同时撤销服务端后台授权。需要查询或删除服务端反馈、缓存等数据时，请通过项目 GitHub Issues 联系维护者。

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
const _splitLoginBreakpoint = 960.0;
