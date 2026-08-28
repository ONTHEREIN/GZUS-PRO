import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api_client.dart';
import '../../app_providers.dart';
import '../../responsive/breakpoints.dart';
import '../../responsive/sizing.dart';
import '../../responsive/spacing.dart';
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
        initialData: widget.api.cachedStudentInfo(),
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
            final sections = _infoSections(info);
            if (wide) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: pane.side,
                    child: PagePanel(
                      title: '个人信息',
                      icon: Icons.badge,
                      child: _IdentitySummary(info: info),
                    ),
                  ),
                  const SizedBox(width: GzusSpacing.m),
                  Expanded(
                    child: PagePanel(
                      title: '详细信息',
                      icon: Icons.info_outline,
                      expandChild: true,
                      child: SingleChildScrollView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        child: _InfoDetails(sections: sections),
                      ),
                    ),
                  ),
                ],
              );
            }
            return SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: GzusSpacing.m),
                  _IdentitySummary(info: info),
                  const SizedBox(height: GzusSpacing.l),
                  _InfoDetails(sections: sections),
                  const SizedBox(height: GzusSpacing.xl),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

List<_InfoSectionData> _infoSections(StudentInfo info) => [
      _InfoSectionData(
        id: 'academic',
        title: '学籍信息',
        icon: Icons.school_outlined,
        fields: [
          _InfoField(
              id: 'college',
              icon: Icons.apartment,
              label: '学院',
              value: info.college ?? '-',
              fullWidth: false),
          _InfoField(
              id: 'major',
              icon: Icons.school,
              label: '专业',
              value: info.major ?? '-',
              fullWidth: false),
          _InfoField(
              id: 'class-name',
              icon: Icons.groups,
              label: '班级',
              value: info.className ?? '-',
              fullWidth: false),
          _InfoField(
              id: 'grade',
              icon: Icons.calendar_today,
              label: '年级',
              value: info.grade ?? '-',
              fullWidth: false),
          if (info.studentStatus != null)
            _InfoField(
                id: 'student-status',
                icon: Icons.how_to_reg,
                label: '学籍状态',
                value: info.studentStatus!,
                fullWidth: false),
          if (info.educationLevel != null)
            _InfoField(
                id: 'education-level',
                icon: Icons.workspace_premium,
                label: '培养层次',
                value: info.educationLevel!,
                fullWidth: false),
          if (info.enrollDate != null)
            _InfoField(
                id: 'enroll-date',
                icon: Icons.event,
                label: '入学日期',
                value: info.enrollDate!,
                fullWidth: false),
        ],
      ),
      _InfoSectionData(
        id: 'personal',
        title: '个人资料',
        icon: Icons.person_outline,
        fields: [
          if (info.gender != null)
            _InfoField(
                id: 'gender',
                icon: Icons.wc,
                label: '性别',
                value: info.gender!,
                fullWidth: false),
          if (info.idNumber != null)
            _InfoField(
                id: 'id-number',
                icon: Icons.credit_card,
                label: '证件号码',
                value: info.idNumber!,
                fullWidth: true),
          if (info.birthDate != null)
            _InfoField(
                id: 'birth-date',
                icon: Icons.cake,
                label: '出生日期',
                value: info.birthDate!,
                fullWidth: false),
          if (info.ethnicity != null)
            _InfoField(
                id: 'ethnicity',
                icon: Icons.people,
                label: '民族',
                value: info.ethnicity!,
                fullWidth: false),
          if (info.politicalStatus != null)
            _InfoField(
                id: 'political-status',
                icon: Icons.flag,
                label: '政治面貌',
                value: info.politicalStatus!,
                fullWidth: false),
          if (info.nativePlace != null)
            _InfoField(
                id: 'native-place',
                icon: Icons.place,
                label: '籍贯',
                value: info.nativePlace!,
                fullWidth: false),
        ],
      ),
      _InfoSectionData(
        id: 'contact',
        title: '联系方式',
        icon: Icons.contact_phone_outlined,
        fields: [
          if (info.phone != null)
            _InfoField(
                id: 'phone',
                icon: Icons.phone,
                label: '手机号码',
                value: info.phone!,
                fullWidth: false),
          if (info.email != null)
            _InfoField(
                id: 'email',
                icon: Icons.email,
                label: '电子邮箱',
                value: info.email!,
                fullWidth: false),
          if (info.address != null)
            _InfoField(
                id: 'address',
                icon: Icons.home,
                label: '家庭地址',
                value: info.address!,
                fullWidth: true),
        ],
      ),
    ].where((section) => section.fields.isNotEmpty).toList();

class _IdentitySummary extends StatelessWidget {
  const _IdentitySummary({required this.info});

  final StudentInfo info;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          StudentAvatar(photoDataUrl: info.photoDataUrl, name: info.name),
          const SizedBox(height: GzusSpacing.l),
          Text(info.name,
              style:
                  const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          if (info.studentId.isNotEmpty)
            Text(info.studentId,
                style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}

class _InfoDetails extends StatelessWidget {
  const _InfoDetails({required this.sections});

  final List<_InfoSectionData> sections;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var index = 0; index < sections.length; index++) ...[
          _InfoSection(section: sections[index]),
          if (index != sections.length - 1)
            const SizedBox(height: GzusSpacing.xl),
        ],
      ],
    );
  }
}

class _InfoSection extends StatelessWidget {
  const _InfoSection({required this.section});

  final _InfoSectionData section;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      key: Key('info-section-${section.id}'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(section.icon, size: 18, color: colorScheme.primary),
            const SizedBox(width: GzusSpacing.s),
            Text(section.title,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    )),
          ],
        ),
        const SizedBox(height: GzusSpacing.s),
        LayoutBuilder(
          builder: (context, constraints) {
            const spacing = GzusSpacing.s;
            final columnWidth = (constraints.maxWidth - spacing) / 2;
            return Wrap(
              key: Key('info-grid-${section.id}'),
              spacing: spacing,
              runSpacing: spacing,
              children: [
                for (final field in section.fields)
                  SizedBox(
                    key: Key(field.fullWidth
                        ? 'info-full-${field.id}'
                        : 'info-tile-${field.id}'),
                    width: field.fullWidth ? constraints.maxWidth : columnWidth,
                    child: InfoTile(
                      label: field.label,
                      value: field.value,
                      icon: field.icon,
                      minWidth: 0,
                      maxWidth:
                          field.fullWidth ? constraints.maxWidth : columnWidth,
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _InfoSectionData {
  const _InfoSectionData({
    required this.id,
    required this.title,
    required this.icon,
    required this.fields,
  });

  final String id;
  final String title;
  final IconData icon;
  final List<_InfoField> fields;
}

class _InfoField {
  const _InfoField({
    required this.id,
    required this.icon,
    required this.label,
    required this.value,
    required this.fullWidth,
  });

  final String id;
  final IconData icon;
  final String label;
  final String value;
  final bool fullWidth;
}
