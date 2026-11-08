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
  /// 封面下方文字区的固定高度（标题 + 作者 + 类别行 + 间距）。
  ///
  /// 网格用它计算 childAspectRatio，**必须与实际渲染高度一致**，
  /// 否则类别标签的圆角会被卡片底边裁掉。
  static const double textBlockHeight = 82;

  final String title;
  final String? subtitle;
  final String? cover;
  final String? badge;
  final VoidCallback? onTap;

  /// 长按（书架用于进入多选）
  final VoidCallback? onLongPress;
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

  /// 是否本地收藏（封面右上角显示「本地」角标）
  final bool localTag;

  /// 是否云端收藏（封面右上角显示云朵角标）
  final bool cloudTag;

  /// 封面右下角的**类型**角标：漫画 / 小说 / 视频。
  ///
  /// 与左上角的源标识（JM/EH）、右上角的收藏标识分处不同角落，
  /// 三者互不遮挡。
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


  /// 封面角标的统一样式（左上角用）。
  ///
  /// 高度固定 17、圆角 6、字号 10 —— 与右上角的云端/本地角标**完全一致**，
  /// 左右两个标签看起来才整齐。
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
      // 飞行层**独立构造**，不引用 from/to 任何一方的 widget。
      //
      // 之前用 `return child`（源卡片实例）：飞行途中若源卡片被重建、
      // 滚出 cacheExtent、或图片字节被内存 LRU 淘汰，飞行层就跟着失效 ——
      // 表现正是「Hero 动画有几率直接消失，变成硬切」。
      // 独立构造只依赖 cover URL，任何时刻都能画出来。
      flightShuttleBuilder: (context, animation, direction, fromCtx, toCtx) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(AppStyle.cardRadius),
          child: CoverImage(url: cover),
        );
      },
      // 源卡片在飞行期间留同尺寸占位，避免整行重新布局（卡片「跳一下」）
      placeholderBuilder: (context, size, widget) => SizedBox(
        width: size.width,
        height: size.height,
      ),
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
      onLongPress: onLongPress,
      borderRadius: BorderRadius.circular(AppStyle.cardRadius),
      child: Column(
        // 关键：必须 min，否则 Column 会尝试填满父级高度，
        // 在 Wrap / Grid 的受限约束下把文字区压缩，导致类别标签被裁。
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 封面用 LayoutBuilder + 显式高度代替 AspectRatio。
          //
          // 原因：AspectRatio 在不同约束模式下行为不同 ——
          // 松约束下按宽度算高，紧约束下可能反向压缩宽度，
          // 导致卡片总高不确定，文字区（类别标签行）被挤出卡片而被裁。
          // 显式给定高度后，卡片尺寸完全确定，任何约束模式下都一致。
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
                // 收藏来源角标：右上角，**云端优先**
                //  - 已同步云端 → 云朵图标（蓝）
                //  - 仅本地未同步 → 「本地」文字胶囊（主色）
                // 同一条目若同时在云端和本地（正常情况），显示云端；
                // 只有「本地新增、还没上云」才显示「本地」。
                if (cloudTag)
                  Positioned(
                    right: 6,
                    top: 6,
                    child: Container(
                      // 与左上角类型角标**同高同圆角**（高度 17、圆角 6），
                      // 之前云朵角标没有固定高度（只有 icon+padding），
                      // 视觉上比左侧的类型标签矮一截，看起来不整齐。
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
                // 左上角：**类型角标**（漫画 / 小说 / 视频）。
                // 用户说的「类别」就是这个三大类，不是 JM 的同人/韩漫分类。
                // 放在左上最显眼，让用户一眼分清作品是什么形态。
                if (kindTag != null && kindTag!.isNotEmpty)
                  Positioned(
                    left: 6,
                    top: 6,
                    child: _cornerTag(kindTag!, bold: true),
                  )
                // 没有类型角标时才退到源标识（JM）
                else if (badge != null && badge!.isNotEmpty)
                  Positioned(
                    left: 6,
                    top: 6,
                    child: _cornerTag(badge!),
                  ),
                // 右下角：热度（类型角标已移到左上，不再重复显示）
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
              );
            },
          ),
          const SizedBox(height: 6),
          // 文字区：自然高度（不固定、不用 Spacer），
          // 由网格行高留足余量来保证不被裁切。
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
                // 仅显示日期（类别标签已按需求移除）
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

/// 骨架占位：带横向流光（shimmer）的灰块。
///
/// 静态灰块在长列表里几乎看不出「还在加载」，加一条从左掠到右的高光
/// 让加载状态可感知；用 [AnimatedBuilder] 驱动，整棵骨架共用一个控制器
/// 时开销可忽略。
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
        final t = _ctrl.value; // 0..1
        // 高光从 -1 掠到 2：起止都在可视区外，循环时无跳变
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

/// 通用网格（统一首页/分类/搜索/书架的卡片布局）。
class ComicGrid extends StatelessWidget {
  final List<Comic> items;
  final String? Function(Comic) coverOf;
  final void Function(Comic) onTap;
  /// 显式列数；为 null 时读取全局设置（跟随「每行显示数量」）。
  final int? crossAxisCount;
  final EdgeInsets padding;
  final int? loadingCount;

  /// Hero tag 命名空间前缀。
  ///
  /// 不同列表页必须用不同前缀。否则当页面栈里同时存在多个列表页时
  /// （如 发现页 → 详情 → 搜索 → 详情），同名 tag 会互相抢占，
  /// 导致返回时封面飞向错误位置。
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
          // 本地收藏角标（仅「未同步到云端」的条目）
          localTag: AppState.instance.localFavorites.any(
            (f) => '${f['id']}' == c.id && f['pendingSync'] == true,
          ),
          category: c.category,
          // 日期始终显示在类别旁
          coverMeta: _formatDate(c.updateAt),
          heroTag: '${heroPrefix}_${c.source}_${c.id}',
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

/// 更新时间 → YYYY-MM-DD（统一显示完整年月日）
String _formatDate(int? ts) {
  if (ts == null || ts <= 0) return '';
  final d = DateTime.fromMillisecondsSinceEpoch(ts * 1000);
  final y = d.year;
  final m = d.month.toString().padLeft(2, '0');
  final day = d.day.toString().padLeft(2, '0');
  return '$y-$m-$day';
}
