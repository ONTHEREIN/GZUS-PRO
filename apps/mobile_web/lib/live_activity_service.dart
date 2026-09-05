import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_client.dart';

const _iosPushEnvironment = String.fromEnvironment(
  'IOS_PUSH_ENVIRONMENT',
  defaultValue: kDebugMode ? 'sandbox' : 'production',
);

class LiveActivityService {
  static const MethodChannel _channel =
      MethodChannel('cn.gzus.pro/live_activities');
  static ApiClient? _api;
  static bool _enabled = true;
  static bool _initialized = false;

  static Future<void> initialize({required ApiClient api}) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return;
    _api = api;
    final prefs = await SharedPreferences.getInstance();
    _enabled = prefs.getBool('live_activities_enabled') ?? true;
    await _channel.invokeMethod<bool>('configure', {
      'baseUrl': api.baseUrl,
      'sessionId': api.sessionId,
      'environment': _iosPushEnvironment,
    });
    if (!_initialized) {
      _channel.setMethodCallHandler(_handleNativeEvent);
      _initialized = true;
    }
    final capabilities = await _getCapabilities();
    if (capabilities['enabled'] != true) return;
    final token = capabilities['pushToStartToken']?.toString();
    if (_enabled && token != null && token.isNotEmpty) {
      await _registerToken(token: token, tokenType: 'start');
    }
  }

  static Future<void> stop() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return;
    final api = _api;
    _api = null;
    _enabled = false;
    try {
      await _channel.invokeMethod<bool>('endAll');
    } on PlatformException {
      // 没有原生实现时由系统自行清理，不影响登出流程。
    }
    final sessionId = api?.sessionId;
    if (sessionId != null && sessionId.isNotEmpty) {
      try {
        await api!.unregisterIosLiveActivityTokens(sessionId);
      } on ApiException {
        // 会话可能已经失效，原生配置仍需清除。
      }
    }
    try {
      await _channel.invokeMethod<bool>('clearConfiguration');
    } on PlatformException {
      // 原生配置不存在时无需阻断登出。
    }
  }

  static Future<void> setEnabled({required bool enabled}) async {
    _enabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('live_activities_enabled', enabled);
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return;
    if (!enabled) {
      try {
        await _channel.invokeMethod<bool>('endAll');
      } on PlatformException {
        return;
      }
      final api = _api;
      if (api != null && api.sessionId != null) {
        await api.unregisterIosLiveActivityTokens(api.sessionId!);
      }
      return;
    }
    final token =
        await _channel.invokeMethod<String>('registerPushToStartToken');
    if (token != null && token.isNotEmpty) {
      await _registerToken(token: token, tokenType: 'start');
    }
  }

  static Future<bool> startOrUpdate(LiveActivityEvent event) async {
    if (!_enabled || kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) {
      return false;
    }
    try {
      final result = await _channel.invokeMethod<Map<Object?, Object?>>(
        'start',
        _arguments(event),
      );
      return result != null;
    } on MissingPluginException {
      return false;
    } on PlatformException catch (error) {
      debugPrint('[LiveActivityService] iOS 活动启动失败: ${error.code}');
      return false;
    }
  }

  static Future<bool> update(LiveActivityEvent event) async {
    if (!_enabled || kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) {
      return false;
    }
    try {
      final result =
          await _channel.invokeMethod<bool>('update', _arguments(event));
      return result == true;
    } on PlatformException {
      return false;
    }
  }

  static Future<bool> end(
    LiveActivityEvent event, {
    required bool immediate,
  }) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return false;
    try {
      final result = await _channel.invokeMethod<bool>('end', {
        ..._arguments(event),
        'dismissImmediately': immediate,
      });
      return result == true;
    } on PlatformException {
      return false;
    }
  }

  static Future<Map<String, Object?>> _getCapabilities() async {
    try {
      final result = await _channel.invokeMethod<Map<Object?, Object?>>(
        'getCapabilities',
      );
      return result?.map((key, value) => MapEntry(key.toString(), value)) ??
          <String, Object?>{};
    } on MissingPluginException {
      return <String, Object?>{};
    } on PlatformException {
      return <String, Object?>{};
    }
  }

  static Future<void> _handleNativeEvent(MethodCall call) async {
    final arguments = call.arguments is Map
        ? Map<String, dynamic>.from(call.arguments as Map)
        : <String, dynamic>{};
    final token = arguments['token']?.toString();
    if (token == null || token.isEmpty || !_enabled) return;
    final api = _api;
    if (api == null) return;
    if (call.method == 'pushToStartToken') {
      await _registerToken(token: token, tokenType: 'start');
    } else if (call.method == 'activityToken') {
      await _registerToken(
        token: token,
        tokenType: 'activity',
        activityId: arguments['activityId']?.toString(),
        activityType: arguments['activityType']?.toString(),
      );
    }
  }

  static Future<void> _registerToken({
    required String token,
    required String tokenType,
    String? activityId,
    String? activityType,
  }) async {
    final api = _api;
    if (api == null) return;
    await api.registerIosLiveActivityToken(
      tokenType: tokenType,
      token: token,
      environment: _iosPushEnvironment,
      activityId: activityId,
      activityType: activityType,
    );
  }

  static Map<String, Object?> _arguments(LiveActivityEvent event) {
    final end = event.effectiveEndTime;
    return {
      'activityId': event.id,
      'activityType': event.type,
      'title': event.title,
      'body': event.body,
      'shortText': event.shortText ?? event.title,
      'startEpochMillis': event.startTime?.millisecondsSinceEpoch ?? 0,
      'endEpochMillis': end.millisecondsSinceEpoch,
      'progress': event.progress,
      'ongoing': event.ongoing,
      'targetTab': event.targetTab ?? 'home',
      'deepLink': event.deepLink,
    };
  }
}

typedef LiveActivityOpenHandler = void Function(LiveActivityEvent event);

class LiveActivityEvent {
  LiveActivityEvent({
    required this.id,
    required this.type,
    required this.title,
    required this.body,
    this.style = 'metric',
    this.startTime,
    this.endTime,
    this.shortText,
    this.targetTab,
    this.url,
    this.ongoing = false,
    this.progress,
  });

  factory LiveActivityEvent.fromMessage(Map<String, dynamic> message) {
    final extras = message['extras'] is Map
        ? Map<String, dynamic>.from(message['extras'] as Map)
        : <String, dynamic>{};
    Object? value(String key) => message[key] ?? extras[key];
    final type = value('type')?.toString() ?? '';
    final style = value('style')?.toString() ?? 'metric';
    return LiveActivityEvent(
      id: (value('id') ?? _fallbackId(message)).toString(),
      type: type,
      title: value('title')?.toString() ?? '软帮手',
      body: value('body')?.toString() ?? '',
      style: style,
      startTime: _dateTimeFromEpochMillis(value('startTime')),
      endTime: _dateTimeFromEpochMillis(value('endTime')),
      shortText: value('shortCriticalText')?.toString() ??
          value('shortText')?.toString(),
      targetTab: targetTabForType(type),
      url: value('url')?.toString(),
      ongoing: value('ongoing') is bool
          ? value('ongoing') as bool
          : style != 'metric',
      progress: _progressValue(
        value('progress'),
        value('progressMax'),
        value('progressCurrent'),
      ),
    );
  }

  factory LiveActivityEvent.courseReminder({
    required int id,
    required String title,
    required String body,
    required String courseName,
    required DateTime countdownTarget,
    required String shortText,
  }) {
    return LiveActivityEvent(
      id: 'course_reminder:$id',
      type: 'course_reminder',
      title: title,
      body: body,
      style: 'timer',
      endTime: countdownTarget,
      shortText: shortText,
      targetTab: 'schedule',
      ongoing: true,
    );
  }

  final String id;
  final String type;
  final String title;
  final String body;
  final String style;
  final DateTime? startTime;
  final DateTime? endTime;
  final String? shortText;
  final String? targetTab;
  final String? url;
  final bool ongoing;
  final double? progress;
  final DateTime createdAt = DateTime.now();

  DateTime get effectiveEndTime {
    if (endTime != null) return endTime!;
    if (type == 'course_reminder') {
      return createdAt.add(const Duration(minutes: 15));
    }
    return createdAt.add(const Duration(hours: 4));
  }

  String get deepLink {
    return Uri(
      scheme: 'cn.gzus.pro',
      host: 'activity',
      queryParameters: {'tab': targetTab ?? 'home'},
    ).toString();
  }

  /// Whether this event carries a meaningful countdown window.
  /// Exams use the progress transport style but still need a live countdown;
  /// utility reminders remain metric-only despite their short expiry time.
  bool get isCountdown {
    if (type == 'ecard_reminder' || endTime == null) return false;
    if (style == 'timer') return true;
    final start = startTime;
    return start != null && endTime!.isAfter(start);
  }

  bool get isTimer => style == 'timer' && endTime != null;
  bool get isMetric => style == 'metric';
  bool get hasAction =>
      (targetTab != null && targetTab!.isNotEmpty) ||
      (url != null && url!.isNotEmpty);

  int get priority {
    if ((type == 'course_reminder' || type == 'exam_reminder') && ongoing) {
      return 1;
    }
    if (type == 'course_reminder') return 2;
    if (type == 'exam_reminder' || type == 'business_reminder') return 3;
    if (type == 'grade_update' ||
        type == 'attendance_update' ||
        type == 'business_update' ||
        type == 'new_notice') {
      return 4;
    }
    return 5;
  }

  bool isExpired(DateTime now) => !effectiveEndTime.isAfter(now);

  static String? targetTabForType(String? type) {
    switch (type) {
      case 'course_reminder':
        return 'schedule';
      case 'exam_reminder':
        return 'exams';
      case 'ecard_reminder':
        return 'ecard';
      case 'grade_update':
        return 'grades';
      case 'new_notice':
        return 'notices';
      case 'attendance_update':
        return 'attendance';
      case 'business_reminder':
      case 'business_update':
        return 'business';
      default:
        return null;
    }
  }

  static DateTime? _dateTimeFromEpochMillis(Object? value) {
    final millis = _intValue(value);
    if (millis == null || millis <= 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(millis);
  }

  static int? _intValue(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  static double? _doubleValue(Object? value) {
    if (value is num) return value.toDouble().clamp(0.0, 1.0);
    if (value is String) return double.tryParse(value)?.clamp(0.0, 1.0);
    return null;
  }

  static double? _progressValue(
      Object? progress, Object? max, Object? current) {
    final direct = _doubleValue(progress);
    if (direct != null) return direct;
    final maxValue = _intValue(max);
    final currentValue = _intValue(current);
    if (maxValue == null || maxValue <= 0 || currentValue == null) return null;
    return (currentValue / maxValue).clamp(0.0, 1.0);
  }

  static String _fallbackId(Map<String, dynamic> message) {
    return Object.hash(
      message['type'] ?? '',
      message['title'] ?? '',
      message['body'] ?? '',
      message['url'] ?? '',
    ).abs().toString();
  }
}

class LiveActivityViewState {
  const LiveActivityViewState({this.event, this.expanded = false});

  final LiveActivityEvent? event;
  final bool expanded;

  bool get visible => event != null;

  LiveActivityViewState copyWith({
    LiveActivityEvent? event,
    bool? expanded,
  }) {
    return LiveActivityViewState(
      event: event ?? this.event,
      expanded: expanded ?? this.expanded,
    );
  }
}

class LiveActivityController {
  LiveActivityController._();

  static final LiveActivityController instance = LiveActivityController._();

  static const Duration initialExpandedDuration = Duration(seconds: 4);

  final ValueNotifier<LiveActivityViewState> state =
      ValueNotifier(const LiveActivityViewState());
  LiveActivityOpenHandler? onOpen;
  Timer? _collapseTimer;
  Timer? _dismissTimer;
  final List<LiveActivityEvent> _queue = <LiveActivityEvent>[];

  @visibleForTesting
  List<LiveActivityEvent> get queuedEvents => List.unmodifiable(_queue);

  void show(LiveActivityEvent event) {
    if (event.isExpired(DateTime.now())) {
      dismiss(event.id);
      return;
    }
    final current = state.value.event;
    if (current != null && current.id != event.id) {
      if (event.priority >= current.priority) {
        _enqueue(event);
        return;
      }
      _enqueue(current);
    }
    _present(event);
  }

  void _enqueue(LiveActivityEvent event) {
    _queue.removeWhere((queued) => queued.id == event.id);
    _queue.add(event);
    if (_queue.length > 5) {
      var removableIndex = 0;
      for (var index = 1; index < _queue.length; index++) {
        if (_queue[index].priority >= _queue[removableIndex].priority) {
          removableIndex = index;
        }
      }
      _queue.removeAt(removableIndex);
    }
  }

  void _present(LiveActivityEvent event) {
    _collapseTimer?.cancel();
    _dismissTimer?.cancel();
    state.value = LiveActivityViewState(event: event, expanded: true);
    _collapseTimer = Timer(initialExpandedDuration, () {
      if (state.value.event?.id == event.id) {
        state.value = state.value.copyWith(expanded: false);
      }
    });
    final delay = event.effectiveEndTime.difference(DateTime.now());
    _dismissTimer = Timer(delay.isNegative ? Duration.zero : delay, () {
      dismiss(event.id);
    });
  }

  void dismiss(String? id) {
    if (id != null && state.value.event?.id != id) return;
    _collapseTimer?.cancel();
    _dismissTimer?.cancel();
    state.value = const LiveActivityViewState();
    _presentNext();
  }

  void _presentNext() {
    final now = DateTime.now();
    _queue.removeWhere((event) => event.isExpired(now));
    if (_queue.isEmpty) return;
    var nextIndex = 0;
    for (var index = 1; index < _queue.length; index++) {
      if (_queue[index].priority < _queue[nextIndex].priority) {
        nextIndex = index;
      }
    }
    final next = _queue.removeAt(nextIndex);
    _present(next);
  }

  void toggleExpanded() {
    if (!state.value.visible) return;
    state.value = state.value.copyWith(expanded: !state.value.expanded);
  }

  void openCurrent() {
    final event = state.value.event;
    if (event == null) return;
    onOpen?.call(event);
    if (!event.ongoing) dismiss(event.id);
  }

  void dismissAll() {
    _collapseTimer?.cancel();
    _dismissTimer?.cancel();
    _queue.clear();
    state.value = const LiveActivityViewState();
  }

  @visibleForTesting
  void resetForTest() {
    dismissAll();
    onOpen = null;
  }
}

class LiveActivityIsland extends StatefulWidget {
  const LiveActivityIsland({super.key, required this.controller});

  final LiveActivityController controller;

  @override
  State<LiveActivityIsland> createState() => _LiveActivityIslandState();
}

class _LiveActivityIslandState extends State<LiveActivityIsland> {
  Timer? _ticker;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    widget.controller.state.addListener(_syncTicker);
    _syncTicker();
  }

  @override
  void dispose() {
    widget.controller.state.removeListener(_syncTicker);
    _ticker?.cancel();
    super.dispose();
  }

  void _syncTicker() {
    final needsTicker =
        widget.controller.state.value.event?.isCountdown ?? false;
    if (!needsTicker) {
      _ticker?.cancel();
      _ticker = null;
      return;
    }
    if (_ticker != null) return;
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<LiveActivityViewState>(
      valueListenable: widget.controller.state,
      builder: (context, state, _) {
        final event = state.event;
        return IgnorePointer(
          ignoring: event == null,
          child: AnimatedSlide(
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic,
            offset: event == null ? const Offset(0, -1.5) : Offset.zero,
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 180),
              opacity: event == null ? 0 : 1,
              child: SafeArea(
                bottom: false,
                child: Align(
                  alignment: Alignment.topCenter,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: AnimatedContainer(
                      key: const ValueKey('live-activity-island'),
                      duration: const Duration(milliseconds: 280),
                      curve: Curves.easeOutCubic,
                      width: state.expanded ? 420 : 208,
                      constraints: BoxConstraints(
                        maxWidth: MediaQuery.sizeOf(context).width - 32,
                      ),
                      child: event == null
                          ? const SizedBox.shrink()
                          : GestureDetector(
                              onTap: widget.controller.toggleExpanded,
                              onVerticalDragEnd: (details) {
                                if ((details.primaryVelocity ?? 0) < -180) {
                                  widget.controller.dismiss(event.id);
                                }
                              },
                              child: _IslandSurface(
                                event: event,
                                expanded: state.expanded,
                                now: _now,
                                onOpen: widget.controller.openCurrent,
                                onDismiss: () =>
                                    widget.controller.dismiss(event.id),
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
    );
  }
}

class _IslandSurface extends StatelessWidget {
  const _IslandSurface({
    required this.event,
    required this.expanded,
    required this.now,
    required this.onOpen,
    this.onDismiss,
  });

  final LiveActivityEvent event;
  final bool expanded;
  final DateTime now;
  final VoidCallback onOpen;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = _eventColor(theme.colorScheme);
    final isDark = theme.brightness == Brightness.dark;
    final surfaceColor = isDark
        ? const Color(0xFF0B0D10)
        : const Color(0xFFF5F7FA).withValues(alpha: 0.96);
    final foregroundColor =
        isDark ? const Color(0xFFF5F7FA) : const Color(0xFF17191D);
    final mutedColor =
        isDark ? const Color(0xFFA4ABB8) : const Color(0xFF6B7280);
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 280);
    return Material(
      color: surfaceColor,
      elevation: 14,
      borderRadius: BorderRadius.circular(expanded ? 26 : 999),
      child: Semantics(
        label: '即时提醒',
        button: true,
        child: AnimatedContainer(
          duration: duration,
          curve: Curves.easeOutCubic,
          padding: EdgeInsets.all(expanded ? 12 : 8),
          decoration: BoxDecoration(
            color: surfaceColor,
            borderRadius: BorderRadius.circular(expanded ? 26 : 999),
            border: Border.all(
              color: foregroundColor.withValues(alpha: 0.10),
            ),
          ),
          child: DefaultTextStyle.merge(
            style: TextStyle(color: foregroundColor),
            child: IconTheme.merge(
              data: IconThemeData(color: foregroundColor),
              child: expanded
                  ? _expandedContent(
                      context,
                      color,
                      foregroundColor,
                      mutedColor,
                    )
                  : _compactContent(context, color, foregroundColor),
            ),
          ),
        ),
      ),
    );
  }

  Widget _compactContent(
    BuildContext context,
    Color color,
    Color foregroundColor,
  ) {
    return SizedBox(
      height: 30,
      child: Row(
        children: [
          _IslandIcon(type: event.type, color: color, size: 30),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              event.shortText?.isNotEmpty == true
                  ? event.shortText!
                  : _compactText(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w900,
                    color: foregroundColor,
                  ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _expandedContent(
    BuildContext context,
    Color color,
    Color foregroundColor,
    Color mutedColor,
  ) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            _IslandIcon(type: event.type, color: color, size: 38),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    event.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w900,
                      color: foregroundColor,
                    ),
                  ),
                  Text(
                    _subtitle(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: mutedColor,
                    ),
                  ),
                ],
              ),
            ),
            if (onDismiss != null)
              IconButton(
                key: const ValueKey('live-activity-close'),
                tooltip: '关闭',
                visualDensity: VisualDensity.compact,
                onPressed: onDismiss,
                icon: Icon(Icons.close, size: 18, color: mutedColor),
              ),
          ],
        ),
        if (event.body.isNotEmpty && event.type != 'ecard_reminder') ...[
          const SizedBox(height: 10),
          Text(
            event.body,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: foregroundColor.withValues(alpha: 0.82),
            ),
          ),
        ],
        if (event.type == 'ecard_reminder') ...[
          const SizedBox(height: 10),
          _UtilityMetrics(
            body: event.body,
            color: color,
            foregroundColor: foregroundColor,
          ),
        ] else if (_shouldShowProgress()) ...[
          const SizedBox(height: 10),
          _ProgressLine(event: event, now: now, color: color),
        ],
        if (event.hasAction) ...[
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              key: const ValueKey('live-activity-action'),
              onPressed: onOpen,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(38),
                backgroundColor: color,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              child: Text(_actionLabel()),
            ),
          ),
        ],
      ],
    );
  }

  bool _shouldShowProgress() {
    final progress = event.progress;
    if (progress == null || progress >= 1) return false;
    return event.style == 'progress' || event.isCountdown;
  }

  Color _eventColor(ColorScheme scheme) {
    switch (event.type) {
      case 'ecard_reminder':
        return const Color(0xFF0EA5E9);
      case 'exam_reminder':
      case 'attendance_update':
        return const Color(0xFFEA580C);
      case 'grade_update':
        return const Color(0xFF059669);
      case 'course_reminder':
      case 'business_reminder':
      case 'business_update':
        return const Color(0xFF2563EB);
      default:
        return scheme.primary;
    }
  }

  String _subtitle() {
    if (event.type == 'ecard_reminder') return '冷水 · 热水 · 电费';
    if (event.isCountdown && event.endTime != null) {
      return '剩余 ${_durationText(event.endTime!.difference(now))}';
    }
    if (event.shortText?.isNotEmpty == true) return event.shortText!;
    return event.isMetric ? '实时动态' : '新通知';
  }

  String _compactText() {
    if (event.isCountdown && event.endTime != null) {
      return _durationText(event.endTime!.difference(now));
    }
    return event.title;
  }

  String _actionLabel() {
    switch (event.targetTab) {
      case 'schedule':
        return '查看课表';
      case 'exams':
        return '查看考试';
      case 'ecard':
        return '查看水电';
      case 'notices':
        return event.url?.isNotEmpty == true ? '打开通知' : '查看通知';
      case 'grades':
        return '查看成绩';
      case 'attendance':
        return '查看考勤';
      case 'business':
        return '去办理';
      default:
        return event.url?.isNotEmpty == true ? '打开详情' : '查看';
    }
  }
}

class _IslandIcon extends StatelessWidget {
  const _IslandIcon({
    required this.type,
    required this.color,
    required this.size,
  });

  final String type;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        shape: BoxShape.circle,
      ),
      child: Icon(_icon, size: size * 0.54, color: color),
    );
  }

  IconData get _icon {
    switch (type) {
      case 'course_reminder':
        return Icons.schedule;
      case 'exam_reminder':
        return Icons.assignment;
      case 'ecard_reminder':
        return Icons.water_drop;
      case 'grade_update':
        return Icons.school;
      case 'attendance_update':
        return Icons.verified;
      case 'business_reminder':
      case 'business_update':
        return Icons.apartment;
      default:
        return Icons.notifications_active;
    }
  }
}

class _UtilityMetrics extends StatelessWidget {
  const _UtilityMetrics({
    required this.body,
    required this.color,
    required this.foregroundColor,
  });

  final String body;
  final Color color;
  final Color foregroundColor;

  @override
  Widget build(BuildContext context) {
    final values = body
        .split(RegExp(r'[\u00b7|]'))
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .take(3)
        .toList(growable: false);
    final items = values.isEmpty ? <String>['查看当前余额'] : values;
    return Row(
      children: items
          .map((value) => Expanded(
                child: Container(
                  margin: EdgeInsets.only(right: value == items.last ? 0 : 6),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                  decoration: BoxDecoration(
                    color: foregroundColor.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    value,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: color,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ))
          .toList(growable: false),
    );
  }
}

class _ProgressLine extends StatelessWidget {
  const _ProgressLine({
    required this.event,
    required this.now,
    required this.color,
  });

  final LiveActivityEvent event;
  final DateTime now;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final value = event.progress ?? _timerProgress();
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: LinearProgressIndicator(
        minHeight: 5,
        value: value,
        backgroundColor: color.withValues(alpha: 0.12),
        valueColor: AlwaysStoppedAnimation<Color>(color),
      ),
    );
  }

  double? _timerProgress() {
    final endTime = event.endTime;
    if (endTime == null) return event.isMetric ? 1 : null;
    final remaining = endTime.difference(now).inMilliseconds;
    if (remaining <= 0) return 1;
    final startTime = event.startTime;
    if (startTime == null || !endTime.isAfter(startTime)) return null;
    final total = endTime.difference(startTime).inMilliseconds;
    final elapsed = now.difference(startTime).inMilliseconds;
    return (elapsed / total).clamp(0.0, 1.0);
  }
}

String _durationText(Duration duration) {
  final safe = duration.isNegative ? Duration.zero : duration;
  final hours = safe.inHours;
  final minutes = safe.inMinutes.remainder(60);
  final seconds = safe.inSeconds.remainder(60);
  if (safe <= const Duration(minutes: 1)) return '即将开始';
  if (safe >= const Duration(days: 1)) {
    final days = safe.inDays;
    final remainingHours = safe.inHours.remainder(24);
    return remainingHours == 0 ? '$days 天' : '$days 天 $remainingHours 时';
  }
  if (hours > 0) {
    return '$hours:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}
