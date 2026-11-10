import 'package:flutter/material.dart';

class AppLogo extends StatelessWidget {
  const AppLogo({super.key, this.size = 56, this.radius});

  final double size;

  final double? radius;

  @override
  Widget build(BuildContext context) {
    final r = radius ?? size * 0.22;
    return ClipRRect(
      borderRadius: BorderRadius.circular(r),
      child: Image.asset(
        'assets/icon/app_icon.png',
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stack) => Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(r),
          ),
          child: Icon(
            Icons.apps_rounded,
            size: size * 0.5,
            color: Theme.of(context).colorScheme.onPrimaryContainer,
          ),
        ),
      ),
    );
  }
}
