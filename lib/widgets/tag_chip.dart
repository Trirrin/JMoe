import 'package:flutter/material.dart';

class TagChip extends StatelessWidget {
  final String tag;
  final VoidCallback? onTap;
  final bool showHash;
  final bool dense;

  const TagChip({
    super.key,
    required this.tag,
    this.onTap,
    this.showHash = true,
    this.dense = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final label = showHash ? '#$tag' : tag;
    final body = Container(
      padding: EdgeInsets.symmetric(
        horizontal: dense ? 10 : 13,
        vertical: dense ? 5 : 7,
      ),
      decoration: BoxDecoration(
        color: scheme.primaryContainer.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: dense ? 11.5 : 12,
          height: 1.2,
          fontWeight: FontWeight.w500,
          color: scheme.onPrimaryContainer,
        ),
      ),
    );
    if (onTap == null) return body;
    return _PressableChip(onTap: onTap!, child: body);
  }
}

class _PressableChip extends StatefulWidget {
  final VoidCallback onTap;
  final Widget child;
  const _PressableChip({required this.onTap, required this.child});

  @override
  State<_PressableChip> createState() => _PressableChipState();
}

class _PressableChipState extends State<_PressableChip> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapCancel: () => setState(() => _pressed = false),
      onTapUp: (_) => setState(() => _pressed = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _pressed ? 0.94 : 1.0,
        duration: const Duration(milliseconds: 120),
        child: widget.child,
      ),
    );
  }
}

class RemovableTagChip extends StatelessWidget {
  final String tag;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const RemovableTagChip({
    super.key,
    required this.tag,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.primaryContainer.withValues(alpha: 0.55),
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(13, 7, 5, 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 180),
                child: Text(
                  tag,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.2,
                    fontWeight: FontWeight.w500,
                    color: scheme.onPrimaryContainer,
                  ),
                ),
              ),
              const SizedBox(width: 2),
              GestureDetector(
                onTap: onDelete,
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Icon(
                    Icons.close_rounded,
                    size: 13,
                    color: scheme.onPrimaryContainer.withValues(alpha: 0.7),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
