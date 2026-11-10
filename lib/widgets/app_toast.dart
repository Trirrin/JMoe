import 'package:flutter/material.dart';

class AppToast {
  AppToast._();

  static OverlayEntry? _entry;
  static int _seq = 0;

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

  late final Animation<double> _in = CurvedAnimation(
    parent: _ctrl,
    curve: Curves.easeOutBack,
  );

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
    return Positioned(
      left: 24,
      right: 24,
      bottom: 96,
      child: AnimatedBuilder(
          animation: _ctrl,
          builder: (context, child) {
            final t = _ctrl.value.clamp(0.0, 1.0);
            final inT = _in.value.clamp(0.0, 1.2);
            final outT = _out.value.clamp(0.0, 1.0);
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
