import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/app_theme.dart';
import '../core/image_cache.dart';
import '../core/l10n.dart';
import '../core/models.dart';

class CoverImage extends StatelessWidget {
  final String? url;
  final BoxFit fit;
  final BorderRadius? borderRadius;
  final int? memCacheWidth;

  const CoverImage({
    super.key,
    required this.url,
    this.fit = BoxFit.cover,
    this.borderRadius,
    this.memCacheWidth,
  });

  @override
  Widget build(BuildContext context) {
    return CachedCover(
      url: url,
      fit: fit,
      borderRadius: borderRadius,
      memCacheWidth: memCacheWidth,
    );
  }
}

class ComicCard extends StatelessWidget {
  static const double textBlockHeight = 82;

  final String title;
  final String? subtitle;
  final String? cover;
  final String? badge;
  final VoidCallback? onTap;

  final VoidCallback? onLongPress;
  final double? progress;
  final int? memCacheWidth;

  final String? heat;

  final String? category;

  final String? heroTag;

  final String? coverMeta;

  final bool localTag;

  final bool cloudTag;

  final String? kindTag;

  const ComicCard({
    super.key,
    required this.title,
    this.subtitle,
    this.cover,
    this.badge,
    this.onTap,
    this.onLongPress,
    this.progress,
    this.memCacheWidth,
    this.heat,
    this.category,
    this.heroTag,
    this.coverMeta,
    this.localTag = false,
    this.cloudTag = false,
    this.kindTag,
  });

  Widget _cornerTag(String text, {bool bold = false}) {
    return Container(
      height: 17,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.62),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Center(
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: Colors.white,
            fontSize: 10,
            fontWeight: bold ? FontWeight.w700 : FontWeight.w600,
          ),
        ),
      ),
    );
  }

  Widget _maybeHero(Widget child) {
    if (heroTag == null || heroTag!.isEmpty) return child;
    return Hero(
      tag: heroTag!,
      flightShuttleBuilder: (context, animation, direction, fromCtx, toCtx) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(AppStyle.cardRadius),
          child: CoverImage(url: cover),
        );
      },
      placeholderBuilder: (context, size, widget) => SizedBox(
        width: size.width,
        height: size.height,
      ),
      createRectTween: (begin, end) => RectTween(begin: begin, end: end),
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      borderRadius: BorderRadius.circular(AppStyle.cardRadius),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LayoutBuilder(
            builder: (context, box) {
              final w = box.maxWidth.isFinite ? box.maxWidth : 120.0;
              return SizedBox(
                width: w,
                height: w * 4 / 3,
                child: _maybeHero(
              Stack(
              children: [
                Positioned.fill(
                  child: CoverImage(
                    url: cover,
                    borderRadius: BorderRadius.circular(AppStyle.cardRadius),
                    memCacheWidth: memCacheWidth,
                  ),
                ),
                if (cloudTag)
                  Positioned(
                    right: 6,
                    top: 6,
                    child: Container(
                      height: 17,
                      padding: const EdgeInsets.symmetric(horizontal: 5),
                      decoration: BoxDecoration(
                        color: const Color(0xFF2F7DE1).withValues(alpha: 0.92),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Center(
                        child: Icon(
                          Icons.cloud_done_rounded,
                          size: 11,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  )
                else if (localTag)
                  Positioned(
                    right: 6,
                    top: 6,
                    child: Container(
                      height: 17,
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      decoration: BoxDecoration(
                        color: scheme.primary,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Center(
                        child: Text(
                          L.t('localTag'),
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            color: scheme.onPrimary,
                          ),
                        ),
                      ),
                    ),
                  ),
                if (kindTag != null && kindTag!.isNotEmpty)
                  Positioned(
                    left: 6,
                    top: 6,
                    child: _cornerTag(kindTag!, bold: true),
                  )
                else if (badge != null && badge!.isNotEmpty)
                  Positioned(
                    left: 6,
                    top: 6,
                    child: _cornerTag(badge!),
                  ),
                if (heat != null && heat!.isNotEmpty)
                  Positioned(
                    right: 5,
                    bottom: 5,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.62),
                        borderRadius: BorderRadius.circular(5),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.favorite_rounded,
                            size: 9,
                            color: Color(0xFFFF6B81),
                          ),
                          const SizedBox(width: 2),
                          Text(
                            heat!,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 9,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                if (progress != null)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: ClipRRect(
                      borderRadius: const BorderRadius.vertical(
                        bottom: Radius.circular(AppStyle.cardRadius),
                      ),
                      child: LinearProgressIndicator(
                        value: progress,
                        minHeight: 3,
                        backgroundColor: Colors.black26,
                      ),
                    ),
                  ),
                ],
              ),
            ),
              );
            },
          ),
          const SizedBox(height: 6),
          Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    height: 1.25,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (subtitle != null && subtitle!.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
                if (coverMeta != null && coverMeta!.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    coverMeta!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 9.5,
                      height: 1.0,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
        ],
      ),
    );
  }
}

class SectionHeader extends StatelessWidget {
  final String title;
  final String? actionLabel;
  final VoidCallback? onAction;
  final Widget? trailing;

  const SectionHeader({
    super.key,
    required this.title,
    this.actionLabel,
    this.onAction,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 8, 10),
      child: Row(
        children: [
          Container(
            width: 4,
            height: 16,
            margin: const EdgeInsets.only(right: 8),
            decoration: BoxDecoration(
              color: theme.colorScheme.primary,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Expanded(
            child: Text(
              title,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          ?trailing,
          if (actionLabel != null)
            Material(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(20),
              child: InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: onAction,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        actionLabel!,
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(width: 2),
                      Icon(
                        Icons.chevron_right_rounded,
                        size: 15,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class EmptyView extends StatelessWidget {
  final String message;
  final IconData icon;
  final VoidCallback? onRetry;

  const EmptyView({
    super.key,
    required this.message,
    this.icon = Icons.inbox_outlined,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 52,
            color: scheme.onSurfaceVariant.withValues(alpha: 0.45),
          ),
          const SizedBox(height: 12),
          Text(
            message,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
              height: 1.6,
            ),
          ),
          if (onRetry != null) ...[
            const SizedBox(height: 16),
            FilledButton.tonalIcon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh, size: 18),
              label: Text(L.t('retry')),
            ),
          ],
        ],
      ),
    );
  }
}

class ShimmerBox extends StatefulWidget {
  final double? width;
  final double? height;
  final double radius;

  const ShimmerBox({
    super.key,
    this.width,
    this.height,
    this.radius = AppStyle.cardRadius,
  });

  @override
  State<ShimmerBox> createState() => _ShimmerBoxState();
}

class _ShimmerBoxState extends State<ShimmerBox>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final base = scheme.surfaceContainerHighest;
    final shine = scheme.surfaceContainerLow;
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) {
        final t = _ctrl.value;
        final x = t * 3 - 1;
        return Container(
          width: widget.width,
          height: widget.height,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(widget.radius),
            gradient: LinearGradient(
              begin: Alignment(x - 1, 0),
              end: Alignment(x + 1, 0),
              colors: [base, shine, base],
              stops: const [0.0, 0.5, 1.0],
            ),
          ),
        );
      },
    );
  }
}

class ComicGrid extends StatelessWidget {
  final List<Comic> items;
  final String? Function(Comic) coverOf;
  final void Function(Comic) onTap;
  final int? crossAxisCount;
  final EdgeInsets padding;
  final int? loadingCount;

  final String heroPrefix;

  const ComicGrid({
    super.key,
    required this.items,
    required this.coverOf,
    required this.onTap,
    this.crossAxisCount,
    this.padding = const EdgeInsets.all(AppStyle.pagePadding),
    this.loadingCount,
    this.heroPrefix = 'cover',
  });

  @override
  Widget build(BuildContext context) {
    final n = loadingCount ?? 0;
    final state = AppState.instance;

    final (densityCols, hGap, vGap, ratio) = switch (state.cardSize) {
      'compact' => (4, 6.0, 8.0, 0.46),
      'large' => (2, 14.0, 16.0, 0.55),
      _ => (3, 10.0, 12.0, 0.50),
    };

    final cols = crossAxisCount ?? densityCols;

    return GridView.builder(
      cacheExtent: 1200, padding: padding,
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: cols,
        mainAxisSpacing: vGap,
        crossAxisSpacing: hGap,
        childAspectRatio: ratio,
      ),
      itemCount: items.length + n,
      itemBuilder: (context, i) {
        if (i >= items.length) return const ShimmerBox();
        final c = items[i];
        return ComicCard(
          title: c.name,
          subtitle: c.author,
          cover: coverOf(c),
          memCacheWidth: switch (state.imageQuality) {
            'low' => 240,
            'high' => 720,
            _ => 400,
          },
          heat: c.heat == null ? null : _formatCount(c.heat!),
          localTag: AppState.instance.localFavorites.any(
            (f) => '${f['id']}' == c.id && f['pendingSync'] == true,
          ),
          category: c.category,
          coverMeta: _formatDate(c.updateAt),
          heroTag: '${heroPrefix}_${c.source}_${c.id}',
          onTap: () => onTap(c),
        );
      },
    );
  }
}

String _formatCount(int v) {
  if (v >= 1000000) return '${(v / 1000000).toStringAsFixed(1)}m';
  if (v >= 1000) return '${(v / 1000).toStringAsFixed(1)}k';
  return '$v';
}

String _formatDate(int? ts) {
  if (ts == null || ts <= 0) return '';
  final d = DateTime.fromMillisecondsSinceEpoch(ts * 1000);
  final y = d.year;
  final m = d.month.toString().padLeft(2, '0');
  final day = d.day.toString().padLeft(2, '0');
  return '$y-$m-$day';
}
