import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/app_theme.dart';
import '../core/image_cache.dart';
import '../core/l10n.dart';
import '../core/models.dart';

/// 统一封面组件（走磁盘+内存缓存，滚动流畅）。
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

/// 3:4 封面卡片。
class ComicCard extends StatelessWidget {
  final String title;
  final String? subtitle;
  final String? cover;
  final String? badge;
  final VoidCallback? onTap;
  final double? progress;
  final int? memCacheWidth;

  /// 热度角标：点赞数 / 浏览量 / 页数等，右下角显示。
  final String? heat;

  /// 副标题前的分类小标签。
  final String? category;

  /// Hero 标签：与详情页封面共享，形成连贯的平移放大转场。
  final String? heroTag;

  /// 封面右下角文字角标（无热度数据时显示更新时间）。
  final String? coverMeta;

  const ComicCard({
    super.key,
    required this.title,
    this.subtitle,
    this.cover,
    this.badge,
    this.onTap,
    this.progress,
    this.memCacheWidth,
    this.heat,
    this.category,
    this.heroTag,
    this.coverMeta,
  });


  Widget _maybeHero(Widget child) {
    if (heroTag == null || heroTag!.isEmpty) return child;
    return Hero(
      tag: heroTag!,
      // 只用位移/缩放过渡，透明度保持不变（不做淡出淡入）
      flightShuttleBuilder: (context, animation, direction, fromCtx, toCtx) {
        return child;
      },
      // 直线平移：不用默认的 MaterialRectArcTween（弧形路径）。
      // 用普通 RectTween 做矩形线性插值，配合线性时间曲线，
      // 视觉上就是从卡片封面沿直线滑到详情页封面。
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
      borderRadius: BorderRadius.circular(AppStyle.cardRadius),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 用 AspectRatio 固定封面比例（3:4）。
          // 之前用 Expanded，在 shrinkWrap:true 的网格里会被父级无限高度拉伸，
          // 造成分区标题与卡片之间出现大片空白。
          AspectRatio(
            aspectRatio: 3 / 4,
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
                if (badge != null && badge!.isNotEmpty)
                  Positioned(
                    left: 6,
                    top: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.62),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        badge!,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
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
                // coverMeta 已移到「类别行」显示，封面角标不再使用
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
          ),
          const SizedBox(height: 6),
          // 标题固定单行：网格高度是固定比例（0.52），
          // 两行标题会把下方的作者/类别挤出卡片，造成视觉重叠。
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
          // 类别 + 日期同一行（日期不再显示在封面角标）
          if ((category != null && category!.isNotEmpty) ||
              (coverMeta != null && coverMeta!.isNotEmpty)) ...[
            const SizedBox(height: 3),
            Row(
              children: [
                if (category != null && category!.isNotEmpty)
                  Flexible(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 1.5,
                      ),
                      decoration: BoxDecoration(
                        color: scheme.primaryContainer,
                        borderRadius: BorderRadius.circular(5),
                      ),
                      child: Text(
                        category!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 9.5,
                          fontWeight: FontWeight.w600,
                          color: scheme.onPrimaryContainer,
                        ),
                      ),
                    ),
                  ),
                if (category != null &&
                    category!.isNotEmpty &&
                    coverMeta != null &&
                    coverMeta!.isNotEmpty)
                  const SizedBox(width: 4),
                if (coverMeta != null && coverMeta!.isNotEmpty)
                  Text(
                    coverMeta!,
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: 9.5,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// 分区标题。
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
          if (trailing != null) trailing!,
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

/// 空态 / 错误态。
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

/// 骨架占位。
class ShimmerBox extends StatelessWidget {
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
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }
}

/// 通用网格（统一首页/分类/搜索/书架的卡片布局）。
class ComicGrid extends StatelessWidget {
  final List<Comic> items;
  final String? Function(Comic) coverOf;
  final void Function(Comic) onTap;
  /// 显式列数；为 null 时读取全局设置（跟随「每行显示数量」）。
  final int? crossAxisCount;
  final EdgeInsets padding;
  final int? loadingCount;

  const ComicGrid({
    super.key,
    required this.items,
    required this.coverOf,
    required this.onTap,
    this.crossAxisCount,
    this.padding = const EdgeInsets.all(AppStyle.pagePadding),
    this.loadingCount,
  });

  @override
  Widget build(BuildContext context) {
    final n = loadingCount ?? 0;
    final state = AppState.instance;

    // 「列表密度」同时决定列数与间距：
    // 紧凑 = 4 列（更多卡片），宽松 = 2 列（卡片更大）
    // childAspectRatio = 宽/高，**数值越小卡片越高**。
    // 卡片内容 = 封面(宽×1.333) + 标题/作者/类别行(约 59px)，
    // 按各密度常见列宽换算后留余量，确保底部类别行不被裁切。
    final (densityCols, hGap, vGap, ratio) = switch (state.cardSize) {
      'compact' => (4, 6.0, 8.0, 0.46),
      'large' => (2, 14.0, 16.0, 0.55),
      _ => (3, 10.0, 12.0, 0.50),
    };

    // 显式传入的列数优先（如分类页固定 2 列）
    final cols = crossAxisCount ?? densityCols;

    return GridView.builder(
      padding: padding,
      cacheExtent: 1200,
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
          // 缩略图质量：省流量 → 较小解码尺寸；高清 → 更大
          memCacheWidth: switch (state.imageQuality) {
            'low' => 240,
            'high' => 720,
            _ => 400,
          },
          heat: c.heat == null ? null : _formatCount(c.heat!),
          category: c.category,
          // 日期始终显示在类别旁
          coverMeta: _formatDate(c.updateAt),
          heroTag: 'cover_${c.source}_${c.id}',
          onTap: () => onTap(c),
        );
      },
    );
  }
}

/// 大数字缩写：1234 → 1.2k
String _formatCount(int v) {
  if (v >= 1000000) return '${(v / 1000000).toStringAsFixed(1)}m';
  if (v >= 1000) return '${(v / 1000).toStringAsFixed(1)}k';
  return '$v';
}

/// 更新时间 → MM-dd
String _formatDate(int? ts) {
  if (ts == null || ts <= 0) return '';
  final d = DateTime.fromMillisecondsSinceEpoch(ts * 1000);
  final now = DateTime.now();
  if (now.difference(d).inDays == 0) {
    return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }
  return '${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}
