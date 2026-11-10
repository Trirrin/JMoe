import 'package:flutter/material.dart';

class DetailPageRoute<T> extends PageRouteBuilder<T> {
  DetailPageRoute({required WidgetBuilder builder, super.settings})
      : super(
          pageBuilder: (context, animation, secondaryAnimation) =>
              builder(context),
          transitionDuration: const Duration(milliseconds: 300),
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

Route<T> detailRoute<T>({required WidgetBuilder builder}) =>
    DetailPageRoute<T>(builder: builder);
