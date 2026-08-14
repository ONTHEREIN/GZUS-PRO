import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_client.dart';
import 'gzus_design.dart';
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
import 'widgets/icon_label.dart';
import 'widgets/open_browser.dart';
import 'widgets/page_panel.dart';
import 'widgets/page_silent_refresh.dart';
import 'widgets/web_unsupported.dart';

export 'test_flags.dart';

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
      title: '软帮手 Dev',
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
                                        color: accentFill(context),
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
                                      '软帮手 Dev',
                                      style: Theme.of(context)
                                          .textTheme
                                          .headlineMedium,
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      'OneGZUS',
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodyMedium
                                          ?.copyWith(
                                            color: Theme.of(context)
                                                .colorScheme
                                                .onSurfaceVariant,
                                          ),
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
                                        : _login,
                                    child: IconLabel(
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
          child: const Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Icons.school 被 tree-shaking 移除，替换为 emoji 避免白屏
              Text('🎓', style: TextStyle(fontSize: 36)),
              SizedBox(height: 14),
              CircularProgressIndicator(),
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
    this.cloudFirstWeeks = const {},
    this.cloudAutoWeek,
    this.isAdmin = false,
    this.isOwner = false,
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

  /// 云端同步的各学期开学日期（键 "{year}-{term}"），本地缺失时兜底
  final Map<String, String> cloudFirstWeeks;

  /// 云端同步的自动周次开关；null 表示未保存过
  final bool? cloudAutoWeek;

  /// 管理后台身份（由 /admin/me 确认后传入，用于「更多」页显示管理入口）
  final bool isAdmin;
  final bool isOwner;

  /// 账密登录时无法使用的功能 tabId 列表（依赖办事大厅 ehall 会话）
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
  late int year;
  late int term;
  late DateTime firstWeekStart;
  late int currentWeek;
  bool autoWeek = true;
  /// 用户是否手动切换过学期（切换后启动时的自动校正不再覆盖）。
  bool _userPinnedPeriod = false;
  /// 启动时的学期自动校正是否已执行过（只跑一次）。
  bool _periodAutoCorrected = false;
  List<NavTabConfig> _navBarTabs = NavTabConfig.defaultTabs;
  String? _highlightCourse;
  String? _overrideTabId;
  DateTime? _lastBackTime;
  bool _autoHideNavBar = true;
  final ValueNotifier<bool> _navBarVisible = ValueNotifier(true);
  final bool _mobileHeaderToolsVisible = false;
  bool _sidebarCollapsed = false;
  double _lastScrollOffset = 0;

  /// 已访问页面的保活缓存：首次访问时构建，之后常驻 IndexedStack 不销毁，
  /// 切换 Tab 只换 index，页面 State/滚动位置/选中项全部保留。
  final Map<String, Widget> _pageCache = {};
  final Map<String, GlobalKey> _pageKeys = {};
  final Set<String> _visitedTabs = {};
  final Map<String, DateTime> _lastSilentRefresh = {};
  /// 页面参数代数：学年/学期/周次等参数变化时 +1，
  /// 触发缓存页面重建 widget 实例（GlobalKey 保证 State 不销毁，走 didUpdateWidget）。
  int _pageGeneration = 0;
  final Map<String, int> _pageGen = {};
  bool? _lastCompact;

  @override
  void initState() {
    super.initState();
    final period = academicPeriodOf(DateTime.now());
    year = period.$1;
    term = period.$2;
    firstWeekStart = defaultFirstWeekStart(year, term);
    currentWeek = weekFromDate(firstWeekStart, DateTime.now(), clampToTerm: true);
    HomeWidgetBridge.setLaunchHandler(_handleWidgetLaunch);
    NotificationOpenBridge.setOpenTabHandler(_navigateToTab);
    LiveActivityController.instance.onOpen = _handleLiveActivityOpen;
    _loadNavConfig().then((_) => _consumeWidgetLaunch());
    _loadAutoHideSetting();
    _loadScheduleSettings();
    _autoCorrectPeriodOnce();
  }

  @override
  void dispose() {
    HomeWidgetBridge.setLaunchHandler(null);
    NotificationOpenBridge.setOpenTabHandler(null);
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
      _pageGeneration++;
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
    final activeTabId = _overrideTabId ??
        (_navBarTabs.isNotEmpty ? _navBarTabs[index].tabId : null);

    return PopScope(
      canPop: false,
      onPopInvoked: (didPop) {
        if (didPop) return;
        if (_overrideTabId != null) {
          final backTabId =
              _navBarTabs.isNotEmpty && index < _navBarTabs.length
                  ? _navBarTabs[index].tabId
                  : null;
          setState(() => _overrideTabId = null);
          if (backTabId != null) _activateTab(backTabId);
          return;
        }
        if (index != 0) {
          setState(() => index = 0);
          if (_navBarTabs.isNotEmpty) _activateTab(_navBarTabs[0].tabId);
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
            // 断点翻转时重建缓存页面（如 more 页的移动/宽屏参数）
            if (_lastCompact != null && _lastCompact != compact) {
              _pageGeneration++;
            }
            _lastCompact = compact;
            final mobileTabs = _mobileNavTabs(_navBarTabs);
            final effectiveSelected = _overrideTabId != null ? -1 : index;
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
                              FrostedBanner(
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
                                            widget.studentName ?? '软帮手',
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
                                            'OneGZUS',
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
                                FrostedBanner(
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
                              padding: EdgeInsets.fromLTRB(
                                  10,
                                  8,
                                  10,
                                  _autoHideNavBar
                                      ? 10
                                      : MediaQuery.paddingOf(context).bottom +
                                          10),
                              child: _CenteredPage(
                                maxWidth: 720,
                                child: _buildPageStack(activeTabId),
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
                              _activateTab(selectedTab.tabId);
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
                        _activateTab(_navBarTabs[value].tabId);
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
                                    child: _buildPageStack(activeTabId),
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
        final found = NavTabConfig.available.where((t) => t.tabId == id);
        if (found.isNotEmpty) tabs.add(found.first);
      }
    }
    if (mounted) {
      _pageGeneration++;
      setState(() {
        _navBarTabs = _filterRestrictedTabs(tabs);
        final homeIdx = tabs.indexWhere((t) => t.tabId == 'home');
        index = homeIdx >= 0 ? homeIdx : 0;
      });
    }
  }

  /// 账密登录时过滤掉依赖办事大厅的功能标签
  List<NavTabConfig> _filterRestrictedTabs(List<NavTabConfig> tabs) {
    return tabs
        .where((t) => !hideEcardOnCurrentPlatform || t.tabId != 'ecard')
        .where((t) =>
            !widget.isPasswordLogin ||
            !passwordRestrictedTabs.contains(t.tabId))
        .toList();
  }

  /// 惰性保活页面栈：页面首次激活时才构建，之后常驻 IndexedStack 不销毁；
  /// 切换 Tab 只换 index，激活的子页淡入。
  Widget _buildPageStack(String? activeTabId) {
    final children = <Widget>[
      for (final tab in _navBarTabs)
        _pageSlot(tab.tabId, active: tab.tabId == activeTabId),
    ];
    var activeIndex = _navBarTabs.indexWhere((t) => t.tabId == activeTabId);
    if (_overrideTabId != null &&
        !_navBarTabs.any((t) => t.tabId == _overrideTabId)) {
      children.add(_pageSlot(_overrideTabId!, active: true));
      activeIndex = children.length - 1;
    }
    if (activeIndex < 0) activeIndex = 0;
    return IndexedStack(index: activeIndex, children: children);
  }

  /// 单个页面的保活槽位：未访问时用占位符，访问后缓存页面实例；
  /// GlobalKey 保证参数变化重建 widget 实例时 State 不销毁。
  Widget _pageSlot(String tabId, {required bool active}) {
    final key = _pageKeys.putIfAbsent(
        tabId, () => GlobalKey(debugLabel: 'page-$tabId'));
    final Widget child;
    if (_visitedTabs.contains(tabId) || active) {
      _visitedTabs.add(tabId);
      child = _pageFor(tabId);
    } else {
      child = const SizedBox.shrink();
    }
    return KeyedSubtree(
      key: key,
      child: AnimatedOpacity(
        opacity: active ? 1 : 0,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOutCubic,
        child: child,
      ),
    );
  }

  /// 返回页面的缓存 widget 实例；参数代数变化时用当前参数重建（State 保留，
  /// 变化通过各页已有的 didUpdateWidget 传播）。
  Widget _pageFor(String tabId) {
    final cached = _pageCache[tabId];
    if (cached != null && _pageGen[tabId] == _pageGeneration) return cached;
    final built = _buildPage(tabId);
    _pageCache[tabId] = built;
    _pageGen[tabId] = _pageGeneration;
    return built;
  }

  /// Tab 激活：首次访问由 initState 自行拉取；再次访问且距上次超过 60 秒时
  /// 触发页面静默刷新（显示旧数据、后台拉新）。
  void _activateTab(String tabId) {
    final firstVisit = !_visitedTabs.contains(tabId);
    _visitedTabs.add(tabId);
    if (firstVisit) return;
    final last = _lastSilentRefresh[tabId];
    final now = DateTime.now();
    if (last != null && now.difference(last).inSeconds < 60) return;
    _lastSilentRefresh[tabId] = now;
    final state = _pageKeys[tabId]?.currentState;
    if (state is PageSilentRefresh) state.silentRefresh();
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
        if (hideEcardOnCurrentPlatform) {
          return const WebUnsupportedPage(
            title: '自动请假',
            icon: Icons.fact_check,
            message: '自动请假功能需要在手机 App 中使用，Web 端暂不支持自动填写表单。',
          );
        }
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
                _pageGeneration++;
              });
              _navigateToTab('exams');
              Future.delayed(const Duration(seconds: 2), () {
                if (mounted) {
                  setState(() => _highlightCourse = null);
                  _pageGeneration++;
                }
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
            onShowBackgroundGuide: widget.onSettingsPressed,
            isAdmin: widget.isAdmin,
            isOwner: widget.isOwner);
      default:
        return const SizedBox.shrink();
    }
  }

  void _navigateToTab(String tabId) {
    if (hideEcardOnCurrentPlatform && tabId == 'ecard') return;
    // 账密登录时阻止导航到受限功能
    if (widget.isPasswordLogin &&
        passwordRestrictedTabs.contains(tabId)) {
      return;
    }
    _activateTab(tabId);
    final idx = _navBarTabs.indexWhere((t) => t.tabId == tabId);
    if (idx >= 0) {
      _navBarVisible.value = true;
      setState(() {
        index = idx;
        _overrideTabId = null;
      });
      return;
    }
    final tabConfig = NavTabConfig.available.where((t) => t.tabId == tabId);
    if (tabConfig.isEmpty) return;
    _navBarVisible.value = true;
    setState(() {
      _overrideTabId = tabId;
    });
  }

  Future<void> _consumeWidgetLaunch() async {
    final tab = await HomeWidgetBridge.consumeInitialTab();
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
      unawaited(openInAppBrowser(context, url));
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
    // 本地缺失时回退云端（按学期），最后才用默认推导值
    final cloudText = firstWeekText == null
        ? widget.cloudFirstWeeks['$loadYear-$loadTerm']
        : null;
    final savedAuto =
        prefs.getBool('schedule.autoWeek') ?? widget.cloudAutoWeek ?? autoWeek;
    final defaultStart = defaultFirstWeekStart(loadYear, loadTerm);
    final parsedStart =
        DateTime.tryParse(firstWeekText ?? cloudText ?? '');
    final start = parsedStart ?? defaultStart;
    final savedWeek = prefs.getInt(_settingsKey(loadYear, loadTerm, 'week'));
    if (!mounted || loadYear != year || loadTerm != term) return;
    setState(() {
      firstWeekStart = start;
      autoWeek = savedAuto;
      currentWeek = savedAuto
          ? weekFromDate(start, DateTime.now(), clampToTerm: true)
          : (savedWeek ?? weekFromDate(start, DateTime.now(), clampToTerm: true));
    });
  }

  /// 启动时用已保存的开学日期反推当前学期并自动校正一次（best-effort）。
  /// 云端缺失时回退本地 SharedPreferences；用户手动切换过学期后不再校正。
  Future<void> _autoCorrectPeriodOnce() async {
    if (_periodAutoCorrected) return;
    _periodAutoCorrected = true;
    final firstWeeks = Map<String, String>.from(widget.cloudFirstWeeks);
    if (firstWeeks.isEmpty) {
      final prefs = await SharedPreferences.getInstance();
      for (final key in prefs.getKeys()) {
        const prefix = 'schedule.';
        const suffix = '.firstWeekStart';
        if (!key.startsWith(prefix) || !key.endsWith(suffix)) continue;
        final value = prefs.getString(key);
        if (value == null || value.isEmpty) continue;
        final mid = key.substring(prefix.length, key.length - suffix.length);
        firstWeeks[mid.replaceAll('.', '-')] = value;
      }
    }
    final resolved = academicPeriodFromFirstWeeks(firstWeeks, DateTime.now());
    if (resolved == null || resolved == (year, term)) return;
    if (!mounted || _userPinnedPeriod) return;
    setState(() {
      year = resolved.$1;
      term = resolved.$2;
      firstWeekStart = defaultFirstWeekStart(year, term);
      currentWeek = weekFromDate(firstWeekStart, DateTime.now(), clampToTerm: true);
      _pageGeneration++;
    });
    _loadScheduleSettings();
  }

  Future<void> _saveScheduleSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _settingsKey(year, term, 'firstWeekStart'),
      dateText(firstWeekStart),
    );
    await prefs.setInt(_settingsKey(year, term, 'week'), currentWeek);
    await prefs.setBool('schedule.autoWeek', autoWeek);
    unawaited(_syncScheduleSettingsToCloud());
  }

  /// 把当前学期的开学日期合并进云端（best-effort，失败仅打印日志）。
  Future<void> _syncScheduleSettingsToCloud() async {
    try {
      final merged = Map<String, String>.from(widget.cloudFirstWeeks)
        ..['$year-$term'] = dateText(firstWeekStart);
      await widget.api.saveScheduleSettings(
        firstWeeks: merged,
        autoWeek: autoWeek,
      );
    } catch (error) {
      debugPrint('同步开学日期到云端失败: error=${error.runtimeType}');
    }
  }

  void _setAcademicPeriod(int nextYear, int nextTerm) {
    _userPinnedPeriod = true;
    setState(() {
      year = nextYear;
      term = nextTerm;
      firstWeekStart = defaultFirstWeekStart(nextYear, nextTerm);
      currentWeek = weekFromDate(firstWeekStart, DateTime.now(), clampToTerm: true);
      _pageGeneration++;
    });
    _loadScheduleSettings();
  }

  void _setFirstWeekStart(DateTime value) {
    // 兜底归一化：确保首周开始日期始终为周一
    final monday = mondayOf(value);
    setState(() {
      firstWeekStart = monday;
      if (autoWeek) currentWeek = weekFromDate(monday, DateTime.now(), clampToTerm: true);
      _pageGeneration++;
    });
    _saveScheduleSettings();
  }

  void _setCurrentWeek(int value) {
    setState(() {
      currentWeek = value.clamp(1, 30);
      autoWeek = false;
      _pageGeneration++;
    });
    _saveScheduleSettings();
  }

  void _setAutoWeek(bool value) {
    setState(() {
      autoWeek = value;
      if (value) currentWeek = weekFromDate(firstWeekStart, DateTime.now(), clampToTerm: true);
      _pageGeneration++;
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
                        color: accentFill(context),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: const Center(
                          child: Text('🎓', style: TextStyle(fontSize: 22))),
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
                          Text('软帮手 Dev', style: theme.textTheme.titleLarge),
                          const SizedBox(height: 4),
                          Text('OneGZUS', style: theme.textTheme.bodySmall),
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
                      color: active ? accentFill(context) : Colors.transparent,
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
                                ? accentFill(context)
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
