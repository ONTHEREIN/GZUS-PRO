import 'package:flutter/material.dart';

import 'api_client.dart';
import 'background_guide_page.dart';
import 'gzus_design.dart';
import 'pages/schedule/schedule_page.dart';
import 'responsive/spacing.dart';
import 'widgets/empty_state.dart';

/// 首次使用的连续引导；首步保存后，后续步骤可随时从各功能页补充。
class FirstRunOnboardingPage extends StatefulWidget {
  const FirstRunOnboardingPage({
    super.key,
    required this.api,
    required this.studentName,
    required this.onComplete,
  });

  final ApiClient api;
  final String? studentName;
  final VoidCallback onComplete;

  @override
  State<FirstRunOnboardingPage> createState() => _FirstRunOnboardingPageState();
}

class _FirstRunOnboardingPageState extends State<FirstRunOnboardingPage> {
  int _step = 1;

  void _nextStep() {
    setState(() => _step += 1);
  }

  @override
  Widget build(BuildContext context) {
    switch (_step) {
      case 1:
        return ScheduleOnboardingPage(
          api: widget.api,
          studentName: widget.studentName,
          onComplete: _nextStep,
        );
      case 2:
        return DormOnboardingPage(api: widget.api, onNext: _nextStep);
      case 3:
        return FeatureIntroductionPage(onNext: _nextStep);
      case 4:
        return BackgroundGuidePage(
          api: widget.api,
          currentStep: 4,
          totalSteps: 4,
          onComplete: widget.onComplete,
        );
      default:
        throw StateError('无效的首次引导步骤：$_step');
    }
  }
}

class DormOnboardingPage extends StatefulWidget {
  const DormOnboardingPage({
    super.key,
    required this.api,
    required this.onNext,
  });

  final ApiClient api;
  final VoidCallback onNext;

  @override
  State<DormOnboardingPage> createState() => _DormOnboardingPageState();
}

class _DormOnboardingPageState extends State<DormOnboardingPage> {
  final _searchController = TextEditingController();
  late Future<EcardSummary> _summaryFuture;
  Future<List<EcardRoomItem>>? _roomsFuture;
  String? _bindingRoomId;
  String? _error;

  @override
  void initState() {
    super.initState();
    _summaryFuture = _loadSummary();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<EcardSummary> _loadSummary() async {
    final result = await widget.api.ecardSummary();
    return result.data;
  }

  void _searchRooms() {
    final query = _searchController.text.trim();
    if (query.isEmpty) {
      setState(() {
        _roomsFuture = null;
        _error = '请输入楼栋或房间号。';
      });
      return;
    }
    setState(() {
      _error = null;
      _roomsFuture = widget.api.ecardRooms(query: query);
    });
  }

  Future<void> _bindRoom(EcardRoomItem room) async {
    if (_bindingRoomId != null) return;
    setState(() {
      _bindingRoomId = room.id;
      _error = null;
    });
    try {
      final summary = await widget.api.bindEcardRoom(room);
      if (!mounted) return;
      setState(() {
        _summaryFuture = Future<EcardSummary>.value(summary);
        _roomsFuture = null;
        _bindingRoomId = null;
      });
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _bindingRoomId = null;
        _error = error.message;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _bindingRoomId = null;
        _error = '宿舍绑定失败：$error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return _OnboardingScaffold(
      step: 2,
      title: '绑定宿舍',
      description: '绑定后可查看电费、冷水和热水余额，也能收到低余额提醒。',
      body: FutureBuilder<EcardSummary>(
        future: _summaryFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Column(
              children: [
                const EmptyState(message: '宿舍信息加载失败，请稍后在生活缴费页绑定。'),
                const SizedBox(height: GzusSpacing.l),
                FilledButton(
                  onPressed: widget.onNext,
                  child: const Text('跳过，继续'),
                ),
              ],
            );
          }
          final summary = snapshot.data;
          if (summary != null && summary.isBound) {
            return _BoundDormContent(
              roomDisplay: summary.roomDisplay ?? '已绑定宿舍',
              onNext: widget.onNext,
            );
          }
          return _DormSearchContent(
            searchController: _searchController,
            roomsFuture: _roomsFuture,
            bindingRoomId: _bindingRoomId,
            error: _error,
            onSearch: _searchRooms,
            onRoomSelected: _bindRoom,
            onSkip: widget.onNext,
          );
        },
      ),
    );
  }
}

class FeatureIntroductionPage extends StatelessWidget {
  const FeatureIntroductionPage({super.key, required this.onNext});

  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    const features = [
      (Icons.calendar_month, '课表与提醒', '查看每日课程，设置上课提醒和课表日历。'),
      (Icons.workspace_premium_outlined, '成绩与考试', '集中查看成绩、学分与考试安排。'),
      (Icons.campaign_outlined, '校园通知与办事', '接收教务通知，快捷访问常用校园服务。'),
      (Icons.bolt_outlined, '生活缴费', '查看宿舍水电余额并接收低余额提醒。'),
    ];
    return _OnboardingScaffold(
      step: 3,
      title: '软帮手能为你做什么？',
      description: '把学习和校园生活的重要信息放在同一个地方。',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final feature in features) ...[
            _FeatureCard(
              icon: feature.$1,
              title: feature.$2,
              description: feature.$3,
            ),
            const SizedBox(height: GzusSpacing.m),
          ],
          const SizedBox(height: GzusSpacing.m),
          FilledButton.icon(
            onPressed: onNext,
            icon: const Icon(Icons.notifications_active_outlined),
            label: const Padding(
              padding: EdgeInsets.symmetric(vertical: 4),
              child: Text('继续设置提醒'),
            ),
          ),
        ],
      ),
    );
  }
}

class _OnboardingScaffold extends StatelessWidget {
  const _OnboardingScaffold({
    required this.step,
    required this.title,
    required this.description,
    required this.body,
  });

  final int step;
  final String title;
  final String description;
  final Widget body;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(automaticallyImplyLeading: false),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(GzusSpacing.l),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _StepIndicator(step: step),
                  const SizedBox(height: GzusSpacing.xl),
                  Container(
                    padding: const EdgeInsets.all(GzusSpacing.l),
                    decoration: BoxDecoration(
                      color:
                          colorScheme.primaryContainer.withValues(alpha: 0.55),
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title, style: GzusTextStyles.pageTitle(context)),
                        const SizedBox(height: GzusSpacing.xs),
                        Text(
                          description,
                          style:
                              Theme.of(context).textTheme.bodyMedium?.copyWith(
                                    color: colorScheme.onPrimaryContainer,
                                  ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: GzusSpacing.xl),
                  body,
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _StepIndicator extends StatelessWidget {
  const _StepIndicator({required this.step});

  final int step;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Expanded(
          child: LinearProgressIndicator(value: step / 4, minHeight: 4),
        ),
        const SizedBox(width: GzusSpacing.m),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            '步骤 $step / 4',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: colorScheme.onPrimaryContainer,
                  fontWeight: FontWeight.w600,
                ),
          ),
        ),
      ],
    );
  }
}

class _BoundDormContent extends StatelessWidget {
  const _BoundDormContent({required this.roomDisplay, required this.onNext});

  final String roomDisplay;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(GzusSpacing.l),
          decoration: BoxDecoration(
            color: colorScheme.secondaryContainer,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            children: [
              Icon(Icons.check_circle, color: colorScheme.secondary),
              const SizedBox(width: GzusSpacing.m),
              Expanded(child: Text('已绑定：$roomDisplay')),
            ],
          ),
        ),
        const SizedBox(height: GzusSpacing.xl),
        FilledButton(onPressed: onNext, child: const Text('继续')),
      ],
    );
  }
}

class _DormSearchContent extends StatelessWidget {
  const _DormSearchContent({
    required this.searchController,
    required this.roomsFuture,
    required this.bindingRoomId,
    required this.error,
    required this.onSearch,
    required this.onRoomSelected,
    required this.onSkip,
  });

  final TextEditingController searchController;
  final Future<List<EcardRoomItem>>? roomsFuture;
  final String? bindingRoomId;
  final String? error;
  final VoidCallback onSearch;
  final Future<void> Function(EcardRoomItem room) onRoomSelected;
  final VoidCallback onSkip;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: searchController,
          textInputAction: TextInputAction.search,
          onSubmitted: (_) => onSearch(),
          decoration: InputDecoration(
            hintText: '输入楼栋或房间号搜索',
            prefixIcon: const Icon(Icons.search),
            suffixIcon: IconButton(
              tooltip: '搜索',
              onPressed: onSearch,
              icon: const Icon(Icons.arrow_forward),
            ),
            border: const OutlineInputBorder(),
          ),
        ),
        if (error != null) ...[
          const SizedBox(height: GzusSpacing.s),
          Text(
            error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
        const SizedBox(height: GzusSpacing.l),
        if (roomsFuture == null)
          const EmptyState(message: '搜索并选择你的宿舍')
        else
          FutureBuilder<List<EcardRoomItem>>(
            future: roomsFuture,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snapshot.hasError) {
                return const EmptyState(message: '宿舍列表加载失败，请稍后重试');
              }
              final rooms = snapshot.data ?? const <EcardRoomItem>[];
              if (rooms.isEmpty) return const EmptyState(message: '未找到宿舍');
              return SizedBox(
                height: 300,
                child: ListView.separated(
                  itemCount: rooms.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final room = rooms[index];
                    final binding = bindingRoomId == room.id;
                    return ListTile(
                      enabled: bindingRoomId == null,
                      leading: const Icon(Icons.meeting_room_outlined),
                      title: Text(room.displayName),
                      subtitle: Text('${room.schoolArea} ${room.building}'),
                      trailing: binding
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.chevron_right),
                      onTap: bindingRoomId == null
                          ? () => onRoomSelected(room)
                          : null,
                    );
                  },
                ),
              );
            },
          ),
        const SizedBox(height: GzusSpacing.l),
        TextButton(onPressed: onSkip, child: const Text('暂不绑定，继续')),
      ],
    );
  }
}

class _FeatureCard extends StatelessWidget {
  const _FeatureCard({
    required this.icon,
    required this.title,
    required this.description,
  });

  final IconData icon;
  final String title;
  final String description;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(GzusSpacing.m),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          Icon(icon, color: colorScheme.primary),
          const SizedBox(width: GzusSpacing.m),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: GzusTextStyles.cardTitle(context)),
                const SizedBox(height: GzusSpacing.xs),
                Text(
                  description,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
