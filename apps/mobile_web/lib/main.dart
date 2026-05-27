import 'dart:convert';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_client.dart';
import 'browser_redirect.dart';
import 'mobile_sso.dart';

void main() {
  runApp(const GzusProApp());
}

class GzusProApp extends StatefulWidget {
  const GzusProApp({super.key});

  @override
  State<GzusProApp> createState() => _GzusProAppState();
}

class _GzusProAppState extends State<GzusProApp> {
  final api = ApiClient();
  bool darkMode = false;
  bool loggedIn = false;
  bool initializing = true;
  String? studentName;
  String? loginError;

  @override
  void initState() {
    super.initState();
    _bootstrapLoginState();
  }

  @override
  Widget build(BuildContext context) {
    return FluentApp(
      title: 'GZUS-PRO',
      debugShowCheckedModeBanner: false,
      themeMode: darkMode ? ThemeMode.dark : ThemeMode.light,
      theme: FluentThemeData(
        accentColor: Colors.blue,
        brightness: Brightness.light,
        scaffoldBackgroundColor: const Color(0xFFF7F8FA),
      ),
      darkTheme: FluentThemeData(
        accentColor: Colors.blue,
        brightness: Brightness.dark,
      ),
      home: initializing
          ? const LoadingPage()
          : loggedIn
              ? DashboardShell(
                  api: api,
                  studentName: studentName,
                  darkMode: darkMode,
                  onThemeChanged: (value) => setState(() => darkMode = value),
                  onLogout: () {
                    _logout();
                  },
                )
              : LoginPage(
                  api: api,
                  initialError: loginError,
                  onLoggedIn: (result) {
                    _finishLogin(result);
                  },
                ),
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
    await _restoreSession();
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
      });
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
    try {
      final info = await api.me();
      if (!mounted) return;
      setState(() {
        initializing = false;
        loggedIn = true;
        studentName = prefs.getString('auth.studentName') ?? info.name;
      });
    } on ApiException {
      await _clearSavedSession();
      if (!mounted) return;
      setState(() {
        initializing = false;
        loggedIn = false;
      });
    }
  }

  Future<void> _finishLogin(LoginResult result) async {
    await _persistLogin(result);
    if (!mounted) return;
    setState(() {
      loggedIn = true;
      studentName = result.studentName;
      loginError = null;
    });
  }

  Future<void> _persistLogin(LoginResult result) async {
    final prefs = await SharedPreferences.getInstance();
    if (result.sessionId != null) {
      await prefs.setString('auth.sessionId', result.sessionId!);
    }
    if (result.studentName != null) {
      await prefs.setString('auth.studentName', result.studentName!);
    }
  }

  Future<void> _logout() async {
    try {
      await api.logout();
    } on ApiException {
      api.useSession(null);
    }
    await _clearSavedSession();
    if (!mounted) return;
    setState(() {
      loggedIn = false;
      studentName = null;
    });
  }

  Future<void> _clearSavedSession() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('auth.sessionId');
    await prefs.remove('auth.studentName');
    api.useSession(null);
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

class _LoginPageState extends State<LoginPage> {
  final accountController = TextEditingController();
  final passwordController = TextEditingController();
  final captchaController = TextEditingController();
  final passwordFocusNode = FocusNode();
  final captchaFocusNode = FocusNode();
  bool loading = false;
  String? error;
  String? captchaToken;
  String? captchaImage;

  @override
  void initState() {
    super.initState();
    error = widget.initialError;
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
    accountController.dispose();
    passwordController.dispose();
    captchaController.dispose();
    passwordFocusNode.dispose();
    captchaFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ScaffoldPage(
      content: LayoutBuilder(
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
              child: Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: compact ? 460 : 420),
                  child: Card(
                    borderRadius: BorderRadius.circular(8),
                    padding: EdgeInsets.all(compact ? 20 : 26),
                    child: AutofillGroup(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              _IconBadge(
                                icon: FluentIcons.education,
                                size: compact ? 42 : 46,
                              ),
                              const SizedBox(width: 12),
                              const Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'GZUS-PRO',
                                      style: TextStyle(
                                        fontSize: 28,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    SizedBox(height: 3),
                                    Text('推荐使用办事大厅统一登录'),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          SizedBox(height: compact ? 24 : 28),
                          SizedBox(
                            height: compact ? 56 : 60,
                            child: FilledButton(
                              onPressed: loading ? null : _startLySso,
                              child: _IconLabel(
                                icon: FluentIcons.link,
                                label: loading ? '登录中...' : '办事大厅统一登录',
                                centered: true,
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          Expander(
                            header: const _IconLabel(
                              icon: FluentIcons.lock,
                              label: '教务系统登录',
                            ),
                            content: Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  TextBox(
                                    controller: accountController,
                                    placeholder: '学号',
                                    autofillHints: const [
                                      AutofillHints.username,
                                      AutofillHints.email,
                                    ],
                                    textInputAction: TextInputAction.next,
                                    onSubmitted: (_) =>
                                        passwordFocusNode.requestFocus(),
                                    prefix: const Padding(
                                      padding: EdgeInsets.only(left: 10),
                                      child: Icon(FluentIcons.contact),
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                  TextBox(
                                    controller: passwordController,
                                    focusNode: passwordFocusNode,
                                    placeholder: '密码',
                                    obscureText: true,
                                    autofillHints: const [
                                      AutofillHints.password
                                    ],
                                    textInputAction: TextInputAction.done,
                                    onSubmitted: _submitFromKeyboard,
                                    prefix: const Padding(
                                      padding: EdgeInsets.only(left: 10),
                                      child: Icon(FluentIcons.lock),
                                    ),
                                  ),
                                  if (captchaToken != null) ...[
                                    const SizedBox(height: 12),
                                    if (captchaImage != null &&
                                        captchaImage!.isNotEmpty)
                                      CaptchaImage(source: captchaImage!),
                                    const SizedBox(height: 8),
                                    TextBox(
                                      controller: captchaController,
                                      focusNode: captchaFocusNode,
                                      placeholder: '验证码',
                                      textInputAction: TextInputAction.done,
                                      onSubmitted: _submitFromKeyboard,
                                      prefix: const Padding(
                                        padding: EdgeInsets.only(left: 10),
                                        child: Icon(FluentIcons.security_group),
                                      ),
                                    ),
                                  ],
                                  SizedBox(height: compact ? 16 : 18),
                                  SizedBox(
                                    height: 44,
                                    child: Button(
                                      onPressed: loading ? null : _login,
                                      child: _IconLabel(
                                        icon: FluentIcons.signin,
                                        label: loading ? '登录中...' : '教务系统登录',
                                        centered: true,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          if (error != null) ...[
                            const SizedBox(height: 12),
                            InfoBar(
                              severity: InfoBarSeverity.error,
                              title: Text(error!),
                            ),
                          ],
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
    );
  }

  Future<void> _login() async {
    if (loading) return;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final result = captchaToken == null
          ? await widget.api
              .login(accountController.text, passwordController.text)
          : await widget.api
              .submitCaptcha(captchaToken!, captchaController.text);
      if (result.status == 'captcha_required') {
        setState(() {
          captchaToken = result.captchaToken;
          captchaImage = result.captchaImage;
        });
        captchaFocusNode.requestFocus();
      } else {
        TextInput.finishAutofillContext(shouldSave: true);
        widget.onLoggedIn(result);
      }
    } on ApiException catch (exc) {
      setState(() => error = exc.message);
    } finally {
      setState(() => loading = false);
    }
  }

  void _submitFromKeyboard(String _) {
    if (!loading) _login();
  }

  void _startLySso() {
    if (_isMobilePlatform) {
      _startMobileSso();
      return;
    }
    if (kIsWeb) {
      final returnUrl = _withoutSsoParams(Uri.base).toString();
      redirectTo(widget.api.lySsoStartUrl(returnUrl: returnUrl));
      return;
    }
    setState(() => error = '当前平台不支持联奕单点登录');
  }

  Future<void> _startMobileSso() async {
    if (loading) return;
    final account = accountController.text.trim();
    final result = await Navigator.of(context).push<MobileCookieLoginResult>(
      FluentPageRoute(
        builder: (_) => MobileSsoLoginPage(account: account),
      ),
    );
    if (result == null || loading) return;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final loginResult = await widget.api.mobileCookieLogin(
        result.account.trim().isEmpty ? 'sso-account' : result.account,
        result.cookies,
      );
      widget.onLoggedIn(loginResult);
    } on ApiException catch (exc) {
      setState(() => error = exc.message);
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }
}

bool get _isMobilePlatform =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);

const _mobileBreakpoint = 720.0;
const _compactNavBreakpoint = 1024.0;

class LoadingPage extends StatelessWidget {
  const LoadingPage({super.key});

  @override
  Widget build(BuildContext context) {
    return ScaffoldPage(
      content: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              FluentIcons.education,
              size: 36,
              color: FluentTheme.of(context).accentColor,
            ),
            const SizedBox(height: 14),
            const ProgressRing(),
          ],
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
    required this.darkMode,
    required this.onThemeChanged,
    required this.onLogout,
  });

  final ApiClient api;
  final String? studentName;
  final bool darkMode;
  final ValueChanged<bool> onThemeChanged;
  final VoidCallback onLogout;

  @override
  State<DashboardShell> createState() => _DashboardShellState();
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
  bool headerExpanded = false;

  @override
  void initState() {
    super.initState();
    firstWeekStart = _defaultFirstWeekStart(year, term);
    currentWeek = _weekFromDate(firstWeekStart, DateTime.now());
    _loadScheduleSettings();
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      InfoPage(api: widget.api, onSessionExpired: widget.onLogout),
      NoticesPage(api: widget.api, onSessionExpired: widget.onLogout),
      SchedulePage(
        api: widget.api,
        year: year,
        term: term,
        currentWeek: currentWeek,
        firstWeekStart: firstWeekStart,
        autoWeek: autoWeek,
        onFirstWeekChanged: _setFirstWeekStart,
        onCurrentWeekChanged: _setCurrentWeek,
        onAutoWeekChanged: _setAutoWeek,
        onSessionExpired: widget.onLogout,
      ),
      AttendancePage(
          api: widget.api,
          year: year,
          term: term,
          onSessionExpired: widget.onLogout),
      ExamsPage(
          api: widget.api,
          periods: _allAcademicPeriods(),
          onSessionExpired: widget.onLogout),
      GradesPage(
          api: widget.api,
          periods: _allAcademicPeriods(),
          onSessionExpired: widget.onLogout),
      CreditsPage(api: widget.api, onSessionExpired: widget.onLogout),
    ];
    Widget pageHeader({required bool compact, required bool dense}) {
      final title = widget.studentName == null ? '教务助手' : widget.studentName!;
      final subtitle = '$year-${year + 1} 第$term学期 · 第$currentWeek周';
      final horizontalPadding = compact ? 10.0 : (dense ? 18.0 : 24.0);
      final showTools = !compact || headerExpanded;
      return Container(
        key: const ValueKey('dashboard-header'),
        padding: EdgeInsets.fromLTRB(
          horizontalPadding,
          compact ? 6 : 12,
          horizontalPadding,
          compact ? 7 : 12,
        ),
        decoration: BoxDecoration(
          color: FluentTheme.of(context).resources.solidBackgroundFillColorBase,
          border: Border(
            bottom: BorderSide(
              color:
                  FluentTheme.of(context).resources.controlStrokeColorDefault,
            ),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                _IconBadge(
                  icon: _navItems[index].icon,
                  size: compact ? 30 : 42,
                ),
                SizedBox(width: compact ? 8 : 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: compact ? 16 : 20,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '${_navItems[index].label} · $subtitle',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: FluentTheme.of(context).inactiveColor,
                          fontSize: compact ? 11 : 13,
                        ),
                      ),
                    ],
                  ),
                ),
                if (compact) ...[
                  const SizedBox(width: 8),
                  SizedBox(
                    key: const ValueKey('mobile-header-toggle'),
                    width: 38,
                    height: 34,
                    child: Tooltip(
                      message: headerExpanded ? '收起筛选' : '展开筛选',
                      child: IconButton(
                        icon: Icon(
                          headerExpanded
                              ? FluentIcons.chevron_up
                              : FluentIcons.filter,
                          size: 18,
                        ),
                        onPressed: () =>
                            setState(() => headerExpanded = !headerExpanded),
                      ),
                    ),
                  ),
                ],
              ],
            ),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 160),
              child: showTools
                  ? Padding(
                      key: const ValueKey('dashboard-header-tools'),
                      padding: EdgeInsets.only(top: compact ? 8 : 12),
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          SizedBox(
                            width: compact ? 112 : 172,
                            child: ComboBox<int>(
                              value: year,
                              items: [
                                for (final value in _yearOptions())
                                  ComboBoxItem(
                                    value: value,
                                    child: Text(
                                      compact
                                          ? '$value'
                                          : '$value-${value + 1}',
                                    ),
                                  ),
                              ],
                              onChanged: (value) {
                                if (value != null) {
                                  _setAcademicPeriod(value, term);
                                }
                              },
                            ),
                          ),
                          SizedBox(
                            width: compact ? 112 : 120,
                            child: ComboBox<int>(
                              value: term,
                              items: const [
                                ComboBoxItem(value: 1, child: Text('第1学期')),
                                ComboBoxItem(value: 2, child: Text('第2学期')),
                              ],
                              onChanged: (value) {
                                if (value != null) {
                                  _setAcademicPeriod(year, value);
                                }
                              },
                            ),
                          ),
                          ToggleSwitch(
                            checked: widget.darkMode,
                            onChanged: widget.onThemeChanged,
                            content: const _IconLabel(
                              icon: FluentIcons.brightness,
                              label: '深色',
                            ),
                          ),
                          Button(
                            onPressed: widget.onLogout,
                            child: const _IconLabel(
                              icon: FluentIcons.sign_out,
                              label: '退出',
                            ),
                          ),
                        ],
                      ),
                    )
                  : const SizedBox.shrink(
                      key: ValueKey('dashboard-header-tools-collapsed'),
                    ),
            ),
          ],
        ),
      );
    }

    Widget pageContent(
      Widget page, {
      required bool compact,
      required bool dense,
    }) {
      return Column(
        children: [
          pageHeader(compact: compact, dense: dense),
          Expanded(
            child: Padding(
              padding: EdgeInsets.all(compact ? 10 : (dense ? 16 : 24)),
              child: page,
            ),
          ),
        ],
      );
    }

    return ScaffoldPage(
      content: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < _mobileBreakpoint;
          final dense = constraints.maxWidth < _compactNavBreakpoint;
          if (compact) {
            return Column(
              children: [
                Expanded(
                  child: SafeArea(
                    bottom: false,
                    child: pageContent(
                      pages[index],
                      compact: true,
                      dense: true,
                    ),
                  ),
                ),
                MobileNavBar(
                  selected: index,
                  onChanged: (value) => setState(() => index = value),
                ),
              ],
            );
          }
          return Row(
            children: [
              AppSidebar(
                selected: index,
                compact: dense,
                onChanged: (value) => setState(() => index = value),
              ),
              Expanded(
                child: pageContent(
                  pages[index],
                  compact: false,
                  dense: dense,
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  List<int> _yearOptions() =>
      [for (var value = year + 1; value >= year - 5; value--) value];

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
    required this.selected,
    required this.onChanged,
    this.compact = false,
  });

  final int selected;
  final ValueChanged<int> onChanged;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('app-sidebar'),
      width: compact ? 84 : 212,
      color: FluentTheme.of(context).resources.solidBackgroundFillColorBase,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(12, 4, 12, compact ? 14 : 16),
                child: compact
                    ? const Icon(FluentIcons.education, size: 24)
                    : const Text(
                        'GZUS-PRO',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
              ),
              for (var i = 0; i < _navItems.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Button(
                    style: ButtonStyle(
                      padding: WidgetStateProperty.all(
                        const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 10),
                      ),
                      backgroundColor:
                          WidgetStateProperty.resolveWith((states) {
                        if (i == selected) {
                          return FluentTheme.of(context)
                              .accentColor
                              .withValues(alpha: 0.14);
                        }
                        return Colors.transparent;
                      }),
                    ),
                    onPressed: () => onChanged(i),
                    child: compact
                        ? Tooltip(
                            message: _navItems[i].label,
                            child: Center(
                              child: Icon(_navItems[i].icon, size: 20),
                            ),
                          )
                        : Row(
                            children: [
                              Icon(_navItems[i].icon, size: 18),
                              const SizedBox(width: 10),
                              Text(_navItems[i].label),
                            ],
                          ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class MobileNavBar extends StatelessWidget {
  const MobileNavBar(
      {super.key, required this.selected, required this.onChanged});

  final int selected;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.viewPaddingOf(context).bottom;
    return Container(
      key: const ValueKey('mobile-bottom-nav'),
      height: 56 + bottom,
      padding: EdgeInsets.fromLTRB(8, 5, 8, 5 + bottom),
      decoration: BoxDecoration(
        color: FluentTheme.of(context).resources.solidBackgroundFillColorBase,
        border: Border(
          top: BorderSide(
            color: FluentTheme.of(context).resources.controlStrokeColorDefault,
          ),
        ),
      ),
      child: Row(
        children: [
          for (var i = 0; i < _navItems.length; i++)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: _MobileNavButton(
                  item: _navItems[i],
                  selected: i == selected,
                  onPressed: () => onChanged(i),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _MobileNavButton extends StatelessWidget {
  const _MobileNavButton({
    required this.item,
    required this.selected,
    required this.onPressed,
  });

  final _NavItem item;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final accent = FluentTheme.of(context).accentColor;
    return Button(
      style: ButtonStyle(
        padding: WidgetStateProperty.all(EdgeInsets.zero),
        backgroundColor: WidgetStateProperty.resolveWith((states) {
          if (selected) return accent.withValues(alpha: 0.16);
          return Colors.transparent;
        }),
      ),
      onPressed: onPressed,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(item.icon, size: 17, color: selected ? accent : null),
          const SizedBox(height: 2),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              item.shortLabel,
              maxLines: 1,
              style: TextStyle(
                fontSize: 10,
                fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                color: selected ? accent : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _NavItem {
  const _NavItem(this.icon, this.label, [this.shortLabel = '']);

  final IconData icon;
  final String label;
  final String shortLabel;
}

const _navItems = [
  _NavItem(FluentIcons.contact_card, '个人信息', '信息'),
  _NavItem(FluentIcons.info, '通知', '通知'),
  _NavItem(FluentIcons.calendar_week, '课表', '课表'),
  _NavItem(FluentIcons.clock, '考勤', '考勤'),
  _NavItem(FluentIcons.test_beaker, '考试', '考试'),
  _NavItem(FluentIcons.education, '成绩', '成绩'),
  _NavItem(FluentIcons.publish_course, '学分', '学分'),
];

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
          return const Center(child: ProgressRing());
        }
        if (snapshot.hasError) {
          final error = snapshot.error;
          if (error is ApiException && error.statusCode == 401) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              onSessionExpired?.call();
            });
          }
          return InfoBar(
            severity: InfoBarSeverity.error,
            title: Text(
              error is ApiException ? error.message : error.toString(),
            ),
          );
        }
        final data = snapshot.data;
        if (data is List && data.isEmpty) {
          return EmptyState(message: emptyMessage);
        }
        return builder(data as T);
      },
    );
  }
}

class InfoPage extends StatelessWidget {
  const InfoPage({super.key, required this.api, this.onSessionExpired});

  final ApiClient api;
  final VoidCallback? onSessionExpired;

  @override
  Widget build(BuildContext context) {
    return AsyncPanel<StudentInfo>(
      future: api.me(),
      onSessionExpired: onSessionExpired,
      builder: (info) => LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 560;
          final tiles = [
            InfoTile(icon: FluentIcons.contact, label: '姓名', value: info.name),
            InfoTile(
                icon: FluentIcons.contact_card,
                label: '学号',
                value: info.studentId),
            InfoTile(
                icon: FluentIcons.home,
                label: '学院',
                value: info.college ?? '-'),
            InfoTile(
                icon: FluentIcons.education,
                label: '专业',
                value: info.major ?? '-'),
            InfoTile(
                icon: FluentIcons.group,
                label: '班级',
                value: info.className ?? '-'),
            InfoTile(
                icon: FluentIcons.calendar,
                label: '年级',
                value: info.grade ?? '-'),
          ];
          return PagePanel(
            title: '个人信息',
            icon: FluentIcons.contact_card,
            expandChild: compact,
            child: compact
                ? SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Center(
                          child: StudentAvatar(
                            photoDataUrl: info.photoDataUrl,
                            name: info.name,
                          ),
                        ),
                        const SizedBox(height: 16),
                        Wrap(spacing: 12, runSpacing: 12, children: tiles),
                      ],
                    ),
                  )
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      StudentAvatar(
                        photoDataUrl: info.photoDataUrl,
                        name: info.name,
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Wrap(
                          spacing: 12,
                          runSpacing: 12,
                          children: tiles,
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

class StudentAvatar extends StatelessWidget {
  const StudentAvatar(
      {super.key, required this.photoDataUrl, required this.name});

  final String? photoDataUrl;
  final String name;

  @override
  Widget build(BuildContext context) {
    final image = photoDataUrl;
    return Container(
      width: 112,
      height: 144,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: FluentTheme.of(context).resources.subtleFillColorSecondary,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
            color: FluentTheme.of(context).resources.controlStrokeColorDefault),
      ),
      child: image == null || image.isEmpty
          ? Center(
              child: Text(
                name.isEmpty ? '-' : name.characters.first,
                style:
                    const TextStyle(fontSize: 32, fontWeight: FontWeight.w600),
              ),
            )
          : Image.memory(
              base64Decode(image.substring(image.indexOf(',') + 1)),
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) =>
                  const Center(child: Icon(FluentIcons.contact)),
            ),
    );
  }
}

class NoticesPage extends StatelessWidget {
  const NoticesPage({super.key, required this.api, this.onSessionExpired});

  final ApiClient api;
  final VoidCallback? onSessionExpired;

  @override
  Widget build(BuildContext context) {
    return AsyncPanel<List<NoticeItem>>(
      future: api.notices(),
      emptyMessage: '暂无通知',
      onSessionExpired: onSessionExpired,
      builder: (items) => PagePanel(
        title: '通知',
        icon: FluentIcons.info,
        expandChild: true,
        child: ListView.separated(
          itemCount: items.length,
          separatorBuilder: (_, __) => const SizedBox(height: 10),
          itemBuilder: (context, index) => NoticeCard(item: items[index]),
        ),
      ),
    );
  }
}

class NoticeCard extends StatelessWidget {
  const NoticeCard({super.key, required this.item});

  final NoticeItem item;

  @override
  Widget build(BuildContext context) {
    return Card(
      borderRadius: BorderRadius.circular(8),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _IconBadge(icon: FluentIcons.info, size: 32),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
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
          if (item.summary != null && item.summary!.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(item.summary!, maxLines: 2, overflow: TextOverflow.ellipsis),
          ],
          if (item.url != null && item.url!.isNotEmpty) ...[
            const SizedBox(height: 8),
            SelectableText(
              item.url!,
              style: TextStyle(
                fontSize: 12,
                color: FluentTheme.of(context).inactiveColor,
              ),
            ),
          ],
        ],
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
      style: TextStyle(
        fontSize: 12,
        color: FluentTheme.of(context).inactiveColor,
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
  bool showJson = false;
  bool showAllCourses = false;
  String? manageError;

  @override
  void initState() {
    super.initState();
    firstWeekController =
        TextEditingController(text: _dateText(widget.firstWeekStart));
  }

  @override
  void didUpdateWidget(covariant SchedulePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final next = _dateText(widget.firstWeekStart);
    if (firstWeekController.text != next) firstWeekController.text = next;
  }

  @override
  void dispose() {
    firstWeekController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AsyncPanel<ScheduleResult>(
      future: widget.api.schedule(year: widget.year, term: widget.term),
      onSessionExpired: widget.onSessionExpired,
      builder: (result) {
        final visibleItems = result.items
            .where((item) => item.occursInWeek(widget.currentWeek))
            .toList();
        final displayItems = showAllCourses ? result.items : visibleItems;
        return PagePanel(
          title: '课表',
          icon: FluentIcons.calendar_week,
          expandChild: true,
          child: Stack(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Wrap(
                    spacing: 10,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      _MetricPill(
                        icon: FluentIcons.calendar_week,
                        label: '第',
                        value: '${widget.currentWeek}周',
                        dense: true,
                      ),
                      _MetricPill(
                        icon: FluentIcons.list,
                        label: '课程',
                        value: '${displayItems.length}/${result.items.length}',
                        dense: true,
                      ),
                      _MetricPill(
                        icon: FluentIcons.date_time,
                        label: '首周',
                        value: _dateText(widget.firstWeekStart),
                        dense: true,
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  if (result.items.isEmpty)
                    const Expanded(child: EmptyState(message: '当前学期暂无课表'))
                  else if (displayItems.isEmpty)
                    Expanded(
                        child:
                            EmptyState(message: '第${widget.currentWeek}周暂无课程'))
                  else
                    Expanded(child: TimetableView(items: displayItems)),
                  if (showJson) ...[
                    const SizedBox(height: 10),
                    Flexible(child: JsonPanel(json: result.prettyJson)),
                  ],
                ],
              ),
              Positioned(
                right: 0,
                bottom: 0,
                child: SizedBox(
                  key: const ValueKey('schedule-tools-button'),
                  width: 58,
                  height: 42,
                  child: Tooltip(
                    message: '课表工具',
                    child: FilledButton(
                      onPressed: () => _showScheduleTools(result.prettyJson),
                      child: const Icon(FluentIcons.more, size: 18),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _showScheduleTools(String prettyJson) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, localSetState) => ContentDialog(
          title: const Text('课表工具'),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520, maxHeight: 620),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      Button(
                        onPressed: () {
                          setState(() => showAllCourses = !showAllCourses);
                          localSetState(() {});
                        },
                        child: _IconLabel(
                          icon: FluentIcons.view,
                          label: showAllCourses ? '仅本周' : '全部课程',
                        ),
                      ),
                      ToggleSwitch(
                        checked: showJson,
                        onChanged: (value) {
                          setState(() => showJson = value);
                          localSetState(() {});
                        },
                        content: const _IconLabel(
                          icon: FluentIcons.code,
                          label: 'JSON',
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
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('关闭'),
            ),
          ],
        ),
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
    return AccentPanel(
      child: Wrap(
        spacing: compact ? 8 : 12,
        runSpacing: 10,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SizedBox(
            width: compact ? 146 : 160,
            child: TextBox(
              controller: firstWeekController,
              placeholder: 'YYYY-MM-DD',
              prefix: const Padding(
                padding: EdgeInsets.only(left: 8),
                child: Icon(FluentIcons.calendar, size: 15),
              ),
            ),
          ),
          FilledButton(
            onPressed: onSaveFirstWeek,
            child: const _IconLabel(
              icon: FluentIcons.save,
              label: '保存',
            ),
          ),
          Button(
            onPressed: onUseCurrentWeek,
            child: const _IconLabel(
              icon: FluentIcons.date_time,
              label: '设为本周',
            ),
          ),
          ToggleSwitch(
            checked: autoWeek,
            onChanged: onAutoWeekChanged,
            content: _IconLabel(
              icon: FluentIcons.clock,
              label: '自动：第$autoWeekValue周',
            ),
          ),
          SizedBox(
            width: 116,
            child: ComboBox<int>(
              value: currentWeek,
              items: [
                for (var week = 1; week <= 30; week++)
                  ComboBoxItem(value: week, child: Text('第$week周')),
              ],
              onChanged: autoWeek
                  ? null
                  : (value) {
                      if (value != null) onCurrentWeekChanged(value);
                    },
            ),
          ),
          if (error != null) Text(error!, style: TextStyle(color: Colors.red)),
        ],
      ),
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
    final theme = FluentTheme.of(context);
    final lineColor = theme.resources.controlStrokeColorDefault;
    final surface = theme.resources.solidBackgroundFillColorSecondary;
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
    final inactive = FluentTheme.of(context).inactiveColor;
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
      (FluentIcons.book_answers, '课程', course.name),
      (FluentIcons.calendar_week, '星期', '周${course.weekday}'),
      (FluentIcons.clock, '节次', '第$start-${end >= start ? end : start}节'),
      if (_clean(course.classroom) != null)
        (FluentIcons.room, '教室', _clean(course.classroom)!),
      if (_clean(course.teacher) != null)
        (FluentIcons.people, '教师', _clean(course.teacher)!),
      if (_clean(course.weeks) != null)
        (FluentIcons.date_time, '周次', _clean(course.weeks)!),
    ];
    final rawRows = course.raw.entries
        .where((entry) =>
            !_priorityRawKeys.contains(entry.key) &&
            _rawValueText(entry.value).isNotEmpty)
        .map((entry) => (_rawLabel(entry.key), _rawValueText(entry.value)))
        .toList();

    showDialog<void>(
      context: context,
      builder: (context) => ContentDialog(
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
                  Expander(
                    header: const Text('原始字段'),
                    content: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final row in rawRows)
                          _DetailRow(label: row.$1, value: row.$2),
                      ],
                    ),
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
          (FluentIcons.info, _rawLabel(key), _rawValueText(course.raw[key])),
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
      'jxbmc': '教学班(jxbmc)',
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
            Icon(icon, size: 15, color: FluentTheme.of(context).inactiveColor),
            const SizedBox(width: 8),
          ],
          SizedBox(
            width: icon == null ? 132 : 116,
            child: Text(
              label,
              style: TextStyle(color: FluentTheme.of(context).inactiveColor),
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

class JsonPanel extends StatelessWidget {
  const JsonPanel({super.key, required this.json});

  final String json;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxHeight: 360),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color:
            FluentTheme.of(context).resources.solidBackgroundFillColorSecondary,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
            color: FluentTheme.of(context).resources.controlStrokeColorDefault),
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

class AcademicPeriod {
  const AcademicPeriod(this.year, this.term);

  final int year;
  final int term;

  String get label => '$year-${year + 1}-$term';
}

class PeriodExam {
  PeriodExam(this.period, this.exam);

  final AcademicPeriod period;
  final ExamItem exam;
  int retakeIndex = 0;

  bool get isRetake => retakeIndex > 0;
  String get displayName => isRetake && !exam.courseName.contains('补')
      ? '${exam.courseName}（补）'
      : exam.courseName;
  String get examKind => isRetake ? '第${_cnNumber(retakeIndex)}次补考' : '普通考试';
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
    FluentTheme.of(context).accentColor.withValues(alpha: 0.12);

Color _retakeFill(int index) {
  final alpha = (0.10 + index * 0.04).clamp(0.12, 0.26).toDouble();
  return Colors.red.withValues(alpha: alpha);
}

Color _retakeText(int index) => index >= 2 ? Colors.red.dark : Colors.red;

String _cnNumber(int value) {
  const numbers = ['零', '一', '二', '三', '四', '五', '六', '七', '八', '九', '十'];
  if (value >= 0 && value < numbers.length) return numbers[value];
  return '$value';
}

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
  if (aTime != null && bTime != null) return aTime.compareTo(bTime);
  if (aTime != null) return -1;
  if (bTime != null) return 1;
  final periodCompare =
      _periodSortValue(a.period).compareTo(_periodSortValue(b.period));
  if (periodCompare != 0) return periodCompare;
  return a.exam.courseName.compareTo(b.exam.courseName);
}

class AttendancePage extends StatelessWidget {
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
  Widget build(BuildContext context) {
    return AsyncPanel<AttendanceResponse>(
      future: api.attendance(year: year, term: term),
      onSessionExpired: onSessionExpired,
      builder: (data) => LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 640;
          if (data.items.isEmpty) {
            return const PagePanel(
              title: '考勤',
              icon: FluentIcons.clock,
              child: EmptyState(message: '暂无考勤记录'),
            );
          }
          if (compact) {
            return PagePanel(
              title: '考勤',
              icon: FluentIcons.clock,
              expandChild: true,
              child: ListView.separated(
                itemCount: data.items.length + 1,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (context, index) {
                  if (index == 0) {
                    return AccentPanel(
                        child: AttendanceOverview(items: data.items));
                  }
                  final item = data.items[index - 1];
                  return _MobileRecordCard(
                    icon: FluentIcons.clock,
                    title: item.courseName,
                    subtitle: '合计 ${_attendanceStatusTotal(item)} 次',
                    rows: [
                      (FluentIcons.completed, '正常', '${item.normal}'),
                      (FluentIcons.warning, '迟到', '${item.late}'),
                      (FluentIcons.warning, '早退', '${item.leaveEarly}'),
                      (FluentIcons.error, '旷课', '${item.absent}'),
                      (FluentIcons.contact_card, '请假', '${item.leave}'),
                    ],
                  );
                },
              ),
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              PagePanel(
                title: '考勤总览',
                icon: FluentIcons.chart,
                child: AttendanceOverview(items: data.items),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: PagePanel(
                  title: '考勤',
                  icon: FluentIcons.clock,
                  expandChild: true,
                  child: SingleChildScrollView(
                    child: SimpleTable(
                      headers: const ['课程', '正常', '迟到', '早退', '旷课', '请假', '合计'],
                      rows: [
                        for (final item in data.items)
                          [
                            item.courseName,
                            '${item.normal}',
                            '${item.late}',
                            '${item.leaveEarly}',
                            '${item.absent}',
                            '${item.leave}',
                            '${_attendanceStatusTotal(item)}',
                          ],
                      ],
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

int _attendanceStatusTotal(AttendanceItem item) =>
    item.normal + item.late + item.leaveEarly + item.absent + item.leave;

class AttendanceOverview extends StatelessWidget {
  const AttendanceOverview({super.key, required this.items});

  final List<AttendanceItem> items;

  @override
  Widget build(BuildContext context) {
    final normal = items.fold(0, (sum, item) => sum + item.normal);
    final late = items.fold(0, (sum, item) => sum + item.late);
    final leaveEarly = items.fold(0, (sum, item) => sum + item.leaveEarly);
    final absent = items.fold(0, (sum, item) => sum + item.absent);
    final leave = items.fold(0, (sum, item) => sum + item.leave);
    final statusTotal = normal + late + leaveEarly + absent + leave;
    final total = items.fold(0, (sum, item) => sum + item.total);
    final displayTotal = statusTotal > 0 ? statusTotal : total;
    final rate = displayTotal <= 0 ? 0.0 : normal / displayTotal * 100;
    return AccentPanel(
      child: Wrap(
        spacing: 12,
        runSpacing: 8,
        children: [
          InfoTile(
              icon: FluentIcons.list, label: '合计', value: '$displayTotal 次'),
          InfoTile(
              icon: FluentIcons.completed,
              label: '正常率',
              value: '${rate.toStringAsFixed(1)}%'),
          InfoTile(icon: FluentIcons.check_mark, label: '正常', value: '$normal'),
          InfoTile(icon: FluentIcons.warning, label: '迟到', value: '$late'),
          InfoTile(
              icon: FluentIcons.warning, label: '早退', value: '$leaveEarly'),
          InfoTile(icon: FluentIcons.error, label: '旷课', value: '$absent'),
          InfoTile(
              icon: FluentIcons.contact_card, label: '请假', value: '$leave'),
        ],
      ),
    );
  }
}

class ExamsPage extends StatefulWidget {
  const ExamsPage(
      {super.key,
      required this.api,
      required this.periods,
      this.onSessionExpired});

  final ApiClient api;
  final List<AcademicPeriod> periods;
  final VoidCallback? onSessionExpired;

  @override
  State<ExamsPage> createState() => _ExamsPageState();
}

class _ExamsPageState extends State<ExamsPage> {
  var sortMode = 'term';

  @override
  Widget build(BuildContext context) {
    return AsyncPanel<List<PeriodExam>>(
      future: _loadExams(),
      onSessionExpired: widget.onSessionExpired,
      builder: (items) => PagePanel(
        title: '考试',
        icon: FluentIcons.test_beaker,
        expandChild: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: SizedBox(
                width: 160,
                child: ComboBox<String>(
                  value: sortMode,
                  items: const [
                    ComboBoxItem(value: 'term', child: Text('按学期排列')),
                    ComboBoxItem(value: 'time', child: Text('按时间排列')),
                  ],
                  onChanged: (value) {
                    if (value != null) setState(() => sortMode = value);
                  },
                ),
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: SingleChildScrollView(
                child: sortMode == 'term'
                    ? ExamTermSections(items: items)
                    : ExamTable(items: _sortedByTime(items)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<List<PeriodExam>> _loadExams() async {
    final results = await Future.wait([
      for (final period in widget.periods)
        widget.api
            .exams(year: period.year, term: period.term)
            .then(
              (items) => [
                for (final item in items) PeriodExam(period, item),
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
      courseExams.sort(_compareExamsByTime);
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
        if (periodCompare != 0) return periodCompare;
        return _compareExamsByTime(a, b);
      });
  }

  List<PeriodExam> _sortedByTime(List<PeriodExam> items) =>
      [...items]..sort(_compareExamsByTime);
}

class ExamTermSections extends StatelessWidget {
  const ExamTermSections({super.key, required this.items});

  final List<PeriodExam> items;

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
          ExamTable(items: entry.value),
          const SizedBox(height: 16),
        ],
      ],
    );
  }
}

class ExamTable extends StatelessWidget {
  const ExamTable({super.key, required this.items});

  final List<PeriodExam> items;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 640) {
          return Column(
            children: [
              for (final item in items)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _MobileRecordCard(
                    icon: item.isRetake
                        ? FluentIcons.warning
                        : FluentIcons.test_beaker,
                    title: item.displayName,
                    subtitle: '${item.period.label} · ${item.examKind}',
                    highlight: item.isRetake,
                    rows: [
                      (FluentIcons.date_time, '时间', item.exam.time ?? '-'),
                      (FluentIcons.location, '地点', item.exam.location ?? '-'),
                      (FluentIcons.contact_card, '座位', item.exam.seat ?? '-'),
                    ],
                  ),
                ),
            ],
          );
        }
        return SimpleTable(
          headers: const ['学期', '课程', '类型', '时间', '地点', '座位'],
          highlightedRows: {
            for (var i = 0; i < items.length; i++)
              if (items[i].isRetake) i,
          },
          rowHighlightColors: {
            for (var i = 0; i < items.length; i++)
              if (items[i].isRetake) i: _retakeFill(items[i].retakeIndex),
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

class GradesPage extends StatelessWidget {
  const GradesPage(
      {super.key,
      required this.api,
      required this.periods,
      this.onSessionExpired});

  final ApiClient api;
  final List<AcademicPeriod> periods;
  final VoidCallback? onSessionExpired;

  @override
  Widget build(BuildContext context) {
    return AsyncPanel<List<GradeGroup>>(
      future: _loadGrades(),
      onSessionExpired: onSessionExpired,
      builder: (items) => PagePanel(
        title: '成绩',
        icon: FluentIcons.education,
        expandChild: true,
        child: SingleChildScrollView(
          child: GradeGroupList(groups: items),
        ),
      ),
    );
  }

  Future<List<GradeGroup>> _loadGrades() async {
    final results = await Future.wait([
      for (final period in periods)
        api
            .grades(year: period.year, term: period.term)
            .then(
              (items) => [
                for (final item in items) GradeAttempt(period, item),
              ],
            )
            .catchError((_) => <GradeAttempt>[]),
    ]);
    final groups = <String, GradeGroup>{};
    for (final attempt in results.expand((items) => items)) {
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
}

class GradeGroupList extends StatelessWidget {
  const GradeGroupList({super.key, required this.groups});

  final List<GradeGroup> groups;

  @override
  Widget build(BuildContext context) {
    final border = BorderSide(
        color: FluentTheme.of(context).resources.controlStrokeColorDefault);
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 640) {
          return Column(
            children: [
              for (final group in groups)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: GradeMobileCard(group: group),
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
                GradeGroupRow(group: group, border: border),
            ],
          ),
        );
      },
    );
  }
}

class GradeMobileCard extends StatelessWidget {
  const GradeMobileCard({super.key, required this.group});

  final GradeGroup group;

  @override
  Widget build(BuildContext context) {
    final latest = group.latest;
    return _MobileRecordCard(
      icon: group.hasRetake ? FluentIcons.warning : FluentIcons.education,
      title: group.displayName,
      subtitle: latest.period.label,
      highlight: group.hasRetake,
      rows: [
        (FluentIcons.completed, '成绩', latest.grade.score ?? '-'),
        (FluentIcons.publish_course, '学分', latest.grade.credit ?? '-'),
        (FluentIcons.chart, '绩点', latest.grade.gradePoint ?? '-'),
        if (group.hasRetake)
          (FluentIcons.list, '记录', '${group.attempts.length} 次'),
      ],
    );
  }
}

class GradeGroupRow extends StatelessWidget {
  const GradeGroupRow({super.key, required this.group, required this.border});

  final GradeGroup group;
  final BorderSide border;

  @override
  Widget build(BuildContext context) {
    final latest = group.latest;
    final values = [
      group.displayName,
      latest.grade.score ?? '-',
      latest.grade.credit ?? '-',
      latest.grade.gradePoint ?? '-',
    ];
    if (!group.hasRetake) {
      return _TableRow(values: values, border: border);
    }
    return Container(
      decoration: BoxDecoration(
        color: _accentFill(context),
        border: Border(bottom: border),
      ),
      child: Expander(
        header: _TableRowContent(
          values: values,
          color: FluentTheme.of(context).accentColor,
          strong: true,
        ),
        content: Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '更多考试',
                style: TextStyle(
                  color: FluentTheme.of(context).accentColor,
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
      ),
    );
  }
}

class CreditsPage extends StatelessWidget {
  const CreditsPage({super.key, required this.api, this.onSessionExpired});

  final ApiClient api;
  final VoidCallback? onSessionExpired;

  @override
  Widget build(BuildContext context) {
    return AsyncPanel<List<CreditItem>>(
      future: api.credits(),
      onSessionExpired: onSessionExpired,
      builder: (items) => PagePanel(
        title: '学分统计',
        icon: FluentIcons.publish_course,
        expandChild: true,
        child: SingleChildScrollView(
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
      borderRadius: BorderRadius.circular(8),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const _IconBadge(icon: FluentIcons.publish_course, size: 36),
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
                  icon: FluentIcons.certificate,
                  label: '培养方案总学分',
                  value: item.totalCredit ?? '-'),
              InfoTile(
                  icon: FluentIcons.completed,
                  label: '已修学分',
                  value: totalEarned.toStringAsFixed(2)),
              InfoTile(
                  icon: FluentIcons.list,
                  label: '应修合计',
                  value: totalExpected.toStringAsFixed(2)),
              InfoTile(
                  icon: FluentIcons.publish_course,
                  label: '选课学分',
                  value: item.selectedCredit ?? '-'),
            ],
          ),
          const SizedBox(height: 12),
          ProgressBar(value: progress * 100),
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
    final accent = FluentTheme.of(context).accentColor;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: accent.withValues(alpha: 0.22)),
      ),
      child: Icon(icon, size: size * 0.48, color: accent),
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
    final content = Container(
      padding: EdgeInsets.symmetric(
        horizontal: dense ? 8 : 10,
        vertical: dense ? 6 : 8,
      ),
      decoration: BoxDecoration(
        color:
            FluentTheme.of(context).resources.solidBackgroundFillColorSecondary,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: FluentTheme.of(context).resources.controlStrokeColorDefault,
        ),
      ),
      child: Row(
        mainAxisSize: width == null ? MainAxisSize.min : MainAxisSize.max,
        children: [
          Icon(icon,
              size: dense ? 13 : 15,
              color: FluentTheme.of(context).accentColor),
          SizedBox(width: dense ? 4 : 6),
          Flexible(
            child: Text(
              dense ? '$label$value' : '$label $value',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: dense ? 12 : null),
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

class PagePanel extends StatelessWidget {
  const PagePanel({
    super.key,
    required this.title,
    required this.child,
    this.expandChild = false,
    this.icon,
  });

  final String title;
  final Widget child;
  final bool expandChild;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 600;
    return Card(
      borderRadius: BorderRadius.circular(8),
      padding: EdgeInsets.all(compact ? 10 : 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (icon != null) ...[
                _IconBadge(icon: icon!, size: compact ? 28 : 38),
                SizedBox(width: compact ? 8 : 10),
              ],
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: compact ? 18 : 24,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: compact ? 10 : 18),
          if (expandChild) Expanded(child: child) else child,
        ],
      ),
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
    final tileWidth = compact
        ? ((screenWidth - 58) / 2).clamp(142.0, 220.0).toDouble()
        : 220.0;
    return SizedBox(
      width: tileWidth,
      child: Card(
        borderRadius: BorderRadius.circular(8),
        padding: EdgeInsets.all(compact ? 10 : 16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            if (icon != null) ...[
              _IconBadge(icon: icon!, size: compact ? 26 : 34),
              SizedBox(width: compact ? 7 : 10),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style:
                        TextStyle(color: FluentTheme.of(context).inactiveColor),
                  ),
                  SizedBox(height: compact ? 3 : 6),
                  Text(
                    value,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: compact ? 15 : 18,
                      fontWeight: FontWeight.w700,
                    ),
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
    final accent = FluentTheme.of(context).accentColor;
    final compact = MediaQuery.sizeOf(context).width < 600;
    return Container(
      padding: EdgeInsets.all(compact ? 10 : 12),
      decoration: BoxDecoration(
        color: _accentFill(context),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: accent.withValues(alpha: 0.42)),
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
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final List<(IconData, String, String)> rows;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 600;
    return Card(
      borderRadius: BorderRadius.circular(8),
      padding: EdgeInsets.all(compact ? 10 : 14),
      backgroundColor: highlight ? _accentFill(context) : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _IconBadge(icon: icon, size: compact ? 28 : 36),
              SizedBox(width: compact ? 8 : 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: compact ? 14 : 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        subtitle!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: FluentTheme.of(context).inactiveColor,
                          fontSize: compact ? 12 : null,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          if (rows.isNotEmpty) ...[
            SizedBox(height: compact ? 8 : 12),
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
        ],
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
  });

  final List<String> headers;
  final List<List<String>> rows;
  final Set<int> highlightedRows;
  final Map<int, Color> rowHighlightColors;
  final Map<int, Color> rowTextColors;

  @override
  Widget build(BuildContext context) {
    final border = BorderSide(
        color: FluentTheme.of(context).resources.controlStrokeColorDefault);
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
              borderRadius: BorderRadius.circular(8),
              child: Column(
                children: [
                  _TableRow(values: headers, strong: true, border: border),
                  for (var i = 0; i < rows.length; i++)
                    _TableRow(
                      values: rows[i],
                      border: border,
                      highlighted: highlightedRows.contains(i),
                      highlightColor: rowHighlightColors[i],
                      textColor: rowTextColors[i],
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
      this.textColor});

  final List<String> values;
  final BorderSide border;
  final bool strong;
  final bool highlighted;
  final Color? highlightColor;
  final Color? textColor;

  @override
  Widget build(BuildContext context) {
    final accent = FluentTheme.of(context).accentColor;
    return Container(
      decoration: BoxDecoration(
        color: highlighted
            ? highlightColor ?? _accentFill(context)
            : strong
                ? FluentTheme.of(context).resources.subtleFillColorSecondary
                : null,
        border: Border(bottom: border),
      ),
      child: _TableRowContent(
        values: values,
        color: highlighted ? textColor ?? accent : null,
        strong: strong || highlighted,
      ),
    );
  }
}

class _TableRowContent extends StatelessWidget {
  const _TableRowContent(
      {required this.values, this.color, this.strong = false});

  final List<String> values;
  final Color? color;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (final value in values)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Text(
                value,
                overflow: TextOverflow.ellipsis,
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

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(48),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(FluentIcons.inbox,
                size: 44, color: FluentTheme.of(context).inactiveColor),
            const SizedBox(height: 12),
            Text(message),
          ],
        ),
      ),
    );
  }
}
