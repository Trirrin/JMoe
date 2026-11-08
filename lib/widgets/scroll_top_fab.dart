import 'package:flutter/material.dart';

/// 右下角浮动按钮：
/// - 列表态：「回到顶部」（滚动超过阈值才出现）
/// - 详情态：「开始阅读 / 继续阅读」（常显）
///
/// 两态通过同一个 Hero tag 做**形变 + 直线平移**衔接。
///
/// 注意：[scrollOffset] 必须是**真实滚动偏移**，不能用布尔哨兵值，
/// 否则隐藏态（下方 1.6 倍高偏移）会被当作 Hero 的起始矩形，
/// 导致转场看起来是从屏幕下方飞上来。
class ScrollTopFab extends StatelessWidget {
  final double scrollOffset;
  final String? actionLabel;
  final VoidCallback? onAction;

  /// 与目标页 FAB 共用的 Hero 标签。
  final String? heroTag;

  const ScrollTopFab({
    super.key,
    required this.scrollOffset,
    this.actionLabel,
    this.onAction,
    this.heroTag,
  });

  /// 滚动超过这个距离就显示「回到顶部」按钮。
  ///
  /// 用户要求「往下翻 2 页的列表都要有 fab 按钮」—— 往下滚一点就该出现，
  /// 不要等滚很深才给。120px 约等于半屏位移，翻一点就能看到。
  static const double _showThreshold = 120;

  bool get _isAction => actionLabel != null;
  bool get _show => _isAction || scrollOffset > _showThreshold;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final button = _isAction ? _buildAction(scheme) : _buildTop(scheme);

    // 用 TweenAnimationBuilder 而非 AnimatedScale：
    // 本组件是 StatelessWidget，滚动时每帧重建，
    // AnimatedXxx 的内部状态会被重置，动画看不出来。
    // TweenAnimationBuilder 每帧从当前值向目标值插值，无状态依赖。
    final content = TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: _show ? 1.0 : 0.0),
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
      builder: (context, t, child) {
        if (t <= 0.001) {
          return const SizedBox(width: 56, height: 56);
        }
        return SizedBox(
          width: 56,
          height: 56,
          child: Opacity(
            opacity: t,
            child: Transform.scale(
              scale: 0.85 + 0.15 * t,
              child: child,
            ),
          ),
        );
      },
      child: IgnorePointer(ignoring: !_show, child: button),
    );

    if (heroTag == null || heroTag!.isEmpty) return content;
    // Hero 用**原生行为**（不写 flightShuttleBuilder）。
    //
    // 之前用 flightShuttleBuilder + FittedBox(toCtx.widget) 试图保证
    // 两端一致，但那等于让飞行内容和真控件走两套绘制路径，
    // 落位交接时几何/阴影对不上 → 闪一下。
    //
    // 现在交给 Hero 原生：它把 child 按插值矩形缩放，
    // 落位矩形 = child 自然尺寸 → 缩放比 1.0，零跳变。
    //
    // 注意：**不要因为 !_show 就跳过 Hero** —— 列表态默认不显示按钮，
    // 但返回时需要落点，否则收回动画会中断。
    return Hero(
      tag: heroTag!,
      // child 与静止态一致：没滚动时用圆形回顶钮，
      // 避免飞行起点是半透明或空占位。
      child: _show || _isAction ? button : _buildTop(scheme),
    );
  }

  /// 操作按钮（如「开始阅读」）。
  ///
  /// 从「圆形回到顶部」变形而来：圆角、宽度、阴影同步插值，
  /// 不再瞬间变成胶囊 + 阴影突现。
  Widget _buildAction(ColorScheme scheme) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
      builder: (context, t, child) {
        // 圆角：24（圆）→ 24（胶囊，StadiumBorder 半径=高度/2）
        // 两者其实等价，关键是宽度与内容渐变
        return Material(
          color: scheme.primaryContainer,
          borderRadius: BorderRadius.circular(24),
          // 阴影从 0 平滑升到 3
          elevation: 3 * t,
          child: child,
        );
      },
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: onAction,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.menu_book_rounded,
                size: 18,
                color: scheme.onPrimaryContainer,
              ),
              const SizedBox(width: 6),
              Text(
                actionLabel ?? '',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: scheme.onPrimaryContainer,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTop(ColorScheme scheme) {
    return Material(
      color: scheme.primaryContainer,
      shape: const CircleBorder(),
      elevation: 3,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onAction,
        // 尺寸与详情页 FAB 一致（56）：Hero 两端高度相同，
        // 飞行时只有宽度/形状变化，不会出现"突然放大/缩小"。
        // 之前这里是 48，而 FAB 是 56 —— 差距 8px 就是用户看到的跳变来源。
        child: SizedBox(
          width: 56,
          height: 56,
          child: Icon(
            Icons.arrow_upward_rounded,
            size: 22,
            color: scheme.onPrimaryContainer,
          ),
        ),
      ),
    );
  }
}
