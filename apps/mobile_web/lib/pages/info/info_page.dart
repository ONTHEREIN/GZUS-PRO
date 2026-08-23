import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api_client.dart';
import '../../app_providers.dart';
import '../../responsive/breakpoints.dart';
import '../../responsive/sizing.dart';
import '../../widgets/async_panel.dart';
import '../../widgets/info_tile.dart';
import '../../widgets/page_panel.dart';
import '../../widgets/student_avatar.dart';

class InfoPage extends ConsumerStatefulWidget {
  const InfoPage({super.key, required this.api, this.onSessionExpired});

  final ApiClient api;
  final VoidCallback? onSessionExpired;

  @override
  ConsumerState<InfoPage> createState() => _InfoPageState();
}

class _InfoPageState extends ConsumerState<InfoPage> {

  Future<void> _refreshInfo() async {
    ref.invalidate(studentInfoProvider(widget.api));
    await ref.read(studentInfoProvider(widget.api).future);
  }

  @override
  Widget build(BuildContext context) {
    final infoFuture = ref.watch(studentInfoProvider(widget.api).future);
    return PageRefresh(
      onRefresh: _refreshInfo,
      child: AsyncPanel<StudentInfo>(
        future: infoFuture,
        onSessionExpired: widget.onSessionExpired,
        builder: (info) => LayoutBuilder(
          builder: (context, constraints) {
            final breakpoint = constraints.maxWidth.gzusBreakpoint;
            final wide = breakpoint != GzusBreakpoint.compact;
            final pane = GzusSizing.splitPaneAdaptive(
              constraints.maxWidth,
              breakpoint,
              mediumRatio: 0.40,
              expandedRatio: 0.34,
              largeRatio: 0.30,
              minSide: 260,
              maxSide: 340,
            );
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
                    width: pane.side,
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
