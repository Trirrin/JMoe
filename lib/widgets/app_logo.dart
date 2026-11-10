import 'package:flutter/material.dart';

/// 应用图标（读取真实的 launcher 图标资源）。
///
/// 登录页 / 关于页之前用的是 `Icons.auto_stories`（书籍图标）—— 那是
/// 通用 Material 图标，不是本应用的图标。用户要求这两处显示**应用图标**。
///
/// 这里直接引用 Android 侧的 `ic_launcher` 资源，与桌面看到的图标一致。
class AppLogo extends StatelessWidget {
  const AppLogo({super.key, this.size = 56, this.radius});

  final double size;

  /// 圆角；null 时用 size * 0.22（与桌面图标的视觉圆角接近）
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
        // 资源缺失时退回一个不显眼的占位，避免红屏
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
