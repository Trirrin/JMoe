import 'package:flutter/material.dart';

import '../core/ehentai_service.dart';
import 'common_widgets.dart';
import '../core/l10n.dart';

class EHListTile extends StatelessWidget {
  final EHItem item;
  final VoidCallback onTap;
  const EHListTile({super.key, required this.item, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 84,
                height: 112,
                child: CoverImage(
                  url: item.cover.isEmpty ? null : item.cover,
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        height: 1.3,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        if (item.category.isNotEmpty)
                          _tag(theme, item.category, primary: true),
                        if (item.pages > 0) _tag(theme, L.tp('pagesN', {'n': item.pages})),
                        if (item.rating != null)
                          _tag(theme, '★ ${item.rating!.toStringAsFixed(1)}'),
                      ],
                    ),
                    const SizedBox(height: 6),
                    if (item.posted.isNotEmpty)
                      Text(
                        item.posted,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tag(ThemeData theme, String text, {bool primary = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: primary
            ? theme.colorScheme.primary
            : theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: primary
              ? theme.colorScheme.onPrimary
              : theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
