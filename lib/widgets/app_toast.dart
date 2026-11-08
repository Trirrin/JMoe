import 'package:flutter/material.dart';

/// 轻提示（Toast）：带**入场 + 出场**动画。
///
/// 为什么不用 `SnackBar`：
///  * SnackBar 的进出场由系统控制，露头/消失都比较生硬；
///  * SnackBar 会顶起 FAB、占布局、连续弹会排队。
///
/// 这里用 Overlay 直接盖一层，自己控制动画：
///  * 入场：淡入 + 从下方 16px 上滑 + 轻微放大（280ms, easeOutBack）
///  * 停留：1.6 秒
///  * 出场：淡出 + 下沉 8px（220ms, easeIn）
///  * 同一时间只保留一条，新的直接替换旧的（避免排队延迟）
class AppToast {
  AppToast._();

  static OverlayEntry? _entry;
  static int _seq = 0;

  /// 显示一条提示。
  ///
  /// [icon] 可选图标（如「已收藏」给个心形），[accent] 用于强调色。
  /// [actionLabel] + [onAction] 会在右侧加一个可点按钮
  /// （例如导出成功后给「打开目录」）。
  static void show(
    BuildContext context,
    String message, {
    IconData? icon,
    Color? accent,
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;

    // 关掉上一条（连带它的动画）
    _dismiss();

    final id = ++_seq;
    final entry = OverlayEntry(
      builder: (ctx) => _ToastView(
        message: message,
        icon: icon,
        accent: accent,
        actionLabel: actionLabel,
        onAction: onAction,
        onDone: () {
          if (id == _seq) {
            _entry?.remove();
            _entry = null;
          }
        },
      ),
    );
    _entry = entry;
    overlay.insert(entry);
  }

  static void _dismiss() {
    final e = _entry;
    _entry = null;
    e?.remove();
  }
}

class _ToastView extends StatefulWidget {
  final String message;
  final IconData? icon;
  final Color? accent;

  /// 右侧动作按钮文案（如「打开目录」）
  final String? actionLabel;
  final VoidCallback? onAction;
  final VoidCallback onDone;

  const _ToastView({
    required this.message,
    required this.onDone,
    this.icon,
    this.accent,
    this.actionLabel,
    this.onAction,
  });

  @override
  State<_ToastView> createState() => _ToastViewState();
}

class _ToastViewState extends State<_ToastView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 280),
    reverseDuration: const Duration(milliseconds: 220),
  );

  /// 入场：0→1 淡入上滑，easeOutBack 收尾带一点回弹
  late final Animation<double> _in = CurvedAnimation(
    parent: _ctrl,
    curve: Curves.easeOutBack,
  );

  /// 出场：1→0 淡出下沉
  late final Animation<double> _out = CurvedAnimation(
    parent: _ctrl,
    curve: Curves.easeIn,
  );

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    _ctrl.forward();
    // 带动作按钮时多停留一会儿，给用户点的时间
    final hold = widget.actionLabel == null ? 1600 : 3200;
    await Future<void>.delayed(Duration(milliseconds: hold));
    if (!mounted) return;
    await _ctrl.reverse();
    if (mounted) widget.onDone();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = widget.accent ?? scheme.primary;
    // 进度：入场上滑 + 放大；出场下沉
    return Positioned(
      left: 24,
      right: 24,
      bottom: 96,
      // 注意：**不能**用 IgnorePointer 包住整块。
      // 之前这里包了 IgnorePointer(ignoring: true)（本意是「别挡住底下内容」），
      // 结果 Toast 里的「打开目录」按钮完全点不动 —— 用户看到按钮却没反应。
      // 现在的做法：整体可点（只覆盖 Toast 自身矩形，不影响页面其它区域）。
      child: AnimatedBuilder(
          animation: _ctrl,
          builder: (context, child) {
            final t = _ctrl.value.clamp(0.0, 1.0);
            final inT = _in.value.clamp(0.0, 1.2);
            final outT = _out.value.clamp(0.0, 1.0);
            // 入场时从 +16 滑到 0；出场时从 0 滑到 +8
            final dy = (1 - inT) * 16 + (1 - outT) * 8;
            final scale = 0.94 + 0.06 * inT;
            return Opacity(
              opacity: t,
              child: Transform.translate(
                offset: Offset(0, dy),
                child: Transform.scale(scale: scale, child: child),
              ),
            );
          },
          child: Material(
            color: scheme.inverseSurface,
            borderRadius: BorderRadius.circular(14),
            elevation: 6,
            shadowColor: Colors.black45,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 12,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (widget.icon != null) ...[
                    Icon(widget.icon, size: 18, color: accent),
                    const SizedBox(width: 10),
                  ],
                  Flexible(
                    child: Text(
                      widget.message,
                      style: TextStyle(
                        color: scheme.onInverseSurface,
                        fontSize: 13,
                        height: 1.4,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  // 右侧动作按钮（如「打开目录」）
                  if (widget.actionLabel != null) ...[
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: () {
                        widget.onAction?.call();
                        widget.onDone();
                      },
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        foregroundColor: accent,
                      ),
                      child: Text(
                        widget.actionLabel!,
                        style: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
    );
  }
}