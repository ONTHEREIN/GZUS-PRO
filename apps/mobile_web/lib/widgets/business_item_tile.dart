import 'package:flutter/material.dart';

import '../api_client.dart';
import 'badges.dart';
import 'meta_text.dart';
import 'open_browser.dart';
import 'scale_tap.dart';

class BusinessItemTile extends StatelessWidget {
  const BusinessItemTile({super.key, required this.item, required this.api});

  final EhallAffairItem item;
  final ApiClient api;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final inner = Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colorScheme.outlineVariant),
        color: colorScheme.surface,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const IconBadge(icon: Icons.apps, size: 32),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  item.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    if (item.department != null && item.department!.isNotEmpty)
                      MetaText(item.department!),
                    if (item.type != null && item.type!.isNotEmpty)
                      MetaText(item.type!),
                    for (final tag in item.tags.take(2)) MetaText(tag),
                  ],
                ),
                if (item.summary != null && item.summary!.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    item.summary!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: colorScheme.onSurfaceVariant),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          Icon(Icons.open_in_new, size: 18, color: colorScheme.primary),
        ],
      ),
    );
    return ScaleTap(
      onTap: () => openInAppBrowser(context, item.url, api: api),
      borderRadius: BorderRadius.circular(8),
      child: inner,
    );
  }
}
