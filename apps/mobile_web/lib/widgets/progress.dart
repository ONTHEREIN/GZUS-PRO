import 'package:flutter/material.dart';

import '../api_client.dart';
import 'badges.dart';

class ProgressCategoryStrip extends StatelessWidget {
  const ProgressCategoryStrip({super.key, required this.categories});

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
              child: ProgressCategoryTile(category: source[index]),
            ),
          ),
        );
      },
    );
  }
}

class ProgressCategoryTile extends StatelessWidget {
  const ProgressCategoryTile({super.key, required this.category});

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

class ProgressMiniRow extends StatelessWidget {
  const ProgressMiniRow({super.key, required this.item});

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
                      StatusPill(label: item.statusLabel, color: cs.primary),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          StaticProgressBar(value: value),
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

class StaticProgressBar extends StatelessWidget {
  const StaticProgressBar({super.key, required this.value});

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
