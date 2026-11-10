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

    // 显示/隐藏动画：只在**没有 Hero 目标**时使用。
    //
    // 有 heroTag 时必须跳过这个 TweenAnimationBuilder，否则会出现
    // 「落位后又从 0 淡入」—— Hero 落位把真控件交回列表页，
    // 而这里又从 t=0 重播淡入+缩放 → 就是「到位后闪一下」。
    //
    // 注意：这里**不能用 `&& _show` 限制**。
    // 之前加过 `&& _show`，结果是按钮未滚出时根本不注册 Hero，
    // 从详情页返回时找不到落点 → 没有「按钮飞回」的过渡动画
    // （用户反馈「搜索页的 FAB 没有过渡到开始按钮的动画」）。
    //
    // 正确做法：只要 heroTag 存在就注册 Hero，并**始终用胶囊形态**
    // 作为落点 —— 它的几何与详情页 FAB 一致（高 56、圆角 16），
    // Hero 飞行时只有宽窄变化，不会出现形变跳变。
    final hasHero = heroTag != null && heroTag!.isNotEmpty;
    if (hasHero) {
      return Hero(
        tag: heroTag!,
        child: _show || _isAction ? button : _buildTop(scheme),
      );
    }

    // 无 Hero：保留原来的淡入+缩放动画
    return TweenAnimationBuilder<double>(
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
  }

  /// 操作按钮（如「开始阅读」）。
  ///
  /// **不做入场动画**：这个按钮在 Hero 飞行时是真控件的落点，
  /// 如果它自己还有 "elevation 从 0 升到 3" 之类的动画，
  /// Hero 落位瞬间会重新播一遍 → 用户看到的「到位后闪一下」。
  /// 之前 `elevation: 3 * t` 配合 TweenAnimationBuilder 就是这个问题。
  ///
  /// 现在直接给最终态（elevation 3、圆角 24），没有中间态可跳变。
  Widget _buildAction(ColorScheme scheme) {
    return Material(
      color: scheme.primaryContainer,
      borderRadius: BorderRadius.circular(24),
      elevation: 3,
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
