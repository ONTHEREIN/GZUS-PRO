import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_client.dart';
import 'gzus_design.dart';
import 'responsive/spacing.dart';
import 'schedule_utils.dart';
import 'services_deferred.dart';

import 'background_guide_page.dart';
import 'browser_redirect.dart';
import 'live_activity_service.dart';

import 'persistent_cache.dart' deferred as persistent_cache;
import 'ws_service.dart' deferred as ws_service;
import 'mobile_sso.dart' deferred as mobile_sso;
import 'background_service.dart' deferred as background_service;
import 'update_service.dart' deferred as update_service;
import 'web_pwa_cache.dart' deferred as web_pwa_cache;
import 'push_service.dart' deferred as push_service;

import 'models/nav_config.dart';
import 'models/schedule_settings.dart';
import 'pages/ftp/ftp_upload_page.dart';
import 'pages/grades/grades_page.dart';
import 'pages/home/home_page.dart';
import 'pages/info/info_page.dart';
import 'pages/leave/auto_leave_page.dart';
import 'pages/login/login_page.dart';
import 'pages/applications/applications_page.dart';
import 'pages/attendance/attendance_page.dart';
import 'pages/credits/credits_page.dart';
import 'pages/ecard/ecard_page.dart';
import 'pages/exams/exams_page.dart';
import 'pages/business/business_page.dart';
import 'pages/more/more_page.dart';
import 'pages/notices/notices_page.dart';
import 'pages/schedule/schedule_page.dart';
import 'test_flags.dart';
import 'widgets/open_browser.dart';
import 'widgets/page_panel.dart';
import 'widgets/page_silent_refresh.dart';
import 'widgets/web_unsupported.dart';

export 'test_flags.dart';

part 'shell/dashboard_shell.dart';
part 'shell/nav_widgets.dart';
part 'shell/marquee_text.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.dark,
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarDividerColor: Colors.transparent,
    systemNavigationBarIconBrightness: Brightness.dark,
  ));

  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

  runApp(const OneGzusApp());

  unawaited(_initDeferredServices());
}

Future<void> _initDeferredServices() async {
  try {
    await DeferredServices().initialize();
  } catch (_) {}
}

ThemeData _appTheme(Brightness brightness,
    {Color seedColor = GzusColors.blue}) {
  return gzusTheme(brightness,
      navBarHeight: _mobileNavBarHeight, seedColor: seedColor);
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
  bool _scheduleOnboardingCompleted = false;
  DataSourceInfo _globalDataSource = const DataSourceInfo();
  bool get isOfflineMode => _globalDataSource.isStale;

  /// 云端课表偏好（登录后拉取；登出时清空，避免多账号串数据）。
  ScheduleSettings? _cloudScheduleSettings;

  /// 登录方式: "password" = 教务系统账密登录, "sso" = 办事大厅一键登录, null = 未登录
  String? loginMethod;

  /// 防止 _logout() 被并发调用
  bool _logoutInProgress = false;

  /// 管理后台身份（best-effort 由 /admin/me 确认；登录响应 isAdmin 仅作快速初值）
  bool _isAdmin = false;
  bool _isOwner = false;

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
        debugPrint('Ignoring relogin failure within 5s of login (transient)');
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
    api.dispose();
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
    return '${(color.r * 255.0).round().clamp(0, 255).toRadixString(16).padLeft(2, '0')}${(color.g * 255.0).round().clamp(0, 255).toRadixString(16).padLeft(2, '0')}${(color.b * 255.0).round().clamp(0, 255).toRadixString(16).padLeft(2, '0')}'
        .toUpperCase();
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
      title: '软帮手',
      debugShowCheckedModeBanner: false,
      themeMode: themeMode,
      theme: _appTheme(Brightness.light, seedColor: seedColor),
      darkTheme: _appTheme(Brightness.dark, seedColor: seedColor),
      builder: (context, child) {
        return MediaQuery.withClampedTextScaling(
          minScaleFactor: 0.8,
          maxScaleFactor: 1.3,
          child: child!,
        );
      },
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
              : !_scheduleOnboardingCompleted
                  ? ScheduleOnboardingPage(
                      api: api,
                      studentName: studentName,
                      onComplete: () async {
                        final prefs =
                            await SharedPreferences.getInstance();
                        await prefs.setBool(
                            'schedule_onboarding_completed', true);
                        if (!mounted) return;
                        setState(() {
                          _scheduleOnboardingCompleted = true;
                        });
                      },
                      onSkip: () async {
                        final prefs =
                            await SharedPreferences.getInstance();
                        await prefs.setBool(
                            'schedule_onboarding_completed', true);
                        // 云端记录完成标记，换设备后不再要求选择
                        unawaited(_markScheduleOnboardingCompleted());
                        if (!mounted) return;
                        setState(() {
                          _scheduleOnboardingCompleted = true;
                        });
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
              _navigatorKey.currentState
                  ?.pushNamedAndRemoveUntil('/', (route) => false);
            });
            return const LoadingPage();
          }
          return _buildDashboardShell();
        },
        '/background-guide': (context) {
          if (!loggedIn) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _navigatorKey.currentState
                  ?.pushNamedAndRemoveUntil('/', (route) => false);
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
    // 添加超时保护，防止 API 响应慢导致 LoadingPage 永远卡住
    try {
      await _restoreSession().timeout(const Duration(seconds: 8));
    } on TimeoutException {
      debugPrint(
          'Session restore timed out after 8 seconds, showing login page');
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
    await api.loadSavedCredentials();
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
    final guideCompleted = prefs.getBool('background_guide_completed') ?? false;
    final localOnboardingCompleted =
        prefs.getBool('schedule_onboarding_completed') ?? false;
    // 优先使用云端完成标记（换设备/清缓存后不重复引导），失败回退本地
    final cloud = await _fetchCloudScheduleSettings();
    if (!mounted) return;
    setState(() {
      initializing = false;
      loggedIn = true;
      studentName = prefs.getString('auth.studentName') ?? '软帮手';
      _backgroundGuideCompleted = guideCompleted;
      _cloudScheduleSettings = cloud;
      _scheduleOnboardingCompleted =
          cloud?.onboardingCompleted ?? localOnboardingCompleted;
      _globalDataSource = const DataSourceInfo(fromLocalCache: true);
      loginMethod = prefs.getString('auth.loginMethod');
    });

    unawaited(_tryBackgroundRefresh(prefs));
    unawaited(_checkAdminStatus());
    _initPushServices();
    _checkForUpdate();
  }

  Future<void> _tryBackgroundRefresh(SharedPreferences prefs) async {
    try {
      // forceRefresh: 会话恢复后主动拉取最新个人信息，避免命中 me 的
      // 本地缓存而一直显示旧姓名/学号（此前未强制刷新且优先用本地旧值）。
      final result = await api.me(forceRefresh: true);
      if (!mounted) return;
      final freshName = result.data.name.isNotEmpty
          ? result.data.name
          : (prefs.getString('auth.studentName') ?? '软帮手');
      final freshId = result.data.studentId.isNotEmpty
          ? result.data.studentId
          : (prefs.getString('auth.studentId') ?? '');
      setState(() {
        _globalDataSource = result.source;
        studentName = freshName;
      });
      if (freshId.isNotEmpty) {
        api.setStudentId(freshId);
      }
      // 用 API 返回的最新身份回写本地缓存，保证下次冷启动显示一致
      await prefs.setString('auth.studentName', freshName);
      if (freshId.isNotEmpty) {
        await prefs.setString('auth.studentId', freshId);
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
      if (tab != null) NotificationOpenBridge.openTab(tab);
    });
  }

  Future<void> _openAuthenticatedUrl(String url) async {
    try {
      await mobile_sso.loadLibrary();
      if (!mounted) return;
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
    // 开学日期已云端持久化：登录后不再强制重选，以云端完成标记为准
    // （拉取失败时回退本地标记，保证离线可用）。
    final cloud = await _fetchCloudScheduleSettings();
    final prefs = await SharedPreferences.getInstance();
    final localCompleted =
        prefs.getBool('schedule_onboarding_completed') ?? false;
    if (!mounted) return;
    setState(() {
      loggedIn = true;
      studentName = result.studentName;
      loginError = null;
      _backgroundGuideCompleted = false;
      _cloudScheduleSettings = cloud;
      _scheduleOnboardingCompleted =
          cloud?.onboardingCompleted ?? localCompleted;
      loginMethod = result.loginMethod;
    });

    // Fetch student info asynchronously (studentId, photo, etc.)
    // This was separated from the login flow to speed up login response time.
    unawaited(_fetchStudentInfoAfterLogin());

    _initPushServices();
    _checkForUpdate();
  }

  /// 拉取云端课表偏好（best-effort：失败或超时返回 null，不阻塞登录）。
  Future<ScheduleSettings?> _fetchCloudScheduleSettings() async {
    try {
      return await api
          .fetchScheduleSettings()
          .timeout(const Duration(seconds: 4));
    } catch (_) {
      return null;
    }
  }

  /// 云端标记开学引导已完成（best-effort，失败仅打印日志）。
  Future<void> _markScheduleOnboardingCompleted() async {
    try {
      await api.saveScheduleSettings(onboardingCompleted: true);
    } catch (error) {
      debugPrint('同步开学引导完成标记到云端失败: error=${error.runtimeType}');
    }
  }

  Future<void> _fetchStudentInfoAfterLogin() async {
    final info = await api.fetchStudentInfo();
    if (info == null || !mounted) return;
    final studentId = info.studentId;
    if (studentId.isNotEmpty) {
      api.setStudentId(studentId);
    }
    // 姓名也以 API 返回的最新值为准并回写本地，避免首页/桌面组件一直
    // 显示登录响应里的旧姓名。
    if (info.name.isNotEmpty && info.name != studentName) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('auth.studentName', info.name);
      if (mounted) {
        setState(() => studentName = info.name);
      }
    }
  }

  Future<void> _persistLogin(LoginResult result) async {
    _lastLoginAt = DateTime.now();
    _isAdmin = result.isAdmin ?? false;
    // 登录响应只带 isAdmin 布尔；角色（owner/admin）以 /admin/me 为准
    unawaited(_checkAdminStatus());
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
  }

  /// 确认当前会话的管理员身份与角色（best-effort）。
  ///
  /// 非管理员会收到 403，网络失败/超时也静默忽略，不影响正常使用。
  Future<void> _checkAdminStatus() async {
    if (api.sessionId == null || api.sessionId!.isEmpty) return;
    try {
      final data =
          await api.adminMe().timeout(const Duration(seconds: 4));
      if (!mounted) return;
      setState(() {
        _isAdmin = data['isAdmin'] == true || data['role'] != null;
        _isOwner = data['role'] == 'owner';
      });
    } on ApiException catch (e) {
      if (e.statusCode == 403) {
        // 非管理员会话：保持当前状态
        if (mounted && _isAdmin) {
          setState(() {
            _isAdmin = false;
            _isOwner = false;
          });
        }
      }
      // 其他错误（网络/超时）静默忽略
    } catch (_) {
      // 静默忽略
    }
  }

  Future<void> _logout() async {
    if (_logoutInProgress || !loggedIn) return;
    _logoutInProgress = true;
    final activeSessionId = api.sessionId;
    final activeStudentId = api.studentId;
    api.clearCredentials();
    LoginRequiredServices.disconnect();

    if (!mounted) {
      unawaited(_performLogoutCleanup(activeSessionId, activeStudentId));
      return;
    }
    setState(() {
      loggedIn = false;
      studentName = null;
      _backgroundGuideCompleted = false;
      _scheduleOnboardingCompleted = false;
      _cloudScheduleSettings = null; // 清空云端偏好，防止多账号串数据
      _globalDataSource = const DataSourceInfo();
      loginMethod = null;
      loginError = null;
      _isAdmin = false;
      _isOwner = false;
    });
    _navigatorKey.currentState?.popUntil((route) => route.isFirst);

    unawaited(_performLogoutCleanup(activeSessionId, activeStudentId));
  }

  Future<void> _performLogoutCleanup(
    String? activeSessionId,
    String? activeStudentId,
  ) async {
    try {
      if (activeSessionId != null && activeSessionId.isNotEmpty) {
        try {
          await api.unregisterPushForSession(activeSessionId);
        } catch (error) {
          debugPrint('注销推送绑定失败: error=${error.runtimeType}');
        }
        if (kIsWeb) {
          try {
            await LoginRequiredServices.unsubscribeWebPush(
              api.baseUrl,
              activeSessionId,
            );
          } catch (error) {
            debugPrint('注销 Web Push 订阅失败: error=${error.runtimeType}');
          }
        }
        try {
          await api.revokeSession(activeSessionId);
        } catch (error) {
          debugPrint('撤销服务端会话失败: error=${error.runtimeType}');
        }
      }

      try {
        await _clearSavedSession();
      } catch (error) {
        debugPrint('清除本地登录状态失败: error=${error.runtimeType}');
      }
      if (activeStudentId != null && activeStudentId.isNotEmpty) {
        try {
          await persistent_cache.loadLibrary();
          await persistent_cache.PersistentCache.clearForStudent(activeStudentId);
        } catch (error) {
          debugPrint('清除账号缓存失败: error=${error.runtimeType}');
        }
      }
      try {
        await LoginRequiredServices.disableBackgroundService();
      } catch (error) {
        debugPrint('关闭后台服务失败: error=${error.runtimeType}');
      }
      try {
        LoginRequiredServices.cancelCourseReminders();
      } catch (error) {
        debugPrint('取消课程提醒失败: error=${error.runtimeType}');
      }
    } finally {
      _logoutInProgress = false;
    }
  }

  Future<void> _clearSavedSession() async {
    final prefs = await SharedPreferences.getInstance();
    await api.clearSavedAuthState();
    await prefs.remove('background_guide_completed');
    try {
      await web_pwa_cache.loadLibrary();
      web_pwa_cache.clearPwaApiCache();
    } catch (error) {
      debugPrint('清除 PWA API 缓存失败: error=${error.runtimeType}');
    }
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
      cloudFirstWeeks: _cloudScheduleSettings?.firstWeeks ?? const {},
      cloudAutoWeek: _cloudScheduleSettings?.autoWeek,
      isAdmin: _isAdmin,
      isOwner: _isOwner,
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
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Scaffold(
      body: Center(
        child: FadeTransition(
          opacity: _fadeIn,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Hero(
                tag: 'app-logo',
                child: Container(
                  width: 88,
                  height: 88,
                  decoration: BoxDecoration(
                    color: colorScheme.primary,
                    borderRadius: BorderRadius.circular(GzusRadii.xl),
                    boxShadow: [
                      BoxShadow(
                        color: colorScheme.primary.withValues(alpha: 0.30),
                        blurRadius: 24,
                        offset: const Offset(0, 10),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(GzusRadii.xl),
                    child: Image.asset(
                      'assets/icon.png',
                      fit: BoxFit.cover,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: GzusSpacing.xl),
              Text(
                '软帮手',
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: GzusSpacing.xs),
              Text(
                '广州软件学院教务助手',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: GzusSpacing.xxl),
              SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(
                  strokeWidth: 3,
                  valueColor: AlwaysStoppedAnimation(colorScheme.primary),
                ),
              ),
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
