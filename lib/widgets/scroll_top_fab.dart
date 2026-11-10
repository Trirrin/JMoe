import 'package:flutter/material.dart';

class ScrollTopFab extends StatelessWidget {
  final double scrollOffset;
  final String? actionLabel;
  final VoidCallback? onAction;

  final String? heroTag;

  const ScrollTopFab({
    super.key,
    required this.scrollOffset,
    this.actionLabel,
    this.onAction,
    this.heroTag,
  });

  static const double _showThreshold = 120;

  bool get _isAction => actionLabel != null;
  bool get _show => _isAction || scrollOffset > _showThreshold;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final button = _isAction ? _buildAction(scheme) : _buildTop(scheme);

    final hasHero = heroTag != null && heroTag!.isNotEmpty;
    if (hasHero) {
      return Hero(
        tag: heroTag!,
        child: _show || _isAction ? button : _buildTop(scheme),
      );
    }

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
