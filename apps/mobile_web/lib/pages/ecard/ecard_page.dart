import 'dart:async';

import 'package:flutter/material.dart';

import '../../api_client.dart';
import '../../gzus_design.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/page_panel.dart';

enum EcardConsumptionSort { dateNewest, dateOldest, usageHighest, usageLowest }

List<EcardConsumptionItem> sortEcardConsumptionItems(
  List<EcardConsumptionItem> items,
  EcardConsumptionSort sort,
) {
  final sorted = [...items];
  sorted.sort((a, b) {
    final dateA = DateTime.tryParse(a.date.isNotEmpty ? a.date : a.time) ??
        DateTime.fromMillisecondsSinceEpoch(0);
    final dateB = DateTime.tryParse(b.date.isNotEmpty ? b.date : b.time) ??
        DateTime.fromMillisecondsSinceEpoch(0);
    final usageA = a.usage ?? -1;
    final usageB = b.usage ?? -1;
    switch (sort) {
      case EcardConsumptionSort.dateNewest:
        return dateB.compareTo(dateA);
      case EcardConsumptionSort.dateOldest:
        return dateA.compareTo(dateB);
      case EcardConsumptionSort.usageHighest:
        return usageB.compareTo(usageA);
      case EcardConsumptionSort.usageLowest:
        return usageA.compareTo(usageB);
    }
  });
  return sorted;
}

class EcardPage extends StatefulWidget {
  const EcardPage({super.key, required this.api, this.onSessionExpired});

  final ApiClient api;
  final VoidCallback? onSessionExpired;

  @override
  State<EcardPage> createState() => _EcardPageState();
}

class _EcardPageState extends State<EcardPage> {
  static const _backgroundRefreshInterval = Duration(minutes: 30);

  late Future<EcardSummary> _summaryFuture;
  EcardSummary? _latestSummary;
  Future<List<EcardRoomItem>>? _roomsFuture;
  final _searchController = TextEditingController();
  bool _refreshing = false;
  bool _backgroundRefreshing = false;
  bool _bindingRoom = false;
  String? _bindingRoomId;
  int _refreshVersion = 0;
  int _consumptionHistoryVersion = 0;
  String? _error;
  Timer? _periodicRefreshTimer;
  Timer? _searchDebounce;
  String _lastSearchQuery = '';

  @override
  void initState() {
    super.initState();
    _summaryFuture = _loadSummary();
    _periodicRefreshTimer = Timer.periodic(_backgroundRefreshInterval, (_) {
      if (!mounted) return;
      unawaited(_refreshBalanceInBackground());
    });
  }

  @override
  void didUpdateWidget(covariant EcardPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.api != widget.api) {
      _latestSummary = null;
      _summaryFuture = _loadSummary();
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

  Future<EcardSummary> _loadSummary() async {
    final summary =
        await widget.api.ecardSummary().then((result) => result.data);
    _latestSummary = summary;
    if (_needsBackgroundRefresh(summary)) {
      unawaited(_refreshBalanceInBackground());
    }
    return summary;
  }

  bool _needsBackgroundRefresh(EcardSummary summary) {
    if (!summary.isBound) return false;
    final updatedAt = summary.updatedAt;
    final updated = updatedAt == null ? null : DateTime.tryParse(updatedAt);
    return updated == null ||
        DateTime.now().difference(updated.toLocal()) >=
            _backgroundRefreshInterval;
  }

  Future<void> _refreshBalanceInBackground() async {
    final current = _latestSummary;
    if (_backgroundRefreshing ||
        current == null ||
        !_needsBackgroundRefresh(current)) {
      return;
    }
    _backgroundRefreshing = true;
    try {
      final summary = await widget.api.refreshEcard();
      if (!mounted) return;
      _latestSummary = summary;
      setState(() {
        _summaryFuture = Future.value(summary);
      });
    } catch (_) {
      // 后台刷新失败时继续展示缓存，避免打断用户。
    } finally {
      _backgroundRefreshing = false;
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
      _latestSummary = summary;
      setState(() {
        _summaryFuture = Future.value(summary);
      });
      if (summary.stale) {
        // 后端刷新失败、返回的是旧缓存:明确提示,避免用户以为数据已更新
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content:
                Text('刷新失败：${summary.staleReason ?? '一卡通服务暂时不可用'}，当前显示的是缓存数据'),
          ),
        );
      }
    } catch (exc) {
      _handleError(exc);
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _refreshEcardPage() async {
    await _refreshBalance();
    if (!mounted) return;
    setState(() {
      _refreshVersion++;
      if (_roomsFuture != null) {
        _roomsFuture = widget.api.ecardRooms(
          query: _lastSearchQuery,
          forceRefresh: true,
        );
      }
    });
  }

  Future<void> _bindRoom(EcardRoomItem room) async {
    if (_bindingRoom) return;
    setState(() {
      _bindingRoom = true;
      _bindingRoomId = room.id;
      _error = null;
    });
    try {
      final summary = await widget.api
          .bindEcardRoom(room)
          .timeout(const Duration(seconds: 45));
      if (!mounted) return;
      setState(() {
        _summaryFuture = Future.value(summary);
        _roomsFuture = null;
        _error = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text('已绑定 ${summary.roomDisplay ?? room.displayName}')),
      );
    } catch (exc) {
      _handleError(exc);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(exc is ApiException
                ? exc.message
                : exc is TimeoutException
                    ? '宿舍绑定超时，请稍后重试'
                    : '宿舍绑定失败'),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _bindingRoom = false;
          _bindingRoomId = null;
        });
      }
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
      setState(() {
        _summaryFuture = Future.value(summary);
      });
    } catch (exc) {
      _handleError(exc);
    }
  }

  void _handleError(Object exc) {
    if (!mounted) return;
    if (exc is ApiException &&
        exc.statusCode == 401 &&
        widget.onSessionExpired != null) {
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
        if (snapshot.connectionState != ConnectionState.done &&
            !snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          final error = snapshot.error;
          final isSessionError =
              error is ApiException && error.statusCode == 401;
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
                  bindingRoomId: _bindingRoomId,
                  isBinding: _bindingRoom,
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
                    bindingRoomId: _bindingRoomId,
                    isBinding: _bindingRoom,
                  ),
                const SizedBox(height: 12),
                _EcardReminderPanel(
                  summary: summary,
                  onChanged: _updateReminder,
                ),
                const SizedBox(height: 12),
                _EcardConsumptionOverviewPanel(
                  api: widget.api,
                  refreshVersion: _consumptionHistoryVersion,
                ),
                const SizedBox(height: 12),
                _EcardConsumptionPanel(
                  api: widget.api,
                  refreshVersion: _refreshVersion,
                  onMonthRecorded: () {
                    if (mounted) {
                      setState(() => _consumptionHistoryVersion++);
                    }
                  },
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
    required this.bindingRoomId,
    required this.isBinding,
  });

  final Future<List<EcardRoomItem>>? roomsFuture;
  final TextEditingController searchController;
  final ValueChanged<String> onSearchChanged;
  final Future<void> Function(EcardRoomItem room) onRoomSelected;
  final String? bindingRoomId;
  final bool isBinding;

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
          if (widget.isBinding)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: Theme.of(context)
                    .colorScheme
                    .primaryContainer
                    .withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      '正在绑定宿舍，请稍候…',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onPrimaryContainer,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          if (widget.isBinding) const SizedBox(height: 12),
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
                      final isSelected = widget.bindingRoomId == room.id;
                      return ListTile(
                        enabled: !widget.isBinding,
                        leading: const Icon(Icons.meeting_room),
                        title: Text(room.displayName,
                            overflow: TextOverflow.ellipsis),
                        subtitle: Text('${room.schoolArea} ${room.building}'),
                        trailing: isSelected
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.chevron_right),
                        onTap: widget.isBinding
                            ? null
                            : () => widget.onRoomSelected(room),
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

class _EcardConsumptionOverviewPanel extends StatefulWidget {
  const _EcardConsumptionOverviewPanel({
    required this.api,
    required this.refreshVersion,
  });

  final ApiClient api;
  final int refreshVersion;

  @override
  State<_EcardConsumptionOverviewPanel> createState() =>
      _EcardConsumptionOverviewPanelState();
}

class _EcardConsumptionOverviewPanelState
    extends State<_EcardConsumptionOverviewPanel> {
  late Future<EcardConsumptionOverviewResponse> _overviewFuture;

  @override
  void initState() {
    super.initState();
    _overviewFuture = widget.api.ecardConsumptionOverview();
  }

  @override
  void didUpdateWidget(covariant _EcardConsumptionOverviewPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.api != widget.api ||
        oldWidget.refreshVersion != widget.refreshVersion) {
      _overviewFuture = widget.api.ecardConsumptionOverview();
    }
  }

  @override
  Widget build(BuildContext context) {
    return PagePanel(
      title: '水电费历史总览',
      icon: Icons.insights_outlined,
      child: FutureBuilder<EcardConsumptionOverviewResponse>(
        future: _overviewFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) return const EmptyState(message: '历史总览加载失败');
          final data = snapshot.data;
          if (data == null ||
              (data.months.isEmpty &&
                  data.coldWaterMonths.isEmpty &&
                  data.hotWaterMonths.isEmpty)) {
            return EmptyState(message: data?.message ?? '查询月份后会在这里生成历史总览');
          }
          return Column(
            children: [
              _ElectricityHistoryCard(months: data.months),
              const SizedBox(height: 12),
              _WaterHistoryCard(
                key: const Key('ecard-cold-water-history'),
                title: '冷水余额趋势',
                icon: Icons.water_drop_outlined,
                color: Colors.lightBlue,
                months: data.coldWaterMonths,
              ),
              const SizedBox(height: 12),
              _WaterHistoryCard(
                key: const Key('ecard-hot-water-history'),
                title: '热水余额趋势',
                icon: Icons.local_fire_department_outlined,
                color: Colors.deepOrange,
                months: data.hotWaterMonths,
              ),
            ],
          );
        },
      ),
    );
  }
}

class _ElectricityHistoryCard extends StatelessWidget {
  const _ElectricityHistoryCard({required this.months});

  final List<EcardConsumptionMonthOverview> months;

  @override
  Widget build(BuildContext context) {
    if (months.isEmpty) {
      return const _HistoryCard(
        key: Key('ecard-electricity-history'),
        title: '电费月度用量',
        icon: Icons.electric_bolt,
        child: EmptyState(message: '查询电费月份后会在这里生成历史总览'),
      );
    }
    final chartMonths = months.take(12).toList().reversed.toList();
    return _HistoryCard(
      key: const Key('ecard-electricity-history'),
      title: '电费月度用量',
      icon: Icons.electric_bolt,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _BarTrendChart(
            values: [for (final month in chartMonths) month.totalUsage],
            labels: [for (final month in chartMonths) month.month.substring(5)],
            unit: chartMonths.last.unit,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 8),
          for (final month in months)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.calendar_month_outlined),
              title: Text(month.month),
              subtitle: Text(
                '共 ${month.recordedDays} 天 · 日均 ${month.averageDailyUsage.toStringAsFixed(2)} ${month.unit} · 峰值 ${month.peakUsage.toStringAsFixed(2)} ${month.unit}',
              ),
              trailing: Text(
                '总计 ${month.totalUsage.toStringAsFixed(2)} ${month.unit}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
        ],
      ),
    );
  }
}

class _WaterHistoryCard extends StatelessWidget {
  const _WaterHistoryCard({
    super.key,
    required this.title,
    required this.icon,
    required this.color,
    required this.months,
  });

  final String title;
  final IconData icon;
  final Color color;
  final List<EcardWaterMonthOverview> months;

  @override
  Widget build(BuildContext context) {
    if (months.isEmpty) {
      return _HistoryCard(
        title: title,
        icon: icon,
        child: const EmptyState(message: '余额刷新后会在这里生成水费历史'),
      );
    }
    final chartMonths = months.take(12).toList().reversed.toList();
    return _HistoryCard(
      title: title,
      icon: icon,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '基于余额缓存估算；同日仅保留最新值，数据非官方消费明细',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          _BalanceTrendChart(
            values: [for (final month in chartMonths) month.closingBalance],
            labels: [for (final month in chartMonths) month.month.substring(5)],
            unit: chartMonths.last.unit,
            color: color,
          ),
          const SizedBox(height: 8),
          for (final month in months)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.calendar_month_outlined),
              title: Text(month.month),
              isThreeLine: true,
              subtitle: Text(
                '记录 ${month.recordedDays} 天 · 期初 ${month.openingBalance.toStringAsFixed(2)} ${month.unit} · 期末 ${month.closingBalance.toStringAsFixed(2)} ${month.unit}\n消耗 ${month.estimatedUsage.toStringAsFixed(2)} ${month.unit} · 日均 ${month.averageDailyUsage.toStringAsFixed(2)} ${month.unit} · 峰值 ${month.peakUsage.toStringAsFixed(2)} ${month.unit}${month.peakDate == null ? '' : '（${month.peakDate}）'}',
              ),
              trailing: Text(
                '充值 ${month.estimatedRecharge.toStringAsFixed(2)} ${month.unit}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
        ],
      ),
    );
  }
}

class _HistoryCard extends StatelessWidget {
  const _HistoryCard({
    super.key,
    required this.title,
    required this.icon,
    required this.child,
  });

  final String title;
  final IconData icon;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      key: key,
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color:
            theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Text(title, style: theme.textTheme.titleMedium),
            ],
          ),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }
}

class _BarTrendChart extends StatelessWidget {
  const _BarTrendChart({
    required this.values,
    required this.labels,
    required this.unit,
    required this.color,
  });

  final List<double> values;
  final List<String> labels;
  final String unit;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: values.isEmpty ? '暂无用电趋势数据' : '最近 ${values.length} 个月用电量，单位 $unit',
      child: Column(
        children: [
          SizedBox(
            height: 140,
            child: CustomPaint(painter: _BarTrendPainter(values, color)),
          ),
          _ChartLabels(labels: labels),
        ],
      ),
    );
  }
}

class _BalanceTrendChart extends StatelessWidget {
  const _BalanceTrendChart({
    required this.values,
    required this.labels,
    required this.unit,
    required this.color,
  });

  final List<double> values;
  final List<String> labels;
  final String unit;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label:
          values.isEmpty ? '暂无余额趋势数据' : '最近 ${values.length} 个月期末余额，单位 $unit',
      child: Column(
        children: [
          SizedBox(
            height: 140,
            child: CustomPaint(painter: _LineTrendPainter(values, color)),
          ),
          _ChartLabels(labels: labels),
        ],
      ),
    );
  }
}

class _ChartLabels extends StatelessWidget {
  const _ChartLabels({required this.labels});

  final List<String> labels;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        for (final label in labels)
          Text(label, style: Theme.of(context).textTheme.labelSmall),
      ],
    );
  }
}

class _BarTrendPainter extends CustomPainter {
  _BarTrendPainter(this.values, this.color);

  final List<double> values;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty) return;
    final maxValue = values.reduce((a, b) => a > b ? a : b);
    final barWidth = size.width / (values.length * 1.7);
    final gap = barWidth * 0.7;
    final paint = Paint()..color = color.withValues(alpha: 0.75);
    for (var index = 0; index < values.length; index++) {
      final height =
          maxValue <= 0 ? 0.0 : size.height * values[index] / maxValue;
      final left = index * (barWidth + gap) + gap / 2;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(left, size.height - height, barWidth, height),
          const Radius.circular(5),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _BarTrendPainter oldDelegate) =>
      oldDelegate.values != values || oldDelegate.color != color;
}

class _LineTrendPainter extends CustomPainter {
  _LineTrendPainter(this.values, this.color);

  final List<double> values;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty) return;
    final minValue = values.reduce((a, b) => a < b ? a : b);
    final maxValue = values.reduce((a, b) => a > b ? a : b);
    final range =
        (maxValue - minValue).abs() < 0.001 ? 1.0 : maxValue - minValue;
    final points = <Offset>[];
    for (var index = 0; index < values.length; index++) {
      final x = values.length == 1
          ? size.width / 2
          : size.width * index / (values.length - 1);
      final y = size.height - (values[index] - minValue) / range * size.height;
      points.add(Offset(x, y));
    }
    final line = Paint()
      ..color = color
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (final point in points.skip(1)) {
      path.lineTo(point.dx, point.dy);
    }
    canvas.drawPath(path, line);
    final dot = Paint()..color = color;
    for (final point in points) {
      canvas.drawCircle(point, 4, dot);
    }
  }

  @override
  bool shouldRepaint(covariant _LineTrendPainter oldDelegate) =>
      oldDelegate.values != values || oldDelegate.color != color;
}

class _EcardConsumptionPanel extends StatefulWidget {
  const _EcardConsumptionPanel({
    required this.api,
    required this.refreshVersion,
    required this.onMonthRecorded,
  });

  final ApiClient api;
  final int refreshVersion;
  final VoidCallback onMonthRecorded;

  @override
  State<_EcardConsumptionPanel> createState() => _EcardConsumptionPanelState();
}

class _EcardConsumptionPanelState extends State<_EcardConsumptionPanel> {
  late Future<EcardConsumptionResponse> _consumptionFuture;
  late String _selectedMonth;
  EcardConsumptionSort _sort = EcardConsumptionSort.dateNewest;
  String? _lastRecordedMonth;

  @override
  void initState() {
    super.initState();
    _selectedMonth = _monthKey(DateTime.now());
    _consumptionFuture = widget.api.ecardConsumption(month: _selectedMonth);
  }

  @override
  void didUpdateWidget(covariant _EcardConsumptionPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.api != widget.api ||
        oldWidget.refreshVersion != widget.refreshVersion) {
      _consumptionFuture = widget.api.ecardConsumption(month: _selectedMonth);
    }
  }

  Future<void> _selectMonth() async {
    final parts = _selectedMonth.split('-');
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime(int.parse(parts[0]), int.parse(parts[1])),
      firstDate: DateTime(2020),
      lastDate: DateTime(DateTime.now().year + 1, 12),
      helpText: '选择查询月份',
    );
    if (picked == null) return;
    final month = _monthKey(picked);
    if (!mounted || month == _selectedMonth) return;
    setState(() {
      _selectedMonth = month;
      _consumptionFuture = widget.api.ecardConsumption(month: month);
    });
  }

  String _monthKey(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-${value.month.toString().padLeft(2, '0')}';

  String get _sortLabel {
    switch (_sort) {
      case EcardConsumptionSort.dateNewest:
        return '日期最新';
      case EcardConsumptionSort.dateOldest:
        return '日期最早';
      case EcardConsumptionSort.usageHighest:
        return '用电量从高到低';
      case EcardConsumptionSort.usageLowest:
        return '用电量从低到高';
    }
  }

  @override
  Widget build(BuildContext context) {
    return PagePanel(
      title: '电费消费记录',
      icon: Icons.electric_bolt,
      trailing: PopupMenuButton<EcardConsumptionSort>(
        key: const Key('ecard-consumption-sort'),
        tooltip: '排序',
        icon: const Icon(Icons.sort),
        onSelected: (sort) => setState(() => _sort = sort),
        itemBuilder: (context) => const [
          PopupMenuItem(
            value: EcardConsumptionSort.dateNewest,
            child: Text('日期最新'),
          ),
          PopupMenuItem(
            value: EcardConsumptionSort.dateOldest,
            child: Text('日期最早'),
          ),
          PopupMenuItem(
            value: EcardConsumptionSort.usageHighest,
            child: Text('用电量从高到低'),
          ),
          PopupMenuItem(
            value: EcardConsumptionSort.usageLowest,
            child: Text('用电量从低到高'),
          ),
        ],
      ),
      child: FutureBuilder<EcardConsumptionResponse>(
        future: _consumptionFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) return const EmptyState(message: '消费记录加载失败');
          final data = snapshot.data;
          if (data?.status == 'ok' && _lastRecordedMonth != _selectedMonth) {
            _lastRecordedMonth = _selectedMonth;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) widget.onMonthRecorded();
            });
          }
          final items =
              sortEcardConsumptionItems(data?.items ?? const [], _sort);
          return Column(
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  key: const Key('ecard-consumption-month'),
                  onPressed: _selectMonth,
                  icon: const Icon(Icons.calendar_month_outlined),
                  label: Text('查询月份：$_selectedMonth · $_sortLabel'),
                ),
              ),
              const SizedBox(height: 6),
              if (items.isEmpty)
                EmptyState(message: data?.message ?? '暂无消费记录')
              else
                for (final item in items)
                  ListTile(
                    leading: const Icon(Icons.payments),
                    title: Text(item.title, overflow: TextOverflow.ellipsis),
                    subtitle:
                        Text(item.date.isNotEmpty ? item.date : item.time),
                    trailing: Text(item.amount.isEmpty ? '-' : item.amount),
                  ),
            ],
          );
        },
      ),
    );
  }
}
