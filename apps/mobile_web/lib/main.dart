import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart' as path_provider;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:share_plus/share_plus.dart';
import 'api_client.dart';
import 'gzus_design.dart';
import 'services_deferred.dart';

import 'background_guide_page.dart';
import 'browser_redirect.dart';
import 'live_activity_service.dart';
import 'ftp_upload_service.dart';
import 'leave_attachment.dart';

import 'persistent_cache.dart' deferred as persistent_cache;
import 'ws_service.dart' deferred as ws_service;
import 'mobile_sso.dart' deferred as mobile_sso;
import 'permission_service.dart' deferred as permission_service;
import 'location_service.dart' deferred as location_service;
import 'avatar_open.dart' deferred as avatar_open;
import 'background_service.dart' deferred as background_service;
import 'reminder_service.dart' deferred as reminder_service;
import 'ics_download.dart' deferred as ics_download;
import 'local_notification_service.dart' deferred as local_notification_service;
import 'live_update_service.dart' deferred as live_update_service;
import 'update_service.dart' deferred as update_service;
import 'web_pwa_cache.dart' deferred as web_pwa_cache;
import 'push_service.dart' deferred as push_service;
import 'web_push_service.dart' deferred as web_push_service;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.dark,
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarDividerColor: Colors.transparent,
    systemNavigationBarIconBrightness: Brightness.dark,
  ));

  runApp(const OneGzusApp());

  unawaited(_initDeferredServices());
}

Future<void> _initDeferredServices() async {
  try {
    await DeferredServices().initialize();
  } catch (_) {}
}

ThemeData _appTheme(Brightness brightness, {Color seedColor = GzusColors.blue}) {
  return gzusTheme(brightness, navBarHeight: _mobileNavBarHeight, seedColor: seedColor);
}

class OneGzusApp extends StatefulWidget {
  const OneGzusApp({super.key});

  @override
  State<OneGzusApp> createState() => _OneGzusAppState();
}

class _OneGzusAppState extends State<OneGzusApp> with WidgetsBindingObserver {
  final api = ApiClient();
  final _navigatorKey = GlobalKey<NavigatorState>();
  ThemeMode themeMode = ThemeMode.system;
  Color seedColor = GzusColors.blue;
  bool _systemDark = false;
  bool loggedIn = false;
  bool initializing = true;
  String? studentName;
  String? loginError;
  bool _backgroundGuideCompleted = false;
  DataSourceInfo _globalDataSource = const DataSourceInfo();
  bool get isOfflineMode => _globalDataSource.isStale;

  /// 登录方式: "password" = 教务系统账密登录, "sso" = 办事大厅一键登录, null = 未登录
  String? loginMethod;

  /// 防止 _logout() 被并发调用
  bool _logoutInProgress = false;

  /// 最近一次登录成功的时间，用于防止登录后立即因瞬态 401 被踢出
  DateTime? _lastLoginAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _systemDark =
        WidgetsBinding.instance.platformDispatcher.platformBrightness ==
            Brightness.dark;
    // 当 relogin 失败时（credential token 已失效），触发 logout
    // 添加 5 秒冷却期，防止登录后立即因 Vercel/Neon 瞬态错误被踢出
    api.onReloginFailed = () {
      if (!loggedIn) return;
      final now = DateTime.now();
      if (_lastLoginAt != null &&
          now.difference(_lastLoginAt!) < const Duration(seconds: 5)) {
        debugPrint(
            'Ignoring relogin failure within 5s of login (transient)');
        return;
      }
      _logout();
    };
    _loadThemePreference();
    _loadSeedColorPreference();
    api.startWarmup();
    _bootstrapLoginState();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  bool _hasBeenResumed = false;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    debugPrint(
        '[AppLifecycle] state changed to: $state, loggedIn: $loggedIn, _hasBeenResumed: $_hasBeenResumed');
    if (!loggedIn) return;
    if (state == AppLifecycleState.resumed) {
      _hasBeenResumed = true;
      debugPrint(
          '[AppLifecycle] Resuming - calling WsService.resume() and setAppForeground(true)');
      unawaited(_handleAppResume());
      // 仅在推送体验引导完成后才拉取离线消息，避免引导页触发不必要的 /push/poll 请求
      if (_backgroundGuideCompleted) {
        unawaited(_drainPendingPushMessages());
      }
    } else if (_hasBeenResumed &&
        (state == AppLifecycleState.paused ||
            state == AppLifecycleState.inactive ||
            state == AppLifecycleState.hidden ||
            state == AppLifecycleState.detached)) {
      debugPrint(
          '[AppLifecycle] Pausing - calling WsService.pause() and setAppForeground(false)');
      unawaited(_handleAppPause());
    }
  }

  Future<void> _handleAppResume() async {
    try {
      await push_service.loadLibrary();
      push_service.PushService.resume();
    } catch (_) {}
    try {
      await ws_service.loadLibrary();
      ws_service.WsService.resume();
    } catch (_) {}
    try {
      await background_service.loadLibrary();
      await background_service.BackgroundService.setAppForeground(true);
    } catch (_) {}
  }

  Future<void> _handleAppPause() async {
    try {
      await ws_service.loadLibrary();
      ws_service.WsService.pause();
    } catch (_) {}
    try {
      await background_service.loadLibrary();
      await background_service.BackgroundService.setAppForeground(false);
    } catch (_) {}
  }

  @override
  void didChangePlatformBrightness() {
    final dark =
        WidgetsBinding.instance.platformDispatcher.platformBrightness ==
            Brightness.dark;
    if (dark != _systemDark) {
      setState(() => _systemDark = dark);
      _updateSystemUIOverlayStyle();
    }
  }

  Future<void> _loadThemePreference() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('theme.mode');
    if (saved != null) {
      final mode = ThemeMode.values.firstWhere(
        (m) => m.name == saved,
        orElse: () => ThemeMode.system,
      );
      if (mounted && mode != themeMode) {
        setState(() => themeMode = mode);
      }
    }
    _updateSystemUIOverlayStyle();
  }

  Future<void> _setThemeMode(ThemeMode mode) async {
    setState(() => themeMode = mode);
    _updateSystemUIOverlayStyle();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('theme.mode', mode.name);
  }

  Future<void> _loadSeedColorPreference() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('theme.seedColor');
    if (saved != null) {
      final color = _colorFromHex(saved);
      if (color != null && mounted && color != seedColor) {
        setState(() => seedColor = color);
      }
    }
  }

  Future<void> _setSeedColor(Color color) async {
    setState(() => seedColor = color);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('theme.seedColor', _colorToHex(color));
  }

  static Color? _colorFromHex(String hex) {
    final buffer = StringBuffer();
    if (hex.length == 6) buffer.write('FF');
    buffer.write(hex.toUpperCase());
    final value = int.tryParse(buffer.toString(), radix: 16);
    if (value == null) return null;
    return Color(value);
  }

  static String _colorToHex(Color color) {
    return '${(color.r * 255.0).round().clamp(0, 255).toRadixString(16).padLeft(2, '0')}${(color.g * 255.0).round().clamp(0, 255).toRadixString(16).padLeft(2, '0')}${(color.b * 255.0).round().clamp(0, 255).toRadixString(16).padLeft(2, '0')}'.toUpperCase();
  }

  /// 根据当前主题模式更新系统状态栏/导航栏图标颜色
  void _updateSystemUIOverlayStyle() {
    final isDark = themeMode == ThemeMode.dark ||
        (themeMode == ThemeMode.system && _systemDark);
    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarDividerColor: Colors.transparent,
      systemNavigationBarIconBrightness:
          isDark ? Brightness.light : Brightness.dark,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: _navigatorKey,
      title: 'OneGZUS',
      debugShowCheckedModeBanner: false,
      themeMode: themeMode,
      theme: _appTheme(Brightness.light, seedColor: seedColor),
      darkTheme: _appTheme(Brightness.dark, seedColor: seedColor),
      home: initializing
          ? const LoadingPage()
          : !loggedIn
              ? LoginPage(
                  api: api,
                  initialError: loginError,
                  onLoggedIn: (result) {
                    _finishLogin(result);
                  },
                )
              : !_backgroundGuideCompleted
                  ? BackgroundGuidePage(
                      api: api,
                      onComplete: () {
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          _navigatorKey.currentState?.pushNamedAndRemoveUntil(
                              '/dashboard', (route) => false);
                        });
                      })
                  : _buildDashboardShell(),
      routes: {
        '/dashboard': (context) {
          if (!loggedIn) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _navigatorKey.currentState?.pushNamedAndRemoveUntil(
                  '/', (route) => false);
            });
            return const LoadingPage();
          }
          return _buildDashboardShell();
        },
        '/background-guide': (context) {
          if (!loggedIn) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _navigatorKey.currentState?.pushNamedAndRemoveUntil(
                  '/', (route) => false);
            });
            return const LoadingPage();
          }
          return BackgroundGuidePage(api: api);
        },
      },
    );
  }

  Future<void> _bootstrapLoginState() async {
    final uri = Uri.base;
    final ssoError = uri.queryParameters['ssoError'];
    final ssoCode = uri.queryParameters['ssoCode'];
    if (ssoError != null && ssoError.isNotEmpty) {
      replaceBrowserUrl(_withoutSsoParams(uri).toString());
      if (!mounted) return;
      setState(() {
        initializing = false;
        loginError = ssoError;
      });
      return;
    }
    if (ssoCode != null && ssoCode.isNotEmpty) {
      await _completeSsoLogin(ssoCode, uri);
      return;
    }
    // 添加 5 秒超时保护，防止 API 响应慢导致 LoadingPage 永远卡住
    try {
      await _restoreSession().timeout(const Duration(seconds: 5));
    } on TimeoutException {
      debugPrint('Session restore timed out after 5 seconds, showing login page');
      if (mounted) {
        setState(() => initializing = false);
      }
    }
  }

  Future<void> _completeSsoLogin(String ssoCode, Uri uri) async {
    try {
      final result = await api.completeLySso(ssoCode);
      await _persistLogin(result);
      replaceBrowserUrl(_withoutSsoParams(uri).toString());
      if (!mounted) return;
      setState(() {
        initializing = false;
        loggedIn = true;
        studentName = result.studentName;
        loginError = null;
        _backgroundGuideCompleted = false;
        loginMethod = result.loginMethod ?? 'sso';
      });
      _initPushServices();
    } on ApiException catch (exc) {
      replaceBrowserUrl(_withoutSsoParams(uri).toString());
      await _clearSavedSession();
      if (!mounted) return;
      setState(() {
        initializing = false;
        loggedIn = false;
        loginError = exc.message;
      });
    }
  }

  Future<void> _restoreSession() async {
    final prefs = await SharedPreferences.getInstance();
    final savedSession = prefs.getString('auth.sessionId');
    if (savedSession == null || savedSession.isEmpty) {
      if (!mounted) return;
      setState(() => initializing = false);
      return;
    }
    api.useSession(savedSession);
    final savedStudentId = prefs.getString('auth.studentId');
    if (savedStudentId != null && savedStudentId.isNotEmpty) {
      api.setStudentId(savedStudentId);
    }
    // 恢复 ehall 凭证到 ApiClient
    final savedEhallCookies = prefs.getString('auth.ehallCookies');
    if (savedEhallCookies != null && savedEhallCookies.isNotEmpty) {
      api.setEhallCookies(savedEhallCookies);
    }
    final savedEhallAuthToken = prefs.getString('auth.ehallAuthToken');
    if (savedEhallAuthToken != null && savedEhallAuthToken.isNotEmpty) {
      api.setEhallAuthToken(savedEhallAuthToken);
    }

    await persistent_cache.loadLibrary();
    final pcache = persistent_cache.PersistentCache(namespace: api.namespace);
    await pcache.init();
    final cachedMe = pcache.getRaw('me');
    if (cachedMe != null && cachedMe is Map<String, dynamic>) {
      final guideCompleted =
          prefs.getBool('background_guide_completed') ?? false;
      if (!mounted) return;
      setState(() {
        initializing = false;
        loggedIn = true;
        studentName =
            prefs.getString('auth.studentName') ?? cachedMe['name'] as String?;
        _backgroundGuideCompleted = guideCompleted;
        _globalDataSource =
            const DataSourceInfo(fromLocalCache: true, isOffline: true);
        loginMethod = prefs.getString('auth.loginMethod');
      });
      _tryBackgroundRefresh(prefs);
      return;
    }

    try {
      final result = await api.me();
      final info = result.data;
      final guideCompleted =
          prefs.getBool('background_guide_completed') ?? false;
      if (!mounted) return;
      setState(() {
        initializing = false;
        loggedIn = true;
        studentName = prefs.getString('auth.studentName') ?? info.name;
        _backgroundGuideCompleted = guideCompleted;
        _globalDataSource = result.source;
        loginMethod = prefs.getString('auth.loginMethod');
      });

      final studentId = prefs.getString('auth.studentId') ?? info.studentId;
      if (studentId.isNotEmpty) {
        api.setStudentId(studentId);
      }

      _initPushServices();
      _checkForUpdate();
    } on ApiException {
      await _clearSavedSession();
      if (!mounted) return;
      setState(() {
        initializing = false;
        loggedIn = false;
      });
    } catch (_) {
      await _clearSavedSession();
      if (!mounted) return;
      setState(() {
        initializing = false;
        loggedIn = false;
      });
    }
  }

  Future<void> _tryBackgroundRefresh(SharedPreferences prefs) async {
    try {
      final result = await api.me();
      if (!mounted) return;
      setState(() {
        _globalDataSource = result.source;
        studentName = prefs.getString('auth.studentName') ?? result.data.name;
      });
      final studentId =
          prefs.getString('auth.studentId') ?? result.data.studentId;
      if (studentId.isNotEmpty) {
        api.setStudentId(studentId);
      }
      _initPushServices();
    } on ApiException {
      if (!mounted) return;
      setState(() {
        _globalDataSource =
            const DataSourceInfo(fromLocalCache: true, isOffline: true);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _globalDataSource =
            const DataSourceInfo(fromLocalCache: true, isOffline: true);
      });
    }
  }

  Future<void> _initPushServices() async {
    await LoginRequiredServices.initialize(
      apiBaseUrl: api.baseUrl,
      sessionId: api.sessionId ?? '',
      onNotificationTap: _handleNotificationTap,
    );
    unawaited(_registerPushIfNeeded());
    unawaited(_drainPendingPushMessages());
  }

  Future<void> _registerPushIfNeeded() async {
    try {
      final regId = await LoginRequiredServices.getPushRegistrationId();
      if (regId != null && regId.isNotEmpty) {
        await api.registerPush(regId);
      }
    } on ApiException {
      // WebSocket/native polling still cover notifications if JPush is absent.
    } catch (_) {}
  }

  void _handleNotificationTap(Map<String, dynamic> extras) {
    final url = extras['url']?.toString().trim();
    if (!mounted) return;
    final tab = _tabForNotificationType(extras['type']?.toString());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (url != null && url.isNotEmpty) {
        unawaited(_openAuthenticatedUrl(url));
        return;
      }
      if (tab != null) _NotificationOpenBridge.openTab(tab);
    });
  }

  Future<void> _openAuthenticatedUrl(String url) async {
    try {
      await mobile_sso.loadLibrary();
      await mobile_sso.openAuthenticatedEhallUrl(context, url);
    } catch (_) {}
  }

  Future<void> _drainPendingPushMessages() async {
    if (api.sessionId == null || api.sessionId!.isEmpty) return;
    try {
      final messages = await api.pollPushMessages();
      await ws_service.loadLibrary();
      for (final message in messages) {
        await ws_service.WsService.handleNotificationMessage(message);
      }
    } catch (_) {}
  }

  String? _tabForNotificationType(String? type) {
    switch (type) {
      case 'course_reminder':
        return 'schedule';
      case 'exam_reminder':
        return 'exams';
      case 'ecard_reminder':
        return 'ecard';
      case 'new_notice':
        return 'notices';
      default:
        return null;
    }
  }

  void _checkForUpdate() {
    if (!mounted) return;
    unawaited(_checkForUpdateDeferred());
  }

  Future<void> _checkForUpdateDeferred() async {
    try {
      await update_service.loadLibrary();
      update_service.UpdateService().checkForUpdateIfNeeded();
    } catch (_) {}
  }

  Future<void> _finishLogin(LoginResult result) async {
    await _persistLogin(result);
    if (!mounted) return;
    setState(() {
      loggedIn = true;
      studentName = result.studentName;
      loginError = null;
      _backgroundGuideCompleted = false;
      loginMethod = result.loginMethod;
    });

    // Fetch student info asynchronously (studentId, photo, etc.)
    // This was separated from the login flow to speed up login response time.
    unawaited(_fetchStudentInfoAfterLogin());

    _initPushServices();
    _checkForUpdate();
  }

  Future<void> _fetchStudentInfoAfterLogin() async {
    final info = await api.fetchStudentInfo();
    if (info == null || !mounted) return;
    final studentId = info.studentId;
    if (studentId.isNotEmpty) {
      api.setStudentId(studentId);
    }
  }

  Future<void> _persistLogin(LoginResult result) async {
    _lastLoginAt = DateTime.now();
    final prefs = await SharedPreferences.getInstance();
    if (result.sessionId != null) {
      api.useSession(result.sessionId);
      await prefs.setString('auth.sessionId', result.sessionId!);
    }
    if (result.studentName != null) {
      await prefs.setString('auth.studentName', result.studentName!);
    }
    if (result.studentId != null) {
      await prefs.setString('auth.studentId', result.studentId!);
    }
    if (result.loginMethod != null) {
      await prefs.setString('auth.loginMethod', result.loginMethod!);
    }
    if (result.ehallCookies != null && result.ehallCookies!.isNotEmpty) {
      await prefs.setString('auth.ehallCookies', result.ehallCookies!);
    } else {
      await prefs.remove('auth.ehallCookies');
    }
    if (result.ehallAuthToken != null && result.ehallAuthToken!.isNotEmpty) {
      await prefs.setString('auth.ehallAuthToken', result.ehallAuthToken!);
    } else {
      await prefs.remove('auth.ehallAuthToken');
    }
  }

  Future<void> _logout() async {
    if (_logoutInProgress || !loggedIn) return;
    _logoutInProgress = true;
    api.clearCredentials();
    LoginRequiredServices.disconnect();

    if (!mounted) {
      _logoutInProgress = false;
      return;
    }
    setState(() {
      loggedIn = false;
      studentName = null;
      _backgroundGuideCompleted = false;
      _globalDataSource = const DataSourceInfo();
      loginMethod = null;
      loginError = null;
    });
    _navigatorKey.currentState?.popUntil((route) => route.isFirst);

    unawaited(_performLogoutCleanup());
  }

  Future<void> _performLogoutCleanup() async {
    try {
      try {
        await api.unregisterPush();
      } catch (_) {}
      if (kIsWeb && (api.sessionId?.isNotEmpty ?? false)) {
        await LoginRequiredServices.unsubscribeWebPush(api.baseUrl, api.sessionId!);
      }
      try {
        await api.logout();
      } catch (_) {}

      api.useSession(null);

      try {
        final studentId = api.studentId;
        if (studentId != null && studentId.isNotEmpty) {
          await persistent_cache.loadLibrary();
          await persistent_cache.PersistentCache.clearForStudent(studentId);
        }

        await LoginRequiredServices.disableBackgroundService();
        LoginRequiredServices.cancelCourseReminders();
        await _clearSavedSession();
      } catch (_) {}
    } finally {
      _logoutInProgress = false;
    }
  }

  Future<void> _clearSavedSession() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('auth.sessionId');
    await prefs.remove('auth.studentName');
    await prefs.remove('auth.studentId');
    await prefs.remove('auth.ehallCookies');
    await prefs.remove('auth.ehallAuthToken');
    await prefs.remove('auth.loginMethod');
    await prefs.remove('auth.credentialToken');
    await prefs.remove('auth.account');
    await prefs.remove('auth.password');
    await prefs.remove('auth.rememberPassword');
    await prefs.remove('background_guide_completed');
    try {
      await web_pwa_cache.loadLibrary();
      web_pwa_cache.clearPwaApiCache();
    } catch (_) {}
    api.useSession(null);
  }

  DashboardShell _buildDashboardShell() {
    return DashboardShell(
      api: api,
      studentName: studentName,
      themeMode: themeMode,
      onThemeChanged: _setThemeMode,
      seedColor: seedColor,
      onSeedColorChanged: _setSeedColor,
      onLogout: () {
        if (loggedIn) _logout();
      },
      onSettingsPressed: _showBackgroundGuide,
      dataSource: _globalDataSource,
      loginMethod: loginMethod,
    );
  }

  void _showBackgroundGuide() {
    if (!mounted) return;
    _navigatorKey.currentState?.push(
      MaterialPageRoute(
        builder: (context) => BackgroundGuidePage(
          api: api,
          onComplete: () {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _navigatorKey.currentState?.pop();
            });
          },
        ),
      ),
    );
  }
}

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
                                    Container(
                                      width: compact ? 44 : 48,
                                      height: compact ? 44 : 48,
                                      decoration: BoxDecoration(
                                        color: _accentFill(context),
                                        borderRadius: BorderRadius.circular(14),
                                      ),
                                      child: Center(
                                        child: Text(
                                          '🎓',
                                          style: TextStyle(
                                            fontSize: compact ? 24 : 28,
                                          ),
                                        ),
                                      ),
                                    ),
                                    SizedBox(height: compact ? 18 : 22),
                                    Text(
                                      'OneGZUS',
                                      style: Theme.of(context)
                                          .textTheme
                                          .headlineMedium,
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      '推荐使用办事大厅统一登录',
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodyMedium
                                          ?.copyWith(
                                            color: Theme.of(context)
                                                .colorScheme
                                                .onSurfaceVariant,
                                          ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      '教务系统登录',
                                      style:
                                          Theme.of(context).textTheme.bodySmall,
                                    ),
                                    const SizedBox(height: 14),
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
                                          const SizedBox(width: 8),
                                          Expanded(
                                            child: Text(
                                              '登录后自动同步课表、考勤、成绩、通知与生活缴费',
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
                                SizedBox(height: compact ? 24 : 28),
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
                                const SizedBox(height: 12),
                                TextField(
                                  controller: passwordController,
                                  focusNode: passwordFocusNode,
                                  decoration: const InputDecoration(
                                    hintText: '密码',
                                    prefixIcon: Icon(Icons.lock),
                                  ),
                                  obscureText: true,
                                  autofillHints: const [AutofillHints.password],
                                  textInputAction: TextInputAction.done,
                                  onSubmitted: _submitFromKeyboard,
                                ),
                                InkWell(
                                  borderRadius:
                                      BorderRadius.circular(GzusRadii.sm),
                                  onTap: loading
                                      ? null
                                      : () => setState(() =>
                                          rememberPassword = !rememberPassword),
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
                                        const Text('记住学号'),
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
                                        : _login,
                                    child: _IconLabel(
                                      icon: Icons.login,
                                      label: loading ? '登录中...' : '办事大厅统一登录',
                                      centered: true,
                                    ),
                                  ),
                                ),
                                if (error != null) ...[
                                  const SizedBox(height: 16),
                                  Card(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .errorContainer,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: Padding(
                                      padding: const EdgeInsets.all(16),
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(Icons.error_outline,
                                              size: 48,
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .onErrorContainer),
                                          const SizedBox(height: 12),
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
                                  const SizedBox(height: 20),
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
                                                .withOpacity(0.45),
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
      // Save credential token for auto-relogin
      if (result.credentialToken != null) {
        await widget.api.saveCredentialToken(result.credentialToken);
      }
      await widget.api.savePasswordCredentials(
        account,
        password,
        remember: rememberPassword,
      );
      unawaited(_saveAgreementState());
      widget.onLoggedIn(LoginResult(
        status: result.status,
        sessionId: result.sessionId,
        studentName: result.studentName,
        studentId: result.studentId,
        loginMethod: 'sso',
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
              padding: const EdgeInsets.symmetric(vertical: 12),
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
              padding: const EdgeInsets.symmetric(horizontal: 24),
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
OneGZUS 用户服务协议（摘要）

重要提示：请在使用本应用前仔细阅读。使用即视为同意本协议。

一、服务说明
OneGZUS（软帮手）是一个学生自发开发的开源工具，仅供学习交流使用，聚合展示学校教务系统中的课表、成绩、考勤、水电费、通知、考试安排等数据。本应用非学校官方产品，所有数据以学校系统为准。

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
OneGZUS 隐私政策（摘要）

我们重视您的隐私。本政策说明我们如何收集、使用和保护您的信息。

一、信息收集
我们仅收集完成教务查询功能所必需的信息：学号与密码（仅用于统一身份认证）、课表、成绩、考勤、水电费余额、校园通知、请假记录、一卡通消费记录。同时收集设备型号和操作系统版本用于适配优化，IP地址仅用于服务端安全防护。

二、信息使用
信息仅用于展示课表、成绩、考勤、水电费等校内教务服务，遵循最小必要原则。

三、信息存储
密码不在任何位置持久化存储。学校系统Cookie仅保存在服务端内存中，会话关闭后自动清除。前端本地仅保存sessionId和展示用学生姓名，退出登录时清除。

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
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
      child: DefaultTextStyle(
        style: Theme.of(context).textTheme.bodyMedium!.copyWith(height: 1.8),
        child: Text(content),
      ),
    );
  }
}

const _mobileBreakpoint = 720.0;
const _compactNavBreakpoint = 1024.0;
const _mobileNavBarHeight = 80.0;
const _mobileMainNavLimit = 4;

class LoadingPage extends StatefulWidget {
  const LoadingPage({super.key});

  @override
  State<LoadingPage> createState() => _LoadingPageState();
}

class _LoadingPageState extends State<LoadingPage>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 600),
  );
  late final _fadeIn =
      CurvedAnimation(parent: _controller, curve: Curves.easeIn);

  @override
  void initState() {
    super.initState();
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: FadeTransition(
          opacity: _fadeIn,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Icons.school 被 tree-shaking 移除，替换为 emoji 避免白屏
              const Text('🎓', style: TextStyle(fontSize: 36)),
              const SizedBox(height: 14),
              const CircularProgressIndicator(),
            ],
          ),
        ),
      ),
    );
  }
}

Uri _withoutSsoParams(Uri uri) {
  final query = Map<String, String>.from(uri.queryParameters)
    ..remove('ssoCode')
    ..remove('ssoError');
  return uri.replace(queryParameters: query.isEmpty ? null : query);
}

class _SeedColorPicker extends StatelessWidget {
  const _SeedColorPicker({
    required this.selectedColor,
    required this.onColorSelected,
  });

  final Color selectedColor;
  final ValueChanged<Color> onColorSelected;

  static const _presets = <Color>[
    Color(0xFF2563EB), // 蓝色
    Color(0xFF059669), // 绿色
    Color(0xFF7C3AED), // 紫色
    Color(0xFFEA580C), // 橙色
    Color(0xFFDC2626), // 红色
    Color(0xFF0891B2), // 青色
  ];

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 16,
      runSpacing: 12,
      alignment: WrapAlignment.center,
      children: _presets.map((color) {
        final isSelected = color.toARGB32() == selectedColor.toARGB32();
        return GestureDetector(
          onTap: () => onColorSelected(color),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: isSelected
                  ? Border.all(
                      color: color,
                      width: 3,
                      strokeAlign: BorderSide.strokeAlignOutside,
                    )
                  : null,
              boxShadow: isSelected
                  ? [
                      BoxShadow(
                        color: color.withValues(alpha: 0.4),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ]
                  : null,
            ),
            child: isSelected
                ? const Icon(Icons.check, color: Colors.white, size: 20)
                : null,
          ),
        );
      }).toList(),
    );
  }
}

class DashboardShell extends StatefulWidget {
  const DashboardShell({
    super.key,
    required this.api,
    required this.studentName,
    required this.themeMode,
    required this.onThemeChanged,
    required this.onLogout,
    this.seedColor = GzusColors.blue,
    this.onSeedColorChanged,
    this.onSettingsPressed,
    this.dataSource = const DataSourceInfo(),
    this.loginMethod,
  });

  final ApiClient api;
  final String? studentName;
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeChanged;
  final Color seedColor;
  final ValueChanged<Color>? onSeedColorChanged;
  final VoidCallback onLogout;
  final VoidCallback? onSettingsPressed;
  final DataSourceInfo dataSource;

  /// 登录方式: "password" = 教务系统账密登录, "sso" = 办事大厅一键登录
  final String? loginMethod;

  /// 账密登录时无法使用的功能 tabId 列表（依赖办事大厅 ehall 会话）
  static const passwordRestrictedTabs = {
    'notices',
    'business',
    'applications',
    'leave',
  };

  bool get isPasswordLogin => loginMethod == 'password';

  @override
  State<DashboardShell> createState() => _DashboardShellState();
}

class _OfflineBanner extends StatelessWidget {
  const _OfflineBanner({required this.source});

  final DataSourceInfo source;

  @override
  Widget build(BuildContext context) {
    if (!source.isStale) return const SizedBox.shrink();
    final text = source.displayText;
    final timeStr =
        source.cachedAt != null ? '上次更新：${_formatTime(source.cachedAt!)}' : '';
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      color: source.needsRelogin
          ? theme.colorScheme.errorContainer
          : theme.colorScheme.tertiaryContainer,
      child: Row(
        children: [
          Icon(
            source.isOffline ? Icons.cloud_off : Icons.cloud_queue,
            size: 14,
            color: source.needsRelogin
                ? theme.colorScheme.onErrorContainer
                : theme.colorScheme.onTertiaryContainer,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              timeStr.isNotEmpty ? '$text · $timeStr' : text,
              style: TextStyle(
                fontSize: 11,
                color: source.needsRelogin
                    ? theme.colorScheme.onErrorContainer
                    : theme.colorScheme.onTertiaryContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _formatTime(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inHours < 1) return '${diff.inMinutes}分钟前';
    if (diff.inDays < 1) return '${diff.inHours}小时前';
    if (diff.inDays < 7) return '${diff.inDays}天前';
    return '${dt.month}/${dt.day} ${dt.hour}:${dt.minute.toString().padLeft(2, '0')}';
  }
}

class _PasswordLoginBanner extends StatelessWidget {
  const _PasswordLoginBanner({required this.onLogout});

  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: theme.colorScheme.errorContainer,
      child: Row(
        children: [
          Icon(Icons.warning_amber_rounded,
              size: 16, color: theme.colorScheme.onErrorContainer),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '账密登录模式，部分功能不可用，建议退出后使用一键登录',
              style: TextStyle(
                fontSize: 11,
                color: theme.colorScheme.onErrorContainer,
              ),
            ),
          ),
          const SizedBox(width: 4),
          GestureDetector(
            onTap: onLogout,
            child: Text(
              '退出',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.onErrorContainer,
                decoration: TextDecoration.underline,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class CaptchaImage extends StatelessWidget {
  const CaptchaImage({super.key, required this.source});

  final String source;

  @override
  Widget build(BuildContext context) {
    if (source.startsWith('data:image')) {
      final data = source.substring(source.indexOf(',') + 1);
      return Image.memory(base64Decode(data), height: 56, fit: BoxFit.contain);
    }
    return Image.network(source, height: 56, fit: BoxFit.contain);
  }
}

class _DashboardShellState extends State<DashboardShell> {
  int index = 0;
  int year =
      DateTime.now().month >= 9 ? DateTime.now().year : DateTime.now().year - 1;
  int term = DateTime.now().month >= 9 || DateTime.now().month <= 1 ? 1 : 2;
  late DateTime firstWeekStart;
  late int currentWeek;
  bool autoWeek = true;
  List<NavTabConfig> _navBarTabs = [
    ...NavTabConfig.all,
    NavTabConfig.moreTab,
  ];
  String? _highlightCourse;
  String? _overrideTabId;
  DateTime? _lastBackTime;
  bool _autoHideNavBar = true;
  final ValueNotifier<bool> _navBarVisible = ValueNotifier(true);
  final bool _mobileHeaderToolsVisible = false;
  bool _sidebarCollapsed = false;
  double _lastScrollOffset = 0;

  @override
  void initState() {
    super.initState();
    firstWeekStart = _defaultFirstWeekStart(year, term);
    currentWeek = _weekFromDate(firstWeekStart, DateTime.now());
    _HomeWidgetBridge.setLaunchHandler(_handleWidgetLaunch);
    _NotificationOpenBridge.setOpenTabHandler(_navigateToTab);
    LiveActivityController.instance.onOpen = _handleLiveActivityOpen;
    _loadNavConfig().then((_) => _consumeWidgetLaunch());
    _loadAutoHideSetting();
    _loadScheduleSettings();
  }

  @override
  void dispose() {
    _HomeWidgetBridge.setLaunchHandler(null);
    _NotificationOpenBridge.setOpenTabHandler(null);
    LiveActivityController.instance.onOpen = null;
    _navBarVisible.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant DashboardShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.loginMethod != widget.loginMethod) {
      _navBarTabs = _filterRestrictedTabs(_navBarTabs);
      if (index >= _navBarTabs.length) index = 0;
    }
  }

  bool _onScrollNotification(ScrollNotification notification) {
    if (!_autoHideNavBar) return false;
    if (notification is ScrollUpdateNotification) {
      final currentOffset = notification.metrics.pixels;
      final delta = currentOffset - _lastScrollOffset;
      if (delta > 8 && _navBarVisible.value) {
        _navBarVisible.value = false;
      } else if (delta < -8 && !_navBarVisible.value) {
        _navBarVisible.value = true;
      } else if (currentOffset <= 0 && !_navBarVisible.value) {
        _navBarVisible.value = true;
      }
      _lastScrollOffset = currentOffset;
    } else if (notification is ScrollEndNotification) {
      if (!_navBarVisible.value && notification.metrics.pixels <= 0) {
        _navBarVisible.value = true;
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    if (_navBarTabs.isNotEmpty && index >= _navBarTabs.length) index = 0;
    final currentTabId = _overrideTabId ??
        (_navBarTabs.isNotEmpty ? _navBarTabs[index].tabId : null);
    final currentPage = currentTabId != null
        ? _buildPage(currentTabId)
        : const SizedBox.shrink();

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_overrideTabId != null) {
          setState(() => _overrideTabId = null);
          return;
        }
        if (index != 0) {
          setState(() => index = 0);
          return;
        }
        final now = DateTime.now();
        if (_lastBackTime != null &&
            now.difference(_lastBackTime!).inSeconds < 2) {
          SystemNavigator.pop();
          return;
        }
        _lastBackTime = now;
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('再按一次退出应用'),
            duration: Duration(seconds: 2),
          ),
        );
      },
      child: Scaffold(
        body: LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < _mobileBreakpoint;
            final mobileTabs = _mobileNavTabs(_navBarTabs);
            final effectiveSelected = _overrideTabId != null ? -1 : index;
            final activeTabId = _overrideTabId ??
                (_navBarTabs.isNotEmpty ? _navBarTabs[index].tabId : null);
            final activeMobileIndex =
                mobileTabs.indexWhere((t) => t.tabId == activeTabId);
            final moreMobileIndex =
                mobileTabs.indexWhere((t) => t.tabId == 'more');
            final mobileSelected =
                activeMobileIndex >= 0 ? activeMobileIndex : moreMobileIndex;
            if (compact) {
              return Stack(
                children: [
                  Column(
                    children: [
                      _OfflineBanner(source: widget.dataSource),
                      if (widget.isPasswordLogin)
                        _PasswordLoginBanner(onLogout: widget.onLogout),
                      SafeArea(
                        bottom: false,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(14, 4, 14, 6),
                          child: Column(
                            children: [
                              _FrostedBanner(
                                padding:
                                    const EdgeInsets.fromLTRB(14, 2, 14, 2),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Column(
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        crossAxisAlignment:
                                            CrossAxisAlignment.center,
                                        children: [
                                          Text(
                                            widget.studentName ?? 'OneGZUS',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: Theme.of(context)
                                                .textTheme
                                                .bodySmall
                                                ?.copyWith(
                                                  fontSize: 1,
                                                  height: 0.1,
                                                ),
                                          ),
                                          Text(
                                            '软帮手',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: Theme.of(context)
                                                .textTheme
                                                .bodySmall
                                                ?.copyWith(
                                                  fontSize: 1,
                                                  height: 0.1,
                                                ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              if (_mobileHeaderToolsVisible) ...[
                                const SizedBox(height: 8),
                                _FrostedBanner(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 6),
                                  child: Row(
                                    key: const ValueKey(
                                        'dashboard-header-tools'),
                                    children: [
                                      TextButton.icon(
                                        onPressed: widget.onSettingsPressed,
                                        icon: const Icon(Icons.settings,
                                            size: 18),
                                        label: const Text('后台'),
                                      ),
                                      const Spacer(),
                                      TextButton.icon(
                                        onPressed: widget.onLogout,
                                        icon:
                                            const Icon(Icons.logout, size: 18),
                                        label: const Text('退出'),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                      Expanded(
                        child: NotificationListener<ScrollNotification>(
                          onNotification: _onScrollNotification,
                          child: SafeArea(
                            top: false,
                            bottom: false,
                            child: Padding(
                              padding: EdgeInsets.fromLTRB(10, 8, 10, _autoHideNavBar ? 10 : _mobileNavBarHeight + MediaQuery.paddingOf(context).bottom + 16 + 10),
                              child: _CenteredPage(
                                maxWidth: 720,
                                child: AnimatedSwitcher(
                                  duration: const Duration(milliseconds: 250),
                                  switchInCurve: Curves.easeOutCubic,
                                  switchOutCurve: Curves.easeInCubic,
                                  transitionBuilder: (child, animation) {
                                    return FadeTransition(
                                      opacity: animation,
                                      child: SlideTransition(
                                        position: Tween<Offset>(
                                          begin: const Offset(0.04, 0),
                                          end: Offset.zero,
                                        ).animate(animation),
                                        child: child,
                                      ),
                                    );
                                  },
                                  child: KeyedSubtree(
                                    key: ValueKey(currentTabId),
                                    child: currentPage,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  Positioned(
                    bottom: 0,
                    left: 0,
                    right: 0,
                    child: ValueListenableBuilder<bool>(
                      valueListenable: _navBarVisible,
                      builder: (context, visible, _) {
                        final show = !_autoHideNavBar || visible;
                        final bottomPadding =
                            MediaQuery.paddingOf(context).bottom;
                        return AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          curve: Curves.easeInOut,
                          height: show
                              ? _mobileNavBarHeight + bottomPadding + 16
                              : 0,
                          clipBehavior: Clip.none,
                          child: MobileNavBar(
                            tabs: mobileTabs,
                            selected:
                                mobileSelected.clamp(0, mobileTabs.length - 1),
                            onChanged: (value) async {
                              _navBarVisible.value = true;
                              final selectedTab = mobileTabs[value];
                              final fullIndex = _navBarTabs.indexWhere(
                                  (t) => t.tabId == selectedTab.tabId);
                              setState(() {
                                index = fullIndex >= 0 ? fullIndex : index;
                                _overrideTabId = null;
                              });
                            },
                          ),
                        );
                      },
                    ),
                  ),
                  LiveActivityIsland(
                    controller: LiveActivityController.instance,
                  ),
                ],
              );
            }
            final dense = constraints.maxWidth < _compactNavBreakpoint;
            return Stack(
              children: [
                Row(
                  children: [
                    AppSidebar(
                      tabs: _navBarTabs,
                      selected: effectiveSelected,
                      compact: _sidebarCollapsed,
                      dense: dense,
                      onToggleCompact: () {
                        setState(() => _sidebarCollapsed = !_sidebarCollapsed);
                      },
                      onChanged: (value) async {
                        _navBarVisible.value = true;
                        setState(() {
                          index = value;
                          _overrideTabId = null;
                        });
                      },
                    ),
                    Expanded(
                      child: Column(
                        children: [
                          _OfflineBanner(source: widget.dataSource),
                          if (widget.isPasswordLogin)
                            _PasswordLoginBanner(onLogout: widget.onLogout),
                          Expanded(
                            child: SafeArea(
                              child: Padding(
                                padding: EdgeInsets.all(dense ? 16 : 24),
                                child: NotificationListener<ScrollNotification>(
                                  onNotification: _onScrollNotification,
                                  child: _CenteredPage(
                                    maxWidth: 1280,
                                    child: AnimatedSwitcher(
                                      duration:
                                          const Duration(milliseconds: 250),
                                      switchInCurve: Curves.easeOutCubic,
                                      switchOutCurve: Curves.easeInCubic,
                                      transitionBuilder: (child, animation) {
                                        return FadeTransition(
                                          opacity: animation,
                                          child: SlideTransition(
                                            position: Tween<Offset>(
                                              begin: const Offset(0.04, 0),
                                              end: Offset.zero,
                                            ).animate(animation),
                                            child: child,
                                          ),
                                        );
                                      },
                                      child: KeyedSubtree(
                                        key: ValueKey(currentTabId),
                                        child: currentPage,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                LiveActivityIsland(
                  controller: LiveActivityController.instance,
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Future<void> _loadAutoHideSetting() async {
    final value = await NavPreferences.loadAutoHideNavBar();
    if (mounted) setState(() => _autoHideNavBar = value);
  }

  Future<void> _loadNavConfig() async {
    final tabIds = await NavPreferences.load();
    final tabs = <NavTabConfig>[];
    final normalizedTabIds =
        tabIds.contains('home') ? tabIds : ['home', ...tabIds];
    for (final id in normalizedTabIds) {
      if (id == 'more') {
        tabs.add(NavTabConfig.moreTab);
      } else {
        final found = NavTabConfig.all.where((t) => t.tabId == id);
        if (found.isNotEmpty) tabs.add(found.first);
      }
    }
    if (mounted) {
      setState(() {
        _navBarTabs = _filterRestrictedTabs(tabs);
        final homeIdx = tabs.indexWhere((t) => t.tabId == 'home');
        index = homeIdx >= 0 ? homeIdx : 0;
      });
    }
  }

  /// 账密登录时过滤掉依赖办事大厅的功能标签
  List<NavTabConfig> _filterRestrictedTabs(List<NavTabConfig> tabs) {
    if (!widget.isPasswordLogin) return tabs;
    return tabs
        .where((t) => !DashboardShell.passwordRestrictedTabs.contains(t.tabId))
        .toList();
  }

  Widget _buildPage(String tabId) {
    switch (tabId) {
      case 'home':
        return HomePage(
          api: widget.api,
          year: year,
          term: term,
          currentWeek: currentWeek,
          firstWeekStart: firstWeekStart,
          onNavigate: _navigateToTab,
          onSessionExpired: widget.onLogout,
          loginMethod: widget.loginMethod,
        );
      case 'info':
        return InfoPage(api: widget.api, onSessionExpired: widget.onLogout);
      case 'notices':
        return NoticesPage(api: widget.api, onSessionExpired: widget.onLogout);
      case 'business':
        return BusinessPage(api: widget.api, onSessionExpired: widget.onLogout);
      case 'applications':
        return ApplicationsPage(
            api: widget.api, onSessionExpired: widget.onLogout);
      case 'schedule':
        return SchedulePage(
            api: widget.api,
            year: year,
            term: term,
            currentWeek: currentWeek,
            firstWeekStart: firstWeekStart,
            autoWeek: autoWeek,
            onFirstWeekChanged: _setFirstWeekStart,
            onCurrentWeekChanged: _setCurrentWeek,
            onAutoWeekChanged: _setAutoWeek,
            onSessionExpired: widget.onLogout);
      case 'attendance':
        return AttendancePage(
            api: widget.api,
            year: year,
            term: term,
            onSessionExpired: widget.onLogout);
      case 'leave':
        return AutoLeavePage(
            api: widget.api,
            year: year,
            term: term,
            firstWeekStart: firstWeekStart,
            onSessionExpired: widget.onLogout);
      case 'exams':
        return ExamsPage(
            api: widget.api,
            periods: _allAcademicPeriods(),
            onSessionExpired: widget.onLogout,
            highlightCourse: _highlightCourse);
      case 'grades':
        return GradesPage(
            api: widget.api,
            periods: _allAcademicPeriods(),
            onSessionExpired: widget.onLogout,
            onNavigateToExam: (courseName) {
              setState(() {
                _highlightCourse = courseName;
              });
              _navigateToTab('exams');
              Future.delayed(const Duration(seconds: 2), () {
                if (mounted) setState(() => _highlightCourse = null);
              });
            });
      case 'credits':
        return CreditsPage(api: widget.api, onSessionExpired: widget.onLogout);
      case 'ecard':
        return EcardPage(api: widget.api, onSessionExpired: widget.onLogout);
      case 'ftpUpload':
        return const FtpUploadPage();
      case 'more':
        final compactLayout =
            MediaQuery.sizeOf(context).width < _mobileBreakpoint;
        return MorePage(
            api: widget.api,
            navBarTabs:
                compactLayout ? _mobileNavTabs(_navBarTabs) : _navBarTabs,
            navBarLimit: compactLayout ? _mobileMainNavLimit : null,
            onNavigate: _navigateToTab,
            onConfigChanged: _loadNavConfig,
            year: year,
            term: term,
            themeMode: widget.themeMode,
            onThemeChanged: widget.onThemeChanged,
            seedColor: widget.seedColor,
            onSeedColorChanged: widget.onSeedColorChanged,
            onLogout: widget.onLogout,
            onYearChanged: (v) => _setAcademicPeriod(v, term),
            onTermChanged: (v) => _setAcademicPeriod(year, v),
            autoHideNavBar: _autoHideNavBar,
            onAutoHideNavBarChanged: (v) async {
              await NavPreferences.saveAutoHideNavBar(v);
              setState(() => _autoHideNavBar = v);
            },
            loginMethod: widget.loginMethod,
            onShowBackgroundGuide: widget.onSettingsPressed);
      default:
        return const SizedBox.shrink();
    }
  }

  void _navigateToTab(String tabId) {
    // 账密登录时阻止导航到受限功能
    if (widget.isPasswordLogin &&
        DashboardShell.passwordRestrictedTabs.contains(tabId)) {
      return;
    }
    final idx = _navBarTabs.indexWhere((t) => t.tabId == tabId);
    if (idx >= 0) {
      _navBarVisible.value = true;
      setState(() {
        index = idx;
        _overrideTabId = null;
      });
      return;
    }
    final tabConfig = NavTabConfig.all.where((t) => t.tabId == tabId);
    if (tabConfig.isEmpty) return;
    _navBarVisible.value = true;
    setState(() {
      _overrideTabId = tabId;
    });
  }

  Future<void> _consumeWidgetLaunch() async {
    final tab = await _HomeWidgetBridge.consumeInitialTab();
    _handleWidgetLaunch(tab);
  }

  void _handleWidgetLaunch(String? tab) {
    if (!mounted || tab == null || tab.isEmpty || tab == 'home') return;
    _navigateToTab(tab);
  }

  void _handleLiveActivityOpen(LiveActivityEvent event) {
    final tab = event.targetTab;
    if (tab != null && tab.isNotEmpty) {
      _navigateToTab(tab);
      return;
    }
    final url = event.url;
    if (url != null && url.isNotEmpty) {
      unawaited(_openInAppBrowser(context, url));
    }
  }

  List<AcademicPeriod> _allAcademicPeriods() => [
        for (var value = year - 5; value <= year; value++)
          for (var valueTerm = 1; valueTerm <= 2; valueTerm++)
            AcademicPeriod(value, valueTerm),
      ];

  Future<void> _loadScheduleSettings() async {
    final loadYear = year;
    final loadTerm = term;
    final prefs = await SharedPreferences.getInstance();
    final firstWeekText =
        prefs.getString(_settingsKey(loadYear, loadTerm, 'firstWeekStart'));
    final savedAuto = prefs.getBool('schedule.autoWeek') ?? autoWeek;
    final defaultStart = _defaultFirstWeekStart(loadYear, loadTerm);
    final parsedStart =
        firstWeekText == null ? null : DateTime.tryParse(firstWeekText);
    final start = parsedStart ?? defaultStart;
    final savedWeek = prefs.getInt(_settingsKey(loadYear, loadTerm, 'week'));
    if (!mounted || loadYear != year || loadTerm != term) return;
    setState(() {
      firstWeekStart = start;
      autoWeek = savedAuto;
      currentWeek = savedAuto
          ? _weekFromDate(start, DateTime.now())
          : (savedWeek ?? _weekFromDate(start, DateTime.now()));
    });
  }

  Future<void> _saveScheduleSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _settingsKey(year, term, 'firstWeekStart'),
      _dateText(firstWeekStart),
    );
    await prefs.setInt(_settingsKey(year, term, 'week'), currentWeek);
    await prefs.setBool('schedule.autoWeek', autoWeek);
  }

  void _setAcademicPeriod(int nextYear, int nextTerm) {
    setState(() {
      year = nextYear;
      term = nextTerm;
      firstWeekStart = _defaultFirstWeekStart(nextYear, nextTerm);
      currentWeek = _weekFromDate(firstWeekStart, DateTime.now());
    });
    _loadScheduleSettings();
  }

  void _setFirstWeekStart(DateTime value) {
    final normalized = _mondayOf(value);
    setState(() {
      firstWeekStart = normalized;
      if (autoWeek) currentWeek = _weekFromDate(normalized, DateTime.now());
    });
    _saveScheduleSettings();
  }

  void _setCurrentWeek(int value) {
    setState(() {
      currentWeek = value.clamp(1, 30);
      autoWeek = false;
    });
    _saveScheduleSettings();
  }

  void _setAutoWeek(bool value) {
    setState(() {
      autoWeek = value;
      if (value) currentWeek = _weekFromDate(firstWeekStart, DateTime.now());
    });
    _saveScheduleSettings();
  }
}

class _CenteredPage extends StatelessWidget {
  const _CenteredPage({required this.child, required this.maxWidth});

  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: maxWidth,
              minHeight: constraints.maxHeight,
              maxHeight: constraints.maxHeight,
            ),
            child: child,
          ),
        );
      },
    );
  }
}

String _settingsKey(int year, int term, String name) =>
    'schedule.$year.$term.$name';

DateTime _defaultFirstWeekStart(int year, int term) {
  final seed = term == 1 ? DateTime(year, 9, 1) : DateTime(year + 1, 3, 1);
  return _mondayOf(seed);
}

DateTime _mondayOf(DateTime date) {
  final day = DateTime(date.year, date.month, date.day);
  return day.subtract(Duration(days: day.weekday - DateTime.monday));
}

int _weekFromDate(DateTime firstWeekStart, DateTime date) {
  final start = DateTime(
    firstWeekStart.year,
    firstWeekStart.month,
    firstWeekStart.day,
  );
  final current = DateTime(date.year, date.month, date.day);
  return (current.difference(start).inDays ~/ 7 + 1).clamp(1, 30);
}

String _dateText(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

class AppSidebar extends StatelessWidget {
  const AppSidebar({
    super.key,
    required this.tabs,
    required this.selected,
    required this.onChanged,
    this.compact = false,
    this.dense = false,
    this.onToggleCompact,
  });

  final List<NavTabConfig> tabs;
  final int selected;
  final ValueChanged<int> onChanged;
  final bool compact;
  final bool dense;
  final VoidCallback? onToggleCompact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return AnimatedContainer(
      key: const ValueKey('app-sidebar'),
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeInOutCubic,
      width: compact ? 86 : 248,
      clipBehavior: Clip.hardEdge,
      padding: EdgeInsets.fromLTRB(
          compact ? 10 : 16, dense ? 18 : 28, compact ? 10 : 16, 18),
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        border: Border(right: BorderSide(color: gzusBorder(context))),
      ),
      child: Column(
        crossAxisAlignment:
            compact ? CrossAxisAlignment.center : CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.symmetric(horizontal: compact ? 0 : 10),
            child: Row(
              mainAxisAlignment:
                  compact ? MainAxisAlignment.center : MainAxisAlignment.start,
              children: [
                if (compact)
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeInCubic,
                    child: Container(
                      key: const ValueKey('compact-logo'),
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: _accentFill(context),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: const Center(child: Text('🎓', style: TextStyle(fontSize: 22))),
                    ),
                  )
                else
                  Expanded(
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 200),
                      switchInCurve: Curves.easeOutCubic,
                      switchOutCurve: Curves.easeInCubic,
                      child: Column(
                        key: const ValueKey('expanded-logo'),
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('OneGZUS', style: theme.textTheme.titleLarge),
                          const SizedBox(height: 4),
                          Text('软帮手', style: theme.textTheme.bodySmall),
                        ],
                      ),
                    ),
                  ),
                if (!compact && onToggleCompact != null) ...[
                  const SizedBox(width: 8),
                  IconButton(
                    onPressed: onToggleCompact,
                    icon: const Icon(Icons.keyboard_double_arrow_left),
                    tooltip: '折叠边栏',
                  ),
                ],
              ],
            ),
          ),
          if (compact && onToggleCompact != null) ...[
            const SizedBox(height: 12),
            IconButton(
              onPressed: onToggleCompact,
              icon: const Icon(Icons.keyboard_double_arrow_right),
              tooltip: '展开边栏',
            ),
          ],
          const SizedBox(height: 28),
          Expanded(
            child: ListView.separated(
              itemCount: tabs.length,
              separatorBuilder: (_, __) => const SizedBox(height: 4),
              itemBuilder: (context, i) {
                final tab = tabs[i];
                final active = i == selected;
                return InkWell(
                  borderRadius: BorderRadius.circular(GzusRadii.sm),
                  onTap: () => onChanged(i),
                  child: Container(
                    constraints: const BoxConstraints(minHeight: 48),
                    padding: EdgeInsets.symmetric(
                      horizontal: compact ? 0 : 14,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: active ? _accentFill(context) : Colors.transparent,
                      borderRadius: BorderRadius.circular(GzusRadii.sm),
                    ),
                    child: Row(
                      mainAxisAlignment: compact
                          ? MainAxisAlignment.center
                          : MainAxisAlignment.start,
                      children: [
                        Icon(
                          tab.icon,
                          size: 22,
                          color: active
                              ? colorScheme.primary
                              : colorScheme.onSurfaceVariant,
                        ),
                        AnimatedSize(
                          duration: const Duration(milliseconds: 250),
                          curve: Curves.easeInOutCubic,
                          alignment: Alignment.centerLeft,
                          child: compact
                              ? const SizedBox.shrink()
                              : Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const SizedBox(width: 14),
                                    Text(
                                      tab.label,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style:
                                          theme.textTheme.bodyMedium?.copyWith(
                                        color: active
                                            ? colorScheme.primary
                                            : colorScheme.onSurfaceVariant,
                                        fontWeight: active
                                            ? FontWeight.w800
                                            : FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class MobileNavBar extends StatelessWidget {
  const MobileNavBar({
    super.key,
    required this.tabs,
    required this.selected,
    required this.onChanged,
  });

  final List<NavTabConfig> tabs;
  final int selected;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final bottomPadding = MediaQuery.paddingOf(context).bottom;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(14, 0, 14, bottomPadding + 8),
      child: Container(
        height: _mobileNavBarHeight,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(26),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.10),
              blurRadius: 24,
              offset: const Offset(0, 8),
            ),
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(26),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
            child: Container(
              key: const ValueKey('mobile-bottom-nav'),
              height: _mobileNavBarHeight,
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 7),
              decoration: BoxDecoration(
                color: gzusSurface(context).withValues(alpha: 0.72),
                borderRadius: BorderRadius.circular(26),
                border: Border.all(
                  color: gzusBorder(context).withValues(alpha: 0.5),
                ),
              ),
              child: Row(
                children: [
                  for (var i = 0; i < tabs.length; i++)
                    Expanded(
                      child: InkWell(
                        borderRadius: BorderRadius.circular(20),
                        onTap: () => onChanged(i),
                        child: Container(
                          height: double.infinity,
                          decoration: BoxDecoration(
                            color: i == selected
                                ? _accentFill(context)
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                tabs[i].icon,
                                size: 24,
                                color: i == selected
                                    ? colorScheme.primary
                                    : colorScheme.onSurfaceVariant,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                tabs[i].shortLabel,
                                maxLines: 1,
                                overflow: TextOverflow.clip,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: i == selected
                                      ? colorScheme.primary
                                      : colorScheme.onSurfaceVariant,
                                  fontWeight: i == selected
                                      ? FontWeight.w900
                                      : FontWeight.w700,
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
        ),
      ),
    );
  }
}

List<NavTabConfig> _mobileNavTabs(List<NavTabConfig> tabs) {
  final result = <NavTabConfig>[];
  for (final tab in tabs) {
    if (result.length >= _mobileMainNavLimit) break;
    if (tab.tabId != 'more' && !result.any((item) => item.tabId == tab.tabId)) {
      result.add(tab);
    }
  }
  result.add(NavTabConfig.moreTab);
  return result;
}

class NavTabConfig {
  const NavTabConfig({
    required this.tabId,
    required this.icon,
    required this.label,
    this.shortLabel = '',
    this.isFixed = false,
  });

  final String tabId;
  final IconData icon;
  final String label;
  final String shortLabel;
  final bool isFixed;

  static const all = [
    NavTabConfig(
        tabId: 'home',
        icon: Icons.home,
        label: '首页',
        shortLabel: '首页',
        isFixed: true),
    NavTabConfig(
        tabId: 'info',
        icon: Icons.badge,
        label: '个人信息',
        shortLabel: '信息',
        isFixed: true),
    NavTabConfig(
        tabId: 'notices',
        icon: Icons.notifications,
        label: '通知',
        shortLabel: '通知'),
    NavTabConfig(
        tabId: 'business', icon: Icons.apps, label: '业务', shortLabel: '业务'),
    NavTabConfig(
        tabId: 'applications',
        icon: Icons.dashboard_customize,
        label: '应用',
        shortLabel: '应用'),
    NavTabConfig(
        tabId: 'schedule',
        icon: Icons.calendar_month,
        label: '课表',
        shortLabel: '课表',
        isFixed: true),
    NavTabConfig(
        tabId: 'leave',
        icon: Icons.fact_check,
        label: '自动请假',
        shortLabel: '请假'),
    NavTabConfig(
        tabId: 'attendance',
        icon: Icons.schedule,
        label: '考勤',
        shortLabel: '考勤'),
    NavTabConfig(
        tabId: 'exams', icon: Icons.assignment, label: '考试', shortLabel: '考试'),
    NavTabConfig(
        tabId: 'grades', icon: Icons.school, label: '成绩', shortLabel: '成绩'),
    NavTabConfig(
        tabId: 'credits',
        icon: Icons.auto_stories,
        label: '学分',
        shortLabel: '学分'),
    NavTabConfig(
        tabId: 'ecard',
        icon: Icons.water_drop,
        label: '生活缴费',
        shortLabel: '缴费'),
    NavTabConfig(
        tabId: 'ftpUpload',
        icon: Icons.upload_file,
        label: '作业上传',
        shortLabel: '上传'),
  ];

  static const moreTab = NavTabConfig(
      tabId: 'more',
      icon: Icons.more_horiz,
      label: '更多',
      shortLabel: '更多',
      isFixed: true);

  static const defaultNavBar = [
    'home',
    'info',
    'applications',
    'schedule',
    'leave',
    'attendance',
    'exams',
    'grades',
    'credits',
    'ecard',
    'more',
  ];

  Map<String, dynamic> toJson() => {
        'tabId': tabId,
        'icon': icon.codePoint,
        'label': label,
        'shortLabel': shortLabel,
        'isFixed': isFixed,
      };
}

class NavPreferences {
  static const _key = 'nav_bar_config';
  static const _autoHideKey = 'auto_hide_nav_bar';

  static Future<List<String>> load() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_key) ?? NavTabConfig.defaultNavBar;
  }

  static Future<void> save(List<String> tabIds) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_key, tabIds);
  }

  static Future<void> reset() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }

  static Future<bool> loadAutoHideNavBar() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_autoHideKey) ?? true;
  }

  static Future<void> saveAutoHideNavBar(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoHideKey, value);
  }
}

class AsyncPanel<T> extends StatelessWidget {
  const AsyncPanel({
    super.key,
    required this.future,
    required this.builder,
    this.emptyMessage = '暂无数据',
    this.onSessionExpired,
  });

  final Future<T> future;
  final Widget Function(T data) builder;
  final String emptyMessage;
  final VoidCallback? onSessionExpired;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<T>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          final error = snapshot.error;
          // 不再在 401 时触发 onSessionExpired，_withFallback 已处理 relogin
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.error_outline,
                      size: 48, color: Theme.of(context).colorScheme.error),
                  const SizedBox(height: 12),
                  Text(
                    error is ApiException ? error.message : error.toString(),
                    textAlign: TextAlign.center,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                ],
              ),
            ),
          );
        }
        final data = snapshot.data;
        if (data is List && data.isEmpty) {
          return ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              SizedBox(
                height: MediaQuery.sizeOf(context).height * 0.45,
                child: EmptyState(message: emptyMessage),
              ),
            ],
          );
        }
        return builder(data as T);
      },
    );
  }
}

class PageRefresh extends StatelessWidget {
  const PageRefresh({super.key, required this.onRefresh, required this.child});

  final Future<void> Function() onRefresh;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      notificationPredicate: (notification) =>
          notification.metrics.axis == Axis.vertical,
      onRefresh: onRefresh,
      child: child,
    );
  }
}

class HomeModuleConfig {
  const HomeModuleConfig(this.id, this.label, this.icon);

  final String id;
  final String label;
  final IconData icon;
}

class HomePreferences {
  static const orderKey = 'home.moduleOrder';
  static const hiddenKey = 'home.hiddenModules';
  static const defaultModules = [
    HomeModuleConfig('nextClass', '下一节课', Icons.watch_later),
    HomeModuleConfig('todayTimeline', '今日时间线', Icons.view_timeline),
    HomeModuleConfig('weekGrid', '周课表', Icons.grid_view),
    HomeModuleConfig('dailyCourses', '今日课程', Icons.format_list_bulleted),
    HomeModuleConfig('weather', '今日天气', Icons.wb_sunny),
    HomeModuleConfig('grades', '本学期成绩', Icons.school),
    HomeModuleConfig('examCountdown', '考试倒计时', Icons.timer),
    HomeModuleConfig('utilities', '水电余额', Icons.water_drop),
    HomeModuleConfig('progress', '业务进度', Icons.route),
    HomeModuleConfig('notifications', '通知摘要', Icons.notifications_active),
    HomeModuleConfig('attendance', '考勤统计', Icons.fact_check),
    HomeModuleConfig('credits', '学分进度', Icons.workspace_premium),
    HomeModuleConfig('profile', '个人资料', Icons.badge),
    HomeModuleConfig('apps', '常用服务', Icons.apps),
  ];

  static Future<List<String>> loadOrder() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList(orderKey) ?? const [];
    return _normalizeOrder(saved);
  }

  static Future<Set<String>> loadHidden() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(hiddenKey) ?? const []).toSet();
  }

  static Future<void> save({
    required List<String> order,
    required Set<String> hidden,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(orderKey, _normalizeOrder(order));
    await prefs.setStringList(hiddenKey, hidden.toList());
  }

  static Future<void> reset() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(orderKey);
    await prefs.remove(hiddenKey);
  }

  static List<String> _normalizeOrder(List<String> value) {
    final validIds = defaultModules.map((item) => item.id).toSet();
    final result = <String>[];
    for (final id in value) {
      if (validIds.contains(id) && !result.contains(id)) result.add(id);
    }
    for (final config in defaultModules) {
      if (!result.contains(config.id)) result.add(config.id);
    }
    return result;
  }

  static HomeModuleConfig configFor(String id) =>
      defaultModules.firstWhere((item) => item.id == id);
}

class _HomeDashboardData {
  const _HomeDashboardData({
    required this.info,
    required this.courses,
    required this.notices,
    required this.attendance,
    required this.credits,
    required this.ecard,
    required this.apps,
    required this.progressOverview,
    this.weather,
    this.grades,
    this.exams,
  });

  final StudentInfo info;
  final List<ScheduleCourse> courses;
  final List<NoticeItem> notices;
  final AttendanceResponse attendance;
  final List<CreditItem> credits;
  final EcardSummary ecard;
  final List<EhallApplicationItem> apps;
  final EhallProgressOverview progressOverview;
  final WeatherData? weather;
  final List<GradeItem>? grades;
  final List<ExamItem>? exams;

  List<EhallProgressItem> get progress => progressOverview.items;
}

class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.api,
    required this.year,
    required this.term,
    required this.currentWeek,
    required this.firstWeekStart,
    required this.onNavigate,
    this.onSessionExpired,
    this.loginMethod,
  });

  final ApiClient api;
  final int year;
  final int term;
  final int currentWeek;
  final DateTime firstWeekStart;
  final ValueChanged<String> onNavigate;
  final VoidCallback? onSessionExpired;
  final String? loginMethod;

  bool get isPasswordLogin => loginMethod == 'password';

  /// 账密登录时首页隐藏的模块 id（依赖办事大厅 ehall 会话）
  static const passwordRestrictedModules = {
    'progress',
    'notifications',
    'apps',
  };

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  // 分模块异步加载的 Future
  late Future<StudentInfo> _infoFuture;
  late Future<ScheduleResult> _scheduleFuture;
  late Future<List<NoticeItem>> _noticesFuture;
  late Future<AttendanceResponse> _attendanceFuture;
  late Future<List<CreditItem>> _creditsFuture;
  late Future<EcardSummary> _ecardFuture;
  late Future<List<EhallApplicationItem>> _appsFuture;
  late Future<EhallProgressOverview> _progressFuture;
  late Future<WeatherData?> _weatherFuture;
  late Future<List<GradeItem>> _gradesFuture;
  late Future<List<ExamItem>> _examsFuture;

  List<String> _moduleOrder =
      HomePreferences.defaultModules.map((item) => item.id).toList();
  Set<String> _hiddenModules = {};

  @override
  void initState() {
    super.initState();
    _initFutures();
    _loadPreferences();
  }

  void _initFutures({bool forceRefresh = false}) {
    _infoFuture = _safeLoad(
      widget.api.me(forceRefresh: forceRefresh).then((r) => r.data),
      StudentInfo(studentId: '', name: 'OneGZUS'),
    );
    _scheduleFuture = _safeLoad(
      widget.api
          .schedule(
              year: widget.year, term: widget.term, forceRefresh: forceRefresh)
          .then((r) => r.data),
      ScheduleResult(items: const [], raw: const []),
    );
    _noticesFuture = _safeLoad(
      widget.api.notices(forceRefresh: forceRefresh).then((r) => r.data),
      const <NoticeItem>[],
    );
    _attendanceFuture = _safeLoad(
      widget.api
          .attendance(
              year: widget.year, term: widget.term, forceRefresh: forceRefresh)
          .then((r) => r.data),
      AttendanceResponse.fromJson({'status': 'empty', 'items': []}),
    );
    _creditsFuture = _safeLoad(
      widget.api.credits(forceRefresh: forceRefresh).then((r) => r.data),
      const <CreditItem>[],
    );
    _ecardFuture = _safeLoad(
      widget.api.ecardSummary(forceRefresh: forceRefresh).then((r) => r.data),
      EcardSummary.fromJson({'status': 'not_bound'}),
    );
    _appsFuture = _safeLoad(
      widget.api.ehallApplications(forceRefresh: forceRefresh),
      const <EhallApplicationItem>[],
    );
    _progressFuture = _safeLoad(
      widget.api.ehallProgressOverview(forceRefresh: forceRefresh),
      EhallProgressOverview.fromItems(const <EhallProgressItem>[]),
    );
    _weatherFuture = _loadWeather(forceRefresh: forceRefresh);
    _gradesFuture = _safeLoad(
      widget.api
          .grades(
              year: widget.year, term: widget.term, forceRefresh: forceRefresh)
          .then((r) => r.data),
      const <GradeItem>[],
    ).then((grades) async {
      if (grades.isNotEmpty) return grades;
      return _loadLocalGrades();
    });
    _examsFuture = _safeLoad(
      widget.api
          .exams(
              year: widget.year, term: widget.term, forceRefresh: forceRefresh)
          .then((r) => r.data),
      const <ExamItem>[],
    ).then((exams) async {
      if (exams.isNotEmpty) return exams;
      return _loadLocalExams();
    });
  }

  Future<WeatherData?> _loadWeather({bool forceRefresh = false}) async {
    final loc = await _safeLoad(_getLocationWithPermission(), null);
    final weather = await _safeLoad(
      widget.api
          .weather(forceRefresh: forceRefresh, lat: loc?.lat, lon: loc?.lon)
          .then((r) => r.data),
      null,
    );
    final WeatherData? effectiveWeather = weather ?? await _loadLocalWeather();
    if (weather != null) _saveLocalWeather(weather);
    return effectiveWeather;
  }

  @override
  void didUpdateWidget(covariant HomePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.year != widget.year ||
        oldWidget.term != widget.term ||
        oldWidget.currentWeek != widget.currentWeek ||
        oldWidget.firstWeekStart != widget.firstWeekStart) {
      _initFutures();
    }
  }

  Future<void> _loadPreferences() async {
    final order = await HomePreferences.loadOrder();
    final hidden = await HomePreferences.loadHidden();
    if (mounted) {
      setState(() {
        _moduleOrder = order;
        _hiddenModules = hidden;
      });
    }
  }

  Future<T> _safeLoad<T>(Future<T> future, T fallback) async {
    try {
      return await future;
    } catch (_) {
      return fallback;
    }
  }

  static const _weatherKey = 'local.weather';
  static const _gradesKey = 'local.grades';
  static const _examsKey = 'local.exams';

  Future<WeatherData?> _loadLocalWeather() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_weatherKey);
      if (raw != null) return WeatherData.fromJson(jsonDecode(raw));
    } catch (_) {}
    final def = _defaultWeather();
    _saveLocalWeather(def);
    return def;
  }

  Future<void> _saveLocalWeather(WeatherData data) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_weatherKey, jsonEncode(_weatherToJson(data)));
    } catch (_) {}
  }

  WeatherData _defaultWeather() {
    final now = DateTime.now();
    const weekdays = ['周日', '周一', '周二', '周三', '周四', '周五', '周六'];
    final forecastDays = <Map<String, String>>[];
    for (var i = 1; i <= 4; i++) {
      final d = now.add(Duration(days: i));
      final dateStr =
          '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
      forecastDays.add({
        'date': dateStr,
        'week': weekdays[d.weekday % 7],
        'temp_max': (30 + (i % 3)).toString(),
        'temp_min': (22 + (i % 3)).toString(),
        'weather_day': ['晴', '多云', '阵雨', '多云'][i - 1],
      });
    }
    return WeatherData.fromJson({
      'city': '广州',
      'district': '大学城',
      'weather': '晴',
      'weather_icon': '100',
      'temperature': 28,
      'wind_direction': '东南风',
      'wind_power': '2级',
      'humidity': 65,
      'temp_max': 32,
      'temp_min': 24,
      'forecast': forecastDays,
    });
  }

  Map<String, dynamic> _weatherToJson(WeatherData w) {
    return {
      'city': w.city,
      'district': w.district,
      'weather': w.weather,
      'weather_icon': w.weatherIcon,
      'temperature': w.temperature,
      'wind_direction': w.windDirection,
      'wind_power': w.windPower,
      'humidity': w.humidity,
      'temp_max': w.tempMax,
      'temp_min': w.tempMin,
      'forecast': w.forecast
          .map((f) => {
                'date': f.date,
                'week': f.week,
                'temp_max': f.tempMax,
                'temp_min': f.tempMin,
                'weather_day': f.weatherDay,
              })
          .toList(),
    };
  }

  Future<List<GradeItem>> _loadLocalGrades() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_gradesKey);
      if (raw != null) {
        final list = jsonDecode(raw) as List<dynamic>;
        return list
            .whereType<Map<String, dynamic>>()
            .map((e) => GradeItem.fromJson(e))
            .toList();
      }
    } catch (_) {}
    final def = _defaultGrades();
    _saveLocalGrades(def);
    return def;
  }

  Future<void> _saveLocalGrades(List<GradeItem> data) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = data
          .map((g) => {
                'courseName': g.courseName,
                'score': g.score,
                'credit': g.credit,
                'gradePoint': g.gradePoint,
                'term': g.term,
              })
          .toList();
      await prefs.setString(_gradesKey, jsonEncode(list));
    } catch (_) {}
  }

  List<GradeItem> _defaultGrades() {
    const defaults = [
      {
        'courseName': '数据结构与算法',
        'score': '92',
        'credit': '4.0',
        'gradePoint': '4.0',
        'term': ''
      },
      {
        'courseName': '操作系统原理',
        'score': '88',
        'credit': '3.5',
        'gradePoint': '3.7',
        'term': ''
      },
      {
        'courseName': '计算机网络',
        'score': '85',
        'credit': '3.0',
        'gradePoint': '3.7',
        'term': ''
      },
      {
        'courseName': '数据库系统概论',
        'score': '90',
        'credit': '3.0',
        'gradePoint': '4.0',
        'term': ''
      },
      {
        'courseName': '软件工程',
        'score': '87',
        'credit': '2.5',
        'gradePoint': '3.7',
        'term': ''
      },
      {
        'courseName': '人工智能导论',
        'score': '94',
        'credit': '2.0',
        'gradePoint': '4.0',
        'term': ''
      },
      {
        'courseName': '编译原理',
        'score': '78',
        'credit': '3.0',
        'gradePoint': '3.0',
        'term': ''
      },
      {
        'courseName': '计算机图形学',
        'score': '82',
        'credit': '2.0',
        'gradePoint': '3.3',
        'term': ''
      },
    ];
    return defaults.map((e) => GradeItem.fromJson(e)).toList();
  }

  Future<List<ExamItem>> _loadLocalExams() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_examsKey);
      if (raw != null) {
        final list = jsonDecode(raw) as List<dynamic>;
        return list
            .whereType<Map<String, dynamic>>()
            .map((e) => ExamItem.fromJson(e))
            .toList();
      }
    } catch (_) {}
    final def = _defaultExams();
    _saveLocalExams(def);
    return def;
  }

  Future<void> _saveLocalExams(List<ExamItem> data) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = data
          .map((e) => {
                'name': e.name,
                'date': e.date,
                'time': e.time,
                'weekday': e.weekday,
                'location': e.location,
              })
          .toList();
      await prefs.setString(_examsKey, jsonEncode(list));
    } catch (_) {}
  }

  List<ExamItem> _defaultExams() {
    final now = DateTime.now();
    final y = now.year;
    final defaults = [
      {
        'name': '数据结构与算法',
        'date': '$y-06-15',
        'time': '09:00-11:00',
        'weekday': '周日',
        'location': '教学楼 A-302',
      },
      {
        'name': '操作系统原理',
        'date': '$y-06-18',
        'time': '14:00-16:00',
        'weekday': '周三',
        'location': '实验楼 B-105',
      },
      {
        'name': '计算机网络',
        'date': '$y-06-22',
        'time': '09:00-11:00',
        'weekday': '周日',
        'location': '教学楼 C-201',
      },
      {
        'name': '数据库系统概论',
        'date': '$y-06-25',
        'time': '14:00-16:00',
        'weekday': '周三',
        'location': '教学楼 A-401',
      },
      {
        'name': '软件工程',
        'date': '$y-06-28',
        'time': '09:00-11:00',
        'weekday': '周六',
        'location': '教学楼 B-203',
      },
    ];
    return defaults.map((e) => ExamItem.fromJson(e)).toList();
  }

  Future<({double lat, double lon})?> _getLocationWithPermission() async {
    try {
      await permission_service.loadLibrary();
      final hasPermission = await permission_service.PermissionService.checkLocationPermission();
      if (!hasPermission) {
        await permission_service.PermissionService.requestLocationPermission();
        await Future.delayed(const Duration(milliseconds: 500));
      }
    } catch (_) {}
    try {
      await location_service.loadLibrary();
      return location_service.LocationService.getCoarseLocation();
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return PagePanel(
      title: '首页',
      icon: Icons.home,
      expandChild: true,
      trailing: TextButton.icon(
        onPressed: () => _showCustomizeSheet(context),
        icon: const Icon(Icons.tune, size: 18),
        label: const Text('自定义'),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final columns = constraints.maxWidth >= 980
                    ? 3
                    : constraints.maxWidth >= 640
                        ? 2
                        : 1;
                final spacing = columns == 1 ? 10.0 : 12.0;
                final visible = _moduleOrder
                    .where((id) => !_hiddenModules.contains(id))
                    .where((id) =>
                        !widget.isPasswordLogin ||
                        !HomePage.passwordRestrictedModules.contains(id))
                    .toList();
                return RefreshIndicator(
                  onRefresh: () async {
                    setState(() => _initFutures(forceRefresh: true));
                    // 等待所有模块加载完成
                    await Future.wait([
                      _infoFuture,
                      _scheduleFuture,
                      _noticesFuture,
                      _attendanceFuture,
                      _creditsFuture,
                      _ecardFuture,
                      _appsFuture,
                      _progressFuture,
                      _weatherFuture,
                      _gradesFuture,
                      _examsFuture,
                    ]).catchError((_) => []);
                    // 更新桌面小组件
                    _updateHomeWidget();
                  },
                  child: columns == 1
                      ? ListView.separated(
                          physics: const AlwaysScrollableScrollPhysics(),
                          itemCount: visible.length + 1,
                          separatorBuilder: (_, __) =>
                              SizedBox(height: spacing),
                          itemBuilder: (context, i) {
                            if (i == visible.length) {
                              return const SizedBox(height: 24);
                            }
                            return _StaggeredAppear(
                              index: i,
                              child: _homeModuleFor(visible[i]),
                            );
                          },
                        )
                      : GridView.builder(
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: const EdgeInsets.only(bottom: 24),
                          gridDelegate:
                              SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: columns,
                            mainAxisSpacing: spacing,
                            crossAxisSpacing: spacing,
                            mainAxisExtent: 360,
                          ),
                          itemCount: visible.length,
                          itemBuilder: (context, i) {
                            return _StaggeredAppear(
                              index: i,
                              child: _homeModuleFor(visible[i]),
                            );
                          },
                        ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _updateHomeWidget() async {
    try {
      final results = await Future.wait([
        _infoFuture,
        _scheduleFuture,
        _noticesFuture,
        _attendanceFuture,
        _creditsFuture,
        _ecardFuture,
        _appsFuture,
        _progressFuture,
        _weatherFuture,
        _gradesFuture,
        _examsFuture,
      ]).catchError((_) => List.filled(11, null));
      final data = _HomeDashboardData(
        info: results[0] as StudentInfo? ??
            StudentInfo(studentId: '', name: 'OneGZUS'),
        courses: (results[1] as ScheduleResult?)?.items ?? const [],
        notices: results[2] as List<NoticeItem>? ?? const [],
        attendance: results[3] as AttendanceResponse? ??
            AttendanceResponse.fromJson({'status': 'empty', 'items': []}),
        credits: results[4] as List<CreditItem>? ?? const [],
        ecard: results[5] as EcardSummary? ??
            EcardSummary.fromJson({'status': 'not_bound'}),
        apps: results[6] as List<EhallApplicationItem>? ?? const [],
        progressOverview: results[7] as EhallProgressOverview? ??
            EhallProgressOverview.fromItems(const []),
        weather: results[8] as WeatherData?,
        grades: results[9] as List<GradeItem>?,
        exams: results[10] as List<ExamItem>?,
      );
      await _HomeWidgetBridge.update(
        data: data,
        currentWeek: widget.currentWeek,
        firstWeekStart: widget.firstWeekStart,
      );
    } catch (_) {}
  }

  Widget _homeModuleFor(String id) {
    switch (id) {
      case 'nextClass':
        return _AsyncModuleCard<ScheduleResult>(
          future: _scheduleFuture,
          title: '下一节课',
          icon: Icons.watch_later,
          builder: (data) {
            final timedCourses = _homeTimedCourses(
              data.items,
              currentWeek: widget.currentWeek,
              firstWeekStart: widget.firstWeekStart,
            );
            return _NextClassHomeCard(
              course: _nextTimedCourse(timedCourses),
              onTap: () => widget.onNavigate('schedule'),
            );
          },
        );
      case 'todayTimeline':
        return _AsyncModuleCard<ScheduleResult>(
          future: _scheduleFuture,
          title: '今日时间线',
          icon: Icons.view_timeline,
          builder: (data) {
            final timedCourses = _homeTimedCourses(
              data.items,
              currentWeek: widget.currentWeek,
              firstWeekStart: widget.firstWeekStart,
            );
            return _TodayTimelineHomeCard(
                courses: _todayTimedCourses(timedCourses));
          },
        );
      case 'weekGrid':
        return _AsyncModuleCard<ScheduleResult>(
          future: _scheduleFuture,
          title: '周课表',
          icon: Icons.grid_view,
          builder: (data) {
            return _WeekGridHomeCard(
              courses: data.items
                  .where((item) => item.occursInWeek(widget.currentWeek))
                  .toList(),
            );
          },
        );
      case 'dailyCourses':
        return _AsyncModuleCard<ScheduleResult>(
          future: _scheduleFuture,
          title: '今日课程',
          icon: Icons.format_list_bulleted,
          builder: (data) {
            final timedCourses = _homeTimedCourses(
              data.items,
              currentWeek: widget.currentWeek,
              firstWeekStart: widget.firstWeekStart,
            );
            return _DailyCoursesHomeCard(
                courses: _todayTimedCourses(timedCourses));
          },
        );
      case 'utilities':
        return _AsyncModuleCard<EcardSummary>(
          future: _ecardFuture,
          title: '水电余额',
          icon: Icons.water_drop,
          builder: (data) => _UtilitiesHomeCard(
              summary: data, onTap: () => widget.onNavigate('ecard')),
        );
      case 'progress':
        return _AsyncModuleCard<EhallProgressOverview>(
          future: _progressFuture,
          title: '业务进度',
          icon: Icons.route,
          builder: (data) => _BusinessProgressHomeCard(
              overview: data, onTap: () => widget.onNavigate('business')),
        );
      case 'notifications':
        return _AsyncModuleCard<List<NoticeItem>>(
          future: _noticesFuture,
          title: '通知摘要',
          icon: Icons.notifications_active,
          builder: (data) => _NotificationsHomeCard(
              notices: data, onTap: () => widget.onNavigate('notices')),
        );
      case 'attendance':
        return _AsyncModuleCard<AttendanceResponse>(
          future: _attendanceFuture,
          title: '考勤统计',
          icon: Icons.fact_check,
          builder: (data) => _AttendanceHomeCard(
              data: data, onTap: () => widget.onNavigate('attendance')),
        );
      case 'credits':
        return _AsyncModuleCard<List<CreditItem>>(
          future: _creditsFuture,
          title: '学分进度',
          icon: Icons.workspace_premium,
          builder: (data) => _CreditsHomeCard(
              credits: data, onTap: () => widget.onNavigate('credits')),
        );
      case 'weather':
        return _AsyncModuleCard<WeatherData?>(
          future: _weatherFuture,
          title: '今日天气',
          icon: Icons.wb_sunny,
          allowNull: true,
          builder: (data) => _WeatherHomeCard(weather: data),
        );
      case 'grades':
        return _AsyncModuleCard<List<GradeItem>>(
          future: _gradesFuture,
          title: '本学期成绩',
          icon: Icons.school,
          builder: (data) => _GradesHomeCard(
              grades: data, onTap: () => widget.onNavigate('grades')),
        );
      case 'examCountdown':
        return _AsyncModuleCard<List<ExamItem>>(
          future: _examsFuture,
          title: '考试倒计时',
          icon: Icons.timer,
          builder: (data) => _ExamCountdownHomeCard(
              exams: data, onTap: () => widget.onNavigate('exams')),
        );
      case 'profile':
        return _AsyncModuleCard<StudentInfo>(
          future: _infoFuture,
          title: '个人资料',
          icon: Icons.badge,
          builder: (data) => _ProfileHomeCard(
              info: data, onTap: () => widget.onNavigate('info')),
        );
      case 'apps':
        return _AsyncModuleCard<List<EhallApplicationItem>>(
          future: _appsFuture,
          title: '常用服务',
          icon: Icons.apps,
          builder: (data) => _AppsHomeCard(
              apps: data, onTap: () => widget.onNavigate('applications')),
        );
      default:
        return const SizedBox.shrink();
    }
  }

  void _showCustomizeSheet(BuildContext context) {
    var order = [..._moduleOrder];
    var hidden = {..._hiddenModules};
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, localSetState) {
          Future<void> persist() async {
            await HomePreferences.save(order: order, hidden: hidden);
            if (mounted) {
              setState(() {
                _moduleOrder = [...order];
                _hiddenModules = {...hidden};
              });
            }
          }

          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          '自定义首页',
                          style: TextStyle(
                              fontSize: 18, fontWeight: FontWeight.w800),
                        ),
                      ),
                      TextButton(
                        onPressed: () async {
                          await HomePreferences.reset();
                          order = HomePreferences.defaultModules
                              .map((item) => item.id)
                              .toList();
                          hidden = {};
                          await persist();
                          localSetState(() {});
                        },
                        child: const Text('恢复默认'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: ReorderableListView.builder(
                      itemCount: order.length,
                      onReorderItem: (oldIndex, newIndex) async {
                        final id = order.removeAt(oldIndex);
                        order.insert(newIndex, id);
                        await persist();
                        localSetState(() {});
                      },
                      itemBuilder: (context, index) {
                        final id = order[index];
                        final config = HomePreferences.configFor(id);
                        final visible = !hidden.contains(id);
                        final restricted = widget.isPasswordLogin &&
                            HomePage.passwordRestrictedModules.contains(id);
                        return ListTile(
                          key: ValueKey(id),
                          leading: Icon(config.icon,
                              color: restricted
                                  ? Theme.of(context).disabledColor
                                  : null),
                          title: Text(config.label,
                              style: restricted
                                  ? TextStyle(
                                      color: Theme.of(context).disabledColor,
                                      decoration: TextDecoration.lineThrough)
                                  : null),
                          subtitle: restricted
                              ? const Text('需一键登录',
                                  style: TextStyle(fontSize: 11))
                              : null,
                          trailing: Switch(
                            value: visible && !restricted,
                            onChanged: restricted
                                ? null
                                : (value) async {
                                    if (value) {
                                      hidden.remove(id);
                                    } else {
                                      hidden.add(id);
                                    }
                                    await persist();
                                    localSetState(() {});
                                  },
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _HomeWidgetBridge {
  static const _channel = MethodChannel('cn.gzus.pro/home_widgets');
  static ValueChanged<String?>? _onLaunch;

  static void setLaunchHandler(ValueChanged<String?>? handler) {
    if (kIsWeb) return;
    _onLaunch = handler;
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'launch') return null;
      final args = call.arguments;
      final tab = args is Map ? args['tab']?.toString() : null;
      _onLaunch?.call(tab);
      return true;
    });
  }

  static Future<void> update({
    required _HomeDashboardData data,
    required int currentWeek,
    required DateTime firstWeekStart,
  }) async {
    if (kIsWeb) return;
    final timedCourses = _homeTimedCourses(
      data.courses,
      currentWeek: currentWeek,
      firstWeekStart: firstWeekStart,
    );
    final today = _todayTimedCourses(timedCourses);
    final next = _nextTimedCourse(timedCourses);
    final nextLocation = _notBlank(next?.course.classroom) ?? '-';
    final utilityDetail = _cleanJoin([
      _notBlank(data.ecard.updatedAt) == null
          ? null
          : '更新 ${data.ecard.updatedAt}',
      data.ecard.isBound ? '点击查看生活缴费' : '点击绑定宿舍',
    ], ' · ');
    final progress = data.progress.isEmpty ? null : data.progress.first;
    final progressMeta = progress == null
        ? '办事大厅'
        : _cleanJoin([
            _notBlank(progress.statusLabel),
            _notBlank(progress.currentNode),
            _notBlank(progress.category),
          ], ' · ');
    try {
      await _channel.invokeMethod('update', {
        'nextTitle': next?.course.name ?? '暂无下一节课',
        'nextMeta':
            next == null ? '今天没有更多课程' : '${next.timeText} · $nextLocation',
        'nextDetail': next == null
            ? '点击查看课表'
            : _cleanJoin([
                _notBlank(next.course.teacher),
                next.isOngoing ? '进行中' : '待开始',
              ], ' · '),
        'nextClassroom': next?.course.classroom ?? '',
        'nextTeacher': next?.course.teacher ?? '',
        'nextStatus':
            next == null ? 'none' : (next.isOngoing ? 'ongoing' : 'upcoming'),
        'nextTime': next?.timeText ?? '',
        'todayTitle': today.isEmpty ? '今日无课' : '今日 ${today.length} 节课',
        'todayMeta': '第$currentWeek周 · ${today.length} 节课',
        'todayItems': today
            .take(4)
            .map((item) => '${item.timeText} ${item.course.name}')
            .toList(),
        'todayCoursesJson': jsonEncode(today
            .map((item) => {
                  'time': '${_two(item.start.hour)}:${_two(item.start.minute)}',
                  'name': item.course.name,
                  'info': [item.course.classroom, item.course.teacher]
                      .where((s) => s != null && s.isNotEmpty)
                      .join(' · '),
                  'ongoing': item.isOngoing,
                })
            .toList()),
        'utilityTitle':
            data.ecard.isBound ? (data.ecard.roomDisplay ?? '生活缴费') : '未绑定宿舍',
        'utilityMeta':
            '电 ${data.ecard.powerText ?? '-'} · 冷水 ${data.ecard.coldWaterText ?? '-'} · 热水 ${data.ecard.hotWaterText ?? '-'}',
        'utilityDetail': utilityDetail,
        'utilityColdWater': data.ecard.coldWaterText ?? '-',
        'utilityHotWater': data.ecard.hotWaterText ?? '-',
        'utilityElectricity': data.ecard.powerText ?? '-',
        'utilityRoomInfo': _cleanJoin([
          data.ecard.roomDisplay,
          _notBlank(data.ecard.updatedAt) == null
              ? null
              : '更新 ${data.ecard.updatedAt}',
        ], ' · '),
        'progressTitle': progress == null ? '暂无业务进度' : progress.title,
        'progressMeta': progressMeta,
        'progressDetail': progress == null
            ? '点击查看办事大厅'
            : _cleanJoin([
                progress.progress == null ? null : '${progress.progress}%',
                _notBlank(progress.date),
                _notBlank(progress.summary),
              ], ' · '),
        'progressItemsJson': jsonEncode(data.progress
            .map((item) => {
                  'title': item.title,
                  'status': item.statusLabel,
                  'node': item.currentNode ?? '',
                  'progress': item.progress?.toString() ?? '',
                  'date': item.date ?? '',
                })
            .toList()),
      }).timeout(const Duration(milliseconds: 300));
    } catch (_) {}
  }

  static Future<String?> consumeInitialTab() async {
    if (kIsWeb) return null;
    try {
      return await _channel
          .invokeMethod<String>('consumeInitialTab')
          .timeout(const Duration(milliseconds: 300));
    } catch (_) {
      return null;
    }
  }

  static String? _notBlank(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  static String _cleanJoin(Iterable<String?> values, String separator) {
    return values
        .whereType<String>()
        .where((item) => item.isNotEmpty)
        .join(separator);
  }
}

class _NotificationOpenBridge {
  static ValueChanged<String>? _onOpenTab;

  static void setOpenTabHandler(ValueChanged<String>? handler) {
    _onOpenTab = handler;
  }

  static void openTab(String tabId) {
    _onOpenTab?.call(tabId);
  }
}

/// 分模块异步加载的卡片包装器：加载中显示骨架屏，加载完成后显示实际内容
class _AsyncModuleCard<T> extends StatelessWidget {
  const _AsyncModuleCard({
    required this.future,
    required this.title,
    required this.icon,
    required this.builder,
    this.allowNull = false,
  });

  final Future<T> future;
  final String title;
  final IconData icon;
  final Widget Function(T data) builder;
  final bool allowNull;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<T>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return _HomeCard(
            title: title,
            icon: icon,
            child: const _ShimmerPlaceholder(),
          );
        }
        if (snapshot.hasError) {
          return _HomeCard(
            title: title,
            icon: icon,
            child: const Center(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Text('加载失败', style: TextStyle(fontSize: 13)),
              ),
            ),
          );
        }
        final data = snapshot.data;
        if (!allowNull && data == null) {
          return _HomeCard(
            title: title,
            icon: icon,
            child: const Center(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Text('暂无数据', style: TextStyle(fontSize: 13)),
              ),
            ),
          );
        }
        return builder(data as T);
      },
    );
  }
}

/// 骨架屏占位组件
class _ShimmerPlaceholder extends StatelessWidget {
  const _ShimmerPlaceholder();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final color = isDark ? GzusColors.darkSurfaceSoft : GzusColors.surfaceSoft;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _placeholderLine(color, 0.6),
        const SizedBox(height: 10),
        _placeholderLine(color, 0.9),
        const SizedBox(height: 10),
        _placeholderLine(color, 0.4),
        const SizedBox(height: 10),
        _placeholderLine(color, 0.7),
      ],
    );
  }

  Widget _placeholderLine(Color color, double widthFactor) {
    return FractionallySizedBox(
      widthFactor: widthFactor,
      alignment: Alignment.centerLeft,
      child: Container(
        height: 14,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(4),
        ),
      ),
    );
  }
}

class _StaggeredAppear extends StatefulWidget {
  const _StaggeredAppear({required this.index, required this.child});
  final int index;
  final Widget child;

  @override
  State<_StaggeredAppear> createState() => _StaggeredAppearState();
}

class _StaggeredAppearState extends State<_StaggeredAppear>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 350),
  );
  late final _anim =
      CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic);

  @override
  void initState() {
    super.initState();
    Future.delayed(Duration(milliseconds: widget.index * 60), () {
      if (mounted) _controller.forward();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _anim,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.08),
          end: Offset.zero,
        ).animate(_anim),
        child: widget.child,
      ),
    );
  }
}

class _ScaleTap extends StatefulWidget {
  const _ScaleTap(
      {required this.onTap, required this.child, this.borderRadius});
  final VoidCallback? onTap;
  final Widget child;
  final BorderRadius? borderRadius;

  @override
  State<_ScaleTap> createState() => _ScaleTapState();
}

class _ScaleTapState extends State<_ScaleTap>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 120),
    lowerBound: 0.0,
    upperBound: 1.0,
  );
  late final _scaleAnim = Tween<double>(begin: 1.0, end: 0.96).animate(
    CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onTapDown(TapDownDetails _) => _controller.forward();
  void _onTapUp(TapUpDetails _) => _controller.reverse();
  void _onTapCancel() => _controller.reverse();

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: widget.onTap != null ? _onTapDown : null,
      onTapUp: widget.onTap != null ? _onTapUp : null,
      onTapCancel: widget.onTap != null ? _onTapCancel : null,
      onTap: widget.onTap,
      child: ScaleTransition(
        scale: _scaleAnim,
        child: widget.child,
      ),
    );
  }
}

class _HomeCard extends StatelessWidget {
  const _HomeCard({
    required this.title,
    required this.icon,
    required this.child,
    this.badge,
    this.onTap,
  });

  final String title;
  final IconData icon;
  final Widget child;
  final String? badge;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final content = Container(
      constraints: const BoxConstraints(minHeight: 196),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: gzusSurface(context),
        borderRadius: BorderRadius.circular(GzusRadii.lg),
        border: Border.all(color: gzusBorder(context)),
        boxShadow: gzusShadow(context),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: _accentFill(context),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, size: 19, color: cs.primary),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
              if (badge != null)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: _accentFill(context),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    badge!,
                    style: TextStyle(
                      color: cs.primary,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
    if (onTap == null) return content;
    return _ScaleTap(
      onTap: onTap,
      borderRadius: BorderRadius.circular(GzusRadii.lg),
      child: content,
    );
  }
}

class _TimedCourse {
  const _TimedCourse({
    required this.course,
    required this.start,
    required this.end,
  });

  final ScheduleCourse course;
  final DateTime start;
  final DateTime end;

  String get timeText =>
      '${_two(start.hour)}:${_two(start.minute)}-${_two(end.hour)}:${_two(end.minute)}';
  bool get isOngoing {
    final now = DateTime.now();
    return !now.isBefore(start) && now.isBefore(end);
  }
}

List<_TimedCourse> _homeTimedCourses(
  List<ScheduleCourse> courses, {
  required int currentWeek,
  required DateTime firstWeekStart,
}) {
  final result = <_TimedCourse>[];
  for (final course in courses) {
    final weekday = course.weekday;
    final startSection = course.startSection;
    final endSection = course.endSection ?? startSection;
    if (weekday == null ||
        startSection == null ||
        endSection == null ||
        weekday < 1 ||
        weekday > 7 ||
        startSection < 1 ||
        endSection < 1 ||
        startSection > icsScheduleTimes.length ||
        endSection > icsScheduleTimes.length ||
        !course.occursInWeek(currentWeek)) {
      continue;
    }
    final day =
        firstWeekStart.add(Duration(days: (currentWeek - 1) * 7 + weekday - 1));
    final startTime = _timeParts(icsScheduleTimes[startSection - 1].$1);
    final endTime = _timeParts(icsScheduleTimes[endSection - 1].$2);
    result.add(_TimedCourse(
      course: course,
      start: DateTime(day.year, day.month, day.day, startTime.$1, startTime.$2),
      end: DateTime(day.year, day.month, day.day, endTime.$1, endTime.$2),
    ));
  }
  result.sort((a, b) => a.start.compareTo(b.start));
  return result;
}

List<_TimedCourse> _todayTimedCourses(List<_TimedCourse> courses) {
  final now = DateTime.now();
  return courses
      .where((item) =>
          item.start.year == now.year &&
          item.start.month == now.month &&
          item.start.day == now.day)
      .toList();
}

_TimedCourse? _nextTimedCourse(List<_TimedCourse> courses) {
  final now = DateTime.now();
  final current = courses
      .where((item) => !now.isBefore(item.start) && now.isBefore(item.end));
  if (current.isNotEmpty) return current.first;
  final upcoming = courses.where((item) => item.start.isAfter(now));
  return upcoming.isEmpty ? null : upcoming.first;
}

String _two(int value) => value.toString().padLeft(2, '0');

(int, int) _timeParts(String value) {
  final parts = value.split(':');
  return (
    parts.isNotEmpty ? int.tryParse(parts[0]) ?? 0 : 0,
    parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0,
  );
}

Color _homeCourseColor(String name) {
  const palette = [
    Color(0xFF6750A4),
    Color(0xFF386A20),
    Color(0xFF0061A4),
    Color(0xFF7D5260),
    Color(0xFF9B3D2D),
    Color(0xFF006C67),
  ];
  var hash = 0;
  for (final unit in name.codeUnits) {
    hash = (hash + unit) % palette.length;
  }
  return palette[hash];
}

T? _firstOrNull<T>(Iterable<T> values) {
  final iterator = values.iterator;
  return iterator.moveNext() ? iterator.current : null;
}

class _NextClassHomeCard extends StatelessWidget {
  const _NextClassHomeCard({required this.course, required this.onTap});

  final _TimedCourse? course;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final item = course;
    return _HomeCard(
      title: '下一节课',
      icon: Icons.watch_later,
      badge: item?.isOngoing == true ? '进行中' : '焦点',
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: cs.primaryContainer,
          borderRadius: BorderRadius.circular(16),
        ),
        child: item == null
            ? Text('今天没有更多课程', style: TextStyle(color: cs.onPrimaryContainer))
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.course.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: cs.onPrimaryContainer,
                      fontSize: 22,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    children: [
                      _HomeMeta(icon: Icons.schedule, text: item.timeText),
                      if (item.course.classroom != null)
                        _HomeMeta(
                            icon: Icons.location_on,
                            text: item.course.classroom!),
                      if (item.course.teacher != null)
                        _HomeMeta(
                            icon: Icons.person, text: item.course.teacher!),
                    ],
                  ),
                ],
              ),
      ),
    );
  }
}

class _TodayTimelineHomeCard extends StatelessWidget {
  const _TodayTimelineHomeCard({required this.courses});

  final List<_TimedCourse> courses;

  @override
  Widget build(BuildContext context) {
    final display = courses.length > 6 ? courses.sublist(0, 6) : courses;
    final hasMore = courses.length > 6;
    return _HomeCard(
      title: '今日时间线',
      icon: Icons.view_timeline,
      badge: '${courses.length} 节',
      child: courses.isEmpty
          ? const EmptyState(message: '今日无课')
          : Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final item in display) _TimelineMiniRow(course: item),
                if (hasMore)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      '还有 ${courses.length - 6} 节课',
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}

class _TimelineMiniRow extends StatelessWidget {
  const _TimelineMiniRow({required this.course});

  final _TimedCourse course;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color =
        course.isOngoing ? cs.error : _homeCourseColor(course.course.name);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 48,
            child: Text(
              '${_two(course.start.hour)}:${_two(course.start.minute)}',
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
            ),
          ),
          Container(
            width: 10,
            height: 10,
            margin: const EdgeInsets.only(top: 4),
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: course.isOngoing
                    ? cs.primaryContainer
                    : cs.surfaceContainerHighest.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(course.course.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w800)),
                  const SizedBox(height: 4),
                  Text(
                    [course.course.classroom, course.course.teacher]
                        .where((item) => item != null && item.isNotEmpty)
                        .join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _WeekGridHomeCard extends StatelessWidget {
  const _WeekGridHomeCard({required this.courses});

  final List<ScheduleCourse> courses;

  @override
  Widget build(BuildContext context) {
    const days = ['一', '二', '三', '四', '五'];
    const slots = [1, 3, 5, 7];
    return _HomeCard(
      title: '周课表',
      icon: Icons.grid_view,
      badge: '紧凑',
      child: Column(
        children: [
          Row(
            children: [
              const SizedBox(width: 36),
              for (final day in days)
                Expanded(
                  child: Text('周$day',
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 12)),
                ),
            ],
          ),
          const SizedBox(height: 6),
          for (final slot in slots)
            Row(
              children: [
                SizedBox(
                  width: 36,
                  child: Text('$slot-${slot + 1}',
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                          fontSize: 11)),
                ),
                for (var day = 1; day <= 5; day++)
                  Expanded(
                    child: _WeekGridCell(
                      course: _firstOrNull(courses.where((item) {
                        final start = item.startSection ?? 0;
                        return item.weekday == day &&
                            start >= slot &&
                            start <= slot + 1;
                      })),
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

class _WeekGridCell extends StatelessWidget {
  const _WeekGridCell({required this.course});

  final ScheduleCourse? course;

  @override
  Widget build(BuildContext context) {
    final item = course;
    final cs = Theme.of(context).colorScheme;
    return Container(
      height: 50,
      margin: const EdgeInsets.all(2),
      padding: const EdgeInsets.all(5),
      decoration: BoxDecoration(
        color: item == null
            ? cs.surfaceContainerHighest.withValues(alpha: 0.35)
            : _homeCourseColor(item.name).withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(8),
      ),
      child: item == null
          ? null
          : Center(
              child: Text(
                item.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.w800),
              ),
            ),
    );
  }
}

class _DailyCoursesHomeCard extends StatelessWidget {
  const _DailyCoursesHomeCard({required this.courses});

  final List<_TimedCourse> courses;

  @override
  Widget build(BuildContext context) {
    return _HomeCard(
      title: '今日课程',
      icon: Icons.format_list_bulleted,
      badge: '列表',
      child: courses.isEmpty
          ? const EmptyState(message: '今日无课')
          : Column(
              children: [
                for (final item in courses.take(5))
                  _CompactCourseRow(course: item),
              ],
            ),
    );
  }
}

class _CompactCourseRow extends StatelessWidget {
  const _CompactCourseRow({required this.course});

  final _TimedCourse course;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: Row(
        children: [
          SizedBox(
            width: 82,
            child: Text(course.timeText,
                style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12)),
          ),
          Expanded(
            child: Text(course.course.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700)),
          ),
          _StatusPill(
            label: course.isOngoing ? '进行中' : '待开始',
            color: course.isOngoing ? cs.primary : cs.tertiary,
          ),
        ],
      ),
    );
  }
}

class _UtilitiesHomeCard extends StatelessWidget {
  const _UtilitiesHomeCard({required this.summary, required this.onTap});

  final EcardSummary summary;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return _HomeCard(
      title: '水电费余额',
      icon: Icons.water_drop,
      badge: summary.isBound ? '实时' : '未绑定',
      onTap: onTap,
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: _UtilityMini(
                  icon: Icons.ac_unit,
                  label: '冷水',
                  value: summary.coldWaterText ?? '-',
                  color: const Color(0xFF0288D1),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _UtilityMini(
                  icon: Icons.local_fire_department,
                  label: '热水',
                  value: summary.hotWaterText ?? '-',
                  color: const Color(0xFFD84315),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _UtilityMini(
                  icon: Icons.electric_bolt,
                  label: '电费',
                  value: summary.powerText ?? '-',
                  color: const Color(0xFFF9A825),
                ),
              ),
            ],
          ),
          if (summary.roomDisplay != null) ...[
            const SizedBox(height: 12),
            Text(summary.roomDisplay!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ],
        ],
      ),
    );
  }
}

class _UtilityMini extends StatelessWidget {
  const _UtilityMini({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 112),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Icon(icon, color: color),
          const SizedBox(height: 12),
          Text(label,
              style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 12)),
          const SizedBox(height: 4),
          Text(value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w900)),
        ],
      ),
    );
  }
}

class _BusinessProgressHomeCard extends StatelessWidget {
  const _BusinessProgressHomeCard(
      {required this.overview, required this.onTap});

  final EhallProgressOverview overview;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final items = overview.items;
    final total = overview.categories.fold<int>(
      0,
      (sum, item) => sum + item.count,
    );
    return _HomeCard(
      title: '业务进度',
      icon: Icons.route,
      badge: '$total 项',
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ProgressCategoryStrip(categories: overview.categories),
          const SizedBox(height: 12),
          if (items.isEmpty)
            const EmptyState(message: '暂无业务进度')
          else
            SizedBox(
              height: 130,
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    for (final item in items) _ProgressMiniRow(item: item),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ProgressCategoryStrip extends StatelessWidget {
  const _ProgressCategoryStrip({required this.categories});

  final List<EhallProgressCategory> categories;

  @override
  Widget build(BuildContext context) {
    final source = categories.isEmpty
        ? EhallProgressOverview.fromItems(const <EhallProgressItem>[])
            .categories
        : categories;
    return LayoutBuilder(
      builder: (context, constraints) {
        final tileWidth = constraints.maxWidth < 420 ? 96.0 : 112.0;
        return SizedBox(
          height: 82,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: source.length,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (context, index) => SizedBox(
              width: tileWidth,
              child: _ProgressCategoryTile(category: source[index]),
            ),
          ),
        );
      },
    );
  }
}

class _ProgressCategoryTile extends StatelessWidget {
  const _ProgressCategoryTile({required this.category});

  final EhallProgressCategory category;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isActive = category.count > 0;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
      decoration: BoxDecoration(
        color: isActive
            ? cs.primaryContainer.withValues(alpha: 0.75)
            : cs.surfaceContainerHighest.withValues(alpha: 0.62),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Center(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                category.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: isActive ? cs.onPrimaryContainer : cs.onSurfaceVariant,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                '${category.count}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: isActive ? cs.onPrimaryContainer : cs.onSurfaceVariant,
                  fontSize: 16,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProgressMiniRow extends StatelessWidget {
  const _ProgressMiniRow({required this.item});

  final EhallProgressItem item;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final value = ((item.progress ?? 0).clamp(0, 100)) / 100;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                flex: 3,
                child: Text(item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700)),
              ),
              const SizedBox(width: 8),
              Flexible(
                flex: 2,
                child: Align(
                  alignment: Alignment.centerRight,
                  child:
                      _StatusPill(label: item.statusLabel, color: cs.primary),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          _StaticProgressBar(value: value),
          const SizedBox(height: 4),
          Text(item.currentNode ?? item.summary ?? item.category,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12)),
        ],
      ),
    );
  }
}

class _NotificationsHomeCard extends StatelessWidget {
  const _NotificationsHomeCard({required this.notices, required this.onTap});

  final List<NoticeItem> notices;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return _HomeCard(
      title: '最新通知',
      icon: Icons.notifications_active,
      badge: '${notices.length}',
      onTap: onTap,
      child: notices.isEmpty
          ? const EmptyState(message: '暂无通知')
          : Column(
              children: [
                for (final item in notices.take(4)) _NoticeMiniRow(item: item),
              ],
            ),
    );
  }
}

class _NoticeMiniRow extends StatelessWidget {
  const _NoticeMiniRow({required this.item});

  final NoticeItem item;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          const _IconBadge(icon: Icons.campaign, size: 34),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                Text(item.summary ?? item.category,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AttendanceHomeCard extends StatelessWidget {
  const _AttendanceHomeCard({required this.data, required this.onTap});

  final AttendanceResponse data;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final normal = data.items.fold(0, (sum, item) => sum + item.normal);
    final late = data.items.fold(0, (sum, item) => sum + item.late);
    final early = data.items.fold(0, (sum, item) => sum + item.leaveEarly);
    final absent = data.items.fold(0, (sum, item) => sum + item.absent);
    return _HomeCard(
      title: '本月考勤统计',
      icon: Icons.fact_check,
      badge: '${data.items.length} 门',
      onTap: onTap,
      child: Row(
        children: [
          Expanded(
              child:
                  _AttendanceStatMini('正常', normal, const Color(0xFF2E7D32))),
          Expanded(
              child: _AttendanceStatMini('迟到', late, const Color(0xFFF57C00))),
          Expanded(
              child: _AttendanceStatMini('早退', early, const Color(0xFF7B1FA2))),
          Expanded(
              child:
                  _AttendanceStatMini('旷课', absent, const Color(0xFFC62828))),
        ],
      ),
    );
  }
}

class _AttendanceStatMini extends StatelessWidget {
  const _AttendanceStatMini(this.label, this.value, this.color);

  final String label;
  final int value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 3),
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Text('$value',
              style: TextStyle(
                  color: color, fontSize: 22, fontWeight: FontWeight.w900)),
          const SizedBox(height: 4),
          Text(label, style: const TextStyle(fontSize: 12)),
        ],
      ),
    );
  }
}

class _CreditsHomeCard extends StatelessWidget {
  const _CreditsHomeCard({required this.credits, required this.onTap});

  final List<CreditItem> credits;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final item = credits.isEmpty ? null : credits.first;
    final expected = item?.totalExpected ?? 0;
    final earned = item?.totalEarned ?? 0;
    final progress = expected <= 0 ? 0.0 : (earned / expected).clamp(0.0, 1.0);
    return _HomeCard(
      title: '学分进度',
      icon: Icons.workspace_premium,
      badge: item?.grade ?? '学分',
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('${earned.toStringAsFixed(1)} / ${expected.toStringAsFixed(1)}',
              style:
                  const TextStyle(fontSize: 24, fontWeight: FontWeight.w900)),
          const SizedBox(height: 10),
          _StaticProgressBar(value: progress),
          const SizedBox(height: 12),
          _HomeInfoLine(
              '必修',
              item == null
                  ? '-'
                  : '${item.requiredEarned.toStringAsFixed(1)} / ${item.requiredExpected.toStringAsFixed(1)}'),
          _HomeInfoLine(
              '选修',
              item == null
                  ? '-'
                  : '${item.electiveEarned.toStringAsFixed(1)} / ${item.electiveExpected.toStringAsFixed(1)}'),
        ],
      ),
    );
  }
}

class _ProfileHomeCard extends StatelessWidget {
  const _ProfileHomeCard({required this.info, required this.onTap});

  final StudentInfo info;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return _HomeCard(
      title: '个人资料',
      icon: Icons.badge,
      badge: '已认证',
      onTap: onTap,
      child: Row(
        children: [
          CircleAvatar(
            radius: 34,
            child: Text(info.name.isEmpty ? '-' : info.name.characters.first),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(info.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 20, fontWeight: FontWeight.w900)),
                const SizedBox(height: 6),
                _HomeInfoLine('学号', info.studentId),
                _HomeInfoLine('专业', info.major ?? '-'),
                _HomeInfoLine('班级', info.className ?? '-'),
                if (info.gender != null) _HomeInfoLine('性别', info.gender!),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AppsHomeCard extends StatelessWidget {
  const _AppsHomeCard({required this.apps, required this.onTap});

  final List<EhallApplicationItem> apps;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final visible = apps.take(8).toList();
    return _HomeCard(
      title: '常用服务',
      icon: Icons.apps,
      badge: '${apps.length} 个',
      onTap: onTap,
      child: visible.isEmpty
          ? const EmptyState(message: '暂无应用')
          : Wrap(
              alignment: WrapAlignment.center,
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final app in visible)
                  SizedBox(
                    width: 72,
                    child: Column(
                      children: [
                        const _IconBadge(icon: Icons.dashboard_customize),
                        const SizedBox(height: 6),
                        Text(app.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontSize: 12)),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }
}

class _WeatherHomeCard extends StatelessWidget {
  const _WeatherHomeCard({this.weather});

  final WeatherData? weather;

  IconData _weatherIcon(String? weatherText) {
    final w = weatherText ?? '';
    if (w.contains('雨')) return Icons.water_drop;
    if (w.contains('雪')) return Icons.ac_unit;
    if (w.contains('云') || w.contains('阴')) return Icons.wb_cloudy;
    return Icons.wb_sunny;
  }

  Color _weatherColor(String? weatherText, BuildContext context) {
    final w = weatherText ?? '';
    if (w.contains('雨')) return Colors.blue;
    if (w.contains('雪')) return Colors.lightBlue;
    if (w.contains('云') || w.contains('阴')) return Colors.grey;
    return Theme.of(context).colorScheme.primary;
  }

  @override
  Widget build(BuildContext context) {
    final w = weather;
    if (w == null) {
      return const _HomeCard(
        title: '今日天气',
        icon: Icons.wb_sunny,
        badge: '--',
        child: Center(child: Text('天气数据加载失败')),
      );
    }

    final forecast =
        w.forecast.length > 1 ? w.forecast.sublist(1, 4) : <WeatherForecast>[];

    return _HomeCard(
      title: '今日天气',
      icon: Icons.wb_sunny,
      badge: w.location,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(_weatherIcon(w.weather),
                  size: 40, color: _weatherColor(w.weather, context)),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${w.temperature.round()}°',
                      style: const TextStyle(
                          fontSize: 36, fontWeight: FontWeight.w200)),
                  Text(
                    '${w.weather}  ${w.tempMin != null ? w.tempMin!.round() : '--'}°~${w.tempMax != null ? w.tempMax!.round() : '--'}°',
                    style: TextStyle(
                        fontSize: 13,
                        color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _HomeMeta(icon: Icons.water_drop, text: '湿度 ${w.humidity}%'),
              const SizedBox(width: 16),
              _HomeMeta(
                  icon: Icons.air, text: '${w.windDirection} ${w.windPower}'),
            ],
          ),
          if (forecast.isNotEmpty) ...[
            const Divider(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                for (final f in forecast)
                  Column(
                    children: [
                      Text(f.week,
                          style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant)),
                      const SizedBox(height: 4),
                      Icon(_weatherIcon(f.weatherDay),
                          size: 20,
                          color:
                              Theme.of(context).colorScheme.onSurfaceVariant),
                      const SizedBox(height: 4),
                      Text('${f.tempMax.round()}°',
                          style: const TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w700)),
                    ],
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _GradesHomeCard extends StatelessWidget {
  const _GradesHomeCard({this.grades, required this.onTap});

  final List<GradeItem>? grades;
  final VoidCallback onTap;

  double _scoreToGPA(String? scoreStr) {
    final score = int.tryParse(scoreStr ?? '');
    if (score == null) return 0;
    if (score >= 90) return 4.0;
    if (score >= 85) return 3.7;
    if (score >= 82) return 3.3;
    if (score >= 78) return 3.0;
    if (score >= 75) return 2.7;
    if (score >= 72) return 2.3;
    if (score >= 68) return 2.0;
    if (score >= 66) return 1.7;
    if (score >= 64) return 1.3;
    if (score >= 60) return 1.0;
    return 0;
  }

  ({String gpa, String avg, int count}) _calcStats(List<GradeItem> list) {
    double totalGPA = 0;
    double totalScore = 0;
    int valid = 0;
    for (final g in list) {
      final s = int.tryParse(g.score ?? '');
      if (s != null) {
        totalGPA += _scoreToGPA(g.score);
        totalScore += s;
        valid++;
      }
    }
    if (valid == 0) return (gpa: '0.00', avg: '0.0', count: 0);
    return (
      gpa: (totalGPA / valid).toStringAsFixed(2),
      avg: (totalScore / valid).toStringAsFixed(1),
      count: valid,
    );
  }

  Color _scoreColor(int? score, ColorScheme cs) {
    if (score == null) return cs.onSurfaceVariant;
    if (score >= 90) return Colors.green;
    if (score >= 80) return cs.primary;
    if (score >= 60) return Colors.orange;
    return Colors.red;
  }

  Color _gpaTagColor(double gpa, ColorScheme cs) {
    if (gpa >= 4.0) return Colors.green;
    if (gpa >= 3.0) return cs.primary;
    if (gpa >= 2.0) return Colors.orange;
    return Colors.red;
  }

  @override
  Widget build(BuildContext context) {
    final list = grades ?? [];
    final stats = _calcStats(list);
    final sorted =
        list.where((g) => int.tryParse(g.score ?? '') != null).toList()
          ..sort((a, b) {
            final sa = int.parse(a.score!);
            final sb = int.parse(b.score!);
            return sb.compareTo(sa);
          });

    return _HomeCard(
      title: '本学期成绩',
      icon: Icons.school,
      badge: '${stats.count} 门',
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  children: [
                    Text(stats.gpa,
                        style: TextStyle(
                            fontSize: 32,
                            fontWeight: FontWeight.w800,
                            color: Theme.of(context).colorScheme.primary)),
                    Text('平均绩点',
                        style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant)),
                  ],
                ),
              ),
              Container(
                  width: 1, height: 40, color: Theme.of(context).dividerColor),
              Expanded(
                child: Column(
                  children: [
                    Text(stats.avg,
                        style: const TextStyle(
                            fontSize: 32, fontWeight: FontWeight.w800)),
                    Text('平均分',
                        style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant)),
                  ],
                ),
              ),
            ],
          ),
          const Divider(height: 20),
          SizedBox(
            height: 152,
            child: sorted.isEmpty
                ? const Center(child: Text('暂无成绩数据'))
                : ListView.separated(
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: sorted.length.clamp(0, 4),
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (context, i) {
                      final g = sorted[i];
                      final score = int.parse(g.score!);
                      final gpa = _scoreToGPA(g.score);
                      return Row(
                        children: [
                          Container(
                            width: 4,
                            height: 28,
                            decoration: BoxDecoration(
                              color: _scoreColor(
                                  score, Theme.of(context).colorScheme),
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(g.courseName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600)),
                                if (g.credit != null)
                                  Text('${g.credit} 学分',
                                      style: TextStyle(
                                          fontSize: 11,
                                          color: Theme.of(context)
                                              .colorScheme
                                              .onSurfaceVariant)),
                              ],
                            ),
                          ),
                          Text('$score',
                              style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w800,
                                  color: _scoreColor(
                                      score, Theme.of(context).colorScheme))),
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: _gpaTagColor(
                                      gpa, Theme.of(context).colorScheme)
                                  .withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(gpa.toStringAsFixed(1),
                                style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                    color: _gpaTagColor(
                                        gpa, Theme.of(context).colorScheme))),
                          ),
                        ],
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _ExamCountdownHomeCard extends StatelessWidget {
  const _ExamCountdownHomeCard({this.exams, required this.onTap});

  final List<ExamItem>? exams;
  final VoidCallback onTap;

  DateTime? _examDate(ExamItem e) {
    var dateStr = e.date;
    if (dateStr.isEmpty) {
      final t = e.time ?? '';
      final spaceIdx = t.indexOf(' ');
      dateStr = spaceIdx > 0 ? t.substring(0, spaceIdx) : t;
    }
    return DateTime.tryParse(dateStr);
  }

  int _calcCountdown(ExamItem e) {
    final target = _examDate(e);
    if (target == null) return 9999;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return target.difference(today).inDays;
  }

  List<ExamItem> _upcoming(List<ExamItem> list) {
    return list.where((e) {
      final days = _calcCountdown(e);
      return days >= -7 || days == 9999;
    }).toList()
      ..sort((a, b) {
        final da = _calcCountdown(a);
        final db = _calcCountdown(b);
        if (da == 9999 && db == 9999) return 0;
        if (da == 9999) return 1;
        if (db == 9999) return -1;
        return da.compareTo(db);
      });
  }

  @override
  Widget build(BuildContext context) {
    final list = exams ?? [];
    final upcoming = _upcoming(list);

    return _HomeCard(
      title: '考试倒计时',
      icon: Icons.timer,
      badge: '期末',
      onTap: onTap,
      child: upcoming.isEmpty
          ? const Center(child: Text('暂无即将到来的考试'))
          : ListView.separated(
              physics: const NeverScrollableScrollPhysics(),
              itemCount: upcoming.length.clamp(0, 4),
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (context, i) {
                final exam = upcoming[i];
                final days = _calcCountdown(exam);
                final dateObj = _examDate(exam);
                final day = dateObj?.day ?? 0;
                final month = dateObj?.month ?? 0;
                final isPast = days < 0;
                final isUrgent = days >= 0 && days <= 3;
                final isToday = days == 0;

                return Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: isUrgent
                        ? Theme.of(context)
                            .colorScheme
                            .errorContainer
                            .withValues(alpha: 0.3)
                        : Theme.of(context)
                            .colorScheme
                            .surfaceContainerHighest
                            .withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: isUrgent
                          ? Theme.of(context)
                              .colorScheme
                              .error
                              .withValues(alpha: 0.3)
                          : Theme.of(context)
                              .dividerColor
                              .withValues(alpha: 0.3),
                    ),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: isUrgent
                              ? Theme.of(context)
                                  .colorScheme
                                  .error
                                  .withValues(alpha: 0.12)
                              : Theme.of(context)
                                  .colorScheme
                                  .primary
                                  .withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text('$day',
                                style: TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w800,
                                    color: isUrgent
                                        ? Theme.of(context).colorScheme.error
                                        : Theme.of(context)
                                            .colorScheme
                                            .primary)),
                            Text('$month月',
                                style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                    color: isUrgent
                                        ? Theme.of(context).colorScheme.error
                                        : Theme.of(context)
                                            .colorScheme
                                            .primary)),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(exam.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontSize: 14, fontWeight: FontWeight.w700)),
                            const SizedBox(height: 2),
                            Text('${exam.weekday ?? ''}${(exam.weekday ?? '').isNotEmpty && exam.timeDisplay.isNotEmpty ? ' · ' : ''}${exam.timeDisplay}',
                                style: TextStyle(
                                    fontSize: 12,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant)),
                            Text(exam.location ?? '',
                                style: TextStyle(
                                    fontSize: 12,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant)),
                          ],
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: isToday
                              ? Theme.of(context).colorScheme.error
                              : isPast
                                  ? Theme.of(context)
                                      .colorScheme
                                      .surfaceContainerHighest
                                      .withValues(alpha: 0.6)
                                  : Theme.of(context)
                                      .colorScheme
                                      .surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Column(
                          children: [
                            Text(
                                days == 9999
                                    ? '?'
                                    : isToday
                                        ? '!'
                                        : '${days.abs()}',
                                style: TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.w800,
                                    color: isToday
                                        ? Colors.white
                                        : isPast
                                            ? Theme.of(context)
                                                .colorScheme
                                                .onSurfaceVariant
                                            : Theme.of(context)
                                                .colorScheme
                                                .onSurface)),
                            Text(
                                days == 9999
                                    ? '待定'
                                    : isToday
                                        ? '今天'
                                        : isPast
                                            ? '天前'
                                            : '天',
                                style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                    color: isToday
                                        ? Colors.white
                                        : Theme.of(context)
                                            .colorScheme
                                            .onSurfaceVariant)),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }
}

class _HomeMeta extends StatelessWidget {
  const _HomeMeta({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16),
        const SizedBox(width: 4),
        Text(text, maxLines: 1, overflow: TextOverflow.ellipsis),
      ],
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
              color: color, fontSize: 11, fontWeight: FontWeight.w800)),
    );
  }
}

class _StaticProgressBar extends StatelessWidget {
  const _StaticProgressBar({required this.value});

  final double value;

  @override
  Widget build(BuildContext context) {
    final clamped = value.clamp(0.0, 1.0).toDouble();
    final cs = Theme.of(context).colorScheme;
    return Container(
      height: 6,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: cs.outlineVariant.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(3),
      ),
      child: FractionallySizedBox(
        alignment: Alignment.centerLeft,
        widthFactor: clamped,
        child: Container(color: cs.primary),
      ),
    );
  }
}

class _HomeInfoLine extends StatelessWidget {
  const _HomeInfoLine(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Row(
        children: [
          SizedBox(
            width: 42,
            child: Text(label,
                style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: 12)),
          ),
          Expanded(
            child: Text(value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }
}

class InfoPage extends StatefulWidget {
  const InfoPage({super.key, required this.api, this.onSessionExpired});

  final ApiClient api;
  final VoidCallback? onSessionExpired;

  @override
  State<InfoPage> createState() => _InfoPageState();
}

class _InfoPageState extends State<InfoPage> {
  late Future<StudentInfo> _infoFuture;

  @override
  void initState() {
    super.initState();
    _infoFuture = _loadInfo();
  }

  @override
  void didUpdateWidget(covariant InfoPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.api != widget.api) {
      _infoFuture = _loadInfo();
    }
  }

  Future<StudentInfo> _loadInfo({bool forceRefresh = false}) =>
      widget.api.me(forceRefresh: forceRefresh).then((r) => r.data);

  Future<void> _refreshInfo() async {
    setState(() => _infoFuture = _loadInfo(forceRefresh: true));
    await _infoFuture;
  }

  @override
  Widget build(BuildContext context) {
    return PageRefresh(
      onRefresh: _refreshInfo,
      child: AsyncPanel<StudentInfo>(
        future: _infoFuture,
        onSessionExpired: widget.onSessionExpired,
        builder: (info) => LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 720;
            final tiles = [
              InfoTile(icon: Icons.person, label: '姓名', value: info.name),
              InfoTile(icon: Icons.badge, label: '学号', value: info.studentId),
              InfoTile(
                  icon: Icons.apartment,
                  label: '学院',
                  value: info.college ?? '-'),
              InfoTile(
                  icon: Icons.school, label: '专业', value: info.major ?? '-'),
              InfoTile(
                  icon: Icons.groups,
                  label: '班级',
                  value: info.className ?? '-'),
              InfoTile(
                  icon: Icons.calendar_today,
                  label: '年级',
                  value: info.grade ?? '-'),
              if (info.gender != null)
                InfoTile(icon: Icons.wc, label: '性别', value: info.gender!),
              if (info.idNumber != null)
                InfoTile(
                    icon: Icons.credit_card,
                    label: '证件号码',
                    value: info.idNumber!),
              if (info.birthDate != null)
                InfoTile(
                    icon: Icons.cake, label: '出生日期', value: info.birthDate!),
              if (info.ethnicity != null)
                InfoTile(
                    icon: Icons.people, label: '民族', value: info.ethnicity!),
              if (info.politicalStatus != null)
                InfoTile(
                    icon: Icons.flag,
                    label: '政治面貌',
                    value: info.politicalStatus!),
              if (info.enrollDate != null)
                InfoTile(
                    icon: Icons.event, label: '入学日期', value: info.enrollDate!),
              if (info.nativePlace != null)
                InfoTile(
                    icon: Icons.place, label: '籍贯', value: info.nativePlace!),
              if (info.studentStatus != null)
                InfoTile(
                    icon: Icons.how_to_reg,
                    label: '学籍状态',
                    value: info.studentStatus!),
              if (info.educationLevel != null)
                InfoTile(
                    icon: Icons.workspace_premium,
                    label: '培养层次',
                    value: info.educationLevel!),
              if (info.phone != null)
                InfoTile(icon: Icons.phone, label: '手机号码', value: info.phone!),
              if (info.email != null)
                InfoTile(icon: Icons.email, label: '电子邮箱', value: info.email!),
              if (info.address != null)
                InfoTile(icon: Icons.home, label: '家庭地址', value: info.address!),
            ];
            if (wide) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 300,
                    child: PagePanel(
                      title: '个人信息',
                      icon: Icons.badge,
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            StudentAvatar(
                              photoDataUrl: info.photoDataUrl,
                              name: info.name,
                            ),
                            const SizedBox(height: 16),
                            Text(info.name,
                                style: const TextStyle(
                                    fontSize: 18, fontWeight: FontWeight.w700)),
                            if (info.studentId.isNotEmpty)
                              Text(info.studentId,
                                  style: TextStyle(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant)),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: PagePanel(
                      title: '详细信息',
                      icon: Icons.info_outline,
                      expandChild: true,
                      child: SingleChildScrollView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        child:
                            Wrap(spacing: 12, runSpacing: 12, children: tiles),
                      ),
                    ),
                  ),
                ],
              );
            }
            return SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  const SizedBox(height: 12),
                  StudentAvatar(
                    photoDataUrl: info.photoDataUrl,
                    name: info.name,
                  ),
                  const SizedBox(height: 8),
                  Text(info.name,
                      style: const TextStyle(
                          fontSize: 18, fontWeight: FontWeight.w700)),
                  if (info.studentId.isNotEmpty)
                    Text(info.studentId,
                        style: TextStyle(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant)),
                  const SizedBox(height: 12),
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 8,
                    runSpacing: 8,
                    children: tiles,
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class StudentAvatar extends StatelessWidget {
  const StudentAvatar(
      {super.key, required this.photoDataUrl, required this.name});

  final String? photoDataUrl;
  final String name;

  @override
  Widget build(BuildContext context) {
    final image = photoDataUrl;
    return GestureDetector(
      onTap: image != null && image.isNotEmpty
          ? () => _showAvatarOverlay(context, image)
          : null,
      child: Container(
        width: 112,
        height: 144,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
          border:
              Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        ),
        child: image == null || image.isEmpty
            ? Center(
                child: Text(
                  name.isEmpty ? '-' : name.characters.first,
                  style: const TextStyle(
                      fontSize: 32, fontWeight: FontWeight.w600),
                ),
              )
            : Stack(
                fit: StackFit.expand,
                children: [
                  Image.memory(
                    base64Decode(image.substring(image.indexOf(',') + 1)),
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) =>
                        const Center(child: Icon(Icons.person)),
                  ),
                  Positioned(
                    right: 4,
                    bottom: 4,
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Icon(
                        Icons.zoom_in,
                        color: Colors.white,
                        size: 16,
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  void _showAvatarOverlay(BuildContext context, String dataUrl) {
    showDialog(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.5),
      builder: (dialogContext) => _AvatarOverlayDialog(
        photoDataUrl: dataUrl,
        name: name,
      ),
    );
  }
}

class _AvatarOverlayDialog extends StatelessWidget {
  const _AvatarOverlayDialog({
    required this.photoDataUrl,
    required this.name,
  });

  final String photoDataUrl;
  final String name;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Material(
        color: Colors.transparent,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 400),
          decoration: BoxDecoration(
            color: cs.surface,
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.3),
                blurRadius: 32,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(Icons.photo_camera, size: 20, color: cs.primary),
                  const SizedBox(width: 8),
                  Text(
                    '📸 头像抓取成功',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: cs.onSurface,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Container(
                width: 160,
                height: 160,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: cs.primary, width: 3),
                ),
                child: Image.memory(
                  base64Decode(
                      photoDataUrl.substring(photoDataUrl.indexOf(',') + 1)),
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) =>
                      const Center(child: Icon(Icons.person, size: 48)),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                name,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: cs.onSurface,
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  FilledButton.icon(
                    onPressed: () => _openInNewTab(context),
                    icon: const Icon(Icons.open_in_new, size: 18),
                    label: const Text('新标签页打开'),
                    style: FilledButton.styleFrom(
                      backgroundColor: cs.primary,
                      foregroundColor: cs.onPrimary,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    style: OutlinedButton.styleFrom(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ),
                    child: const Text('关闭'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openInNewTab(BuildContext context) {
    avatar_open.loadLibrary().then((_) {
      avatar_open.openAvatarInNewTab(photoDataUrl, name);
    });
    Navigator.of(context).pop();
  }
}

class _BusinessProgressSection extends StatefulWidget {
  const _BusinessProgressSection({
    required this.api,
    required this.refreshVersion,
    this.onSessionExpired,
  });

  final ApiClient api;
  final int refreshVersion;
  final VoidCallback? onSessionExpired;

  @override
  State<_BusinessProgressSection> createState() =>
      _BusinessProgressSectionState();
}

class _BusinessProgressSectionState extends State<_BusinessProgressSection> {
  String _status = '全部';
  bool _expanded = false;
  late Future<EhallProgressOverview> _progressFuture;

  @override
  void initState() {
    super.initState();
    _progressFuture = widget.api.ehallProgressOverview();
  }

  @override
  void didUpdateWidget(covariant _BusinessProgressSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.api != widget.api ||
        oldWidget.refreshVersion != widget.refreshVersion) {
      _progressFuture = widget.api.ehallProgressOverview(
        forceRefresh: oldWidget.refreshVersion != widget.refreshVersion,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<EhallProgressOverview>(
      future: _progressFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const SizedBox(
            height: 72,
            child: Center(child: CircularProgressIndicator()),
          );
        }
        if (snapshot.hasError) {
          // 不再在 401 时触发 onSessionExpired，_withFallback 已处理 relogin
          return const SizedBox.shrink();
        }
        final overview = snapshot.data ??
            EhallProgressOverview.fromItems(const <EhallProgressItem>[]);
        final items = overview.items;
        final statuses = [
          '全部',
          ...items
              .map((item) => item.statusLabel)
              .where((item) => item.isNotEmpty)
              .toSet(),
        ];
        final filtered = _status == '全部'
            ? items
            : items.where((item) => item.statusLabel == _status).toList();
        return Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Icons.route,
                      size: 20, color: Theme.of(context).colorScheme.primary),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text('业务进度',
                        style: TextStyle(fontWeight: FontWeight.w800)),
                  ),
                  Text('${filtered.length} 项',
                      style: TextStyle(
                          color:
                              Theme.of(context).colorScheme.onSurfaceVariant)),
                  const SizedBox(width: 4),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon:
                        Icon(_expanded ? Icons.expand_less : Icons.expand_more),
                    onPressed: () => setState(() => _expanded = !_expanded),
                  ),
                ],
              ),
              if (_expanded) ...[
                const SizedBox(height: 10),
                _ProgressCategoryStrip(categories: overview.categories),
                const SizedBox(height: 10),
                SizedBox(
                  height: 40,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: statuses.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 8),
                    itemBuilder: (context, index) {
                      final status = statuses[index];
                      return ChoiceChip(
                        label: Text(status),
                        selected: _status == status,
                        onSelected: (_) => setState(() => _status = status),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 10),
                if (filtered.isEmpty)
                  const EmptyState(message: '暂无业务进度')
                else
                  Column(
                    children: [
                      for (final item in filtered.take(5))
                        InkWell(
                          onTap: () => _openInAppBrowser(context, item.url),
                          child: _ProgressMiniRow(item: item),
                        ),
                    ],
                  ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class BusinessPage extends StatefulWidget {
  const BusinessPage({super.key, required this.api, this.onSessionExpired});

  final ApiClient api;
  final VoidCallback? onSessionExpired;

  @override
  State<BusinessPage> createState() => _BusinessPageState();
}

class _BusinessPageState extends State<BusinessPage> {
  String _query = '';
  String _department = '全部';
  int _refreshVersion = 0;
  late Future<List<EhallAffairItem>> _affairsFuture;

  @override
  void initState() {
    super.initState();
    _affairsFuture = _loadAffairs();
  }

  @override
  void didUpdateWidget(covariant BusinessPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.api != widget.api) {
      _affairsFuture = _loadAffairs();
    }
  }

  Future<List<EhallAffairItem>> _loadAffairs({bool forceRefresh = false}) =>
      widget.api.ehallAffairs(forceRefresh: forceRefresh);

  Future<void> _refreshAffairs() async {
    setState(() {
      _refreshVersion++;
      _affairsFuture = _loadAffairs(forceRefresh: true);
    });
    await _affairsFuture;
  }

  @override
  Widget build(BuildContext context) {
    return AsyncPanel<List<EhallAffairItem>>(
      future: _affairsFuture,
      emptyMessage: '暂无业务',
      onSessionExpired: widget.onSessionExpired,
      builder: (items) {
        final departments = _departments(items);
        final filtered = items.where((item) {
          final query = _query.trim().toLowerCase();
          final matchesDepartment =
              _department == '全部' || item.department == _department;
          final searchable = [
            item.title,
            item.department ?? '',
            item.type ?? '',
            item.summary ?? '',
            ...item.tags,
          ].join(' ').toLowerCase();
          return matchesDepartment &&
              (query.isEmpty || searchable.contains(query));
        }).toList();
        return PagePanel(
          title: '业务',
          icon: Icons.apps,
          expandChild: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _BusinessProgressSection(
                api: widget.api,
                refreshVersion: _refreshVersion,
                onSessionExpired: widget.onSessionExpired,
              ),
              const SizedBox(height: 12),
              _BusinessFilters(
                departments: departments,
                selectedDepartment: _department,
                onQueryChanged: (value) => setState(() => _query = value),
                onDepartmentChanged: (value) =>
                    setState(() => _department = value),
              ),
              const SizedBox(height: 12),
              Text(
                '共 ${filtered.length} 项',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 10),
              Expanded(
                child: PageRefresh(
                  onRefresh: _refreshAffairs,
                  child: filtered.isEmpty
                      ? ListView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          children: const [
                            SizedBox(height: 120),
                            EmptyState(message: '没有匹配的业务'),
                          ],
                        )
                      : LayoutBuilder(
                          builder: (context, constraints) {
                            final columns = _contentGridColumns(
                              constraints.maxWidth,
                              minTileWidth: 170,
                              maxColumns: 4,
                            );
                            return GridView.builder(
                              physics: const AlwaysScrollableScrollPhysics(),
                              gridDelegate:
                                  SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: columns,
                                crossAxisSpacing: 10,
                                mainAxisSpacing: 10,
                                childAspectRatio: columns == 1 ? 2.8 : 1.35,
                              ),
                              itemCount: filtered.length,
                              itemBuilder: (context, index) =>
                                  _BusinessItemTile(item: filtered[index]),
                            );
                          },
                        ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  List<String> _departments(List<EhallAffairItem> items) {
    final values = items
        .map((item) => item.department?.trim())
        .where((value) => value != null && value.isNotEmpty)
        .cast<String>()
        .toSet()
        .toList()
      ..sort();
    return ['全部', ...values];
  }
}

class _BusinessFilters extends StatelessWidget {
  const _BusinessFilters({
    required this.departments,
    required this.selectedDepartment,
    required this.onQueryChanged,
    required this.onDepartmentChanged,
  });

  final List<String> departments;
  final String selectedDepartment;
  final ValueChanged<String> onQueryChanged;
  final ValueChanged<String> onDepartmentChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          onChanged: onQueryChanged,
          decoration: const InputDecoration(
            prefixIcon: Icon(Icons.search),
            hintText: '搜索业务',
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 40,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: departments.length,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (context, index) {
              final department = departments[index];
              return ChoiceChip(
                label: Text(department),
                selected: selectedDepartment == department,
                onSelected: (_) => onDepartmentChanged(department),
              );
            },
          ),
        ),
      ],
    );
  }
}

enum _FtpQueueStatus { pending, uploading, done, failed }

enum _FtpDownloadStatus { pending, downloading, done, failed }

class _FtpQueuedFile {
  _FtpQueuedFile({
    required this.name,
    required this.path,
    required this.size,
  });

  final String name;
  final String path;
  final int size;
  _FtpQueueStatus status = _FtpQueueStatus.pending;
  double progress = 0;
  String? error;
}

class _FtpDownloadingFile {
  _FtpDownloadingFile({
    required this.name,
    required this.remotePath,
    required this.size,
    required this.localPath,
  });

  final String name;
  final String remotePath;
  final int size;
  final String localPath;
  _FtpDownloadStatus status = _FtpDownloadStatus.pending;
  String? error;
}

class FtpUploadPage extends StatefulWidget {
  const FtpUploadPage({super.key});

  @override
  State<FtpUploadPage> createState() => _FtpUploadPageState();
}

class _FtpUploadPageState extends State<FtpUploadPage> {
  final _hostController = TextEditingController(text: 'ftp.school.local');
  final _portController = TextEditingController(text: '21');
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final List<_FtpQueuedFile> _queue = [];
  final List<_FtpDownloadingFile> _downloads = [];
  List<FtpEntry> _entries = const [];
  String _currentDirectory = '/';
  bool _passiveMode = true;
  bool _settingsLoaded = false;
  bool _testing = false;
  bool _listing = false;
  bool _uploading = false;
  bool _downloading = false;
  bool _connected = false;
  String? _message;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  @override
  void dispose() {
    _hostController.dispose();
    _portController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!FtpUploadService.isSupported) {
      return const PagePanel(
        title: '作业上传',
        icon: Icons.upload_file,
        expandChild: true,
        child:
            EmptyState(message: 'Web 端无法直连 FTP，请使用 Android App 并连接学校内网或 VPN。'),
      );
    }

    return PagePanel(
      title: '作业上传',
      icon: Icons.upload_file,
      expandChild: true,
      child: RefreshIndicator(
        onRefresh: _connected ? _listCurrentDirectory : _testConnection,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            _buildStatusCards(),
            const SizedBox(height: 12),
            if (_message != null)
              _buildBanner(_message!, Icons.check_circle, false),
            if (_error != null)
              _buildBanner(_error!, Icons.error_outline, true),
            if (_message != null || _error != null) const SizedBox(height: 12),
            LayoutBuilder(
              builder: (context, constraints) {
                final compact = constraints.maxWidth < 760;
                final children = [
                  _buildMainColumn(),
                  _buildConfigColumn(),
                ];
                if (compact) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      children[0],
                      const SizedBox(height: 12),
                      children[1],
                    ],
                  );
                }
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 3, child: children[0]),
                    const SizedBox(width: 12),
                    Expanded(flex: 2, child: children[1]),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusCards() {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 680;
        final cards = [
          _FtpStatusCard(
            title: '平台',
            value: 'Android',
            detail: '客户端直连 FTP',
            icon: Icons.phone_android,
            color: scheme.primary,
          ),
          _FtpStatusCard(
            title: '连接',
            value: _connected ? '已连接' : '未连接',
            detail: _connected ? _hostController.text.trim() : '需连接学校内网/VPN',
            icon: _connected ? Icons.wifi_tethering : Icons.wifi_off,
            color: _connected ? GzusColors.green : GzusColors.amber,
          ),
          _FtpStatusCard(
            title: '队列',
            value:
                '${_queue.where((f) => f.status != _FtpQueueStatus.done).length} 个待处理',
            detail:
                '${_queue.where((f) => f.status == _FtpQueueStatus.done).length} 个已完成',
            icon: Icons.cloud_upload_outlined,
            color: scheme.secondary,
          ),
        ];
        if (compact) {
          return Column(
            children: [
              for (final card in cards) ...[card, const SizedBox(height: 10)],
            ],
          );
        }
        return Row(
          children: [
            for (var i = 0; i < cards.length; i++) ...[
              Expanded(child: cards[i]),
              if (i != cards.length - 1) const SizedBox(width: 10),
            ],
          ],
        );
      },
    );
  }

  Widget _buildMainColumn() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AccentPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text('上传文件',
                        style: Theme.of(context).textTheme.titleMedium),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: _pickFiles,
                    icon: const Icon(Icons.add),
                    label: const Text('添加文件'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: _pickFiles,
                style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(112)),
                child: const Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.upload_file, size: 34),
                    SizedBox(height: 8),
                    Text('选择 PDF、Word、PPT、ZIP 等作业文件'),
                    SizedBox(height: 2),
                    Text('单个文件最大 100 MB'),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _canUpload ? _uploadPendingFiles : null,
                icon: _uploading
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.cloud_upload),
                label: Text(_uploading ? '上传中...' : '开始上传'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _buildDirectoryPanel(),
        const SizedBox(height: 12),
        _buildQueuePanel(),
        const SizedBox(height: 12),
        _buildDownloadPanel(),
      ],
    );
  }

  Widget _buildConfigColumn() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('FTP 配置', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 12),
                TextField(
                  controller: _hostController,
                  decoration: const InputDecoration(
                    labelText: '服务器',
                    prefixIcon: Icon(Icons.dns_outlined),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _portController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: '端口',
                    prefixIcon: Icon(Icons.numbers),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _usernameController,
                  decoration: const InputDecoration(
                    labelText: '账号',
                    prefixIcon: Icon(Icons.person_outline),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _passwordController,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: '密码',
                    prefixIcon: Icon(Icons.key_outlined),
                  ),
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  value: _passiveMode,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('被动模式'),
                  subtitle: const Text('校园网 FTP 通常建议开启'),
                  onChanged: (value) => setState(() => _passiveMode = value),
                ),
                const SizedBox(height: 8),
                FilledButton.icon(
                  onPressed:
                      !_settingsLoaded || _testing ? null : _testConnection,
                  icon: _testing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.bolt),
                  label: Text(_testing ? '测试中...' : '测试连接'),
                ),
                const SizedBox(height: 8),
                Text(
                  '密码仅保存在系统安全区，不发送到 OneGZUS 后端。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDirectoryPanel() {
    final scheme = Theme.of(context).colorScheme;
    final dirs = _entries.where((e) => e.isDirectory).toList();
    final files = _entries.where((e) => !e.isDirectory).toList();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('远程目录',
                      style: Theme.of(context).textTheme.titleMedium),
                ),
                IconButton(
                  onPressed:
                      _connected && !_listing ? _listCurrentDirectory : null,
                  icon: const Icon(Icons.refresh),
                  tooltip: '刷新目录',
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                InputChip(
                  label: Text(_currentDirectory),
                  avatar: const Icon(Icons.folder, size: 18),
                  onPressed: _connected ? () => _openDirectory('/') : null,
                ),
                if (_currentDirectory != '/')
                  ActionChip(
                    avatar: const Icon(Icons.arrow_upward, size: 18),
                    label: const Text('上一级'),
                    onPressed: _openParentDirectory,
                  ),
              ],
            ),
            const SizedBox(height: 12),
            if (_listing)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: CircularProgressIndicator(),
                ),
              )
            else if (!_connected)
              const EmptyState(message: '测试连接后显示 FTP 目录')
            else if (dirs.isEmpty && files.isEmpty)
              const EmptyState(message: '当前目录为空')
            else ...[
              // 目录列表
              for (final entry in dirs) ...[
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.folder_outlined,
                      color: GzusColors.amber),
                  title: Text(entry.name),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _openDirectory(entry.path),
                ),
                const Divider(height: 1),
              ],
              // 文件列表（带下载按钮）
              if (files.isNotEmpty) ...[
                if (dirs.isNotEmpty) const SizedBox(height: 4),
                for (final entry in files) ...[
                  ListTile(
                    dense: true,
                    leading: Icon(
                      _fileIcon(entry.name),
                      color: scheme.primary,
                      size: 22,
                    ),
                    title: Text(entry.name,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(_formatFtpSize(entry.size)),
                    trailing: IconButton(
                      icon: const Icon(Icons.download_outlined, size: 20),
                      tooltip: '下载',
                      onPressed:
                          _downloading ? null : () => _downloadFile(entry),
                    ),
                  ),
                  const Divider(height: 1),
                ],
              ],
            ],
          ],
        ),
      ),
    );
  }

  IconData _fileIcon(String name) {
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    return switch (ext) {
      'pdf' => Icons.picture_as_pdf_outlined,
      'doc' || 'docx' => Icons.description_outlined,
      'xls' || 'xlsx' => Icons.table_chart_outlined,
      'ppt' || 'pptx' => Icons.slideshow_outlined,
      'zip' || 'rar' || '7z' || 'tar' || 'gz' => Icons.folder_zip_outlined,
      'jpg' ||
      'jpeg' ||
      'png' ||
      'gif' ||
      'bmp' ||
      'webp' =>
        Icons.image_outlined,
      'mp4' || 'avi' || 'mkv' || 'mov' => Icons.videocam_outlined,
      'mp3' || 'wav' || 'flac' || 'aac' => Icons.audiotrack_outlined,
      'txt' || 'md' || 'log' => Icons.article_outlined,
      _ => Icons.insert_drive_file_outlined,
    };
  }

  Future<void> _downloadFile(FtpEntry entry) async {
    final config = _readConfig();
    if (config == null) return;

    // 使用应用的 Download 目录
    final downloadDir = await _getDownloadDirectory();
    if (downloadDir == null) {
      if (mounted) setState(() => _error = '无法访问下载目录');
      return;
    }
    final localPath = '$downloadDir/${entry.name}';

    final item = _FtpDownloadingFile(
      name: entry.name,
      remotePath: entry.path,
      size: entry.size,
      localPath: localPath,
    );
    setState(() {
      _downloads.insert(0, item);
      _downloading = true;
      _error = null;
      _message = '开始下载 ${entry.name}';
    });

    try {
      await FtpUploadService.downloadFile(
        config: config,
        remotePath: entry.path,
        localPath: localPath,
      );
      if (!mounted) return;
      setState(() {
        item.status = _FtpDownloadStatus.done;
        _message = '${entry.name} 下载完成';
      });
    } catch (exc) {
      if (!mounted) return;
      setState(() {
        item.status = _FtpDownloadStatus.failed;
        item.error = _messageForError(exc);
        _error = '${entry.name} 下载失败：${_messageForError(exc)}';
      });
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  Future<String?> _getDownloadDirectory() async {
    try {
      // 优先使用 Android Download 目录
      final dir = await path_provider.getExternalStorageDirectories();
      if (dir != null && dir.isNotEmpty) {
        return dir.first.path;
      }
    } catch (_) {}
    try {
      final dir = await path_provider.getApplicationDocumentsDirectory();
      return dir.path;
    } catch (_) {}
    return null;
  }

  Widget _buildQueuePanel() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('上传队列', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            if (_queue.isEmpty)
              const EmptyState(message: '还没有选择文件')
            else
              for (final file in _queue) ...[
                _FtpQueueTile(
                  file: file,
                  onRetry: file.status == _FtpQueueStatus.failed
                      ? () => _retryFile(file)
                      : null,
                  onRemove: _uploading ? null : () => _removeFile(file),
                ),
                const SizedBox(height: 8),
              ],
          ],
        ),
      ),
    );
  }

  Widget _buildDownloadPanel() {
    if (_downloads.isEmpty) return const SizedBox.shrink();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('下载记录',
                      style: Theme.of(context).textTheme.titleMedium),
                ),
                TextButton(
                  onPressed: () => setState(() => _downloads.clear()),
                  child: const Text('清空'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            for (final item in _downloads) ...[
              _FtpDownloadTile(
                item: item,
                onRemove: () => setState(() => _downloads.remove(item)),
              ),
              const SizedBox(height: 8),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildBanner(String text, IconData icon, bool isError) {
    final color =
        isError ? Theme.of(context).colorScheme.error : GzusColors.green;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(GzusRadii.md),
        border: Border.all(color: color.withValues(alpha: 0.24)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color),
          const SizedBox(width: 8),
          Expanded(child: Text(text)),
          IconButton(
            onPressed: () => setState(() {
              _message = null;
              _error = null;
            }),
            icon: const Icon(Icons.close),
          ),
        ],
      ),
    );
  }

  bool get _canUpload =>
      _connected &&
      !_uploading &&
      _queue.any((f) =>
          f.status == _FtpQueueStatus.pending ||
          f.status == _FtpQueueStatus.failed);

  FtpConfig? _readConfig() {
    final host = _hostController.text.trim();
    final port = int.tryParse(_portController.text.trim());
    final username = _usernameController.text.trim();
    final password = _passwordController.text;
    if (host.isEmpty || port == null || username.isEmpty || password.isEmpty) {
      setState(() => _error = '请填写 FTP 服务器、端口、账号和密码');
      return null;
    }
    return FtpConfig(
      host: host,
      port: port,
      username: username,
      password: password,
      passiveMode: _passiveMode,
    );
  }

  Future<void> _loadSettings() async {
    final settings = await FtpUploadService.loadSettings();
    if (!mounted) return;
    setState(() {
      _hostController.text = settings.host;
      _portController.text = settings.port.toString();
      _usernameController.text = settings.username;
      _passwordController.text = settings.password;
      _passiveMode = settings.passiveMode;
      _currentDirectory = settings.lastDirectory;
      _settingsLoaded = true;
    });
  }

  Future<void> _saveSettings(FtpConfig config) async {
    await FtpUploadService.saveSettings(
      host: config.host,
      port: config.port,
      username: config.username,
      password: config.password,
      passiveMode: config.passiveMode,
      lastDirectory: _currentDirectory,
    );
  }

  Future<void> _testConnection() async {
    final config = _readConfig();
    if (config == null) return;
    setState(() {
      _testing = true;
      _error = null;
      _message = null;
    });
    try {
      await FtpUploadService.testConnection(config);
      await _saveSettings(config);
      if (!mounted) return;
      setState(() {
        _connected = true;
        _message = 'FTP 连接成功';
      });
      await _listCurrentDirectory();
    } catch (exc) {
      _handleFtpError(exc);
      if (mounted) setState(() => _connected = false);
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _listCurrentDirectory() async {
    final config = _readConfig();
    if (config == null) return;
    setState(() {
      _listing = true;
      _error = null;
    });
    try {
      final entries =
          await FtpUploadService.listDirectory(config, _currentDirectory);
      await _saveSettings(config);
      if (!mounted) return;
      setState(() {
        _connected = true;
        _entries = entries;
      });
    } catch (exc) {
      _handleFtpError(exc);
    } finally {
      if (mounted) setState(() => _listing = false);
    }
  }

  Future<void> _openDirectory(String path) async {
    setState(() => _currentDirectory = path.isEmpty ? '/' : path);
    await _listCurrentDirectory();
  }

  void _openParentDirectory() {
    final normalized =
        _currentDirectory.endsWith('/') && _currentDirectory.length > 1
            ? _currentDirectory.substring(0, _currentDirectory.length - 1)
            : _currentDirectory;
    final index = normalized.lastIndexOf('/');
    final parent = index <= 0 ? '/' : normalized.substring(0, index);
    _openDirectory(parent);
  }

  Future<void> _pickFiles() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      withData: false,
    );
    if (!mounted || result == null) return;
    final added = <_FtpQueuedFile>[];
    final rejected = <String>[];
    for (final file in result.files) {
      final path = file.path;
      if (path == null || path.isEmpty) {
        rejected.add(file.name);
        continue;
      }
      if (file.size > FtpUploadService.maxFileBytes) {
        rejected.add(file.name);
        continue;
      }
      added.add(_FtpQueuedFile(name: file.name, path: path, size: file.size));
    }
    setState(() {
      _queue.addAll(added);
      _message = added.isEmpty ? null : '已添加 ${added.length} 个文件';
      _error = rejected.isEmpty ? null : '${rejected.length} 个文件无法添加或超过 100 MB';
    });
  }

  Future<void> _uploadPendingFiles() async {
    final config = _readConfig();
    if (config == null) return;
    setState(() {
      _uploading = true;
      _error = null;
      _message = null;
    });
    for (final file in _queue.where((f) =>
        f.status == _FtpQueueStatus.pending ||
        f.status == _FtpQueueStatus.failed)) {
      await _uploadOne(config, file);
    }
    if (!mounted) return;
    setState(() {
      _uploading = false;
      _message = '上传队列处理完成';
    });
  }

  Future<void> _retryFile(_FtpQueuedFile file) async {
    final config = _readConfig();
    if (config == null) return;
    setState(() => _uploading = true);
    await _uploadOne(config, file);
    if (mounted) setState(() => _uploading = false);
  }

  Future<void> _uploadOne(FtpConfig config, _FtpQueuedFile file) async {
    if (!mounted) return;
    setState(() {
      file.status = _FtpQueueStatus.uploading;
      file.progress = 0.12;
      file.error = null;
    });
    try {
      await FtpUploadService.uploadFile(
        config: config,
        localPath: file.path,
        remoteDirectory: _currentDirectory,
      );
      if (!mounted) return;
      setState(() {
        file.status = _FtpQueueStatus.done;
        file.progress = 1;
      });
    } catch (exc) {
      if (!mounted) return;
      setState(() {
        file.status = _FtpQueueStatus.failed;
        file.progress = 0;
        file.error = _messageForError(exc);
      });
    }
  }

  void _removeFile(_FtpQueuedFile file) {
    setState(() => _queue.remove(file));
  }

  void _handleFtpError(Object exc) {
    if (!mounted) return;
    setState(() => _error = _messageForError(exc));
  }

  String _messageForError(Object exc) {
    if (exc is FtpUploadException) {
      switch (exc.code) {
        case 'AUTH_FAILED':
          return '登录失败，请检查 FTP 账号或密码';
        case 'NETWORK_ERROR':
          return '无法连接 FTP，请确认已连接学校内网或 VPN';
        case 'PERMISSION_DENIED':
          return '当前目录无权限，请更换目录';
        case 'FILE_NOT_FOUND':
          return '远程文件不存在或本地路径无效';
        case 'DOWNLOAD_FAILED':
          return '下载失败，请稍后重试';
        case 'UNSUPPORTED':
        case 'unsupported':
          return '当前平台不支持客户端 FTP';
        default:
          return exc.message;
      }
    }
    return 'FTP 操作失败，请稍后重试';
  }
}

class _FtpStatusCard extends StatelessWidget {
  const _FtpStatusCard({
    required this.title,
    required this.value,
    required this.detail,
    required this.icon,
    required this.color,
  });

  final String title;
  final String value;
  final String detail;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(GzusRadii.md),
              ),
              child: Icon(icon, color: color),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: Theme.of(context).textTheme.labelMedium),
                  const SizedBox(height: 2),
                  Text(value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium),
                  Text(detail,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FtpQueueTile extends StatelessWidget {
  const _FtpQueueTile({
    required this.file,
    this.onRetry,
    this.onRemove,
  });

  final _FtpQueuedFile file;
  final VoidCallback? onRetry;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final color = switch (file.status) {
      _FtpQueueStatus.done => GzusColors.green,
      _FtpQueueStatus.failed => Theme.of(context).colorScheme.error,
      _FtpQueueStatus.uploading => Theme.of(context).colorScheme.primary,
      _FtpQueueStatus.pending => Theme.of(context).colorScheme.onSurfaceVariant,
    };
    final label = switch (file.status) {
      _FtpQueueStatus.done => '完成',
      _FtpQueueStatus.failed => '失败',
      _FtpQueueStatus.uploading => '上传中',
      _FtpQueueStatus.pending => '待上传',
    };
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: gzusSurfaceSoft(context),
        borderRadius: BorderRadius.circular(GzusRadii.md),
        border: Border.all(color: gzusBorder(context)),
      ),
      child: Row(
        children: [
          Icon(Icons.insert_drive_file_outlined, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(file.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(
                    '${_formatFtpSize(file.size)} · $label${file.error == null ? '' : ' · ${file.error}'}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall),
                if (file.status == _FtpQueueStatus.uploading) ...[
                  const SizedBox(height: 8),
                  LinearProgressIndicator(value: file.progress),
                ],
              ],
            ),
          ),
          if (onRetry != null)
            IconButton(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              tooltip: '重试',
            ),
          if (onRemove != null)
            IconButton(
              onPressed: onRemove,
              icon: const Icon(Icons.close),
              tooltip: '移除',
            ),
        ],
      ),
    );
  }
}

class _FtpDownloadTile extends StatelessWidget {
  const _FtpDownloadTile({
    required this.item,
    this.onRemove,
  });

  final _FtpDownloadingFile item;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final color = switch (item.status) {
      _FtpDownloadStatus.done => GzusColors.green,
      _FtpDownloadStatus.failed => Theme.of(context).colorScheme.error,
      _FtpDownloadStatus.downloading => Theme.of(context).colorScheme.primary,
      _FtpDownloadStatus.pending =>
        Theme.of(context).colorScheme.onSurfaceVariant,
    };
    final label = switch (item.status) {
      _FtpDownloadStatus.done => '已下载',
      _FtpDownloadStatus.failed => '失败',
      _FtpDownloadStatus.downloading => '下载中',
      _FtpDownloadStatus.pending => '等待中',
    };
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: gzusSurfaceSoft(context),
        borderRadius: BorderRadius.circular(GzusRadii.md),
        border: Border.all(color: gzusBorder(context)),
      ),
      child: Row(
        children: [
          Icon(Icons.download_done, color: color, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(item.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(
                    '${_formatFtpSize(item.size)} · $label${item.error == null ? '' : ' · ${item.error}'}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          if (onRemove != null)
            IconButton(
              onPressed: onRemove,
              icon: const Icon(Icons.close, size: 18),
              tooltip: '移除',
            ),
        ],
      ),
    );
  }
}

String _formatFtpSize(int bytes) {
  if (bytes >= 1024 * 1024) {
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
  if (bytes >= 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
  return '$bytes B';
}

class AutoLeavePage extends StatefulWidget {
  const AutoLeavePage({
    super.key,
    required this.api,
    required this.year,
    required this.term,
    required this.firstWeekStart,
    this.onSessionExpired,
  });

  final ApiClient api;
  final int year;
  final int term;
  final DateTime firstWeekStart;
  final VoidCallback? onSessionExpired;

  @override
  State<AutoLeavePage> createState() => _AutoLeavePageState();
}

class _AutoLeavePageState extends State<AutoLeavePage> {
  late final TextEditingController _startController;
  late final TextEditingController _endController;
  final _reasonController = TextEditingController();
  PickedAttachment? _attachment;
  LeavePreviewResponse? _preview;
  LeaveFillResponse? _fillResult;
  final Map<String, StaffCandidateItem> _teacherSelections = {};
  String? _error;
  bool _loadingPreview = false;
  bool _filling = false;

  @override
  void initState() {
    super.initState();
    final today = _dateText(DateTime.now());
    _startController = TextEditingController(text: today);
    _endController = TextEditingController(text: today);
    _startController.addListener(_refreshLeaveFormState);
    _endController.addListener(_refreshLeaveFormState);
    _reasonController.addListener(_refreshLeaveFormState);
  }

  @override
  void dispose() {
    _startController.removeListener(_refreshLeaveFormState);
    _endController.removeListener(_refreshLeaveFormState);
    _reasonController.removeListener(_refreshLeaveFormState);
    _startController.dispose();
    _endController.dispose();
    _reasonController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final preview = _preview;
    final missing = preview?.hasMissingFields ?? false;
    return PagePanel(
      title: '自动请假',
      icon: Icons.fact_check,
      expandChild: true,
      child: RefreshIndicator(
        onRefresh: _loadPreview,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            AccentPanel(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final compact = constraints.maxWidth < 620;
                  final dateWidth = compact ? double.infinity : 160.0;
                  return Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      SizedBox(
                        width: dateWidth,
                        child: _DatePickerField(
                          controller: _startController,
                          labelText: '开始日期',
                          icon: Icons.event,
                        ),
                      ),
                      SizedBox(
                        width: dateWidth,
                        child: _DatePickerField(
                          controller: _endController,
                          labelText: '结束日期',
                          icon: Icons.event_available,
                        ),
                      ),
                      SizedBox(
                        width: compact ? double.infinity : 260,
                        child: TextField(
                          controller: _reasonController,
                          decoration: const InputDecoration(
                            labelText: '请假理由',
                            prefixIcon: Icon(Icons.edit_note, size: 18),
                          ),
                        ),
                      ),
                      OutlinedButton(
                        onPressed: _chooseAttachment,
                        child: _IconLabel(
                          icon: Icons.image,
                          label: _attachment?.name ?? '选择图片',
                        ),
                      ),
                      FilledButton(
                        onPressed: _loadingPreview ? null : _loadPreview,
                        child: _IconLabel(
                          icon: Icons.search,
                          label: _loadingPreview ? '匹配中...' : '匹配课程',
                        ),
                      ),
                      FilledButton.tonal(
                        onPressed: preview == null ||
                                missing ||
                                _attachment == null ||
                                _reasonController.text.trim().isEmpty ||
                                _filling
                            ? null
                            : _fillLeave,
                        child: _IconLabel(
                          icon: Icons.auto_fix_high,
                          label: _filling ? '生成中...' : '生成请假单',
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
            if (_fillResult != null) ...[
              const SizedBox(height: 10),
              _LeaveResultBanner(
                result: _fillResult!,
                api: widget.api,
                attachment: _attachment,
              ),
              if (_fillResult!.teacherCandidates.isNotEmpty) ...[
                const SizedBox(height: 10),
                _TeacherCandidateSelector(
                  result: _fillResult!,
                  selections: _teacherSelections,
                  confirming: _filling,
                  onSelected: (teacher, candidate) {
                    setState(() => _teacherSelections[teacher] = candidate);
                  },
                  onConfirm: () => _fillLeave(useTeacherSelections: true),
                ),
              ],
            ],
            const SizedBox(height: 12),
            if (preview == null)
              const SizedBox(
                height: 260,
                child: EmptyState(message: '填写信息后匹配受影响课程'),
              )
            else if (preview.items.isEmpty)
              const SizedBox(
                height: 260,
                child: EmptyState(message: '该时间段没有匹配到课程'),
              )
            else
              for (var i = 0; i < preview.items.length; i++) ...[
                _LeaveCourseTile(item: preview.items[i]),
                if (i != preview.items.length - 1) const SizedBox(height: 10),
              ],
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Future<void> _chooseAttachment() async {
    final picked = await pickLeaveAttachment();
    if (!mounted || picked == null) return;
    setState(() => _attachment = picked);
  }

  Future<void> _loadPreview() async {
    final range = _parseRange();
    if (range == null) return;
    setState(() {
      _loadingPreview = true;
      _error = null;
      _fillResult = null;
      _teacherSelections.clear();
    });
    try {
      final result = await widget.api.previewLeave(
        year: widget.year,
        term: widget.term,
        startDate: range.$1,
        endDate: range.$2,
        firstWeekStart: widget.firstWeekStart,
      );
      if (mounted) setState(() => _preview = result);
    } catch (exc) {
      _handleError(exc);
    } finally {
      if (mounted) setState(() => _loadingPreview = false);
    }
  }

  Future<void> _fillLeave({bool useTeacherSelections = false}) async {
    final range = _parseRange();
    final attachment = _attachment;
    if (range == null || attachment == null) return;
    final teacherHandlers = useTeacherSelections
        ? _teacherSelections.entries
            .map(
              (entry) => MatchedTeacherItem(
                teacher: entry.key,
                userid: entry.value.userid,
                cnName: entry.value.cnName,
              ),
            )
            .toList()
        : const <MatchedTeacherItem>[];
    setState(() {
      _filling = true;
      _error = null;
      _fillResult = null;
      if (!useTeacherSelections) _teacherSelections.clear();
    });
    try {
      final result = await widget.api.fillLeave(
        year: widget.year,
        term: widget.term,
        startDate: range.$1,
        endDate: range.$2,
        firstWeekStart: widget.firstWeekStart,
        reason: _reasonController.text.trim(),
        attachmentName: attachment.name,
        attachmentBytes: attachment.bytes,
        teacherHandlers: teacherHandlers,
      );
      if (mounted) setState(() => _fillResult = result);
    } catch (exc) {
      _handleError(exc);
    } finally {
      if (mounted) setState(() => _filling = false);
    }
  }

  void _refreshLeaveFormState() {
    if (mounted) setState(() {});
  }

  (DateTime, DateTime)? _parseRange() {
    final start = DateTime.tryParse(_startController.text.trim());
    final end = DateTime.tryParse(_endController.text.trim());
    if (start == null || end == null) {
      setState(() => _error = '日期格式应为 YYYY-MM-DD');
      return null;
    }
    if (end.isBefore(start)) {
      setState(() => _error = '结束日期不能早于开始日期');
      return null;
    }
    return (start, end);
  }

  void _handleError(Object exc) {
    // 不再在 401 时触发 onSessionExpired，_withFallback 已处理 relogin
    if (mounted) {
      setState(
          () => _error = exc is ApiException ? exc.message : exc.toString());
    }
  }
}

class _DatePickerField extends StatelessWidget {
  const _DatePickerField({
    required this.controller,
    this.labelText,
    this.icon = Icons.calendar_today,
  });

  final TextEditingController controller;
  final String? labelText;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      readOnly: true,
      onTap: () => _pickDate(context),
      decoration: InputDecoration(
        labelText: labelText,
        hintText: 'YYYY-MM-DD',
        prefixIcon: Icon(icon, size: 18),
        suffixIcon: const Icon(Icons.arrow_drop_down),
      ),
    );
  }

  Future<void> _pickDate(BuildContext context) async {
    final now = DateTime.now();
    final firstDate = DateTime(now.year - 6, 1, 1);
    final lastDate = DateTime(now.year + 6, 12, 31);
    final parsed = DateTime.tryParse(controller.text.trim());
    final initialDate = _boundedDate(parsed ?? now, firstDate, lastDate);
    final picked = await showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: firstDate,
      lastDate: lastDate,
    );
    if (picked != null) controller.text = _dateText(picked);
  }

  DateTime _boundedDate(DateTime value, DateTime firstDate, DateTime lastDate) {
    if (value.isBefore(firstDate)) return firstDate;
    if (value.isAfter(lastDate)) return lastDate;
    return value;
  }
}

class _LeaveCourseTile extends StatelessWidget {
  const _LeaveCourseTile({required this.item});

  final LeaveCourseItem item;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final missing = item.missingFields.isNotEmpty;
    return AccentPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  item.courseName,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              Text(
                '缺${item.absenceCount}',
                style:
                    TextStyle(color: cs.primary, fontWeight: FontWeight.w600),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              if (item.teacher != null)
                _InfoChip(icon: Icons.person, text: item.teacher!),
              if (item.courseCode != null)
                _InfoChip(icon: Icons.tag, text: item.courseCode!),
              if (item.teachingClassCode != null)
                _InfoChip(icon: Icons.groups, text: item.teachingClassCode!),
              if (item.courseNature != null)
                _InfoChip(icon: Icons.category, text: item.courseNature!),
              if (item.credit != null)
                _InfoChip(icon: Icons.star, text: '${item.credit}学分'),
            ],
          ),
          const SizedBox(height: 8),
          Text(item.classTime,
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13)),
          if (missing) ...[
            const SizedBox(height: 8),
            Text(
              '缺少：${item.missingFields.join('、')}',
              style: TextStyle(color: cs.error, fontSize: 13),
            ),
          ],
        ],
      ),
    );
  }
}

class _TeacherCandidateSelector extends StatelessWidget {
  const _TeacherCandidateSelector({
    required this.result,
    required this.selections,
    required this.confirming,
    required this.onSelected,
    required this.onConfirm,
  });

  final LeaveFillResponse result;
  final Map<String, StaffCandidateItem> selections;
  final bool confirming;
  final void Function(String teacher, StaffCandidateItem candidate) onSelected;
  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) {
    final groups = result.teacherCandidates;
    final allSelectable = groups.every((group) => group.candidates.isNotEmpty);
    final allSelected = allSelectable &&
        groups.every((group) => selections[group.teacher] != null);
    return AccentPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            '请选择任课教师经办人',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          for (final group in groups) ...[
            if (group.candidates.isEmpty)
              Text('${group.teacher}：未找到候选教师')
            else
              DropdownButtonFormField<String>(
                initialValue: selections[group.teacher]?.userid,
                decoration: InputDecoration(labelText: group.teacher),
                items: [
                  for (final candidate in group.candidates)
                    DropdownMenuItem(
                      value: candidate.userid,
                      child: Text(
                        candidate.folderName == null
                            ? candidate.cnName
                            : '${candidate.cnName} · ${candidate.folderName}',
                      ),
                    ),
                ],
                onChanged: (userid) {
                  if (userid == null) return;
                  final candidate = group.candidates.firstWhere(
                    (item) => item.userid == userid,
                  );
                  onSelected(group.teacher, candidate);
                },
              ),
            const SizedBox(height: 8),
          ],
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.tonal(
              onPressed: allSelected && !confirming ? onConfirm : null,
              child: Text(confirming ? '生成中...' : '生成经办人脚本'),
            ),
          ),
        ],
      ),
    );
  }
}

class _LeaveResultBanner extends StatelessWidget {
  const _LeaveResultBanner({
    required this.result,
    required this.api,
    required this.attachment,
  });

  final LeaveFillResponse result;
  final ApiClient api;
  final PickedAttachment? attachment;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final ok = result.status == 'filled';
    final script =
        result.unmatchedTeachers.isEmpty ? result.combinedScript : null;
    return AccentPanel(
      child: Row(
        children: [
          Icon(ok ? Icons.check_circle : Icons.info,
              color: ok ? cs.primary : cs.tertiary),
          const SizedBox(width: 10),
          Expanded(child: Text(result.message)),
          if (script != null)
            TextButton(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: script));
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('填表脚本已复制')),
                  );
                }
              },
              child: const Text('复制脚本'),
            ),
          if (result.formUrl != null)
            TextButton(
              onPressed: () async {
                await mobile_sso.loadLibrary();
                await mobile_sso.openAuthenticatedEhallUrl(
                  context,
                  result.formUrl!,
                  fillScript: script,
                  api: api,
                  attachmentName: attachment?.name,
                  attachmentBytes: attachment?.bytes,
                );
              },
              child: Text(script == null ? '打开' : '打开并填到提交前'),
            ),
        ],
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  const _InfoChip({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Chip(
      avatar: Icon(icon, size: 14),
      label: Text(text),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
  }
}

class _BusinessItemTile extends StatelessWidget {
  const _BusinessItemTile({required this.item});

  final EhallAffairItem item;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final inner = Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colorScheme.outlineVariant),
        color: colorScheme.surface,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _IconBadge(icon: Icons.apps, size: 32),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  item.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    if (item.department != null && item.department!.isNotEmpty)
                      _MetaText(item.department!),
                    if (item.type != null && item.type!.isNotEmpty)
                      _MetaText(item.type!),
                    for (final tag in item.tags.take(2)) _MetaText(tag),
                  ],
                ),
                if (item.summary != null && item.summary!.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    item.summary!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: colorScheme.onSurfaceVariant),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          Icon(Icons.open_in_new, size: 18, color: colorScheme.primary),
        ],
      ),
    );
    return _ScaleTap(
      onTap: () => _openInAppBrowser(context, item.url),
      borderRadius: BorderRadius.circular(8),
      child: inner,
    );
  }
}

Future<void> _openInAppBrowser(BuildContext context, String? url) async {
  if (url == null || url.isEmpty) return;
  await mobile_sso.loadLibrary();
  final opened = await mobile_sso.openAuthenticatedEhallUrl(context, url);
  if (!opened && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('无法打开链接')),
    );
  }
}

class ApplicationsPage extends StatefulWidget {
  const ApplicationsPage({super.key, required this.api, this.onSessionExpired});

  final ApiClient api;
  final VoidCallback? onSessionExpired;

  @override
  State<ApplicationsPage> createState() => _ApplicationsPageState();
}

class _ApplicationsPageState extends State<ApplicationsPage> {
  String _query = '';
  String _department = '全部';
  String _type = '全部';
  String _tag = '全部';
  bool _filtersExpanded = false;
  late Future<List<EhallApplicationItem>> _applicationsFuture;

  @override
  void initState() {
    super.initState();
    _applicationsFuture = _loadApplications();
  }

  @override
  void didUpdateWidget(covariant ApplicationsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.api != widget.api) {
      _applicationsFuture = _loadApplications();
    }
  }

  Future<List<EhallApplicationItem>> _loadApplications({
    bool forceRefresh = false,
  }) =>
      widget.api.ehallApplications(forceRefresh: forceRefresh);

  Future<void> _refreshApplications() async {
    setState(() => _applicationsFuture = _loadApplications(forceRefresh: true));
    await _applicationsFuture;
  }

  @override
  Widget build(BuildContext context) {
    return AsyncPanel<List<EhallApplicationItem>>(
      future: _applicationsFuture,
      emptyMessage: '暂无应用',
      onSessionExpired: widget.onSessionExpired,
      builder: (items) {
        final departments = _values(items.map((item) => item.department));
        final types = _values(items.map((item) => item.type));
        final tags = _values(items.expand((item) => item.tags));
        final filtered = items.where(_matches).toList();
        return PagePanel(
          title: '应用',
          icon: Icons.dashboard_customize,
          expandChild: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                onChanged: (value) => setState(() => _query = value),
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: '搜索应用',
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(22),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    InkWell(
                      onTap: () =>
                          setState(() => _filtersExpanded = !_filtersExpanded),
                      child: Row(
                        children: [
                          Icon(Icons.filter_list,
                              size: 18,
                              color: Theme.of(context).colorScheme.primary),
                          const SizedBox(width: 8),
                          const Expanded(
                            child: Text('筛选',
                                style: TextStyle(fontWeight: FontWeight.w700)),
                          ),
                          Icon(_filtersExpanded
                              ? Icons.expand_less
                              : Icons.expand_more),
                        ],
                      ),
                    ),
                    if (_filtersExpanded) ...[
                      const SizedBox(height: 10),
                      _ApplicationFilterChips(
                        label: '部门',
                        values: departments,
                        selected: _department,
                        onChanged: (value) =>
                            setState(() => _department = value),
                      ),
                      _ApplicationFilterChips(
                        label: '分类',
                        values: types,
                        selected: _type,
                        onChanged: (value) => setState(() => _type = value),
                      ),
                      _ApplicationFilterChips(
                        label: '标签',
                        values: tags,
                        selected: _tag,
                        onChanged: (value) => setState(() => _tag = value),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '共 ${filtered.length} 个应用',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 10),
              Expanded(
                child: PageRefresh(
                  onRefresh: _refreshApplications,
                  child: filtered.isEmpty
                      ? ListView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          children: const [
                            SizedBox(height: 120),
                            EmptyState(message: '没有匹配的应用'),
                          ],
                        )
                      : LayoutBuilder(
                          builder: (context, constraints) {
                            final columns = _contentGridColumns(
                              constraints.maxWidth,
                              minTileWidth: 170,
                              maxColumns: 4,
                            );
                            return GridView.builder(
                              physics: const AlwaysScrollableScrollPhysics(),
                              gridDelegate:
                                  SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: columns,
                                crossAxisSpacing: 10,
                                mainAxisSpacing: 10,
                                childAspectRatio: columns == 1 ? 3.4 : 1.35,
                              ),
                              itemCount: filtered.length,
                              itemBuilder: (context, index) =>
                                  _ApplicationItemTile(item: filtered[index]),
                            );
                          },
                        ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  bool _matches(EhallApplicationItem item) {
    final query = _query.trim().toLowerCase();
    final searchable = [
      item.title,
      item.department ?? '',
      item.type ?? '',
      item.summary ?? '',
      ...item.tags,
    ].join(' ').toLowerCase();
    return (_department == '全部' || item.department == _department) &&
        (_type == '全部' || item.type == _type) &&
        (_tag == '全部' || item.tags.contains(_tag)) &&
        (query.isEmpty || searchable.contains(query));
  }

  List<String> _values(Iterable<String?> values) {
    final result = values
        .map((value) => value?.trim())
        .where((value) => value != null && value.isNotEmpty)
        .cast<String>()
        .toSet()
        .toList()
      ..sort();
    return ['全部', ...result];
  }
}

int _contentGridColumns(
  double width, {
  required double minTileWidth,
  int maxColumns = 4,
}) {
  if (width < minTileWidth * 1.6) return 1;
  return (width / minTileWidth).floor().clamp(2, maxColumns);
}

class _ApplicationFilterChips extends StatelessWidget {
  const _ApplicationFilterChips({
    required this.label,
    required this.values,
    required this.selected,
    required this.onChanged,
  });

  final String label;
  final List<String> values;
  final String selected;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    if (values.length <= 1) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (var index = 0; index < values.length; index++)
            ChoiceChip(
              label: Text(index == 0 ? '$label: 全部' : values[index]),
              selected: selected == values[index],
              onSelected: (_) => onChanged(values[index]),
            ),
        ],
      ),
    );
  }
}

class _ApplicationItemTile extends StatelessWidget {
  const _ApplicationItemTile({required this.item});

  final EhallApplicationItem item;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final inner = Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colorScheme.outlineVariant),
        color: colorScheme.surface,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _IconBadge(icon: Icons.dashboard_customize, size: 32),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  item.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    if (item.department != null && item.department!.isNotEmpty)
                      _MetaText(item.department!),
                    if (item.type != null && item.type!.isNotEmpty)
                      _MetaText(item.type!),
                    for (final tag in item.tags.take(2)) _MetaText(tag),
                  ],
                ),
                if (item.summary != null && item.summary!.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    item.summary!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: colorScheme.onSurfaceVariant),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          Icon(Icons.open_in_new, size: 18, color: colorScheme.primary),
        ],
      ),
    );
    return _ScaleTap(
      onTap: () => _openInAppBrowser(context, item.url),
      borderRadius: BorderRadius.circular(8),
      child: inner,
    );
  }
}

String _noticeItemTitle(NoticeItem item) {
  final value = item.title.trim();
  return value.isEmpty ? '未命名通知' : value;
}

String _noticeDetailTitle(NoticeItem item, NoticeDetail detail) {
  final value = detail.title.trim();
  return value.isEmpty ? _noticeItemTitle(item) : value;
}

class NoticesPage extends StatefulWidget {
  const NoticesPage({super.key, required this.api, this.onSessionExpired});

  final ApiClient api;
  final VoidCallback? onSessionExpired;

  @override
  State<NoticesPage> createState() => _NoticesPageState();
}

class _NoticesPageState extends State<NoticesPage> {
  int? _selectedIndex;
  late Future<List<NoticeItem>> _noticesFuture;

  @override
  void initState() {
    super.initState();
    _noticesFuture = _loadNotices();
  }

  @override
  void didUpdateWidget(covariant NoticesPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.api != widget.api) {
      _noticesFuture = _loadNotices();
    }
  }

  Future<List<NoticeItem>> _loadNotices({bool forceRefresh = false}) =>
      widget.api.notices(forceRefresh: forceRefresh).then((r) => r.data);

  Future<void> _refreshNotices() async {
    setState(() => _noticesFuture = _loadNotices(forceRefresh: true));
    final items = await _noticesFuture;
    if (mounted && _selectedIndex != null && _selectedIndex! >= items.length) {
      setState(() => _selectedIndex = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PageRefresh(
      onRefresh: _refreshNotices,
      child: AsyncPanel<List<NoticeItem>>(
        future: _noticesFuture,
        emptyMessage: '暂无通知',
        onSessionExpired: widget.onSessionExpired,
        builder: (items) => LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 720;
            if (wide) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 350,
                    child: PagePanel(
                      title: '通知',
                      icon: Icons.info_outline,
                      expandChild: true,
                      child: ListView.separated(
                        physics: const AlwaysScrollableScrollPhysics(),
                        itemCount: items.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 10),
                        itemBuilder: (context, index) => GestureDetector(
                          onTap: () => setState(() => _selectedIndex = index),
                          child: Container(
                            decoration: _selectedIndex == index
                                ? BoxDecoration(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .primaryContainer,
                                    borderRadius: BorderRadius.circular(8),
                                  )
                                : null,
                            child: NoticeCard(item: items[index]),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: PagePanel(
                      title: _selectedIndex != null
                          ? _noticeItemTitle(items[_selectedIndex!])
                          : '通知详情',
                      icon: Icons.article,
                      expandChild: true,
                      child: _selectedIndex != null
                          ? _NoticeDetailContent(
                              api: widget.api,
                              item: items[_selectedIndex!],
                              onSessionExpired: widget.onSessionExpired,
                            )
                          : const Center(child: Text('请选择一条通知查看详情')),
                    ),
                  ),
                ],
              );
            }
            return PagePanel(
              title: '通知',
              icon: Icons.info_outline,
              expandChild: true,
              child: ListView.separated(
                physics: const AlwaysScrollableScrollPhysics(),
                itemCount: items.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (context, index) => NoticeCard(item: items[index]),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _NoticeDetailContent extends StatefulWidget {
  const _NoticeDetailContent(
      {required this.api, required this.item, this.onSessionExpired});
  final ApiClient api;
  final NoticeItem item;
  final VoidCallback? onSessionExpired;

  @override
  State<_NoticeDetailContent> createState() => _NoticeDetailContentState();
}

class _NoticeDetailContentState extends State<_NoticeDetailContent> {
  late Future<NoticeDetail> _detailFuture;

  @override
  void initState() {
    super.initState();
    _loadDetail();
  }

  @override
  void didUpdateWidget(covariant _NoticeDetailContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.url != widget.item.url) _loadDetail();
  }

  void _loadDetail() {
    if (widget.item.url != null && widget.item.url!.isNotEmpty) {
      _detailFuture =
          widget.api.fetchNoticeDetail(widget.item.url!).then((r) => r.data);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.item.url == null || widget.item.url!.isEmpty) {
      return SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _noticeItemTitle(widget.item),
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                    height: 1.25,
                  ),
            ),
            const SizedBox(height: 10),
            if (widget.item.date != null)
              Text(widget.item.date!,
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontSize: 13)),
            const SizedBox(height: 12),
            if (widget.item.summary != null && widget.item.summary!.isNotEmpty)
              Text(widget.item.summary!,
                  style: const TextStyle(fontSize: 15, height: 1.6))
            else
              const Text('暂无详情内容'),
          ],
        ),
      );
    }
    return FutureBuilder<NoticeDetail>(
      future: _detailFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Center(child: Text('加载失败: ${snapshot.error}'));
        }
        final detail = snapshot.data!;
        final title = _noticeDetailTitle(widget.item, detail);
        return SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                      height: 1.25,
                    ),
              ),
              const SizedBox(height: 10),
              if (detail.date != null)
                Text(detail.date!,
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        fontSize: 13)),
              const SizedBox(height: 8),
              Text(detail.contentHtml.replaceAll(RegExp(r'<[^>]*>'), ''),
                  style: const TextStyle(fontSize: 15, height: 1.6)),
            ],
          ),
        );
      },
    );
  }
}

class NoticeCard extends StatelessWidget {
  const NoticeCard({super.key, required this.item});

  final NoticeItem item;

  String get _title {
    return _noticeItemTitle(item);
  }

  String? get _summary {
    final value = item.summary?.trim();
    if (value == null || value.isEmpty || value == _title) return null;
    return value;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final summary = _summary;
    final hasUrl = item.url != null && item.url!.isNotEmpty;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _IconBadge(icon: Icons.info_outline, size: 32),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _title,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium?.copyWith(
                              color: colorScheme.onSurface,
                              fontWeight: FontWeight.w800,
                              height: 1.25,
                            ) ??
                            TextStyle(
                              color: colorScheme.onSurface,
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                              height: 1.25,
                            ),
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          _MetaText(item.category),
                          if (item.date != null) _MetaText(item.date!),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (summary != null) ...[
              const SizedBox(height: 8),
              Text(
                summary,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: colorScheme.onSurfaceVariant),
              ),
            ],
            if (hasUrl) ...[
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.tonalIcon(
                  onPressed: () => _openInAppBrowser(context, item.url),
                  icon: const Icon(Icons.open_in_new, size: 18),
                  label: const Text('打开通知'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _MetaText extends StatelessWidget {
  const _MetaText(this.value);

  final String value;

  @override
  Widget build(BuildContext context) {
    return Text(
      value,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 12,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }
}

class SchedulePage extends StatefulWidget {
  const SchedulePage({
    super.key,
    required this.api,
    required this.year,
    required this.term,
    required this.currentWeek,
    required this.firstWeekStart,
    required this.autoWeek,
    required this.onFirstWeekChanged,
    required this.onCurrentWeekChanged,
    required this.onAutoWeekChanged,
    this.onSessionExpired,
  });

  final ApiClient api;
  final int year;
  final int term;
  final int currentWeek;
  final DateTime firstWeekStart;
  final bool autoWeek;
  final ValueChanged<DateTime> onFirstWeekChanged;
  final ValueChanged<int> onCurrentWeekChanged;
  final ValueChanged<bool> onAutoWeekChanged;
  final VoidCallback? onSessionExpired;

  @override
  State<SchedulePage> createState() => _SchedulePageState();
}

class _SchedulePageState extends State<SchedulePage> {
  late final TextEditingController firstWeekController;
  late Future<ScheduleResult> _scheduleFuture;
  ScheduleViewMode _viewMode = ScheduleViewMode.today;
  bool showJson = false;
  bool showAllCourses = false;
  bool courseRemindersEnabled = false;
  int courseStartReminderMinutes = 10;
  int courseEndReminderMinutes = 5;
  bool _exporting = false;
  String? manageError;

  @override
  void initState() {
    super.initState();
    firstWeekController =
        TextEditingController(text: _dateText(widget.firstWeekStart));
    _scheduleFuture = _loadSchedule();
    _loadReminderSettings();
  }

  @override
  void didUpdateWidget(covariant SchedulePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.api != widget.api ||
        oldWidget.year != widget.year ||
        oldWidget.term != widget.term) {
      _scheduleFuture = _loadSchedule();
    }
    final next = _dateText(widget.firstWeekStart);
    if (firstWeekController.text != next) firstWeekController.text = next;
  }

  Future<ScheduleResult> _loadSchedule({bool forceRefresh = false}) =>
      widget.api
          .schedule(
            year: widget.year,
            term: widget.term,
            forceRefresh: forceRefresh,
          )
          .then((r) => r.data);

  Future<void> _refreshSchedule() async {
    setState(() => _scheduleFuture = _loadSchedule(forceRefresh: true));
    await _scheduleFuture;
  }

  Future<void> _syncCourseRemindersToNative(
    List<ScheduleCourse> courses,
    int beforeStartMinutes,
    int beforeEndMinutes,
    DateTime firstWeekStart,
  ) async {
    final coursesList = courses.map((c) {
      final weeksList = <int>[];
      for (var w = 1; w <= 30; w++) {
        if (c.occursInWeek(w)) weeksList.add(w);
      }
      return {
        'name': c.name,
        'weekday': c.weekday ?? 0,
        'startSection': c.startSection ?? 0,
        'endSection': c.endSection ?? 0,
        'classroom': c.classroom ?? '',
        'teacher': c.teacher ?? '',
        'weeks': weeksList,
      };
    }).toList();
    final coursesJson = jsonEncode(coursesList);
    final firstWeekStr =
        '${firstWeekStart.year.toString().padLeft(4, '0')}-${firstWeekStart.month.toString().padLeft(2, '0')}-${firstWeekStart.day.toString().padLeft(2, '0')}';
    await background_service.loadLibrary();
    await background_service.BackgroundService.updateCourseReminders(
      coursesJson: coursesJson,
      beforeStartMinutes: beforeStartMinutes,
      beforeEndMinutes: beforeEndMinutes,
      firstWeekStart: firstWeekStr,
    );
  }

  @override
  void dispose() {
    firstWeekController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PageRefresh(
      onRefresh: _refreshSchedule,
      child: AsyncPanel<ScheduleResult>(
        future: _scheduleFuture,
        onSessionExpired: widget.onSessionExpired,
        builder: (result) {
          final weekItems = result.items
              .where((item) => item.occursInWeek(widget.currentWeek))
              .toList();
          final todayItems = weekItems
              .where((item) => item.weekday == DateTime.now().weekday)
              .toList()
            ..sort(_compareScheduleCourses);
          final displayItems =
              _viewMode == ScheduleViewMode.all ? result.items : weekItems;
          reminder_service.loadLibrary().then((_) {
            reminder_service.ReminderService.configureCourseReminders(
              courses: result.items,
              firstWeekStart: widget.firstWeekStart,
              settings: reminder_service.CourseReminderSettings(
                enabled: courseRemindersEnabled,
                beforeStartMinutes: courseStartReminderMinutes,
                beforeEndMinutes: courseEndReminderMinutes,
              ),
            );
          });
          // Sync course data to native Android layer for background reminders
          unawaited(_syncCourseRemindersToNative(
            result.items,
            courseStartReminderMinutes,
            courseEndReminderMinutes,
            widget.firstWeekStart,
          ));
          return PagePanel(
            title: '课表',
            icon: Icons.calendar_month,
            expandChild: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _ScheduleSummaryPanel(
                  currentWeek: widget.currentWeek,
                  firstWeekStart: widget.firstWeekStart,
                  todayCount: todayItems.length,
                  weekCount: weekItems.length,
                  totalCount: result.items.length,
                  nextCourse: _nextScheduleCourse(todayItems),
                ),
                const SizedBox(height: 10),
                _ScheduleViewSwitch(
                  selected: _viewMode,
                  onChanged: (mode) {
                    setState(() {
                      _viewMode = mode;
                      showAllCourses = mode == ScheduleViewMode.all;
                    });
                  },
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: _ScheduleToolsChip(
                    onPressed: () =>
                        _showScheduleTools(result.prettyJson, result.items),
                  ),
                ),
                const SizedBox(height: 10),
                if (result.items.isEmpty)
                  Expanded(
                    child: ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: const [
                        SizedBox(
                          height: 260,
                          child: EmptyState(message: '当前学期暂无课表'),
                        ),
                      ],
                    ),
                  )
                else if (displayItems.isEmpty)
                  Expanded(
                    child: ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: [
                        SizedBox(
                          height: 260,
                          child: EmptyState(
                              message: '第${widget.currentWeek}周暂无课程'),
                        ),
                      ],
                    ),
                  )
                else
                  Expanded(
                    child: ScheduleReadableView(
                      mode: _viewMode,
                      todayItems: todayItems,
                      weekItems: weekItems,
                      allItems: result.items,
                    ),
                  ),
                if (showJson) ...[
                  const SizedBox(height: 10),
                  Flexible(child: JsonPanel(json: result.prettyJson)),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  void _showScheduleTools(String prettyJson, List<ScheduleCourse> items) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, localSetState) {
          final compact = MediaQuery.sizeOf(context).width < 600;
          final colorScheme = Theme.of(context).colorScheme;
          return SafeArea(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * 0.78,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 顶部拖拽指示条
                  Padding(
                    padding: const EdgeInsets.only(top: 12, bottom: 4),
                    child: Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: colorScheme.onSurfaceVariant
                            .withValues(alpha: 0.25),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  // 标题行
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                      compact ? 18 : 24,
                      8,
                      compact ? 18 : 24,
                      0,
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 34,
                          height: 34,
                          decoration: BoxDecoration(
                            color: _accentFill(context),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Icon(Icons.tune,
                              size: 18, color: colorScheme.primary),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            '课表工具',
                            style: Theme.of(context)
                                .textTheme
                                .titleLarge
                                ?.copyWith(fontWeight: FontWeight.w800),
                          ),
                        ),
                        IconButton(
                          onPressed: () => Navigator.pop(sheetContext),
                          icon: const Icon(Icons.close, size: 20),
                          style: IconButton.styleFrom(
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 20, indent: 18, endIndent: 18),
                  // 内容区
                  Flexible(
                    child: SingleChildScrollView(
                      padding: EdgeInsets.fromLTRB(
                        compact ? 18 : 24,
                        0,
                        compact ? 18 : 24,
                        20,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // 快捷操作区
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              TextButton(
                                onPressed: () {
                                  setState(() {
                                    showAllCourses = !showAllCourses;
                                    _viewMode = showAllCourses
                                        ? ScheduleViewMode.all
                                        : ScheduleViewMode.week;
                                  });
                                  localSetState(() {});
                                },
                                child: _IconLabel(
                                  icon: Icons.visibility,
                                  label: showAllCourses ? '仅本周' : '全部课程',
                                ),
                              ),
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const _IconLabel(
                                    icon: Icons.notifications_active,
                                    label: '上下课提醒',
                                  ),
                                  Switch(
                                    value: courseRemindersEnabled,
                                    onChanged: (value) {
                                      _setCourseRemindersEnabled(value);
                                      localSetState(() {});
                                    },
                                  ),
                                ],
                              ),
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const _IconLabel(
                                    icon: Icons.code,
                                    label: 'JSON',
                                  ),
                                  Switch(
                                    value: showJson,
                                    onChanged: (value) {
                                      setState(() => showJson = value);
                                      localSetState(() {});
                                    },
                                  ),
                                ],
                              ),
                              TextButton(
                                onPressed: items.isEmpty || _exporting
                                    ? null
                                    : () async {
                                        setState(() => _exporting = true);
                                        localSetState(() {});
                                        try {
                                          final ics = generateIcs(
                                            courses: items,
                                            firstWeekStart:
                                                widget.firstWeekStart,
                                            year: widget.year,
                                            term: widget.term,
                                          );
                                          final filename =
                                              '课表_${widget.year}_${widget.term}.ics';
                                          if (kIsWeb) {
                                            await ics_download.loadLibrary();
                                            await ics_download.downloadIcs(ics, filename);
                                          } else {
                                            await Share.shareXFiles(
                                              [
                                                XFile.fromData(
                                                  Uint8List.fromList(
                                                      utf8.encode(ics)),
                                                  name: filename,
                                                  mimeType: 'text/calendar',
                                                ),
                                              ],
                                              text: filename,
                                            );
                                          }
                                        } finally {
                                          if (mounted) {
                                            setState(() => _exporting = false);
                                          }
                                          try {
                                            localSetState(() {});
                                          } catch (_) {}
                                        }
                                      },
                                child: _IconLabel(
                                  icon: Icons.download,
                                  label: _exporting ? '导出中...' : '导出 ICS',
                                ),
                              ),
                              TextButton(
                                onPressed: items.isEmpty || _exporting
                                    ? null
                                    : () async {
                                        setState(() => _exporting = true);
                                        localSetState(() {});
                                        try {
                                          final ics = generateIcs(
                                            courses: items,
                                            firstWeekStart:
                                                widget.firstWeekStart,
                                            year: widget.year,
                                            term: widget.term,
                                          );
                                          final filename =
                                              '课表_${widget.year}_${widget.term}.ics';
                                          if (kIsWeb) {
                                            await ics_download.loadLibrary();
                                            await ics_download.downloadIcs(ics, filename);
                                          } else {
                                            await Share.shareXFiles(
                                              [
                                                XFile.fromData(
                                                  Uint8List.fromList(
                                                      utf8.encode(ics)),
                                                  name: filename,
                                                  mimeType: 'text/calendar',
                                                ),
                                              ],
                                              text: filename,
                                            );
                                          }
                                        } finally {
                                          if (mounted) {
                                            setState(() => _exporting = false);
                                          }
                                          try {
                                            localSetState(() {});
                                          } catch (_) {}
                                        }
                                      },
                                child: const _IconLabel(
                                  icon: Icons.event_available,
                                  label: '一键导入日历',
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          ScheduleInlineManage(
                            firstWeekController: firstWeekController,
                            firstWeekStart: widget.firstWeekStart,
                            currentWeek: widget.currentWeek,
                            autoWeek: widget.autoWeek,
                            error: manageError,
                            onAutoWeekChanged: (value) {
                              widget.onAutoWeekChanged(value);
                              localSetState(() {});
                            },
                            onCurrentWeekChanged: (value) {
                              widget.onCurrentWeekChanged(value);
                              localSetState(() {});
                            },
                            onSaveFirstWeek: () {
                              _saveFirstWeek();
                              localSetState(() {});
                            },
                            onUseCurrentWeek: () {
                              firstWeekController.text =
                                  _dateText(_mondayOf(DateTime.now()));
                              _saveFirstWeek();
                              localSetState(() {});
                            },
                          ),
                          if (showJson) ...[
                            const SizedBox(height: 12),
                            JsonPanel(json: prettyJson),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _saveFirstWeek() {
    final parsed = DateTime.tryParse(firstWeekController.text.trim());
    if (parsed == null) {
      setState(() => manageError = '日期格式应为 YYYY-MM-DD');
      return;
    }
    setState(() => manageError = null);
    widget.onFirstWeekChanged(parsed);
  }

  Future<void> _loadReminderSettings() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      courseRemindersEnabled =
          prefs.getBool('schedule.courseRemindersEnabled') ?? false;
      courseStartReminderMinutes =
          prefs.getInt('schedule.courseStartReminderMinutes') ?? 10;
      courseEndReminderMinutes =
          prefs.getInt('schedule.courseEndReminderMinutes') ?? 5;
    });
  }

  Future<void> _setCourseRemindersEnabled(bool value) async {
    setState(() => courseRemindersEnabled = value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('schedule.courseRemindersEnabled', value);
    if (!value) {
      reminder_service.loadLibrary().then((_) {
        reminder_service.ReminderService.cancelCourseReminders();
      });
    }
  }
}

/// 课表工具按钮 — 放在 PagePanel 标题栏右侧的 chip 风格按钮
class _ScheduleToolsChip extends StatelessWidget {
  const _ScheduleToolsChip({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final compact = MediaQuery.sizeOf(context).width < 600;
    return Material(
      key: const ValueKey('schedule-tools-button'),
      color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.72),
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onPressed,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 10 : 14,
            vertical: compact ? 6 : 8,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.tune, size: 16, color: colorScheme.primary),
              SizedBox(width: compact ? 4 : 6),
              Text(
                '工具',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: colorScheme.primary,
                      fontWeight: FontWeight.w700,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ScheduleInlineManage extends StatelessWidget {
  const ScheduleInlineManage({
    super.key,
    required this.firstWeekController,
    required this.firstWeekStart,
    required this.currentWeek,
    required this.autoWeek,
    required this.error,
    required this.onAutoWeekChanged,
    required this.onCurrentWeekChanged,
    required this.onSaveFirstWeek,
    required this.onUseCurrentWeek,
  });

  final TextEditingController firstWeekController;
  final DateTime firstWeekStart;
  final int currentWeek;
  final bool autoWeek;
  final String? error;
  final ValueChanged<bool> onAutoWeekChanged;
  final ValueChanged<int> onCurrentWeekChanged;
  final VoidCallback onSaveFirstWeek;
  final VoidCallback onUseCurrentWeek;

  @override
  Widget build(BuildContext context) {
    final autoWeekValue = _weekFromDate(firstWeekStart, DateTime.now());
    final compact = MediaQuery.sizeOf(context).width < 600;
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: EdgeInsets.all(compact ? 14 : 16),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '第一周与周次',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: firstWeekController,
            keyboardType: TextInputType.datetime,
            decoration: const InputDecoration(
              labelText: '第一周周一',
              hintText: 'YYYY-MM-DD',
              prefixIcon: Icon(Icons.calendar_month),
            ),
            onSubmitted: (_) => onSaveFirstWeek(),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              FilledButton(
                onPressed: onSaveFirstWeek,
                child: const _IconLabel(
                  icon: Icons.save,
                  label: '保存第一周',
                ),
              ),
              OutlinedButton(
                onPressed: onUseCurrentWeek,
                child: const _IconLabel(
                  icon: Icons.access_time,
                  label: '今天所在周设为第1周',
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: _IconLabel(
                  icon: Icons.schedule,
                  label: '自动计算：第$autoWeekValue周',
                ),
              ),
              Switch(value: autoWeek, onChanged: onAutoWeekChanged),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: DropdownMenu<int>(
              initialSelection: currentWeek,
              width: compact ? MediaQuery.sizeOf(context).width - 96 : 260,
              enableSearch: false,
              requestFocusOnTap: false,
              onSelected: autoWeek
                  ? null
                  : (value) {
                      if (value != null) onCurrentWeekChanged(value);
                    },
              dropdownMenuEntries: [
                for (var week = 1; week <= 30; week++)
                  DropdownMenuEntry(value: week, label: '第$week周'),
              ],
            ),
          ),
          if (error != null) ...[
            const SizedBox(height: 8),
            Text(error!, style: TextStyle(color: colorScheme.error)),
          ],
        ],
      ),
    );
  }
}

enum ScheduleViewMode { today, week, all }

class _ScheduleSummaryPanel extends StatelessWidget {
  const _ScheduleSummaryPanel({
    required this.currentWeek,
    required this.firstWeekStart,
    required this.todayCount,
    required this.weekCount,
    required this.totalCount,
    required this.nextCourse,
  });

  final int currentWeek;
  final DateTime firstWeekStart;
  final int todayCount;
  final int weekCount;
  final int totalCount;
  final ScheduleCourse? nextCourse;

  @override
  Widget build(BuildContext context) {
    final nextText = nextCourse == null
        ? '今日无后续课程'
        : '${_scheduleTimeText(nextCourse!)} · ${nextCourse!.name}';
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(context)
            .colorScheme
            .primaryContainer
            .withValues(alpha: 0.28),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: Theme.of(context)
                      .colorScheme
                      .primary
                      .withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(15),
                ),
                child: Icon(Icons.calendar_month,
                    color: Theme.of(context).colorScheme.primary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '第$currentWeek周课表',
                      style: Theme.of(context)
                          .textTheme
                          .titleLarge
                          ?.copyWith(fontWeight: FontWeight.w900),
                    ),
                    Text(
                      nextText,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _MetricPill(
                  icon: Icons.today,
                  label: '今日',
                  value: '$todayCount节',
                  dense: true),
              _MetricPill(
                  icon: Icons.view_week,
                  label: '本周',
                  value: '$weekCount节',
                  dense: true),
              _MetricPill(
                  icon: Icons.list,
                  label: '全部',
                  value: '$totalCount门',
                  dense: true),
              _MetricPill(
                icon: Icons.access_time,
                label: '首周',
                value: _dateText(firstWeekStart),
                dense: true,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ScheduleViewSwitch extends StatelessWidget {
  const _ScheduleViewSwitch({required this.selected, required this.onChanged});

  final ScheduleViewMode selected;
  final ValueChanged<ScheduleViewMode> onChanged;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<ScheduleViewMode>(
      key: const ValueKey('schedule-view-mode'),
      showSelectedIcon: false,
      segments: const [
        ButtonSegment(
            value: ScheduleViewMode.today,
            icon: Icon(Icons.today),
            label: Text('今日')),
        ButtonSegment(
            value: ScheduleViewMode.week,
            icon: Icon(Icons.view_week),
            label: Text('本周')),
        ButtonSegment(
            value: ScheduleViewMode.all,
            icon: Icon(Icons.format_list_bulleted),
            label: Text('全部')),
      ],
      selected: {selected},
      onSelectionChanged: (values) => onChanged(values.single),
    );
  }
}

class ScheduleReadableView extends StatelessWidget {
  const ScheduleReadableView({
    super.key,
    required this.mode,
    required this.todayItems,
    required this.weekItems,
    required this.allItems,
  });

  final ScheduleViewMode mode;
  final List<ScheduleCourse> todayItems;
  final List<ScheduleCourse> weekItems;
  final List<ScheduleCourse> allItems;

  @override
  Widget build(BuildContext context) {
    switch (mode) {
      case ScheduleViewMode.today:
        return _TodayReadableSchedule(items: todayItems);
      case ScheduleViewMode.week:
        if (MediaQuery.sizeOf(context).width < 600) {
          return _WeekReadableSchedule(items: weekItems);
        }
        return TimetableView(items: weekItems);
      case ScheduleViewMode.all:
        return _AllReadableSchedule(items: allItems);
    }
  }
}

class _TodayReadableSchedule extends StatelessWidget {
  const _TodayReadableSchedule({required this.items});

  final List<ScheduleCourse> items;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [
          SizedBox(height: 260, child: EmptyState(message: '今天暂无课程')),
        ],
      );
    }
    final sorted = [...items]..sort(_compareScheduleCourses);
    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: sorted.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, index) =>
          _ScheduleCourseTile(course: sorted[index]),
    );
  }
}

class _WeekReadableSchedule extends StatelessWidget {
  const _WeekReadableSchedule({required this.items});

  final List<ScheduleCourse> items;

  @override
  Widget build(BuildContext context) {
    final byDay = <int, List<ScheduleCourse>>{
      for (var day = 1; day <= 7; day++) day: <ScheduleCourse>[],
    };
    for (final item in items) {
      final weekday = item.weekday;
      if (weekday != null && weekday >= 1 && weekday <= 7) {
        byDay[weekday]!.add(item);
      }
    }
    for (final list in byDay.values) {
      list.sort(_compareScheduleCourses);
    }
    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: 7,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final day = index + 1;
        final courses = byDay[day]!;
        return Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(18),
            border:
                Border.all(color: Theme.of(context).colorScheme.outlineVariant),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Text(_scheduleWeekdayText(day),
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontWeight: FontWeight.w900)),
                  const Spacer(),
                  Text(courses.isEmpty ? '无课' : '${courses.length}节',
                      style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
              if (courses.isNotEmpty) ...[
                const SizedBox(height: 10),
                for (final course in courses)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _CompactScheduleCourseTile(course: course),
                  ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _AllReadableSchedule extends StatelessWidget {
  const _AllReadableSchedule({required this.items});

  final List<ScheduleCourse> items;

  @override
  Widget build(BuildContext context) {
    final grouped = <String, List<ScheduleCourse>>{};
    for (final item in items) {
      grouped.putIfAbsent(item.name, () => []).add(item);
    }
    final names = grouped.keys.toList()..sort();
    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: names.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final name = names[index];
        final courses = grouped[name]!..sort(_compareScheduleCourses);
        return Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(18),
            border:
                Border.all(color: Theme.of(context).colorScheme.outlineVariant),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  _CourseColorMark(name: name),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context)
                            .textTheme
                            .titleMedium
                            ?.copyWith(fontWeight: FontWeight.w900)),
                  ),
                  Text('${courses.length}条',
                      style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
              const SizedBox(height: 10),
              for (final course in courses)
                _CompactScheduleCourseTile(course: course),
            ],
          ),
        );
      },
    );
  }
}

class _ScheduleCourseTile extends StatelessWidget {
  const _ScheduleCourseTile({required this.course});

  final ScheduleCourse course;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () => _showReadableScheduleDetails(context, course),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border:
                Border.all(color: Theme.of(context).colorScheme.outlineVariant),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 5,
                height: 76,
                decoration: BoxDecoration(
                  color: _scheduleCourseColor(course.name),
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 82,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_scheduleTimeText(course),
                        style: Theme.of(context)
                            .textTheme
                            .titleMedium
                            ?.copyWith(fontWeight: FontWeight.w900)),
                    const SizedBox(height: 4),
                    Text(_scheduleSectionText(course),
                        style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(course.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context)
                            .textTheme
                            .titleMedium
                            ?.copyWith(fontWeight: FontWeight.w900)),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 10,
                      runSpacing: 5,
                      children: [
                        _ScheduleMeta(
                            icon: Icons.room,
                            text:
                                _cleanScheduleText(course.classroom) ?? '地点待定'),
                        _ScheduleMeta(
                            icon: Icons.person,
                            text: _cleanScheduleText(course.teacher) ?? '教师待定'),
                        if (_cleanScheduleText(course.weeks) != null)
                          _ScheduleMeta(
                              icon: Icons.date_range,
                              text: _cleanScheduleText(course.weeks)!),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CompactScheduleCourseTile extends StatelessWidget {
  const _CompactScheduleCourseTile({required this.course});

  final ScheduleCourse course;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => _showReadableScheduleDetails(context, course),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(
          children: [
            _CourseColorMark(name: course.name),
            const SizedBox(width: 10),
            SizedBox(width: 84, child: Text(_scheduleTimeText(course))),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(course.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium),
                  Text(
                    [
                      _scheduleSectionText(course),
                      _cleanScheduleText(course.classroom),
                      _cleanScheduleText(course.teacher),
                    ].whereType<String>().join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CourseColorMark extends StatelessWidget {
  const _CourseColorMark({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 12,
      height: 34,
      decoration: BoxDecoration(
        color: _scheduleCourseColor(name),
        borderRadius: BorderRadius.circular(999),
      ),
    );
  }
}

class _ScheduleMeta extends StatelessWidget {
  const _ScheduleMeta({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon,
            size: 14, color: Theme.of(context).colorScheme.onSurfaceVariant),
        const SizedBox(width: 4),
        Text(text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}

class TimetableView extends StatefulWidget {
  const TimetableView({super.key, required this.items});

  final List<ScheduleCourse> items;

  @override
  State<TimetableView> createState() => _TimetableViewState();
}

class _TimetableViewState extends State<TimetableView> {
  final verticalController = ScrollController();

  static const leftWidth = 70.0;
  static const headerHeight = 56.0;
  static const rowHeight = 76.0;
  static const minDayWidth = 112.0;
  static const maxDayWidth = 148.0;
  static const weekdays = ['一', '二', '三', '四', '五', '六', '日'];
  static const times = [
    ('09:00', '09:40'),
    ('09:40', '10:20'),
    ('10:40', '11:20'),
    ('11:20', '12:00'),
    ('12:30', '13:10'),
    ('13:10', '13:50'),
    ('14:00', '14:40'),
    ('14:40', '15:20'),
    ('15:30', '16:10'),
    ('16:10', '16:50'),
    ('17:00', '17:40'),
    ('17:40', '18:20'),
    ('19:00', '19:40'),
    ('19:40', '20:20'),
    ('20:30', '21:10'),
    ('21:10', '21:50'),
  ];
  static const palette = [
    Color(0xFF8E2F43),
    Color(0xFF006C67),
    Color(0xFF1E5A85),
    Color(0xFF8B4D00),
    Color(0xFF654597),
    Color(0xFF9D1734),
    Color(0xFF0E3F63),
    Color(0xFF9B3D2D),
    Color(0xFF1F4E94),
  ];

  @override
  void dispose() {
    verticalController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lineColor = theme.colorScheme.outlineVariant;
    final surface = theme.colorScheme.surfaceContainer;
    final periodCount = _periodCount();
    final compact = MediaQuery.sizeOf(context).width < 600;
    final effectiveLeftWidth = compact ? 34.0 : leftWidth;
    final effectiveHeaderHeight = compact ? 34.0 : headerHeight;
    final effectiveRowHeight = compact ? 64.0 : rowHeight;

    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Container(
        decoration: BoxDecoration(
          color: surface,
          border: Border.all(color: lineColor),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final tableWidth = constraints.maxWidth;
            final availableDayWidth = (tableWidth - effectiveLeftWidth) / 7;
            final dayWidth = compact
                ? availableDayWidth.clamp(34.0, 72.0).toDouble()
                : availableDayWidth.clamp(minDayWidth, maxDayWidth).toDouble();
            final effectiveTableWidth = compact
                ? tableWidth
                : (effectiveLeftWidth + dayWidth * 7)
                    .clamp(tableWidth, double.infinity)
                    .toDouble();
            final tableHeight =
                effectiveHeaderHeight + effectiveRowHeight * periodCount;

            return Scrollbar(
              controller: verticalController,
              child: SingleChildScrollView(
                controller: verticalController,
                physics: const AlwaysScrollableScrollPhysics(),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  physics: compact
                      ? const NeverScrollableScrollPhysics()
                      : const ClampingScrollPhysics(),
                  child: SizedBox(
                    width: effectiveTableWidth,
                    height: tableHeight,
                    child: Stack(
                      children: [
                        _TimetableGrid(
                          leftWidth: effectiveLeftWidth,
                          headerHeight: effectiveHeaderHeight,
                          dayWidth: dayWidth,
                          rowHeight: effectiveRowHeight,
                          periodCount: periodCount,
                          lineColor: lineColor,
                        ),
                        Positioned(
                          left: 0,
                          top: 0,
                          width: effectiveLeftWidth,
                          height: effectiveHeaderHeight,
                          child: const _HeaderCell(label: '节'),
                        ),
                        for (var day = 0; day < 7; day++)
                          Positioned(
                            left: effectiveLeftWidth + dayWidth * day,
                            top: 0,
                            width: dayWidth,
                            height: effectiveHeaderHeight,
                            child: _HeaderCell(
                              label:
                                  compact ? weekdays[day] : '周${weekdays[day]}',
                            ),
                          ),
                        for (var index = 0; index < periodCount; index++)
                          Positioned(
                            left: 0,
                            top: effectiveHeaderHeight +
                                effectiveRowHeight * index,
                            width: effectiveLeftWidth,
                            height: effectiveRowHeight,
                            child: _PeriodCell(
                              section: index + 1,
                              time: index < times.length ? times[index] : null,
                            ),
                          ),
                        for (final item in widget.items)
                          if (_hasPosition(item))
                            _CourseBlock(
                              course: item,
                              dayWidth: dayWidth,
                              rowHeight: effectiveRowHeight,
                              leftWidth: effectiveLeftWidth,
                              headerHeight: effectiveHeaderHeight,
                              color: _courseColor(item.name),
                            ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  int _periodCount() {
    var count = 16;
    for (final item in widget.items) {
      final end = item.endSection ?? item.startSection ?? 0;
      if (end > count) count = end;
    }
    return count;
  }

  bool _hasPosition(ScheduleCourse item) {
    final weekday = item.weekday;
    final start = item.startSection;
    if (weekday == null || weekday < 1 || weekday > 7) return false;
    return start != null && start > 0;
  }

  Color _courseColor(String name) {
    var hash = 0;
    for (final unit in name.codeUnits) {
      hash = (hash + unit) % palette.length;
    }
    return palette[hash];
  }
}

class _TimetableGrid extends StatelessWidget {
  const _TimetableGrid({
    required this.leftWidth,
    required this.headerHeight,
    required this.dayWidth,
    required this.rowHeight,
    required this.periodCount,
    required this.lineColor,
  });

  final double leftWidth;
  final double headerHeight;
  final double dayWidth;
  final double rowHeight;
  final int periodCount;
  final Color lineColor;

  @override
  Widget build(BuildContext context) {
    final fadedLine = lineColor.withValues(alpha: 0.7);
    return Stack(
      children: [
        for (var day = 0; day <= 7; day++)
          Positioned(
            left: leftWidth + dayWidth * day,
            top: 0,
            bottom: 0,
            child: Container(width: 1, color: fadedLine),
          ),
        for (var index = 0; index <= periodCount; index++)
          Positioned(
            left: 0,
            right: 0,
            top: headerHeight + rowHeight * index,
            child: Container(height: 1, color: fadedLine),
          ),
        Positioned(
          left: 0,
          top: headerHeight,
          bottom: 0,
          child: Container(width: 1, color: fadedLine),
        ),
      ],
    );
  }
}

class _HeaderCell extends StatelessWidget {
  const _HeaderCell({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 54;
        return Center(
          child: Text(
            label,
            style: TextStyle(
              fontSize: compact ? 11 : 14,
              fontWeight: FontWeight.w600,
            ),
          ),
        );
      },
    );
  }
}

class _PeriodCell extends StatelessWidget {
  const _PeriodCell({required this.section, required this.time});

  final int section;
  final (String, String)? time;

  @override
  Widget build(BuildContext context) {
    final inactive = Theme.of(context).colorScheme.onSurfaceVariant;
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 44;
        return Padding(
          padding: EdgeInsets.symmetric(horizontal: compact ? 1 : 6),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                '$section',
                style: TextStyle(
                  fontSize: compact ? 12 : 20,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (time != null) ...[
                SizedBox(height: compact ? 2 : 4),
                Text(
                  time!.$1,
                  style: TextStyle(
                    fontSize: compact ? 7 : 11,
                    color: inactive,
                    height: 1,
                  ),
                ),
                Text(
                  time!.$2,
                  style: TextStyle(
                    fontSize: compact ? 7 : 11,
                    color: inactive,
                    height: 1,
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _CourseBlock extends StatelessWidget {
  const _CourseBlock({
    required this.course,
    required this.dayWidth,
    required this.rowHeight,
    required this.leftWidth,
    required this.headerHeight,
    required this.color,
  });

  final ScheduleCourse course;
  final double dayWidth;
  final double rowHeight;
  final double leftWidth;
  final double headerHeight;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final weekday = course.weekday!;
    final start = course.startSection!;
    final end = course.endSection ?? start;
    final span = end >= start ? end - start + 1 : 1;
    final detail = _detailText(span);

    return Positioned(
      left: leftWidth + (weekday - 1) * dayWidth + 2,
      top: headerHeight + (start - 1) * rowHeight + 3,
      width: dayWidth - 4,
      height: rowHeight * span - 6,
      child: GestureDetector(
        onTap: () => _showDetails(context, start, end),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: Container(
            padding: EdgeInsets.symmetric(
              horizontal: dayWidth < 52 ? 2 : 8,
              vertical: dayWidth < 52 ? 4 : 10,
            ),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.92),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.white.withValues(alpha: 0.45)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.12),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Center(
              child: Text(
                detail,
                textAlign: TextAlign.center,
                maxLines: span <= 1 ? 4 : span * 4,
                overflow: TextOverflow.fade,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: dayWidth < 46 ? 8 : (dayWidth < 64 ? 10 : 14),
                  height: 1.08,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _detailText(int span) {
    final lines = <String>[course.name];
    final room = _clean(course.classroom);
    final teacher = _clean(course.teacher);
    if (room != null) lines.add('@$room');
    if (span >= 2 && teacher != null) lines.add(teacher);
    return lines.join('\n');
  }

  String? _clean(String? value) {
    final cleaned = value?.trim();
    if (cleaned == null || cleaned.isEmpty) return null;
    return cleaned;
  }

  void _showDetails(BuildContext context, int start, int end) {
    final standardRows = [
      ..._priorityRawRows(),
      (Icons.menu_book, '课程', course.name),
      (Icons.calendar_month, '星期', '周${course.weekday}'),
      (Icons.schedule, '节次', '第$start-${end >= start ? end : start}节'),
      if (_clean(course.classroom) != null)
        (Icons.room, '教室', _clean(course.classroom)!),
      if (_clean(course.teacher) != null)
        (Icons.people, '教师', _clean(course.teacher)!),
      if (_clean(course.weeks) != null)
        (Icons.access_time, '周次', _clean(course.weeks)!),
    ];
    final rawRows = course.raw.entries
        .where((entry) =>
            !_priorityRawKeys.contains(entry.key) &&
            _rawValueText(entry.value).isNotEmpty)
        .map((entry) => (_rawLabel(entry.key), _rawValueText(entry.value)))
        .toList();

    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(course.name),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620, maxHeight: 520),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final row in standardRows)
                  _DetailRow(icon: row.$1, label: row.$2, value: row.$3),
                if (rawRows.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  ExpansionTile(
                    title: const Text('原始字段'),
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final row in rawRows)
                            _DetailRow(label: row.$1, value: row.$2),
                        ],
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  List<(IconData, String, String)> _priorityRawRows() {
    return [
      for (final key in _priorityRawKeys)
        if (_rawValueText(course.raw[key]).isNotEmpty)
          (Icons.info_outline, _rawLabel(key), _rawValueText(course.raw[key])),
    ];
  }

  static const _priorityRawKeys = ['jxbmc', 'kch', 'kcxz'];

  String _rawValueText(dynamic value) {
    if (value == null) return '';
    if (value is String) return value.trim();
    if (value is num || value is bool) return value.toString();
    return const JsonEncoder.withIndent('  ').convert(value);
  }

  String _rawLabel(String key) {
    const labels = {
      'kch': '课程代码(kch)',
      'kcmc': '课程名称(kcmc)',
      'jxb_id': '班级编号(jxb_id)',
      'jxbmc': '班级编号(jxbmc)',
      'jsxm': '教师(jsxm)',
      'xm': '教师/姓名(xm)',
      'cdmc': '教室(cdmc)',
      'xqj': '星期(xqj)',
      'ksjc': '开始节次(ksjc)',
      'jcs': '节次(jcs)',
      'zcd': '周次(zcd)',
      'xf': '学分(xf)',
      'xnm': '学年(xnm)',
      'xqm': '学期(xqm)',
      'kcxz': '课程性质(kcxz)',
    };
    return labels[key] ?? key;
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value, this.icon});

  final IconData? icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (icon != null) ...[
            Icon(icon,
                size: 15,
                color: Theme.of(context).colorScheme.onSurfaceVariant),
            const SizedBox(width: 8),
          ],
          SizedBox(
            width: icon == null ? 132 : 116,
            child: Text(
              label,
              style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: value.contains('\n')
                  ? const TextStyle(fontFamily: 'Consolas', fontSize: 12)
                  : null,
            ),
          ),
        ],
      ),
    );
  }
}

int _compareScheduleCourses(ScheduleCourse a, ScheduleCourse b) {
  final day = (a.weekday ?? 99).compareTo(b.weekday ?? 99);
  if (day != 0) return day;
  final section = (a.startSection ?? 99).compareTo(b.startSection ?? 99);
  if (section != 0) return section;
  return a.name.compareTo(b.name);
}

ScheduleCourse? _nextScheduleCourse(List<ScheduleCourse> items) {
  final now = DateTime.now();
  for (final item in [...items]..sort(_compareScheduleCourses)) {
    final end = _scheduleCourseEnd(item, now);
    if (end != null && end.isAfter(now)) return item;
  }
  return null;
}

DateTime? _scheduleCourseEnd(ScheduleCourse course, DateTime date) {
  final section = course.endSection ?? course.startSection;
  if (section == null || section < 1 || section > icsScheduleTimes.length) {
    return null;
  }
  return _dateWithScheduleTime(date, icsScheduleTimes[section - 1].$2);
}

DateTime _dateWithScheduleTime(DateTime date, String time) {
  final parts = time.split(':');
  return DateTime(
    date.year,
    date.month,
    date.day,
    int.tryParse(parts.first) ?? 0,
    parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0,
  );
}

String _scheduleTimeText(ScheduleCourse course) {
  final start = course.startSection;
  final end = course.endSection ?? start;
  if (start == null || start < 1 || start > icsScheduleTimes.length) {
    return '时间待定';
  }
  final startText = icsScheduleTimes[start - 1].$1;
  final endText = end != null && end >= 1 && end <= icsScheduleTimes.length
      ? icsScheduleTimes[end - 1].$2
      : icsScheduleTimes[start - 1].$2;
  return '$startText-$endText';
}

String _scheduleSectionText(ScheduleCourse course) {
  final start = course.startSection;
  final end = course.endSection ?? start;
  if (start == null) return '节次待定';
  return '第$start-${end != null && end >= start ? end : start}节';
}

String _scheduleWeekdayText(int weekday) {
  const names = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
  if (weekday < 1 || weekday > 7) return '未知';
  return names[weekday - 1];
}

String? _cleanScheduleText(String? value) {
  final text = value?.trim();
  if (text == null || text.isEmpty) return null;
  return text;
}

Color _scheduleCourseColor(String name) {
  const palette = [
    Color(0xFF8E2F43),
    Color(0xFF006C67),
    Color(0xFF1E5A85),
    Color(0xFF8B4D00),
    Color(0xFF654597),
    Color(0xFF9D1734),
    Color(0xFF0E3F63),
    Color(0xFF9B3D2D),
    Color(0xFF1F4E94),
  ];
  var hash = 0;
  for (final unit in name.codeUnits) {
    hash = (hash + unit) % palette.length;
  }
  return palette[hash];
}

void _showReadableScheduleDetails(BuildContext context, ScheduleCourse course) {
  final rows = [
    (Icons.menu_book, '课程', course.name),
    (
      Icons.calendar_month,
      '星期',
      course.weekday == null ? '星期待定' : _scheduleWeekdayText(course.weekday!)
    ),
    (Icons.schedule, '时间', _scheduleTimeText(course)),
    (Icons.schedule, '节次', _scheduleSectionText(course)),
    if (_cleanScheduleText(course.classroom) != null)
      (Icons.room, '教室', _cleanScheduleText(course.classroom)!),
    if (_cleanScheduleText(course.teacher) != null)
      (Icons.people, '教师', _cleanScheduleText(course.teacher)!),
    if (_cleanScheduleText(course.weeks) != null)
      (Icons.access_time, '周次', _cleanScheduleText(course.weeks)!),
  ];
  showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(course.name),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final row in rows)
              _DetailRow(icon: row.$1, label: row.$2, value: row.$3),
          ],
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
}

class JsonPanel extends StatelessWidget {
  const JsonPanel({super.key, required this.json});

  final String json;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxHeight: 360),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: SingleChildScrollView(
        child: SelectableText(
          json,
          style: const TextStyle(fontFamily: 'Consolas', fontSize: 12),
        ),
      ),
    );
  }
}

class GradeAttempt {
  const GradeAttempt(this.period, this.grade);

  final AcademicPeriod period;
  final GradeItem grade;
}

class GradeGroup {
  GradeGroup(GradeAttempt first) : attempts = [first];

  final List<GradeAttempt> attempts;

  GradeAttempt get first => attempts.first;
  GradeAttempt get latest => attempts.last;
  bool get hasRetake => attempts.length > 1;
  String get displayName => hasRetake && !first.grade.courseName.contains('补')
      ? '${first.grade.courseName}（补）'
      : first.grade.courseName;
}

String _courseKey(String value) => value
    .replaceAll(RegExp(r'\s+'), '')
    .replaceAll('（补）', '')
    .replaceAll('(补)', '')
    .trim();

bool _hasRetakeText(String? value) => value?.contains('补') ?? false;

Color _accentFill(BuildContext context) =>
    Theme.of(context).colorScheme.primary.withValues(alpha: 0.12);

Color _retakeFill(int index) {
  final alpha = (0.10 + index * 0.04).clamp(0.12, 0.26).toDouble();
  return Colors.red.withValues(alpha: alpha);
}

Color _retakeText(int index) => index >= 2 ? Colors.red.shade800 : Colors.red;

int _periodSortValue(AcademicPeriod period) => period.year * 10 + period.term;

DateTime? _examDateTime(String? value) {
  final text = value ?? '';
  final match = RegExp(
    r'(\d{4})[-/年.](\d{1,2})[-/月.](\d{1,2})(?:日)?(?:\s+(\d{1,2}):(\d{1,2}))?',
  ).firstMatch(text);
  if (match == null) return null;
  final year = int.tryParse(match.group(1)!);
  final month = int.tryParse(match.group(2)!);
  final day = int.tryParse(match.group(3)!);
  final hour = int.tryParse(match.group(4) ?? '0') ?? 0;
  final minute = int.tryParse(match.group(5) ?? '0') ?? 0;
  if (year == null || month == null || day == null) return null;
  return DateTime(year, month, day, hour, minute);
}

int _compareExamsByTime(PeriodExam a, PeriodExam b) {
  final aTime = _examDateTime(a.exam.time);
  final bTime = _examDateTime(b.exam.time);
  if (aTime != null && bTime != null) return bTime.compareTo(aTime);
  if (aTime != null) return -1;
  if (bTime != null) return 1;
  final periodCompare =
      _periodSortValue(a.period).compareTo(_periodSortValue(b.period));
  if (periodCompare != 0) return periodCompare;
  return a.exam.courseName.compareTo(b.exam.courseName);
}

int _compareExamsByTimeAsc(PeriodExam a, PeriodExam b) {
  final aTime = _examDateTime(a.exam.time);
  final bTime = _examDateTime(b.exam.time);
  if (aTime != null && bTime != null) return aTime.compareTo(bTime);
  if (aTime != null) return -1;
  if (bTime != null) return 1;
  final periodCompare =
      _periodSortValue(a.period).compareTo(_periodSortValue(b.period));
  if (periodCompare != 0) return periodCompare;
  return a.exam.courseName.compareTo(b.exam.courseName);
}

class AttendancePage extends StatefulWidget {
  const AttendancePage(
      {super.key,
      required this.api,
      required this.year,
      required this.term,
      this.onSessionExpired});

  final ApiClient api;
  final int year;
  final int term;
  final VoidCallback? onSessionExpired;

  @override
  State<AttendancePage> createState() => _AttendancePageState();
}

class _AttendancePageState extends State<AttendancePage> {
  late Future<AttendanceResponse> _attendanceFuture;
  String _sortField = 'none';
  bool _sortDescending = true;
  String _filterType = 'all';
  DateTime? _selectedAttendanceDate;
  Set<String> _highlightedAttendanceKeys = {};
  String? _processedAttendanceSignature;

  @override
  void initState() {
    super.initState();
    _attendanceFuture = _loadAttendance();
  }

  @override
  void didUpdateWidget(covariant AttendancePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.api != widget.api ||
        oldWidget.year != widget.year ||
        oldWidget.term != widget.term) {
      _attendanceFuture = _loadAttendance();
    }
  }

  Future<AttendanceResponse> _loadAttendance({bool forceRefresh = false}) =>
      widget.api
          .attendance(
            year: widget.year,
            term: widget.term,
            forceRefresh: forceRefresh,
          )
          .then((r) => r.data);

  Future<void> _refreshAttendance() async {
    setState(() => _attendanceFuture = _loadAttendance(forceRefresh: true));
    await _attendanceFuture;
  }

  String get _sortLabel {
    const labels = {
      'normal': '正常',
      'late': '迟到',
      'leaveEarly': '早退',
      'absent': '旷课',
      'leave': '请假'
    };
    return '${labels[_sortField] ?? ''}${_sortDescending ? '↓' : '↑'}';
  }

  List<AttendanceItem> _applyFilterSort(List<AttendanceItem> items) {
    var filtered = items;
    if (_filterType != 'all') {
      filtered = items.where((item) {
        switch (_filterType) {
          case 'late':
            return item.late > 0;
          case 'leaveEarly':
            return item.leaveEarly > 0;
          case 'absent':
            return item.absent > 0;
          case 'leave':
            return item.leave > 0;
          default:
            return true;
        }
      }).toList();
    }
    if (_sortField != 'none') {
      filtered = [...filtered]..sort((a, b) {
          int va, vb;
          switch (_sortField) {
            case 'normal':
              va = a.normal;
              vb = b.normal;
            case 'late':
              va = a.late;
              vb = b.late;
            case 'leaveEarly':
              va = a.leaveEarly;
              vb = b.leaveEarly;
            case 'absent':
              va = a.absent;
              vb = b.absent;
            case 'leave':
              va = a.leave;
              vb = b.leave;
            default:
              return 0;
          }
          return _sortDescending ? vb.compareTo(va) : va.compareTo(vb);
        });
    } else {
      filtered = [...filtered]..sort((a, b) {
          final abnormalA = a.late + a.leaveEarly + a.absent;
          final abnormalB = b.late + b.leaveEarly + b.absent;
          if (abnormalA != abnormalB) return abnormalB.compareTo(abnormalA);
          return _attendanceStatusTotal(b).compareTo(_attendanceStatusTotal(a));
        });
    }
    if (_highlightedAttendanceKeys.isNotEmpty) {
      filtered = [...filtered]..sort((a, b) {
          final ah = _highlightedAttendanceKeys.contains(a.compareKey);
          final bh = _highlightedAttendanceKeys.contains(b.compareKey);
          if (ah == bh) return 0;
          return ah ? -1 : 1;
        });
    }
    return filtered;
  }

  Widget _buildToolbar(List<AttendanceItem> items) {
    final dayRecords = _selectedAttendanceDate == null
        ? const <_AttendanceDayRecord>[]
        : _recordsForDate(items, _selectedAttendanceDate!);
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final item in const [
          ('all', '全部'),
          ('late', '迟到'),
          ('leaveEarly', '早退'),
          ('absent', '旷课'),
          ('leave', '请假'),
        ])
          ChoiceChip(
            label: Text(item.$2),
            selected: _filterType == item.$1,
            onSelected: (_) => setState(() => _filterType = item.$1),
          ),
        PopupMenuButton<String>(
          icon: _IconLabel(
            icon: Icons.sort,
            label: _sortField == 'none' ? '异常优先' : _sortLabel,
          ),
          onSelected: (value) {
            if (value == 'none') {
              setState(() => _sortField = 'none');
            } else if (value == _sortField) {
              setState(() => _sortDescending = !_sortDescending);
            } else {
              setState(() {
                _sortField = value;
                _sortDescending = true;
              });
            }
          },
          itemBuilder: (context) => const [
            PopupMenuItem(value: 'none', child: Text('异常优先')),
            PopupMenuItem(value: 'normal', child: Text('按正常次数')),
            PopupMenuItem(value: 'late', child: Text('按迟到次数')),
            PopupMenuItem(value: 'leaveEarly', child: Text('按早退次数')),
            PopupMenuItem(value: 'absent', child: Text('按旷课次数')),
            PopupMenuItem(value: 'leave', child: Text('按请假次数')),
          ],
        ),
        OutlinedButton.icon(
          onPressed: () => _pickAttendanceDate(items),
          icon: const Icon(Icons.calendar_today, size: 16),
          label: Text(_selectedAttendanceDate == null
              ? '按天查询'
              : _dateText(_selectedAttendanceDate!)),
        ),
        if (_selectedAttendanceDate != null)
          IconButton(
            tooltip: '清除日期',
            onPressed: () => setState(() => _selectedAttendanceDate = null),
            icon: const Icon(Icons.close),
          ),
        if (_selectedAttendanceDate != null)
          Text(
            '当天 ${dayRecords.fold(0, (sum, item) => sum + item.record.count)} 次',
            style: const TextStyle(fontSize: 12),
          ),
        IconButton(
          tooltip: '刷新考勤',
          onPressed: () => unawaited(_refreshAttendance()),
          icon: const Icon(Icons.refresh),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return AsyncPanel<AttendanceResponse>(
      future: _attendanceFuture,
      onSessionExpired: widget.onSessionExpired,
      builder: (data) => LayoutBuilder(
        builder: (context, constraints) {
          _queueAttendanceDiffCheck(data.items);
          final compact = constraints.maxWidth < 640;
          if (data.items.isEmpty) {
            return PagePanel(
              title: '考勤',
              icon: Icons.schedule,
              expandChild: true,
              child: RefreshIndicator(
                onRefresh: _refreshAttendance,
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  children: const [
                    SizedBox(
                      height: 260,
                      child: EmptyState(message: '暂无考勤记录'),
                    ),
                  ],
                ),
              ),
            );
          }
          final filteredItems = _applyFilterSort(data.items);
          final dayRecords = _selectedAttendanceDate == null
              ? const <_AttendanceDayRecord>[]
              : _recordsForDate(data.items, _selectedAttendanceDate!);
          return PagePanel(
            title: '考勤',
            icon: Icons.schedule,
            expandChild: true,
            child: RefreshIndicator(
              onRefresh: _refreshAttendance,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  AttendanceOverview(items: data.items),
                  const SizedBox(height: 12),
                  _buildToolbar(data.items),
                  const SizedBox(height: 10),
                  if (_selectedAttendanceDate != null) ...[
                    _AttendanceHistoryPanel(records: dayRecords),
                    const SizedBox(height: 10),
                  ],
                  _AttendanceCourseSection(
                    items: filteredItems,
                    highlightedKeys: _highlightedAttendanceKeys,
                    compact: compact,
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _queueAttendanceDiffCheck(List<AttendanceItem> items) {
    final signature = _attendanceSnapshotSignature(items);
    if (_processedAttendanceSignature == signature) return;
    _processedAttendanceSignature = signature;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _checkAttendanceDiff(items, signature);
    });
  }

  Future<void> _checkAttendanceDiff(
      List<AttendanceItem> items, String signature) async {
    final prefs = await SharedPreferences.getInstance();
    final key =
        'attendance.snapshot.${widget.api.namespace}.${widget.year}.${widget.term}';
    final previousText = prefs.getString(key);
    await prefs.setString(key, signature);
    if (previousText == null || previousText.isEmpty) return;
    final previousItems = _decodeAttendanceSnapshot(previousText);
    final changes = _attendanceAbnormalIncrements(previousItems, items);
    if (changes.isEmpty) {
      if (mounted && _highlightedAttendanceKeys.isNotEmpty) {
        setState(() => _highlightedAttendanceKeys = {});
      }
      return;
    }
    final changedKeys = changes.map((item) => item.item.compareKey).toSet();
    if (mounted) {
      setState(() => _highlightedAttendanceKeys = changedKeys);
    }
    final first = changes.first;
    final more = changes.length > 1 ? ' 等 ${changes.length} 条' : '';
    try {
      await local_notification_service.loadLibrary();
      await local_notification_service.LocalNotificationService.show(
        id: 7301,
        title: '考勤异常更新',
        body:
            '${first.item.courseName} 新增${first.statusLabel} ${first.delta} 次$more',
        extras: {'type': 'attendance_alert'},
      );
    } catch (_) {}
  }

  Future<void> _pickAttendanceDate(List<AttendanceItem> items) async {
    final dates = _attendanceDates(items);
    final initial = _selectedAttendanceDate ??
        (dates.isNotEmpty ? dates.last : DateTime.now());
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate:
          dates.isNotEmpty ? dates.first : DateTime(DateTime.now().year - 1),
      lastDate:
          dates.isNotEmpty ? dates.last : DateTime(DateTime.now().year + 1),
    );
    if (picked != null) setState(() => _selectedAttendanceDate = picked);
  }
}

int _attendanceStatusTotal(AttendanceItem item) =>
    item.normal + item.late + item.leaveEarly + item.absent + item.leave;

String _attendanceSnapshotSignature(List<AttendanceItem> items) {
  final sorted = [...items]
    ..sort((a, b) => a.compareKey.compareTo(b.compareKey));
  return jsonEncode(sorted.map((item) => item.toSnapshotJson()).toList());
}

List<AttendanceItem> _decodeAttendanceSnapshot(String value) {
  try {
    final decoded = jsonDecode(value) as List<dynamic>;
    return decoded
        .whereType<Map<String, dynamic>>()
        .map((item) => AttendanceItem.fromJson(item))
        .toList();
  } catch (_) {
    return const [];
  }
}

List<_AttendanceChange> _attendanceAbnormalIncrements(
  List<AttendanceItem> previous,
  List<AttendanceItem> current,
) {
  final previousByKey = {for (final item in previous) item.compareKey: item};
  final changes = <_AttendanceChange>[];
  for (final item in current) {
    final old = previousByKey[item.compareKey];
    if (old == null) continue;
    for (final status in const ['late', 'leaveEarly', 'absent', 'leave']) {
      final delta = item.countFor(status) - old.countFor(status);
      if (delta > 0) {
        changes.add(_AttendanceChange(
          item: item,
          status: status,
          statusLabel: _attendanceStatusLabel(status),
          delta: delta,
        ));
      }
    }
  }
  return changes;
}

List<_AttendanceDayRecord> _recordsForDate(
    List<AttendanceItem> items, DateTime date) {
  final target = _dateText(date);
  final records = <_AttendanceDayRecord>[];
  for (final item in items) {
    for (final record in item.records) {
      if (record.normalizedDate == target) {
        records.add(_AttendanceDayRecord(item: item, record: record));
      }
    }
  }
  records.sort((a, b) {
    final status = a.record.status.compareTo(b.record.status);
    if (status != 0) return status;
    return a.item.courseName.compareTo(b.item.courseName);
  });
  return records;
}

List<DateTime> _attendanceDates(List<AttendanceItem> items) {
  final values = <DateTime>{};
  for (final item in items) {
    for (final record in item.records) {
      final date = DateTime.tryParse(record.normalizedDate);
      if (date != null) values.add(DateTime(date.year, date.month, date.day));
    }
  }
  final sorted = values.toList()..sort();
  return sorted;
}

String _attendanceStatusLabel(String status) {
  return const {
        'late': '迟到',
        'leaveEarly': '早退',
        'absent': '旷课',
        'leave': '请假',
        'normal': '正常',
      }[status] ??
      status;
}

Color _attendanceStatusColor(BuildContext context, String status) {
  final colorScheme = Theme.of(context).colorScheme;
  switch (status) {
    case 'late':
    case 'absent':
      return colorScheme.error;
    case 'leaveEarly':
      return colorScheme.tertiary;
    case 'leave':
      return colorScheme.secondary;
    default:
      return colorScheme.primary;
  }
}

class _AttendanceChange {
  const _AttendanceChange({
    required this.item,
    required this.status,
    required this.statusLabel,
    required this.delta,
  });

  final AttendanceItem item;
  final String status;
  final String statusLabel;
  final int delta;
}

class _AttendanceDayRecord {
  const _AttendanceDayRecord({required this.item, required this.record});

  final AttendanceItem item;
  final AttendanceRecord record;
}

class _AttendanceHistoryPanel extends StatelessWidget {
  const _AttendanceHistoryPanel({required this.records});

  final List<_AttendanceDayRecord> records;

  @override
  Widget build(BuildContext context) {
    if (records.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(18),
        ),
        child: const EmptyState(message: '当天暂无考勤明细'),
      );
    }
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(4, 0, 4, 6),
            child: Text('当天明细', style: TextStyle(fontWeight: FontWeight.w800)),
          ),
          for (final entry in records)
            ListTile(
              dense: true,
              leading: Icon(
                entry.record.status == 'normal'
                    ? Icons.check_circle
                    : Icons.warning,
                color: _attendanceStatusColor(context, entry.record.status),
              ),
              title: Text(entry.item.courseName,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text([
                entry.record.time,
                entry.record.remark,
              ]
                  .where((value) => value != null && value.isNotEmpty)
                  .join(' · ')),
              trailing: Text(
                '${entry.record.statusLabel ?? _attendanceStatusLabel(entry.record.status)} x${entry.record.count}',
                style: TextStyle(
                  color: _attendanceStatusColor(context, entry.record.status),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _AttendanceCourseSection extends StatelessWidget {
  const _AttendanceCourseSection({
    required this.items,
    required this.highlightedKeys,
    required this.compact,
  });

  final List<AttendanceItem> items;
  final Set<String> highlightedKeys;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const EmptyState(message: '没有匹配的课程');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                '课程明细',
                style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16),
              ),
            ),
            Text(
              '${items.length} 门',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (compact)
          Column(
            children: [
              for (final item in items)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _AttendanceCard(
                    item: item,
                    total: _attendanceStatusTotal(item),
                    highlighted: highlightedKeys.contains(item.compareKey),
                  ),
                ),
            ],
          )
        else
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final item in items)
                SizedBox(
                  width: 280,
                  child: _AttendanceCard(
                    item: item,
                    total: _attendanceStatusTotal(item),
                    highlighted: highlightedKeys.contains(item.compareKey),
                  ),
                ),
            ],
          ),
      ],
    );
  }
}

class _AttendanceCard extends StatelessWidget {
  const _AttendanceCard(
      {required this.item, required this.total, this.highlighted = false});
  final AttendanceItem item;
  final int total;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final abnormal = item.late + item.leaveEarly + item.absent;
    final rate = total <= 0 ? 0.0 : item.normal / total;
    final focusColor = abnormal > 0
        ? colorScheme.error
        : item.leave > 0
            ? colorScheme.secondary
            : colorScheme.primary;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: highlighted
            ? colorScheme.errorContainer.withValues(alpha: 0.45)
            : colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: highlighted
              ? colorScheme.error
              : colorScheme.outlineVariant.withValues(alpha: 0.65),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                abnormal > 0 ? Icons.warning_amber : Icons.check_circle,
                color: focusColor,
                size: 20,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  highlighted ? '★ ${item.courseName}' : item.courseName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              _StatusPill(
                label: abnormal > 0 ? '异常 $abnormal' : '正常',
                color: focusColor,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Text(
                '${(rate * 100).toStringAsFixed(1)}%',
                style: TextStyle(
                  color: focusColor,
                  fontSize: 22,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(child: _StaticProgressBar(value: rate)),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _attendancePill(context, '正常', item.normal, colorScheme.primary),
              _attendancePill(context, '迟到', item.late, colorScheme.error),
              _attendancePill(
                  context, '早退', item.leaveEarly, colorScheme.tertiary),
              _attendancePill(context, '旷课', item.absent, colorScheme.error),
              _attendancePill(context, '请假', item.leave, colorScheme.secondary),
              _attendancePill(
                  context, '合计', total, colorScheme.onSurfaceVariant),
            ],
          ),
        ],
      ),
    );
  }

  Widget _attendancePill(
    BuildContext context,
    String label,
    int value,
    Color color,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: value > 0 ? 0.12 : 0.06),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Text(
        '$label $value',
        style: TextStyle(
          color: value > 0
              ? color
              : Theme.of(context).colorScheme.onSurfaceVariant,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _AttendanceKeyMetric extends StatelessWidget {
  const _AttendanceKeyMetric({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
  });

  final String label;
  final String value;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 142,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(height: 10),
          Text(label,
              style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 12)),
          const SizedBox(height: 4),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: color,
              fontSize: 18,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }
}

class AttendanceOverview extends StatelessWidget {
  const AttendanceOverview({super.key, required this.items});

  final List<AttendanceItem> items;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final normal = items.fold(0, (sum, item) => sum + item.normal);
    final late = items.fold(0, (sum, item) => sum + item.late);
    final leaveEarly = items.fold(0, (sum, item) => sum + item.leaveEarly);
    final absent = items.fold(0, (sum, item) => sum + item.absent);
    final leave = items.fold(0, (sum, item) => sum + item.leave);
    final abnormal = late + leaveEarly + absent;
    final statusTotal = normal + late + leaveEarly + absent + leave;
    final total = items.fold(0, (sum, item) => sum + item.total);
    final displayTotal = statusTotal > 0 ? statusTotal : total;
    final rate = displayTotal <= 0 ? 0.0 : normal / displayTotal;
    final focusColor = abnormal > 0 ? colorScheme.error : colorScheme.primary;
    final focusTitle = abnormal > 0 ? '需要关注' : '考勤稳定';
    final focusText = abnormal > 0
        ? '迟到 $late · 早退 $leaveEarly · 旷课 $absent'
        : '当前没有迟到、早退或旷课记录';
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colorScheme.primaryContainer.withValues(alpha: 0.58),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: focusColor.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(
                  abnormal > 0 ? Icons.warning_amber : Icons.verified,
                  color: focusColor,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      focusTitle,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      focusText,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              Text(
                '${(rate * 100).toStringAsFixed(1)}%',
                style: TextStyle(
                  color: focusColor,
                  fontSize: 28,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          _StaticProgressBar(value: rate),
          const SizedBox(height: 14),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 10,
            runSpacing: 10,
            children: [
              _AttendanceKeyMetric(
                label: '合计',
                value: '$displayTotal 次',
                icon: Icons.list,
                color: colorScheme.primary,
              ),
              _AttendanceKeyMetric(
                label: '正常',
                value: '$normal',
                icon: Icons.check_circle,
                color: colorScheme.primary,
              ),
              _AttendanceKeyMetric(
                label: '异常',
                value: '$abnormal',
                icon: Icons.warning_amber,
                color: abnormal > 0 ? colorScheme.error : colorScheme.tertiary,
              ),
              _AttendanceKeyMetric(
                label: '请假',
                value: '$leave',
                icon: Icons.badge,
                color: colorScheme.secondary,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

String _periodSignature(List<AcademicPeriod> periods) =>
    periods.map((period) => '${period.year}:${period.term}').join('|');

class ExamsPage extends StatefulWidget {
  const ExamsPage(
      {super.key,
      required this.api,
      required this.periods,
      this.onSessionExpired,
      this.highlightCourse});

  final ApiClient api;
  final List<AcademicPeriod> periods;
  final VoidCallback? onSessionExpired;
  final String? highlightCourse;

  @override
  State<ExamsPage> createState() => _ExamsPageState();
}

class _ExamsPageState extends State<ExamsPage> {
  var sortMode = 'term';
  bool sortAscending = false;
  bool _exporting = false;
  late Future<List<PeriodExam>> _examsFuture;
  late String _periodsSignature;
  final ScrollController _scrollController = ScrollController();
  bool _hasScrolledToHighlight = false;

  @override
  void initState() {
    super.initState();
    _periodsSignature = _periodSignature(widget.periods);
    _examsFuture = _loadExams();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToHighlightIfNeeded();
    });
  }

  @override
  void didUpdateWidget(ExamsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final nextSignature = _periodSignature(widget.periods);
    if (oldWidget.api != widget.api || nextSignature != _periodsSignature) {
      _periodsSignature = nextSignature;
      _examsFuture = _loadExams();
    }
    if (widget.highlightCourse != oldWidget.highlightCourse) {
      _hasScrolledToHighlight = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToHighlightIfNeeded();
      });
    }
  }

  void _scrollToHighlightIfNeeded() {
    if (_hasScrolledToHighlight ||
        widget.highlightCourse == null ||
        !_scrollController.hasClients) {
      return;
    }
    final highlightKey = _courseKey(widget.highlightCourse!);
    final items = _sortedByTerm(_allLoadedItems);
    int targetIndex = -1;
    for (int i = 0; i < items.length; i++) {
      if (_courseKey(items[i].exam.courseName) == highlightKey) {
        targetIndex = i;
        break;
      }
    }
    if (targetIndex < 0) return; // 数据尚未加载，等待下次尝试
    _hasScrolledToHighlight = true;
    const estimatedItemHeight = 56.0;
    final scrollPosition = (targetIndex * estimatedItemHeight).clamp(
      0.0,
      _scrollController.position.maxScrollExtent,
    );
    _scrollController.animateTo(
      scrollPosition,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  List<PeriodExam> _allLoadedItems = [];

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PageRefresh(
      onRefresh: _refreshExams,
      child: AsyncPanel<List<PeriodExam>>(
        future: _examsFuture,
        onSessionExpired: widget.onSessionExpired,
        builder: (items) {
          _allLoadedItems = items;
          if (!_hasScrolledToHighlight && widget.highlightCourse != null) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _scrollToHighlightIfNeeded();
            });
          }
          return LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= 720;
              if (wide) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 280,
                      child: Column(
                        children: [
                          Align(
                            alignment: Alignment.centerLeft,
                            child: SizedBox(
                              width: 160,
                              child: DropdownMenu<String>(
                                initialSelection: sortMode,
                                enableSearch: false,
                                requestFocusOnTap: false,
                                onSelected: (value) {
                                  if (value != null) {
                                    setState(() => sortMode = value);
                                  }
                                },
                                dropdownMenuEntries: const [
                                  DropdownMenuEntry(
                                      value: 'term', label: '按学期排列'),
                                  DropdownMenuEntry(
                                      value: 'time', label: '按时间排列'),
                                ],
                              ),
                            ),
                          ),
                          if (sortMode == 'term')
                            Align(
                              alignment: Alignment.centerLeft,
                              child: IconButton(
                                icon: Icon(sortAscending
                                    ? Icons.arrow_upward
                                    : Icons.arrow_downward),
                                tooltip: sortAscending ? '正序' : '倒序',
                                onPressed: () => setState(
                                    () => sortAscending = !sortAscending),
                              ),
                            ),
                          const SizedBox(height: 8),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: TextButton(
                              onPressed: items.isEmpty || _exporting
                                  ? null
                                  : () async {
                                      setState(() => _exporting = true);
                                      try {
                                        final year = widget.periods.first.year;
                                        final term = widget.periods.first.term;
                                        final ics = generateExamIcs(
                                            exams: items,
                                            year: year,
                                            term: term);
                                        if (kIsWeb) {
                                          await ics_download.loadLibrary();
                                          ics_download.downloadIcs(
                                              ics, '考试_${year}_$term.ics');
                                        } else {
                                          await Share.shareXFiles(
                                            [
                                              XFile.fromData(utf8.encode(ics),
                                                  name: '考试_${year}_$term.ics',
                                                  mimeType: 'text/calendar')
                                            ],
                                            text: '考试_${year}_$term.ics',
                                          );
                                        }
                                      } finally {
                                        if (mounted) {
                                          setState(() => _exporting = false);
                                        }
                                      }
                                    },
                              child: _IconLabel(
                                icon: Icons.event_available,
                                label: _exporting ? '导出中...' : '导入至日历',
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          if (sortMode == 'term')
                            for (final entry in _groupedSections(items).entries)
                              ListTile(
                                dense: true,
                                title: Text(entry.key,
                                    style: const TextStyle(fontSize: 14)),
                                trailing: Text('${entry.value.length}场',
                                    style: const TextStyle(fontSize: 13)),
                              ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: SingleChildScrollView(
                        controller: _scrollController,
                        physics: const AlwaysScrollableScrollPhysics(),
                        child: sortMode == 'term'
                            ? ExamTermSections(
                                items: items,
                                highlightCourse: widget.highlightCourse)
                            : ExamTable(
                                items: _sortedByTime(items),
                                highlightCourse: widget.highlightCourse),
                      ),
                    ),
                  ],
                );
              }
              return PagePanel(
                title: '考试',
                icon: Icons.assignment,
                expandChild: true,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Row(
                        children: [
                          SizedBox(
                            width: 160,
                            child: DropdownMenu<String>(
                              initialSelection: sortMode,
                              enableSearch: false,
                              requestFocusOnTap: false,
                              onSelected: (value) {
                                if (value != null) {
                                  setState(() => sortMode = value);
                                }
                              },
                              dropdownMenuEntries: const [
                                DropdownMenuEntry(
                                    value: 'term', label: '按学期排列'),
                                DropdownMenuEntry(
                                    value: 'time', label: '按时间排列'),
                              ],
                            ),
                          ),
                          if (sortMode == 'term')
                            IconButton(
                              icon: Icon(sortAscending
                                  ? Icons.arrow_upward
                                  : Icons.arrow_downward),
                              tooltip: sortAscending ? '正序' : '倒序',
                              onPressed: () => setState(
                                  () => sortAscending = !sortAscending),
                            ),
                          const Spacer(),
                          TextButton(
                            onPressed: items.isEmpty || _exporting
                                ? null
                                : () async {
                                    setState(() => _exporting = true);
                                    try {
                                      final year = widget.periods.first.year;
                                      final term = widget.periods.first.term;
                                      final ics = generateExamIcs(
                                          exams: items, year: year, term: term);
                                      if (kIsWeb) {
                                        await ics_download.loadLibrary();
                                        ics_download.downloadIcs(
                                            ics, '考试_${year}_$term.ics');
                                      } else {
                                        await Share.shareXFiles(
                                          [
                                            XFile.fromData(utf8.encode(ics),
                                                name: '考试_${year}_$term.ics',
                                                mimeType: 'text/calendar')
                                          ],
                                          text: '考试_${year}_$term.ics',
                                        );
                                      }
                                    } finally {
                                      if (mounted) {
                                        setState(() => _exporting = false);
                                      }
                                    }
                                  },
                            child: _IconLabel(
                              icon: Icons.event_available,
                              label: _exporting ? '导出中...' : '导入至日历',
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: SingleChildScrollView(
                        controller: _scrollController,
                        physics: const AlwaysScrollableScrollPhysics(),
                        child: sortMode == 'term'
                            ? ExamTermSections(
                                items: items,
                                highlightCourse: widget.highlightCourse)
                            : ExamTable(
                                items: _sortedByTime(items),
                                highlightCourse: widget.highlightCourse),
                      ),
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _refreshExams() async {
    setState(() => _examsFuture = _loadExams(forceRefresh: true));
    await _examsFuture;
  }

  Future<List<PeriodExam>> _loadExams({bool forceRefresh = false}) async {
    final results = await Future.wait([
      for (final period in widget.periods)
        widget.api
            .exams(
              year: period.year,
              term: period.term,
              forceRefresh: forceRefresh,
            )
            .then(
              (result) => [
                for (final item in result.data) PeriodExam(period, item),
              ],
            )
            .catchError((_) => <PeriodExam>[]),
    ]);
    final exams = results.expand((items) => items).toList();
    final byCourse = <String, List<PeriodExam>>{};
    for (final exam in exams) {
      final key = _courseKey(exam.exam.courseName);
      if (key.isEmpty) continue;
      byCourse.putIfAbsent(key, () => []).add(exam);
    }
    for (final courseExams in byCourse.values) {
      courseExams.sort(_compareExamsByTimeAsc);
      for (var i = 0; i < courseExams.length; i++) {
        final exam = courseExams[i];
        exam.retakeIndex = i;
        if (courseExams.length == 1 &&
            (_hasRetakeText(exam.exam.courseName) ||
                _hasRetakeText(exam.exam.type))) {
          exam.retakeIndex = 1;
        }
      }
    }
    return sortMode == 'term' ? _sortedByTerm(exams) : _sortedByTime(exams);
  }

  List<PeriodExam> _sortedByTerm(List<PeriodExam> items) {
    return [...items]..sort((a, b) {
        final periodCompare =
            _periodSortValue(a.period).compareTo(_periodSortValue(b.period));
        if (periodCompare != 0) {
          return sortAscending ? periodCompare : -periodCompare;
        }
        return _compareExamsByTime(a, b);
      });
  }

  List<PeriodExam> _sortedByTime(List<PeriodExam> items) =>
      [...items]..sort(_compareExamsByTime);

  Map<String, List<PeriodExam>> _groupedSections(List<PeriodExam> items) {
    final sections = <String, List<PeriodExam>>{};
    for (final item in items) {
      sections.putIfAbsent(item.period.label, () => []).add(item);
    }
    return sections;
  }
}

class ExamTermSections extends StatelessWidget {
  const ExamTermSections(
      {super.key, required this.items, this.highlightCourse});

  final List<PeriodExam> items;
  final String? highlightCourse;

  @override
  Widget build(BuildContext context) {
    final sections = <String, List<PeriodExam>>{};
    for (final item in items) {
      sections.putIfAbsent(item.period.label, () => []).add(item);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final entry in sections.entries) ...[
          Text(
            entry.key,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          ExamTable(items: entry.value, highlightCourse: highlightCourse),
          const SizedBox(height: 16),
        ],
      ],
    );
  }
}

class ExamTable extends StatelessWidget {
  const ExamTable({super.key, required this.items, this.highlightCourse});

  final List<PeriodExam> items;
  final String? highlightCourse;

  @override
  Widget build(BuildContext context) {
    final highlightKey =
        highlightCourse != null ? _courseKey(highlightCourse!) : null;
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 640) {
          return Column(
            children: [
              for (final item in items)
                _MobileRecordCard(
                  icon: item.isRetake ? Icons.warning : Icons.assignment,
                  title: item.displayName,
                  subtitle: '${item.period.label} · ${item.examKind}',
                  highlight: item.isRetake,
                  highlighted: highlightKey != null &&
                      _courseKey(item.exam.courseName) == highlightKey,
                  rows: [
                    (Icons.badge, '座位', item.exam.seat ?? '-'),
                  ],
                  extraRows: [
                    Row(
                      children: [
                        Icon(Icons.schedule,
                            size: 16,
                            color: Theme.of(context).colorScheme.primary),
                        const SizedBox(width: 4),
                        Text(item.exam.time ?? '-',
                            style: TextStyle(
                                color: Theme.of(context).colorScheme.primary,
                                fontWeight: FontWeight.bold)),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Icon(Icons.location_on,
                            size: 16,
                            color: Theme.of(context).colorScheme.tertiary),
                        const SizedBox(width: 4),
                        Text(item.exam.location ?? '-',
                            style: TextStyle(
                                color: Theme.of(context).colorScheme.tertiary,
                                fontWeight: FontWeight.bold)),
                      ],
                    ),
                  ],
                ),
            ],
          );
        }
        final highlightRows = <int>{};
        if (highlightKey != null) {
          for (var i = 0; i < items.length; i++) {
            if (_courseKey(items[i].exam.courseName) == highlightKey) {
              highlightRows.add(i);
            }
          }
        }
        return SimpleTable(
          headers: const ['学期', '课程', '类型', '时间', '地点', '座位'],
          columnFlexs: const [2, 3, 2, 4, 3, 1],
          highlightedRows: {
            for (var i = 0; i < items.length; i++)
              if (items[i].isRetake || highlightRows.contains(i)) i,
          },
          rowHighlightColors: {
            for (var i = 0; i < items.length; i++)
              if (items[i].isRetake) i: _retakeFill(items[i].retakeIndex),
            for (final i in highlightRows)
              if (!items[i].isRetake)
                i: Theme.of(context)
                    .colorScheme
                    .primaryContainer
                    .withValues(alpha: 0.3),
          },
          rowTextColors: {
            for (var i = 0; i < items.length; i++)
              if (items[i].isRetake) i: _retakeText(items[i].retakeIndex),
          },
          rows: [
            for (final item in items)
              [
                item.period.label,
                item.displayName,
                item.examKind,
                item.exam.time ?? '-',
                item.exam.location ?? '-',
                item.exam.seat ?? '-',
              ],
          ],
        );
      },
    );
  }
}

class GradesPage extends StatefulWidget {
  const GradesPage(
      {super.key,
      required this.api,
      required this.periods,
      this.onSessionExpired,
      this.onNavigateToExam});

  final ApiClient api;
  final List<AcademicPeriod> periods;
  final VoidCallback? onSessionExpired;
  final ValueChanged<String>? onNavigateToExam;

  @override
  State<GradesPage> createState() => _GradesPageState();
}

class _GradesPageState extends State<GradesPage> {
  late Future<List<GradeGroup>> _gradesFuture;
  late String _periodsSignature;

  @override
  void initState() {
    super.initState();
    _periodsSignature = _periodSignature(widget.periods);
    _gradesFuture = _loadGrades();
  }

  @override
  void didUpdateWidget(covariant GradesPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final nextSignature = _periodSignature(widget.periods);
    if (oldWidget.api != widget.api || nextSignature != _periodsSignature) {
      _periodsSignature = nextSignature;
      _gradesFuture = _loadGrades();
    }
  }

  @override
  Widget build(BuildContext context) {
    return PageRefresh(
      onRefresh: _refreshGrades,
      child: AsyncPanel<List<GradeGroup>>(
        future: _gradesFuture,
        onSessionExpired: widget.onSessionExpired,
        builder: (items) => LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 720;
            if (wide) {
              final retakeCount = items.where((g) => g.hasRetake).length;
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 300,
                    child: PagePanel(
                      title: '成绩统计',
                      icon: Icons.bar_chart,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('共 ${items.length} 门课程'),
                          const SizedBox(height: 8),
                          Text('补考/重修: $retakeCount 门'),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: PagePanel(
                      title: '成绩',
                      icon: Icons.school,
                      expandChild: true,
                      child: SingleChildScrollView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        child: GradeGroupList(
                            groups: items, onExamTap: widget.onNavigateToExam),
                      ),
                    ),
                  ),
                ],
              );
            }
            return PagePanel(
              title: '成绩',
              icon: Icons.school,
              expandChild: true,
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                child: GradeGroupList(
                    groups: items, onExamTap: widget.onNavigateToExam),
              ),
            );
          },
        ),
      ),
    );
  }

  Future<void> _refreshGrades() async {
    setState(() => _gradesFuture = _loadGrades(forceRefresh: true));
    await _gradesFuture;
  }

  Future<List<GradeGroup>> _loadGrades({bool forceRefresh = false}) async {
    final results = await Future.wait([
      for (final period in widget.periods)
        widget.api
            .grades(
              year: period.year,
              term: period.term,
              forceRefresh: forceRefresh,
            )
            .then(
              (result) => [
                for (final item in result.data) GradeAttempt(period, item),
              ],
            )
            .catchError((_) => <GradeAttempt>[]),
    ]);
    final attempts = results.expand((items) => items).toList();
    unawaited(_notifyGradeUpdates(attempts));
    final groups = <String, GradeGroup>{};
    for (final attempt in attempts) {
      final courseKey = _courseKey(attempt.grade.courseName);
      final key = courseKey.isEmpty
          ? '${attempt.period.label}:${attempt.grade.score ?? ''}'
          : courseKey;
      final group = groups[key];
      if (group == null) {
        groups[key] = GradeGroup(attempt);
      } else {
        group.attempts.add(attempt);
      }
    }
    return groups.values.toList();
  }

  Future<void> _notifyGradeUpdates(List<GradeAttempt> attempts) async {
    if (attempts.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final key = 'grades.live_update.$_periodsSignature';
    final current = _gradeSnapshot(attempts);
    final previousRaw = prefs.getString(key);
    await prefs.setString(key, jsonEncode(current));
    if (previousRaw == null || previousRaw.isEmpty) return;
    final previous = _decodeStringMap(previousRaw);
    final changed = attempts.where((attempt) {
      final snapshotKey = _gradeSnapshotKey(attempt);
      final oldValue = previous[snapshotKey];
      return (oldValue != null && oldValue != current[snapshotKey]) ||
          oldValue == null;
    }).toList();
    if (changed.isEmpty) return;
    final latest = changed.first;
    const title = '成绩更新';
    final score = latest.grade.score?.trim();
    final body = score == null || score.isEmpty
        ? '${latest.grade.courseName} 已发布成绩'
        : '${latest.grade.courseName}：$score';
    final eventId =
        'grade_update:${_gradeSnapshotKey(latest)}:${current[_gradeSnapshotKey(latest)]}';
    final extras = {
      'id': eventId,
      'type': 'grade_update',
      'liveUpdate': true,
      'style': 'progress',
      'shortCriticalText': '成绩',
      'progressMax': 100,
      'progressCurrent': 100,
    };
    LiveActivityController.instance.show(LiveActivityEvent(
      id: eventId,
      type: 'grade_update',
      title: title,
      body: body,
      style: 'progress',
      shortText: '成绩',
      targetTab: 'grades',
      ongoing: false,
      progress: 1,
    ));
    final notificationId = eventId.hashCode.abs();
    await live_update_service.loadLibrary();
    final posted = await live_update_service.LiveUpdateService.postLiveUpdate(
      id: notificationId,
      title: title,
      body: body,
      style: 'progress',
      shortCriticalText: '成绩',
      extras: extras,
      ongoing: false,
      progressMax: 100,
      progressCurrent: 100,
    );
    if (!posted) {
      await local_notification_service.loadLibrary();
      await local_notification_service.LocalNotificationService.show(
        id: notificationId,
        title: title,
        body: body,
        extras: extras,
      );
    }
  }

  Map<String, String> _gradeSnapshot(List<GradeAttempt> attempts) {
    return {
      for (final attempt in attempts)
        _gradeSnapshotKey(attempt): [
          attempt.grade.score ?? '',
          attempt.grade.gradePoint ?? '',
        ].join('|'),
    };
  }

  String _gradeSnapshotKey(GradeAttempt attempt) {
    return [
      attempt.period.year,
      attempt.period.term,
      _courseKey(attempt.grade.courseName),
    ].join('|');
  }

  Map<String, String> _decodeStringMap(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const {};
      return decoded.map(
        (key, value) => MapEntry(key.toString(), value.toString()),
      );
    } catch (_) {
      return const {};
    }
  }
}

class GradeGroupList extends StatelessWidget {
  const GradeGroupList({super.key, required this.groups, this.onExamTap});

  final List<GradeGroup> groups;
  final ValueChanged<String>? onExamTap;

  @override
  Widget build(BuildContext context) {
    final border =
        BorderSide(color: Theme.of(context).colorScheme.outlineVariant);
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 640) {
          return Column(
            children: [
              for (final group in groups)
                GradeMobileCard(
                  group: group,
                  onExamTap: onExamTap != null
                      ? () => onExamTap!(group.displayName)
                      : null,
                ),
            ],
          );
        }
        return ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Column(
            children: [
              _TableRow(
                values: const ['课程', '成绩', '学分', '绩点'],
                strong: true,
                border: border,
              ),
              for (final group in groups)
                GradeGroupRow(
                  group: group,
                  border: border,
                  onExamTap: onExamTap != null
                      ? () => onExamTap!(group.displayName)
                      : null,
                ),
            ],
          ),
        );
      },
    );
  }
}

class GradeMobileCard extends StatelessWidget {
  const GradeMobileCard({super.key, required this.group, this.onExamTap});

  final GradeGroup group;
  final VoidCallback? onExamTap;

  @override
  Widget build(BuildContext context) {
    final latest = group.latest;
    return _MobileRecordCard(
      icon: group.hasRetake ? Icons.warning : Icons.school,
      title: group.displayName,
      subtitle: latest.period.label,
      highlight: group.hasRetake,
      rows: [
        (Icons.check_circle, '成绩', latest.grade.score ?? '-'),
        (Icons.auto_stories, '学分', latest.grade.credit ?? '-'),
        (Icons.bar_chart, '绩点', latest.grade.gradePoint ?? '-'),
        if (group.hasRetake) (Icons.list, '记录', '${group.attempts.length} 次'),
      ],
      trailing: onExamTap != null
          ? _ScaleTap(
              onTap: onExamTap,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.assignment,
                        size: 12,
                        color:
                            Theme.of(context).colorScheme.onSecondaryContainer),
                    const SizedBox(width: 2),
                    Text('考试',
                        style: TextStyle(
                            fontSize: 10,
                            color: Theme.of(context)
                                .colorScheme
                                .onSecondaryContainer)),
                  ],
                ),
              ),
            )
          : null,
    );
  }
}

class GradeGroupRow extends StatelessWidget {
  const GradeGroupRow(
      {super.key, required this.group, required this.border, this.onExamTap});

  final GradeGroup group;
  final BorderSide border;
  final VoidCallback? onExamTap;

  @override
  Widget build(BuildContext context) {
    final latest = group.latest;
    final examTag = onExamTap != null
        ? InkWell(
            onTap: onExamTap,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.secondaryContainer,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.assignment,
                      size: 12,
                      color:
                          Theme.of(context).colorScheme.onSecondaryContainer),
                  const SizedBox(width: 2),
                  Text('考试',
                      style: TextStyle(
                          fontSize: 10,
                          color: Theme.of(context)
                              .colorScheme
                              .onSecondaryContainer)),
                ],
              ),
            ),
          )
        : null;
    final values = [
      group.displayName,
      latest.grade.score ?? '-',
      latest.grade.credit ?? '-',
      latest.grade.gradePoint ?? '-',
    ];
    if (!group.hasRetake) {
      if (examTag == null) return _TableRow(values: values, border: border);
      return Container(
        decoration: BoxDecoration(
          border: Border(bottom: border),
        ),
        child: Row(
          children: [
            for (var i = 0; i < values.length; i++)
              Expanded(
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  child: i == 0
                      ? Row(
                          children: [
                            Flexible(
                                child: Text(values[i],
                                    overflow: TextOverflow.ellipsis)),
                            const SizedBox(width: 6),
                            examTag,
                          ],
                        )
                      : Text(values[i], overflow: TextOverflow.ellipsis),
                ),
              ),
          ],
        ),
      );
    }
    return Container(
      decoration: BoxDecoration(
        color: _accentFill(context),
        border: Border(bottom: border),
      ),
      child: ExpansionTile(
        title: _TableRowContent(
          values: values,
          color: Theme.of(context).colorScheme.primary,
          strong: true,
        ),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '更多考试',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                SimpleTable(
                  headers: const ['学期', '课程', '成绩', '学分', '绩点'],
                  rows: [
                    for (final attempt in group.attempts)
                      [
                        attempt.period.label,
                        attempt.grade.courseName,
                        attempt.grade.score ?? '-',
                        attempt.grade.credit ?? '-',
                        attempt.grade.gradePoint ?? '-',
                      ],
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class CreditsPage extends StatefulWidget {
  const CreditsPage({super.key, required this.api, this.onSessionExpired});

  final ApiClient api;
  final VoidCallback? onSessionExpired;

  @override
  State<CreditsPage> createState() => _CreditsPageState();
}

class _CreditsPageState extends State<CreditsPage> {
  late Future<List<CreditItem>> _creditsFuture;

  @override
  void initState() {
    super.initState();
    _creditsFuture = _loadCredits();
  }

  @override
  void didUpdateWidget(covariant CreditsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.api != widget.api) {
      _creditsFuture = _loadCredits();
    }
  }

  Future<List<CreditItem>> _loadCredits({bool forceRefresh = false}) =>
      widget.api.credits(forceRefresh: forceRefresh).then((r) => r.data);

  Future<void> _refreshCredits() async {
    setState(() => _creditsFuture = _loadCredits(forceRefresh: true));
    await _creditsFuture;
  }

  @override
  Widget build(BuildContext context) {
    return PageRefresh(
      onRefresh: _refreshCredits,
      child: AsyncPanel<List<CreditItem>>(
        future: _creditsFuture,
        onSessionExpired: widget.onSessionExpired,
        builder: (items) => LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 720;
            if (wide) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 300,
                    child: PagePanel(
                      title: '学分概览',
                      icon: Icons.auto_stories,
                      child: Column(
                        children: [
                          for (final item in items) ...[
                            _CreditOverviewCard(item: item),
                            if (item != items.last) const SizedBox(height: 12),
                          ],
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: PagePanel(
                      title: '学分统计',
                      icon: Icons.auto_stories,
                      expandChild: true,
                      child: SingleChildScrollView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        child: Column(
                          children: [
                            for (final item in items)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 12),
                                child: CreditCard(item: item),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              );
            }
            return PagePanel(
              title: '学分统计',
              icon: Icons.auto_stories,
              expandChild: true,
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                child: Column(
                  children: [
                    for (final item in items)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: CreditCard(item: item),
                      ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _CreditOverviewCard extends StatelessWidget {
  const _CreditOverviewCard({required this.item});
  final CreditItem item;

  @override
  Widget build(BuildContext context) {
    final expected =
        item.requiredExpected + item.electiveExpected + item.otherExpected;
    final earned = item.requiredEarned + item.electiveEarned + item.otherEarned;
    final totalExpected =
        item.totalExpected == 0 ? expected : item.totalExpected;
    final totalEarned = item.totalEarned == 0 ? earned : item.totalEarned;
    final progress = expected <= 0 ? 0.0 : (earned / expected).clamp(0.0, 1.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${item.name ?? '-'} · ${item.major ?? '-'}',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
                child: Text('已修 ${totalEarned.toStringAsFixed(1)}',
                    style: const TextStyle(fontSize: 13))),
            Text('应修 ${totalExpected.toStringAsFixed(1)}',
                style: const TextStyle(fontSize: 13)),
          ],
        ),
        const SizedBox(height: 4),
        LinearProgressIndicator(value: progress),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            InfoTile(
                icon: Icons.check,
                label: '必修',
                value: '${item.requiredEarned}/${item.requiredExpected}'),
            InfoTile(
                icon: Icons.book,
                label: '选修',
                value: '${item.electiveEarned}/${item.electiveExpected}'),
          ],
        ),
      ],
    );
  }
}

class CreditCard extends StatelessWidget {
  const CreditCard({super.key, required this.item});

  final CreditItem item;

  @override
  Widget build(BuildContext context) {
    final expected =
        item.requiredExpected + item.electiveExpected + item.otherExpected;
    final earned = item.requiredEarned + item.electiveEarned + item.otherEarned;
    final totalExpected =
        item.totalExpected == 0 ? expected : item.totalExpected;
    final totalEarned = item.totalEarned == 0 ? earned : item.totalEarned;
    final progress = expected <= 0 ? 0.0 : (earned / expected).clamp(0.0, 1.0);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const _IconBadge(icon: Icons.auto_stories, size: 36),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '${item.name ?? '-'} · ${item.major ?? '-'}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                InfoTile(
                    icon: Icons.verified,
                    label: '培养方案总学分',
                    value: item.totalCredit ?? '-'),
                InfoTile(
                    icon: Icons.check_circle,
                    label: '已修学分',
                    value: totalEarned.toStringAsFixed(2)),
                InfoTile(
                    icon: Icons.list,
                    label: '应修合计',
                    value: totalExpected.toStringAsFixed(2)),
                InfoTile(
                    icon: Icons.auto_stories,
                    label: '选课学分',
                    value: item.selectedCredit ?? '-'),
              ],
            ),
            const SizedBox(height: 12),
            LinearProgressIndicator(value: progress),
            const SizedBox(height: 12),
            SimpleTable(
              headers: const ['类别', '应修', '实修'],
              rows: [
                ['必修', '${item.requiredExpected}', '${item.requiredEarned}'],
                ['选修', '${item.electiveExpected}', '${item.electiveEarned}'],
                ['其他', '${item.otherExpected}', '${item.otherEarned}'],
                ['合计', '$expected', '$earned'],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _IconLabel extends StatelessWidget {
  const _IconLabel({
    required this.icon,
    required this.label,
    this.centered = false,
  });

  final IconData icon;
  final String label;
  final bool centered;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: centered ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment:
          centered ? MainAxisAlignment.center : MainAxisAlignment.start,
      children: [
        Icon(icon, size: 15),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

class _IconBadge extends StatelessWidget {
  const _IconBadge({required this.icon, this.size = 40});

  final IconData icon;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(size >= 38 ? 16 : 12),
      ),
      child:
          Icon(icon, size: size * 0.48, color: colorScheme.onPrimaryContainer),
    );
  }
}

class _MetricPill extends StatelessWidget {
  const _MetricPill({
    required this.icon,
    required this.label,
    required this.value,
    this.width,
    this.dense = false,
  });

  final IconData icon;
  final String label;
  final String value;
  final double? width;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final content = Container(
      padding: EdgeInsets.symmetric(
        horizontal: dense ? 8 : 12,
        vertical: dense ? 6 : 9,
      ),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.62),
        borderRadius: BorderRadius.circular(dense ? 12 : 16),
      ),
      child: Row(
        mainAxisSize: width == null ? MainAxisSize.min : MainAxisSize.max,
        children: [
          Icon(icon, size: dense ? 13 : 15, color: colorScheme.primary),
          SizedBox(width: dense ? 4 : 6),
          Flexible(
            child: Text(
              dense ? '$label$value' : '$label $value',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: dense ? 12 : null,
                color: colorScheme.onSurface,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
    if (width != null) return SizedBox(width: width, child: content);
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: (MediaQuery.sizeOf(context).width - 56)
            .clamp(136.0, 420.0)
            .toDouble(),
      ),
      child: content,
    );
  }
}

class EcardPage extends StatefulWidget {
  const EcardPage({super.key, required this.api, this.onSessionExpired});

  final ApiClient api;
  final VoidCallback? onSessionExpired;

  @override
  State<EcardPage> createState() => _EcardPageState();
}

class _EcardPageState extends State<EcardPage> {
  late Future<EcardSummary> _summaryFuture;
  Future<List<EcardRoomItem>>? _roomsFuture;
  final _searchController = TextEditingController();
  bool _refreshing = false;
  int _refreshVersion = 0;
  String? _error;
  Timer? _periodicRefreshTimer;
  Timer? _searchDebounce;
  String _lastSearchQuery = '';

  @override
  void initState() {
    super.initState();
    _summaryFuture = widget.api.ecardSummary().then((r) => r.data);
    _periodicRefreshTimer = Timer.periodic(const Duration(minutes: 30), (_) {
      if (!mounted) return;
      _silentRefresh();
    });
  }

  @override
  void didUpdateWidget(covariant EcardPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.api != widget.api) {
      _summaryFuture = widget.api.ecardSummary().then((r) => r.data);
      _roomsFuture = null;
    }
  }

  @override
  void dispose() {
    _periodicRefreshTimer?.cancel();
    _searchDebounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _silentRefresh() async {
    try {
      final summary =
          await widget.api.ecardSummary(forceRefresh: true).then((r) => r.data);
      if (!mounted) return;
      setState(() => _summaryFuture = Future.value(summary));
    } catch (_) {
      // Silent refresh — ignore errors
    }
  }

  Future<void> _refreshBalance() async {
    setState(() {
      _refreshing = true;
      _error = null;
    });
    try {
      final summary = await widget.api.refreshEcard();
      if (!mounted) return;
      setState(() => _summaryFuture = Future.value(summary));
    } catch (exc) {
      _handleError(exc);
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _refreshEcardPage() async {
    setState(() {
      _error = null;
      _refreshVersion++;
      _summaryFuture =
          widget.api.ecardSummary(forceRefresh: true).then((r) => r.data);
      if (_roomsFuture != null) {
        _roomsFuture = widget.api.ecardRooms(
          query: _lastSearchQuery, forceRefresh: true,
        );
      }
    });
    await _summaryFuture;
  }

  Future<void> _bindRoom(EcardRoomItem room) async {
    try {
      final summary = await widget.api.bindEcardRoom(room);
      if (!mounted) return;
      setState(() {
        _summaryFuture = Future.value(summary);
        _roomsFuture = null;
        _error = null;
      });
    } catch (exc) {
      _handleError(exc);
    }
  }

  Future<void> _updateReminder(EcardSummary current,
      {bool? enabled,
      double? lowPowerThreshold,
      double? lowColdWaterThreshold,
      double? lowHotWaterThreshold,
      List<String>? reminderTimes,
      List<String>? reminderItems}) async {
    try {
      final summary = await widget.api.updateEcardReminder(
        enabled: enabled,
        lowPowerThreshold: lowPowerThreshold,
        lowColdWaterThreshold: lowColdWaterThreshold,
        lowHotWaterThreshold: lowHotWaterThreshold,
        reminderTimes: reminderTimes,
        reminderItems: reminderItems,
      );
      if (!mounted) return;
      setState(() => _summaryFuture = Future.value(summary));
    } catch (exc) {
      _handleError(exc);
    }
  }

  void _handleError(Object exc) {
    if (!mounted) return;
    if (exc is ApiException && exc.statusCode == 401 && widget.onSessionExpired != null) {
      widget.onSessionExpired!();
      return;
    }
    setState(() => _error = exc is ApiException ? exc.message : exc.toString());
  }

  void _onRoomSearch(String query) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 400), () {
      final trimmed = query.trim();
      if (trimmed == _lastSearchQuery) return;
      _lastSearchQuery = trimmed;
      if (!mounted) return;
      setState(() {
        _roomsFuture = widget.api.ecardRooms(query: trimmed);
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<EcardSummary>(
      future: _summaryFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          final error = snapshot.error;
          final isSessionError = error is ApiException && error.statusCode == 401;
          if (isSessionError && widget.onSessionExpired != null) {
            return _SessionExpiredPrompt(onRelogin: widget.onSessionExpired!);
          }
          return EmptyState(
            message: error is ApiException ? error.message : '生活缴费加载失败',
          );
        }
        final summary =
            snapshot.data ?? EcardSummary.fromJson({'status': 'not_bound'});
        return RefreshIndicator(
          onRefresh: _refreshEcardPage,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              if (_error != null) ...[
                Text(_error!,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error)),
                const SizedBox(height: 12),
              ],
              if (!summary.isBound)
                _RoomBindingPanel(
                  roomsFuture: _roomsFuture,
                  searchController: _searchController,
                  onSearchChanged: _onRoomSearch,
                  onRoomSelected: _bindRoom,
                )
              else ...[
                _EcardSummaryPanel(
                  summary: summary,
                  refreshing: _refreshing,
                  onRefresh: _refreshBalance,
                  onChangeRoom: () => setState(() {
                    _roomsFuture = widget.api.ecardRooms(forceRefresh: true);
                  }),
                ),
                const SizedBox(height: 12),
                if (_roomsFuture != null)
                  _RoomBindingPanel(
                    roomsFuture: _roomsFuture!,
                    searchController: _searchController,
                    onSearchChanged: _onRoomSearch,
                    onRoomSelected: _bindRoom,
                  ),
                const SizedBox(height: 12),
                _EcardReminderPanel(
                  summary: summary,
                  onChanged: _updateReminder,
                ),
                const SizedBox(height: 12),
                _EcardConsumptionPanel(
                  api: widget.api,
                  refreshVersion: _refreshVersion,
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _SessionExpiredPrompt extends StatelessWidget {
  const _SessionExpiredPrompt({required this.onRelogin});

  final VoidCallback onRelogin;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 24),
          decoration: BoxDecoration(
            color: gzusSurface(context),
            borderRadius: BorderRadius.circular(GzusRadii.lg),
            border: Border.all(color: gzusBorder(context)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: Theme.of(context)
                      .colorScheme
                      .errorContainer
                      .withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(
                  Icons.lock_outline,
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                '登录已过期，请重新登录',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: onRelogin,
                icon: const Icon(Icons.login, size: 18),
                label: const Text('重新登录'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EcardSummaryPanel extends StatelessWidget {
  const _EcardSummaryPanel({
    required this.summary,
    required this.refreshing,
    required this.onRefresh,
    required this.onChangeRoom,
  });

  final EcardSummary summary;
  final bool refreshing;
  final VoidCallback onRefresh;
  final VoidCallback onChangeRoom;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final warnColor =
        summary.isCriticalPower ? colorScheme.error : colorScheme.primary;
    return PagePanel(
      title: '生活缴费',
      icon: Icons.water_drop,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      summary.roomDisplay ?? '-',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    if (summary.studentId != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        '学号: ${summary.studentId}',
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              IconButton(
                tooltip: '刷新',
                onPressed: refreshing ? null : onRefresh,
                icon: refreshing
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh),
              ),
              IconButton(
                tooltip: '更换宿舍',
                onPressed: onChangeRoom,
                icon: const Icon(Icons.edit_location_alt),
              ),
            ],
          ),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, constraints) {
              final columnWidth =
                  ((constraints.maxWidth - 12) / 2).clamp(150.0, 260.0);
              return Center(
                child: Wrap(
                  alignment: WrapAlignment.center,
                  crossAxisAlignment: WrapCrossAlignment.start,
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    _BalanceGroup(
                      title: '宿舍',
                      width: columnWidth.toDouble(),
                      children: [
                        _BalanceCard(
                          icon: Icons.electric_bolt,
                          label: '电费',
                          value: summary.powerText ?? '-',
                          color: summary.isLowPower ? warnColor : null,
                        ),
                        _BalanceCard(
                          icon: Icons.water,
                          label: '冷水',
                          value: summary.coldWaterText ?? '-',
                        ),
                      ],
                    ),
                    _BalanceGroup(
                      title: '个人',
                      width: columnWidth.toDouble(),
                      children: [
                        _BalanceCard(
                          icon: Icons.local_fire_department,
                          label: '热水',
                          value: summary.hotWaterText ?? '-',
                          color: colorScheme.tertiary,
                        ),
                      ],
                    ),
                  ],
                ),
              );
            },
          ),
          if (summary.updatedAt != null) ...[
            const SizedBox(height: 10),
            Text('更新时间 ${summary.updatedAt}',
                style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ],
        ],
      ),
    );
  }
}

class _BalanceGroup extends StatelessWidget {
  const _BalanceGroup({
    required this.title,
    required this.children,
    required this.width,
  });

  final String title;
  final List<Widget> children;
  final double width;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child: Text(
              title,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
            ),
          ),
          for (var i = 0; i < children.length; i++) ...[
            children[i],
            if (i != children.length - 1) const SizedBox(height: 10),
          ],
        ],
      ),
    );
  }
}

class _BalanceCard extends StatelessWidget {
  const _BalanceCard({
    required this.icon,
    required this.label,
    required this.value,
    this.color,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final effectiveColor = color ?? Theme.of(context).colorScheme.primary;
    final colorScheme = Theme.of(context).colorScheme;
    final cardColor = color?.withValues(alpha: 0.08);
    return Card(
      elevation: color != null ? 2 : 1,
      color: cardColor,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: effectiveColor, size: 24),
            const SizedBox(height: 20),
            Text(label, style: TextStyle(color: colorScheme.onSurfaceVariant)),
            const SizedBox(height: 4),
            Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: effectiveColor,
                fontSize: 22,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RoomBindingPanel extends StatefulWidget {
  const _RoomBindingPanel({
    required this.roomsFuture,
    required this.searchController,
    required this.onSearchChanged,
    required this.onRoomSelected,
  });

  final Future<List<EcardRoomItem>>? roomsFuture;
  final TextEditingController searchController;
  final ValueChanged<String> onSearchChanged;
  final ValueChanged<EcardRoomItem> onRoomSelected;

  @override
  State<_RoomBindingPanel> createState() => _RoomBindingPanelState();
}

class _RoomBindingPanelState extends State<_RoomBindingPanel> {
  @override
  Widget build(BuildContext context) {
    return PagePanel(
      title: '宿舍绑定',
      icon: Icons.home_work,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: widget.searchController,
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: '输入楼栋或房间号搜索',
              border: OutlineInputBorder(),
            ),
            onChanged: widget.onSearchChanged,
          ),
          const SizedBox(height: 12),
          if (widget.roomsFuture == null)
            const EmptyState(message: '请输入关键词搜索宿舍')
          else
            FutureBuilder<List<EcardRoomItem>>(
              future: widget.roomsFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.hasError) {
                  return const EmptyState(message: '宿舍列表加载失败');
                }
                final rooms = snapshot.data ?? const [];
                if (rooms.isEmpty) return const EmptyState(message: '未找到宿舍');
                return SizedBox(
                  height: 360,
                  child: ListView.separated(
                    itemCount: rooms.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final room = rooms[index];
                      return ListTile(
                        leading: const Icon(Icons.meeting_room),
                        title: Text(room.displayName,
                            overflow: TextOverflow.ellipsis),
                        subtitle: Text('${room.schoolArea} ${room.building}'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => widget.onRoomSelected(room),
                      );
                    },
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}

class _EcardReminderPanel extends StatefulWidget {
  const _EcardReminderPanel({required this.summary, required this.onChanged});

  final EcardSummary summary;
  final Future<void> Function(
    EcardSummary summary, {
    bool? enabled,
    double? lowPowerThreshold,
    double? lowColdWaterThreshold,
    double? lowHotWaterThreshold,
    List<String>? reminderTimes,
    List<String>? reminderItems,
  }) onChanged;

  @override
  State<_EcardReminderPanel> createState() => _EcardReminderPanelState();
}

class _EcardReminderPanelState extends State<_EcardReminderPanel> {
  late double _powerThreshold;
  late double _coldWaterThreshold;
  late double _hotWaterThreshold;
  late List<String> _reminderTimes;
  late List<String> _reminderItems;

  @override
  void initState() {
    super.initState();
    _syncFromWidget();
  }

  @override
  void didUpdateWidget(covariant _EcardReminderPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.summary.lowPowerThreshold !=
            widget.summary.lowPowerThreshold ||
        oldWidget.summary.lowColdWaterThreshold !=
            widget.summary.lowColdWaterThreshold ||
        oldWidget.summary.lowHotWaterThreshold !=
            widget.summary.lowHotWaterThreshold ||
        oldWidget.summary.reminderTimes != widget.summary.reminderTimes ||
        oldWidget.summary.reminderItems != widget.summary.reminderItems) {
      _syncFromWidget();
    }
  }

  void _syncFromWidget() {
    _powerThreshold = widget.summary.lowPowerThreshold;
    _coldWaterThreshold = widget.summary.lowColdWaterThreshold;
    _hotWaterThreshold = widget.summary.lowHotWaterThreshold;
    _reminderTimes = List.from(widget.summary.reminderTimes);
    _reminderItems = List.from(widget.summary.reminderItems);
  }

  Future<void> _pickTime(int index) async {
    final initial =
        index < _reminderTimes.length ? _reminderTimes[index] : '08:00';
    final parts = initial.split(':');
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(
          hour: int.tryParse(parts[0]) ?? 8,
          minute: int.tryParse(parts[1]) ?? 0),
    );
    if (time == null) return;
    final newTime =
        '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
    setState(() {
      if (index < _reminderTimes.length) {
        _reminderTimes[index] = newTime;
      } else {
        _reminderTimes.add(newTime);
      }
    });
    await widget.onChanged(widget.summary,
        reminderTimes: List.from(_reminderTimes));
  }

  Future<void> _removeTime(int index) async {
    setState(() {
      _reminderTimes.removeAt(index);
    });
    await widget.onChanged(widget.summary,
        reminderTimes: List.from(_reminderTimes));
  }

  @override
  Widget build(BuildContext context) {
    return PagePanel(
      title: '每日提醒',
      icon: Icons.notifications_active,
      child: Column(
        children: [
          SwitchListTile(
            value: widget.summary.reminderEnabled,
            onChanged: (value) =>
                widget.onChanged(widget.summary, enabled: value),
            title: const Text('每日水电费提醒'),
          ),
          // Reminder times
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('提醒时间', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (var i = 0; i < _reminderTimes.length; i++)
                      Chip(
                        label: Text(_reminderTimes[i]),
                        onDeleted: _reminderTimes.length > 1
                            ? () => _removeTime(i)
                            : null,
                      ),
                    if (_reminderTimes.length < 2)
                      ActionChip(
                        avatar: const Icon(Icons.add, size: 18),
                        label: const Text('添加'),
                        onPressed: () => _pickTime(_reminderTimes.length),
                      ),
                  ],
                ),
              ],
            ),
          ),
          const Divider(),
          // Reminder items
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              children: [
                SwitchListTile(
                  value: _reminderItems.contains('power'),
                  onChanged: (v) {
                    setState(() {
                      if (v) {
                        _reminderItems.add('power');
                      } else {
                        _reminderItems.remove('power');
                      }
                    });
                    widget.onChanged(widget.summary,
                        reminderItems: List.from(_reminderItems));
                  },
                  title: const Text('电费提醒'),
                  secondary: const Icon(Icons.electric_bolt),
                ),
                SwitchListTile(
                  value: _reminderItems.contains('cold_water'),
                  onChanged: (v) {
                    setState(() {
                      if (v) {
                        _reminderItems.add('cold_water');
                      } else {
                        _reminderItems.remove('cold_water');
                      }
                    });
                    widget.onChanged(widget.summary,
                        reminderItems: List.from(_reminderItems));
                  },
                  title: const Text('冷水提醒'),
                  secondary: const Icon(Icons.water),
                ),
                SwitchListTile(
                  value: _reminderItems.contains('hot_water'),
                  onChanged: (v) {
                    setState(() {
                      if (v) {
                        _reminderItems.add('hot_water');
                      } else {
                        _reminderItems.remove('hot_water');
                      }
                    });
                    widget.onChanged(widget.summary,
                        reminderItems: List.from(_reminderItems));
                  },
                  title: const Text('热水提醒'),
                  secondary: const Icon(Icons.local_fire_department),
                ),
              ],
            ),
          ),
          const Divider(),
          // Thresholds
          _ThresholdSlider(
            label: '低电阈值',
            value: _powerThreshold,
            unit: '度',
            min: 1,
            max: 100,
            onChanged: (v) => setState(() => _powerThreshold = v),
            onChangeEnd: (v) =>
                widget.onChanged(widget.summary, lowPowerThreshold: v),
          ),
          _ThresholdSlider(
            label: '低冷水阈值',
            value: _coldWaterThreshold,
            unit: '吨',
            min: 0.5,
            max: 50,
            onChanged: (v) => setState(() => _coldWaterThreshold = v),
            onChangeEnd: (v) =>
                widget.onChanged(widget.summary, lowColdWaterThreshold: v),
          ),
          _ThresholdSlider(
            label: '低热水阈值',
            value: _hotWaterThreshold,
            unit: '元',
            min: 1,
            max: 50,
            onChanged: (v) => setState(() => _hotWaterThreshold = v),
            onChangeEnd: (v) =>
                widget.onChanged(widget.summary, lowHotWaterThreshold: v),
          ),
        ],
      ),
    );
  }
}

class _ThresholdSlider extends StatelessWidget {
  const _ThresholdSlider({
    required this.label,
    required this.value,
    required this.unit,
    required this.min,
    required this.max,
    required this.onChanged,
    required this.onChangeEnd,
  });

  final String label;
  final double value;
  final String unit;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: Text(label)),
        SizedBox(
          width: 160,
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: ((max - min) * 2).toInt(),
            label: '${value.toStringAsFixed(1)} $unit',
            onChanged: onChanged,
            onChangeEnd: onChangeEnd,
          ),
        ),
        SizedBox(
          width: 56,
          child: Text('${value.toStringAsFixed(1)} $unit'),
        ),
      ],
    );
  }
}

class _EcardConsumptionPanel extends StatefulWidget {
  const _EcardConsumptionPanel({
    required this.api,
    required this.refreshVersion,
  });

  final ApiClient api;
  final int refreshVersion;

  @override
  State<_EcardConsumptionPanel> createState() => _EcardConsumptionPanelState();
}

class _EcardConsumptionPanelState extends State<_EcardConsumptionPanel> {
  late Future<EcardConsumptionResponse> _consumptionFuture;

  @override
  void initState() {
    super.initState();
    _consumptionFuture = widget.api.ecardConsumption();
  }

  @override
  void didUpdateWidget(covariant _EcardConsumptionPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.api != widget.api ||
        oldWidget.refreshVersion != widget.refreshVersion) {
      _consumptionFuture = widget.api.ecardConsumption(
        forceRefresh: oldWidget.refreshVersion != widget.refreshVersion,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return PagePanel(
      title: '电费消费记录',
      icon: Icons.electric_bolt,
      child: FutureBuilder<EcardConsumptionResponse>(
        future: _consumptionFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) return const EmptyState(message: '消费记录加载失败');
          final data = snapshot.data;
          if (data == null || data.items.isEmpty) {
            return EmptyState(message: data?.message ?? '暂无消费记录');
          }
          return Column(
            children: [
              for (final item in data.items)
                ListTile(
                  leading: const Icon(Icons.payments),
                  title: Text(item.title, overflow: TextOverflow.ellipsis),
                  subtitle: Text(item.time),
                  trailing: Text(item.amount),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _FrostedBanner extends StatelessWidget {
  const _FrostedBanner({
    required this.child,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return ClipRRect(
      borderRadius: BorderRadius.circular(GzusRadii.lg),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: gzusSurface(context).withValues(alpha: dark ? 0.62 : 0.72),
            borderRadius: BorderRadius.circular(GzusRadii.lg),
            border: Border.all(
              color: Colors.white.withValues(alpha: dark ? 0.10 : 0.55),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: dark ? 0.18 : 0.045),
                blurRadius: 22,
                offset: const Offset(0, 12),
              ),
            ],
          ),
          child: child,
        ),
      ),
    );
  }
}

class PagePanel extends StatelessWidget {
  const PagePanel({
    super.key,
    required this.title,
    required this.child,
    this.expandChild = false,
    this.icon,
    this.trailing,
  });

  final String title;
  final Widget child;
  final bool expandChild;
  final IconData? icon;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 600;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _FrostedBanner(
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 12 : 16,
            vertical: compact ? 10 : 12,
          ),
          child: Row(
            children: [
              if (icon != null) ...[
                Container(
                  width: compact ? 34 : 42,
                  height: compact ? 34 : 42,
                  decoration: BoxDecoration(
                    color: _accentFill(context),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(icon!,
                      size: compact ? 19 : 22, color: colorScheme.primary),
                ),
                SizedBox(width: compact ? 8 : 12),
              ],
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: (compact
                          ? theme.textTheme.titleLarge
                          : theme.textTheme.headlineSmall)
                      ?.copyWith(fontWeight: FontWeight.w800),
                ),
              ),
              if (trailing != null) ...[
                SizedBox(width: compact ? 8 : 12),
                trailing!,
              ],
            ],
          ),
        ),
        SizedBox(height: compact ? 6 : 14),
        if (expandChild) Expanded(child: child) else child,
      ],
    );
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 4 : 8,
        vertical: compact ? 4 : 8,
      ),
      child: content,
    );
  }
}

class InfoTile extends StatelessWidget {
  const InfoTile({
    super.key,
    required this.label,
    required this.value,
    this.icon,
  });

  final String label;
  final String value;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.sizeOf(context).width;
    final compact = screenWidth < 600;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final tileWidth = compact
        ? ((screenWidth - 30) / 2).clamp(136.0, 220.0).toDouble()
        : 220.0;
    return SizedBox(
      width: tileWidth,
      height: compact ? 88 : 100,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: EdgeInsets.all(compact ? 10 : 14),
        decoration: BoxDecoration(
          color: gzusSurface(context),
          borderRadius: BorderRadius.circular(compact ? 16 : 20),
          border: Border.all(color: gzusBorder(context)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (icon != null) ...[
              Icon(icon, size: compact ? 18 : 22, color: colorScheme.primary),
              SizedBox(width: compact ? 8 : 10),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    value,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: (compact
                            ? theme.textTheme.bodyMedium
                            : theme.textTheme.titleMedium)
                        ?.copyWith(fontWeight: FontWeight.w800),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class AccentPanel extends StatelessWidget {
  const AccentPanel({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 600;
    return Container(
      padding: EdgeInsets.all(compact ? 12 : 16),
      decoration: BoxDecoration(
        color: gzusSurfaceSoft(context),
        borderRadius: BorderRadius.circular(compact ? 16 : 20),
        border: Border.all(color: gzusBorder(context)),
      ),
      child: child,
    );
  }
}

class _MobileRecordCard extends StatelessWidget {
  const _MobileRecordCard({
    required this.icon,
    required this.title,
    this.subtitle,
    required this.rows,
    this.highlight = false,
    this.extraRows,
    this.trailing,
    this.highlighted = false,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final List<(IconData, String, String)> rows;
  final bool highlight;
  final List<Widget>? extraRows;
  final Widget? trailing;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 600;
    final colorScheme = Theme.of(context).colorScheme;
    final cardColor = highlighted
        ? colorScheme.primaryContainer.withValues(alpha: 0.55)
        : highlight
            ? colorScheme.secondaryContainer.withValues(alpha: 0.5)
            : null;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: cardColor ?? gzusSurface(context),
        borderRadius: BorderRadius.circular(compact ? 16 : 20),
        border: Border.all(color: gzusBorder(context)),
      ),
      child: Padding(
        padding: EdgeInsets.all(compact ? 12 : 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _IconBadge(icon: icon, size: compact ? 32 : 40),
                SizedBox(width: compact ? 10 : 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: compact ? 15 : 16,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          if (trailing != null) ...[
                            const SizedBox(width: 8),
                            trailing!,
                          ],
                        ],
                      ),
                      if (subtitle != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          subtitle!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: colorScheme.onSurfaceVariant,
                            fontSize: compact ? 12 : 13,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            if (rows.isNotEmpty) ...[
              SizedBox(height: compact ? 10 : 14),
              LayoutBuilder(
                builder: (context, constraints) {
                  final itemWidth = compact
                      ? ((constraints.maxWidth - 8) / 2).clamp(118.0, 220.0)
                      : null;
                  return Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final row in rows)
                        _MetricPill(
                          icon: row.$1,
                          label: row.$2,
                          value: row.$3,
                          width: itemWidth?.toDouble(),
                          dense: compact,
                        ),
                    ],
                  );
                },
              ),
            ],
            if (extraRows != null && extraRows!.isNotEmpty) ...[
              SizedBox(height: compact ? 10 : 14),
              ...extraRows!,
            ],
          ],
        ),
      ),
    );
  }
}

class SimpleTable extends StatelessWidget {
  const SimpleTable({
    super.key,
    required this.headers,
    required this.rows,
    this.highlightedRows = const {},
    this.rowHighlightColors = const {},
    this.rowTextColors = const {},
    this.columnFlexs = const [],
  });

  final List<String> headers;
  final List<List<String>> rows;
  final Set<int> highlightedRows;
  final Map<int, Color> rowHighlightColors;
  final Map<int, Color> rowTextColors;
  final List<int> columnFlexs;

  @override
  Widget build(BuildContext context) {
    final border = BorderSide(color: gzusBorder(context));
    return LayoutBuilder(
      builder: (context, constraints) {
        final minWidth = headers.length * 104.0;
        final tableWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth.clamp(minWidth, double.infinity).toDouble()
            : minWidth;
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: tableWidth,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Column(
                children: [
                  _TableRow(
                      values: headers,
                      strong: true,
                      border: border,
                      columnFlexs: columnFlexs),
                  for (var i = 0; i < rows.length; i++)
                    _TableRow(
                      values: rows[i],
                      border: border,
                      highlighted: highlightedRows.contains(i),
                      highlightColor: rowHighlightColors[i],
                      textColor: rowTextColors[i],
                      columnFlexs: columnFlexs,
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _TableRow extends StatelessWidget {
  const _TableRow(
      {required this.values,
      required this.border,
      this.strong = false,
      this.highlighted = false,
      this.highlightColor,
      this.textColor,
      this.columnFlexs = const []});

  final List<String> values;
  final BorderSide border;
  final bool strong;
  final bool highlighted;
  final Color? highlightColor;
  final Color? textColor;
  final List<int> columnFlexs;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Container(
      decoration: BoxDecoration(
        color: highlighted
            ? highlightColor ?? _accentFill(context)
            : strong
                ? gzusSurfaceSoft(context)
                : gzusSurface(context),
        border: Border(bottom: border),
      ),
      child: _TableRowContent(
        values: values,
        color: highlighted ? textColor ?? accent : null,
        strong: strong || highlighted,
        columnFlexs: columnFlexs,
      ),
    );
  }
}

class _TableRowContent extends StatelessWidget {
  const _TableRowContent(
      {required this.values,
      this.color,
      this.strong = false,
      this.columnFlexs = const []});

  final List<String> values;
  final Color? color;
  final bool strong;
  final List<int> columnFlexs;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (var i = 0; i < values.length; i++)
          Expanded(
            flex: i < columnFlexs.length ? columnFlexs[i] : 1,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: _AutoScrollText(
                text: values[i],
                style: TextStyle(
                  color: color,
                  fontWeight: strong ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _AutoScrollText extends StatefulWidget {
  const _AutoScrollText({required this.text, this.style});

  final String text;
  final TextStyle? style;

  @override
  State<_AutoScrollText> createState() => _AutoScrollTextState();
}

class _AutoScrollTextState extends State<_AutoScrollText> {
  final _controller = ScrollController();
  bool _needsScroll = false;
  bool _scrollForward = true;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onScrollChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkOverflow());
  }

  @override
  void didUpdateWidget(covariant _AutoScrollText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text || oldWidget.style != widget.style) {
      _needsScroll = false;
      WidgetsBinding.instance.addPostFrameCallback((_) => _checkOverflow());
    }
  }

  void _checkOverflow() {
    if (!_controller.hasClients) return;
    final max = _controller.position.maxScrollExtent;
    final needs = max > 0;
    if (needs != _needsScroll) {
      setState(() => _needsScroll = needs);
      if (needs) _autoScroll();
    }
  }

  void _onScrollChanged() {
    if (!_controller.hasClients || !_needsScroll) return;
    final pos = _controller.position.pixels;
    final max = _controller.position.maxScrollExtent;
    if (_scrollForward && pos >= max) {
      _scrollForward = false;
      Future.delayed(const Duration(seconds: 2), _autoScroll);
    } else if (!_scrollForward && pos <= 0) {
      _scrollForward = true;
      Future.delayed(const Duration(seconds: 2), _autoScroll);
    }
  }

  void _autoScroll() {
    if (!_controller.hasClients || !_needsScroll || !mounted) return;
    final max = _controller.position.maxScrollExtent;
    _controller.animateTo(
      _scrollForward ? max : 0,
      duration: Duration(milliseconds: (max * 15).round().clamp(800, 3000)),
      curve: Curves.easeInOut,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      controller: _controller,
      child: Text(
        widget.text,
        softWrap: false,
        style: widget.style,
      ),
    );
  }
}

class MorePage extends StatefulWidget {
  const MorePage({
    super.key,
    required this.api,
    required this.navBarTabs,
    this.navBarLimit,
    required this.onNavigate,
    required this.onConfigChanged,
    this.year = 0,
    this.term = 1,
    this.themeMode = ThemeMode.system,
    this.onThemeChanged,
    this.seedColor = GzusColors.blue,
    this.onSeedColorChanged,
    this.onLogout,
    this.onYearChanged,
    this.onTermChanged,
    this.autoHideNavBar = true,
    this.onAutoHideNavBarChanged,
    this.loginMethod,
    this.onShowBackgroundGuide,
  });

  final ApiClient api;
  final List<NavTabConfig> navBarTabs;
  final int? navBarLimit;
  final ValueChanged<String> onNavigate;
  final VoidCallback onConfigChanged;
  final int year;
  final int term;
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode>? onThemeChanged;
  final Color seedColor;
  final ValueChanged<Color>? onSeedColorChanged;
  final VoidCallback? onLogout;
  final ValueChanged<int>? onYearChanged;
  final ValueChanged<int>? onTermChanged;
  final bool autoHideNavBar;
  final ValueChanged<bool>? onAutoHideNavBarChanged;
  final String? loginMethod;
  final VoidCallback? onShowBackgroundGuide;

  bool get isPasswordLogin => loginMethod == 'password';

  @override
  State<MorePage> createState() => _MorePageState();
}

class _MorePageState extends State<MorePage> {
  bool _editing = false;
  late List<NavTabConfig> _barTabs;
  late List<NavTabConfig> _moreTabs;

  @override
  void initState() {
    super.initState();
    _updateTabs();
  }

  @override
  void didUpdateWidget(covariant MorePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.navBarTabs != widget.navBarTabs) _updateTabs();
  }

  void _updateTabs() {
    final barIds = widget.navBarTabs.map((t) => t.tabId).toSet();
    _barTabs = [...widget.navBarTabs.where((t) => t.tabId != 'more')];
    _moreTabs = NavTabConfig.all
        .where((t) => !barIds.contains(t.tabId))
        .where((t) =>
            !widget.isPasswordLogin ||
            !DashboardShell.passwordRestrictedTabs.contains(t.tabId))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final navBarLimit = widget.navBarLimit;
    final canAddNavBarTab =
        navBarLimit == null || _barTabs.length < navBarLimit;
    final navBarTitle = navBarLimit == null ? '边栏应用' : '底栏（最多$navBarLimit个）';
    return Scaffold(
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            // 页面标题
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
                child: Row(
                  children: [
                    Text('更多',
                        style: theme.textTheme.headlineSmall
                            ?.copyWith(fontWeight: FontWeight.w700)),
                    const Spacer(),
                    if (_editing) ...[
                      TextButton(
                        onPressed: () async {
                          await NavPreferences.reset();
                          widget.onConfigChanged();
                          setState(() {
                            _editing = false;
                            _updateTabs();
                          });
                        },
                        child: const Text('恢复默认'),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: () async {
                          final tabIds = [
                            ..._barTabs.map((t) => t.tabId),
                            'more',
                          ];
                          await NavPreferences.save(tabIds);
                          widget.onConfigChanged();
                          setState(() {
                            _editing = false;
                            _updateTabs();
                          });
                        },
                        child: const Text('完成'),
                      ),
                    ] else ...[
                      IconButton(
                        onPressed: () => setState(() => _editing = true),
                        icon: const Icon(Icons.edit),
                        tooltip: '编辑导航',
                      ),
                    ],
                  ],
                ),
              ),
            ),
            // 导航管理区
            if (_editing) ...[
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                  child: Text(navBarTitle,
                      style: theme.textTheme.titleSmall
                          ?.copyWith(color: colorScheme.onSurfaceVariant)),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                sliver: SliverGrid(
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 4,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                    childAspectRatio: 1,
                  ),
                  delegate: SliverChildListDelegate([
                    for (final tab in [..._barTabs])
                      _MoreGridItem(
                        tab: tab,
                        editing: true,
                        canRemove: !tab.isFixed,
                        onRemove: () {
                          if (!tab.isFixed && _barTabs.length > 2) {
                            setState(() {
                              _barTabs.remove(tab);
                              _moreTabs.add(tab);
                            });
                          }
                        },
                      ),
                  ]),
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                  child: Text('更多页',
                      style: theme.textTheme.titleSmall
                          ?.copyWith(color: colorScheme.onSurfaceVariant)),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                sliver: SliverGrid(
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 4,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                    childAspectRatio: 1,
                  ),
                  delegate: SliverChildListDelegate([
                    for (final tab in [..._moreTabs])
                      _MoreGridItem(
                        tab: tab,
                        editing: true,
                        canAdd: canAddNavBarTab,
                        onAdd: () {
                          if (canAddNavBarTab) {
                            setState(() {
                              _moreTabs.remove(tab);
                              _barTabs.add(tab);
                            });
                          }
                        },
                      ),
                  ]),
                ),
              ),
            ] else ...[
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                sliver: SliverGrid(
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 4,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                    childAspectRatio: 1,
                  ),
                  delegate: SliverChildListDelegate([
                    for (final tab in [..._moreTabs])
                      _MoreGridItem(
                        tab: tab,
                        editing: false,
                        onTap: () => widget.onNavigate(tab.tabId),
                      ),
                  ]),
                ),
              ),
            ],
            const SliverToBoxAdapter(child: SizedBox(height: 24)),
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 20),
                child: Divider(),
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 16)),
            // 快捷设置分组
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text('快捷设置',
                    style: theme.textTheme.titleSmall
                        ?.copyWith(color: colorScheme.onSurfaceVariant)),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Card(
                  elevation: 0,
                  color: colorScheme.surfaceContainer,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (widget.onYearChanged != null)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                          child: Row(
                            children: [
                              const Icon(Icons.calendar_today, size: 20),
                              const SizedBox(width: 12),
                              const Text('学年'),
                              const Spacer(),
                              DropdownMenu<int>(
                                initialSelection: widget.year,
                                enableSearch: false,
                                requestFocusOnTap: false,
                                onSelected: (v) {
                                  if (v != null) widget.onYearChanged?.call(v);
                                },
                                dropdownMenuEntries: [
                                  for (var y = DateTime.now().year;
                                      y >= DateTime.now().year - 5;
                                      y--)
                                    DropdownMenuEntry(value: y, label: '$y'),
                                ],
                              ),
                            ],
                          ),
                        ),
                      if (widget.onTermChanged != null)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                          child: Row(
                            children: [
                              const Icon(Icons.view_week, size: 20),
                              const SizedBox(width: 12),
                              const Text('学期'),
                              const Spacer(),
                              DropdownMenu<int>(
                                initialSelection: widget.term,
                                enableSearch: false,
                                requestFocusOnTap: false,
                                onSelected: (v) {
                                  if (v != null) widget.onTermChanged?.call(v);
                                },
                                dropdownMenuEntries: const [
                                  DropdownMenuEntry(value: 1, label: '第1学期'),
                                  DropdownMenuEntry(value: 2, label: '第2学期'),
                                ],
                              ),
                            ],
                          ),
                        ),
                      if (widget.onThemeChanged != null)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Row(
                                children: [
                                  Icon(Icons.palette, size: 20),
                                  SizedBox(width: 12),
                                  Text('外观模式'),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Center(
                                child: SegmentedButton<ThemeMode>(
                                  segments: const [
                                    ButtonSegment(
                                      value: ThemeMode.light,
                                      label: Text('浅色'),
                                      icon: Icon(Icons.light_mode, size: 18),
                                    ),
                                    ButtonSegment(
                                      value: ThemeMode.system,
                                      label: Text('自动'),
                                      icon:
                                          Icon(Icons.brightness_auto, size: 18),
                                    ),
                                    ButtonSegment(
                                      value: ThemeMode.dark,
                                      label: Text('深色'),
                                      icon: Icon(Icons.dark_mode, size: 18),
                                    ),
                                  ],
                                  selected: {widget.themeMode},
                                  onSelectionChanged: (s) =>
                                      widget.onThemeChanged?.call(s.first),
                                ),
                              ),
                            ],
                          ),
                        ),
                      if (widget.onSeedColorChanged != null)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Row(
                                children: [
                                  Icon(Icons.color_lens, size: 20),
                                  SizedBox(width: 12),
                                  Text('主题色'),
                                ],
                              ),
                              const SizedBox(height: 12),
                              Center(
                                child: _SeedColorPicker(
                                  selectedColor: widget.seedColor,
                                  onColorSelected: widget.onSeedColorChanged!,
                                ),
                              ),
                            ],
                          ),
                        ),
                      if (widget.onAutoHideNavBarChanged != null)
                        SwitchListTile(
                          value: widget.autoHideNavBar,
                          onChanged: widget.onAutoHideNavBarChanged,
                          secondary: const Icon(Icons.hide_source),
                          title: const Text('自动隐藏底栏'),
                          subtitle: const Text('滚动时自动隐藏底部导航栏'),
                        ),
                      if (widget.onShowBackgroundGuide != null)
                        ListTile(
                          leading: const Icon(Icons.settings),
                          title: const Text('后台'),
                          subtitle: const Text('设置后台保活和推送'),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: widget.onShowBackgroundGuide,
                        ),
                      ListTile(
                        key: const ValueKey('home-widget-guide-tile'),
                        leading: const Icon(Icons.widgets),
                        title: const Text('桌面组件'),
                        subtitle: const Text('添加方法、显示内容和刷新说明'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                              builder: (context) =>
                                  const HomeWidgetGuidePage()),
                        ),
                      ),
                      ListTile(
                        leading: const Icon(Icons.info),
                        title: const Text('关于'),
                        subtitle: const Text('应用信息与更新'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                              builder: (context) => AboutPage(api: widget.api)),
                        ),
                      ),
                      const SizedBox(height: 4),
                    ],
                  ),
                ),
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 24)),
            // 账户分组
            if (widget.onLogout != null) ...[
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                  child: Text('账户',
                      style: theme.textTheme.titleSmall
                          ?.copyWith(color: colorScheme.onSurfaceVariant)),
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Card(
                    elevation: 0,
                    color: colorScheme.surfaceContainer,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: ListTile(
                      leading: Icon(Icons.logout, color: colorScheme.error),
                      title: Text('退出登录',
                          style: TextStyle(color: colorScheme.error)),
                      onTap: widget.onLogout,
                    ),
                  ),
                ),
              ),
            ],
            const SliverToBoxAdapter(child: SizedBox(height: 32)),
          ],
        ),
      ),
    );
  }
}

class HomeWidgetGuidePage extends StatelessWidget {
  const HomeWidgetGuidePage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    const items = [
      _WidgetGuideItem(
        icon: Icons.schedule,
        title: '下一节课',
        example: '移动应用开发 · 09:00-10:20 · A2-301',
        detail: '适合放在首页第一屏，快速看下一节课、教室和老师。',
      ),
      _WidgetGuideItem(
        icon: Icons.today,
        title: '今日课表',
        example: '今日 4 节课，按时间列出前几节',
        detail: '适合需要完整确认当天课程顺序时使用。',
      ),
      _WidgetGuideItem(
        icon: Icons.water_drop,
        title: '生活缴费',
        example: '电 9 度 · 冷水 12.3 吨 · 热水 4.6 吨',
        detail: '绑定宿舍后显示水电余额，点击进入生活缴费页。',
      ),
      _WidgetGuideItem(
        icon: Icons.assignment_turned_in,
        title: '业务进度',
        example: '请假审批 · 辅导员审核 · 70%',
        detail: '适合追踪请假、办事大厅等流程状态。',
      ),
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('桌面组件')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
          children: [
            Text('添加方法',
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            const _GuideStep(
              index: 1,
              text: '在 Android 桌面长按空白处，进入“小组件/Widget”。',
            ),
            const _GuideStep(
              index: 2,
              text: '找到 OneGZUS，选择需要的组件拖到桌面。',
            ),
            const _GuideStep(
              index: 3,
              text: '打开 App 登录并刷新首页，组件会同步最新课表、水电和业务进度。',
            ),
            const SizedBox(height: 20),
            Text('组件示例',
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            for (final item in items)
              Card(
                elevation: 0,
                color: colorScheme.surfaceContainer,
                margin: const EdgeInsets.only(bottom: 10),
                child: ListTile(
                  leading: Icon(item.icon, color: colorScheme.primary),
                  title: Text(item.title),
                  subtitle: Text('${item.example}\n${item.detail}'),
                  isThreeLine: true,
                ),
              ),
            const SizedBox(height: 10),
            Card(
              elevation: 0,
              color: colorScheme.primaryContainer,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  '刷新规则：打开 App、首页数据更新或从组件点击进入 App 后会刷新。若桌面仍显示旧数据，先打开 App 到首页刷新；仍无变化时，检查后台保活设置。',
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: colorScheme.onPrimaryContainer),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WidgetGuideItem {
  const _WidgetGuideItem({
    required this.icon,
    required this.title,
    required this.example,
    required this.detail,
  });

  final IconData icon;
  final String title;
  final String example;
  final String detail;
}

class _GuideStep extends StatelessWidget {
  const _GuideStep({required this.index, required this.text});

  final int index;
  final String text;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 12,
            backgroundColor: colorScheme.primaryContainer,
            child: Text('$index',
                style: TextStyle(
                  color: colorScheme.onPrimaryContainer,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                )),
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}

class _MoreGridItem extends StatelessWidget {
  const _MoreGridItem({
    required this.tab,
    this.editing = false,
    this.canRemove = false,
    this.canAdd = false,
    this.onTap,
    this.onRemove,
    this.onAdd,
  });

  final NavTabConfig tab;
  final bool editing;
  final bool canRemove;
  final bool canAdd;
  final VoidCallback? onTap;
  final VoidCallback? onRemove;
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final inner = Container(
      decoration: BoxDecoration(
        color: gzusSurface(context),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: gzusBorder(context)),
      ),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(tab.icon, size: 28, color: theme.colorScheme.primary),
                  const SizedBox(height: 6),
                  Text(
                    tab.shortLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelMedium,
                  ),
                ],
              ),
            ),
          ),
          if (editing && canRemove)
            Positioned(
              top: -6,
              right: -6,
              child: IconButton(
                icon: const Icon(Icons.close, size: 18),
                color: Colors.white,
                style: const ButtonStyle(
                  backgroundColor: WidgetStatePropertyAll(Colors.red),
                  padding: WidgetStatePropertyAll(EdgeInsets.all(2)),
                ),
                onPressed: onRemove,
              ),
            ),
          if (editing && canAdd)
            Positioned(
              top: -6,
              right: -6,
              child: IconButton(
                icon: const Icon(Icons.add, size: 18),
                color: Colors.white,
                style: const ButtonStyle(
                  backgroundColor: WidgetStatePropertyAll(Color(0xFF1976D2)),
                  padding: WidgetStatePropertyAll(EdgeInsets.all(2)),
                ),
                onPressed: onAdd,
              ),
            ),
        ],
      ),
    );
    if (editing) return inner;
    return _ScaleTap(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: inner,
    );
  }
}

class AboutPage extends StatefulWidget {
  const AboutPage({super.key, required this.api});

  final ApiClient api;

  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  String _currentVersion = '0.0.0';
  int _currentBuild = 0;
  bool _checkingUpdate = false;
  bool _hasUpdate = false;

  @override
  void initState() {
    super.initState();
    _loadPackageInfo();
  }

  Future<void> _loadPackageInfo() async {
    final packageInfo = await PackageInfo.fromPlatform();
    setState(() {
      _currentVersion = packageInfo.version;
      _currentBuild = int.tryParse(packageInfo.buildNumber) ?? 0;
    });
    await _silentCheckForUpdate();
  }

  Future<void> _silentCheckForUpdate() async {
    try {
      await update_service.loadLibrary();
      final hasUpdate = await update_service.UpdateService().hasUpdate();
      if (mounted) {
        setState(() => _hasUpdate = hasUpdate);
      }
    } catch (_) {}
  }

  Future<void> _checkForUpdate() async {
    if (_checkingUpdate) return;
    setState(() => _checkingUpdate = true);
    try {
      await update_service.loadLibrary();
      await update_service.UpdateService().forceCheckForUpdate();
      await _silentCheckForUpdate();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('检查更新失败，请稍后重试')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _checkingUpdate = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('关于')),
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 40, 20, 20),
                child: Column(
                  children: [
                    Container(
                      width: 80,
                      height: 80,
                      decoration: BoxDecoration(
                        color: colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Icon(Icons.school,
                          size: 40, color: colorScheme.primary),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'OneGZUS',
                      style: theme.textTheme.headlineSmall
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 4),
                    Text('软帮手',
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(color: colorScheme.onSurfaceVariant)),
                  ],
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Card(
                  elevation: 0,
                  color: colorScheme.surfaceContainer,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16)),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        _InfoRow(label: '版本', value: _currentVersion),
                        _InfoRow(label: '构建号', value: '$_currentBuild'),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 24)),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Card(
                  elevation: 0,
                  color: colorScheme.surfaceContainer,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16)),
                  child: ListTile(
                    leading: const Icon(Icons.refresh),
                    title: const Text('检查更新'),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_hasUpdate)
                          Container(
                            width: 8,
                            height: 8,
                            decoration: const BoxDecoration(
                              color: Colors.red,
                              shape: BoxShape.circle,
                            ),
                          ),
                        const SizedBox(width: 8),
                        if (_checkingUpdate)
                          const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2)),
                        if (!_checkingUpdate) const Icon(Icons.chevron_right),
                      ],
                    ),
                    onTap: _checkForUpdate,
                  ),
                ),
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 24)),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Card(
                  elevation: 0,
                  color: colorScheme.surfaceContainer,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16)),
                  child: ListTile(
                    leading: const Icon(Icons.extension_outlined),
                    title: const Text('第三方库与开源组件'),
                    subtitle: const Text('查看本程序使用的组件与致谢'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (context) =>
                            const OpenSourceAcknowledgementsPage(),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 24)),
            const SliverFillRemaining(
              hasScrollBody: false,
              child: Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: EdgeInsets.only(bottom: 32),
                  child: Text('© 2026 OneGZUS',
                      style: TextStyle(fontSize: 12, color: Colors.grey)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class OpenSourceAcknowledgementsPage extends StatelessWidget {
  const OpenSourceAcknowledgementsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('第三方库与开源组件')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
          children: [
            Card(
              elevation: 0,
              color: colorScheme.surfaceContainer,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16)),
              child: const Padding(
                padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _AboutSectionTitle(
                      icon: Icons.extension_outlined,
                      title: '第三方库与开源组件',
                    ),
                    SizedBox(height: 8),
                    _AboutLibraryTile(
                      name: 'Flutter / Dart',
                      description: '跨平台应用框架与运行时。',
                    ),
                    _AboutLibraryTile(
                      name: 'http、web_socket_channel',
                      description: '网络请求与实时连接能力。',
                    ),
                    _AboutLibraryTile(
                      name: 'shared_preferences、package_info_plus',
                      description: '本地偏好存储与应用版本信息读取。',
                    ),
                    _AboutLibraryTile(
                      name: 'webview_flutter、url_launcher、share_plus',
                      description: '网页承载、外部链接打开与系统分享。',
                    ),
                    _AboutLibraryTile(
                      name:
                          'flutter_local_notifications、file_picker、image_picker',
                      description: '本地通知、文件选择与图片选择。',
                    ),
                    _AboutLibraryTile(
                      name: 'FastAPI、Uvicorn、SQLAlchemy、Pydantic',
                      description: '服务端 API、数据模型与持久化基础。',
                    ),
                    _AboutLibraryTile(
                      name:
                          'httpx、asyncpg、aiosqlite、cryptography、Pillow、ddddocr',
                      description: '服务端网络访问、数据库连接、安全与图像处理。',
                    ),
                    _AboutLibraryTile(
                      name: 'Tencent Bugly、desugar_jdk_libs、CocoaPods',
                      description: '崩溃监控、Android 兼容库与 iOS 依赖管理。',
                    ),
                    _AboutLibraryTile(
                      name: 'New School SDK',
                      description: '教务系统数据接口与课表解析能力。',
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              elevation: 0,
              color: colorScheme.surfaceContainer,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16)),
              child: const Padding(
                padding: EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _AboutSectionTitle(
                      icon: Icons.favorite_border,
                      title: '致谢',
                    ),
                    SizedBox(height: 12),
                    Text(
                      'OneGZUS 的开发受益于 Flutter、Dart、Python、Android、iOS 生态及各开源项目维护者的持续贡献。感谢上述第三方库、开源组件和相关工具链为本程序提供稳定的基础能力。',
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AboutSectionTitle extends StatelessWidget {
  const _AboutSectionTitle({required this.icon, required this.title});

  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 20, color: Theme.of(context).colorScheme.primary),
        const SizedBox(width: 8),
        Text(
          title,
          style: Theme.of(context)
              .textTheme
              .titleMedium
              ?.copyWith(fontWeight: FontWeight.w700),
        ),
      ],
    );
  }
}

class _AboutLibraryTile extends StatelessWidget {
  const _AboutLibraryTile({required this.name, required this.description});

  final String name;
  final String description;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(name, style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
          Text(
            description,
            style: TextStyle(
              color: colorScheme.onSurfaceVariant,
              fontSize: 13,
              height: 1.35,
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Text(label,
              style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
          const Spacer(),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 24),
          decoration: BoxDecoration(
            color: gzusSurface(context),
            borderRadius: BorderRadius.circular(GzusRadii.lg),
            border: Border.all(color: gzusBorder(context)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: gzusSurfaceSoft(context),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(
                  Icons.inbox_outlined,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                message,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class MarqueeText extends StatefulWidget {
  const MarqueeText({
    super.key,
    required this.text,
    this.style,
    this.scrollSpeed = 30.0,
  });

  final String text;
  final TextStyle? style;
  final double scrollSpeed;

  @override
  State<MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<MarqueeText>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  double _textWidth = 0;
  double _containerWidth = 0;
  bool _needsScroll = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this);
    _controller.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        Future.delayed(const Duration(seconds: 1), () {
          if (mounted) _controller.forward(from: 0);
        });
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _measure() {
    final span = TextSpan(text: widget.text, style: widget.style);
    final tp = TextPainter(text: span, textDirection: TextDirection.ltr)
      ..layout();
    _textWidth = tp.width;
    if (_needsScroll && _textWidth > 0 && _containerWidth > 0) {
      final distance = _textWidth + 16;
      final duration = (distance / widget.scrollSpeed * 1000).round();
      _controller.duration = Duration(milliseconds: duration);
      _controller.forward(from: 0);
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _containerWidth = constraints.maxWidth;
        return ClipRect(
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, child) {
              final span = TextSpan(text: widget.text, style: widget.style);
              final tp =
                  TextPainter(text: span, textDirection: TextDirection.ltr)
                    ..layout();
              _textWidth = tp.width;
              _needsScroll = _textWidth > _containerWidth;
              if (!_needsScroll) {
                _controller.stop();
                return Text(widget.text,
                    style: widget.style,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis);
              }
              if (!_controller.isAnimating &&
                  _controller.status == AnimationStatus.dismissed) {
                WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
              }
              final offset = _controller.value * (_textWidth + 16);
              return Transform.translate(
                offset: Offset(-offset, 0),
                child: Text(widget.text,
                    style: widget.style, maxLines: 1, softWrap: false),
              );
            },
          ),
        );
      },
    );
  }
}
