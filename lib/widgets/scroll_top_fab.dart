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

  static const double _showThreshold = 400;

  bool get _isAction => actionLabel != null;
  bool get _show => _isAction || scrollOffset > _showThreshold;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final button = _isAction ? _buildAction(scheme) : _buildTop(scheme);

    // 隐藏时直接不参与布局（而非靠 offset 移出屏幕），
    // 这样 Hero 起点永远是按钮的真实位置。
    if (!_show) return const SizedBox.shrink();

    if (heroTag == null || heroTag!.isEmpty) return button;
    return Hero(
      tag: heroTag!,
      flightShuttleBuilder: (context, animation, direction, fromCtx, toCtx) {
        final t = Curves.easeInOutCubic.transform(animation.value);
        final a = direction == HeroFlightDirection.push ? t : 1 - t;
        final w = 48.0 + (148.0 - 48.0) * a;
        final radius = 24.0 + (20.0 - 24.0) * a;
        return SizedBox(
          width: w,
          height: 48,
          child: Material(
            // 必须与列表页真实按钮 / 详情页 FAB 同色（primaryContainer），
            // 否则 pop 方向会闪成 primary 的深绿色。
            color: scheme.primaryContainer,
            borderRadius: BorderRadius.circular(radius),
            child: Center(
              child: a > 0.5
                  ? Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.play_arrow,
                            size: 18, color: scheme.onPrimaryContainer),
                        const SizedBox(width: 4),
                        if (a > 0.8)
                          Text(
                            actionLabel ?? '',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: scheme.onPrimaryContainer,
                            ),
                          ),
                      ],
                    )
                  : Icon(Icons.arrow_upward_rounded,
                      size: 20, color: scheme.onPrimaryContainer),
            ),
          ),
        );
      },
      child: button,
    );
  }

  Widget _buildAction(ColorScheme scheme) {
    return FilledButton.icon(
      onPressed: onAction,
      icon: const Icon(Icons.menu_book_rounded, size: 18),
      label: Text(actionLabel!),
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        shape: const StadiumBorder(),
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
        child: SizedBox(
          width: 48,
          height: 48,
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
