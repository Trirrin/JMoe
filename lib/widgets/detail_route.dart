import 'package:flutter/material.dart';

/// 详情页专用路由：**只放慢「收回」**，进入保持原速。
///
/// # 为什么只改 reverse
///
/// 用户反馈的是「几关闭详情时封面 Hero 移动太快」——
/// 也就是 pop 方向。push 方向原本观感正常，不该一起变慢。
///
/// Hero 的飞行时长绑定在路由过渡时长上，没有独立开关，
/// 所以这里把 `reverseTransitionDuration` 单独拉长（300 → 560ms），
/// 进入仍然用系统的 300ms。
class DetailPageRoute<T> extends PageRouteBuilder<T> {
  DetailPageRoute({required WidgetBuilder builder, super.settings})
      : super(
          pageBuilder: (context, animation, secondaryAnimation) =>
              builder(context),
          // 进入：保持系统默认节奏，不要动
          transitionDuration: const Duration(milliseconds: 300),
          // 收回：拉长到 560ms，Hero 飞回去的过程才看得清
          reverseTransitionDuration: const Duration(milliseconds: 560),
          opaque: true,
        );

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final theme = Theme.of(context);
    final builder =
        theme.pageTransitionsTheme.builders[theme.platform] ??
            const ZoomPageTransitionsBuilder();
    // 收回用 easeInOutCubic（起步缓、收尾缓），视觉上比系统默认更「从容」；
    // 进入沿用系统曲线，保证点开时依然干脆。
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInOutCubic,
    );
    return builder.buildTransitions(
      this,
      context,
      curved,
      secondaryAnimation,
      child,
    );
  }
}

/// 统一入口：所有列表页打开详情都用它。
Route<T> detailRoute<T>({required WidgetBuilder builder}) =>
    DetailPageRoute<T>(builder: builder);
