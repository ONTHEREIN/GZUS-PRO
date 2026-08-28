import 'dart:async';

import 'package:flutter/material.dart';

import 'widgets/liquid_glass.dart';

typedef LiveActivityOpenHandler = void Function(LiveActivityEvent event);

class LiveActivityEvent {
  LiveActivityEvent({
    required this.id,
    required this.type,
    required this.title,
    required this.body,
    this.style = 'metric',
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
  final DateTime? endTime;
  final String? shortText;
  final String? targetTab;
  final String? url;
  final bool ongoing;
  final double? progress;

  bool get isTimer => style == 'timer' && endTime != null;
  bool get isMetric => style == 'metric';
  bool get hasAction =>
      (targetTab != null && targetTab!.isNotEmpty) ||
      (url != null && url!.isNotEmpty);

  bool isExpired(DateTime now) => endTime != null && !endTime!.isAfter(now);

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

  void show(LiveActivityEvent event) {
    if (event.isExpired(DateTime.now())) {
      dismiss(event.id);
      return;
    }
    _collapseTimer?.cancel();
    _dismissTimer?.cancel();
    state.value = LiveActivityViewState(event: event, expanded: true);
    _collapseTimer = Timer(initialExpandedDuration, () {
      if (state.value.event?.id == event.id) {
        state.value = state.value.copyWith(expanded: false);
      }
    });
    final endTime = event.endTime;
    if (endTime != null) {
      final delay = endTime.difference(DateTime.now());
      _dismissTimer = Timer(delay.isNegative ? Duration.zero : delay, () {
        dismiss(event.id);
      });
    }
  }

  void dismiss(String? id) {
    if (id != null && state.value.event?.id != id) return;
    _collapseTimer?.cancel();
    _dismissTimer?.cancel();
    state.value = const LiveActivityViewState();
  }

  void toggleExpanded() {
    if (!state.value.visible) return;
    state.value = state.value.copyWith(expanded: !state.value.expanded);
  }

  void openCurrent() {
    final event = state.value.event;
    if (event == null) return;
    onOpen?.call(event);
  }

  @visibleForTesting
  void resetForTest() {
    _collapseTimer?.cancel();
    _dismissTimer?.cancel();
    onOpen = null;
    state.value = const LiveActivityViewState();
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
    final needsTicker = widget.controller.state.value.event?.isTimer ?? false;
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
                                if (!event.ongoing &&
                                    (details.primaryVelocity ?? 0) < -180) {
                                  widget.controller.dismiss(event.id);
                                }
                              },
                              child: _IslandSurface(
                                event: event,
                                expanded: state.expanded,
                                now: _now,
                                onOpen: widget.controller.openCurrent,
                                onDismiss: event.ongoing
                                    ? null
                                    : () => widget.controller.dismiss(event.id),
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
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 280);
    return Material(
      color: Colors.transparent,
      elevation: 14,
      borderRadius: BorderRadius.circular(expanded ? 26 : 999),
      child: LiquidGlassSurface(
        padding: EdgeInsets.all(expanded ? 12 : 8),
        borderRadius: BorderRadius.circular(expanded ? 26 : 999),
        material: LiquidGlassMaterial.regular,
        semanticsLabel: '即时提醒',
        child: AnimatedContainer(
          duration: duration,
          curve: Curves.easeOutCubic,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(expanded ? 26 : 999),
            border: Border.all(
              color: color.withValues(
                alpha: theme.brightness == Brightness.dark ? 0.32 : 0.18,
              ),
            ),
          ),
          child: expanded
              ? _expandedContent(context, color)
              : _compactContent(context, color),
        ),
      ),
    );
  }

  Widget _compactContent(BuildContext context, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
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
                ),
          ),
        ),
      ],
    );
  }

  Widget _expandedContent(BuildContext context, Color color) {
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
                    ),
                  ),
                  Text(
                    _subtitle(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
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
                icon: const Icon(Icons.close, size: 18),
              ),
          ],
        ),
        if (event.body.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text(
            event.body,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium,
          ),
        ],
        const SizedBox(height: 10),
        _ProgressLine(event: event, now: now, color: color),
        if (event.hasAction) ...[
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              key: const ValueKey('live-activity-action'),
              onPressed: onOpen,
              icon: const Icon(Icons.arrow_forward, size: 18),
              label: Text(_actionLabel()),
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, 38),
                backgroundColor: color,
              ),
            ),
          ),
        ],
      ],
    );
  }

  Color _eventColor(ColorScheme scheme) {
    switch (event.type) {
      case 'ecard_reminder':
        return scheme.secondary;
      case 'exam_reminder':
        return scheme.tertiary;
      case 'course_reminder':
        return scheme.primary;
      default:
        return scheme.primary;
    }
  }

  String _subtitle() {
    if (event.isTimer && event.endTime != null) {
      return '剩余 ${_durationText(event.endTime!.difference(now))}';
    }
    if (event.shortText?.isNotEmpty == true) return event.shortText!;
    return event.isMetric ? '实时动态' : '新通知';
  }

  String _compactText() {
    if (event.isTimer && event.endTime != null) {
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
      default:
        return Icons.notifications_active;
    }
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
    const windowMs = 60 * 60 * 1000;
    return (1 - (remaining / windowMs)).clamp(0.0, 1.0);
  }
}

String _durationText(Duration duration) {
  final safe = duration.isNegative ? Duration.zero : duration;
  final hours = safe.inHours;
  final minutes = safe.inMinutes.remainder(60);
  final seconds = safe.inSeconds.remainder(60);
  if (hours > 0) {
    return '$hours:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}
