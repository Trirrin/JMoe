import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

class AppStyle {
  AppStyle._();

  static const double cardRadius = 12;
  static const double cardSpace = 10;
  static const double pagePadding = 12;
  static const Duration animFast = Duration(milliseconds: 180);
  static const Duration animNormal = Duration(milliseconds: 280);

  static const Color seed = Color(0xFF4CAF50);

  static const List<Map<String, dynamic>> colorSeeds = [
    {'color': Color(0xFF4CAF50), 'label': 'colorDefault'},
    {'color': Color(0xFF009688), 'label': 'colorTeal'},
    {'color': Color(0xFF2196F3), 'label': 'colorBlue'},
    {'color': Color(0xFF3F51B5), 'label': 'colorIndigo'},
    {'color': Color(0xFF6750A4), 'label': 'colorViolet'},
    {'color': Color(0xFFE91E63), 'label': 'colorPink'},
    {'color': Color(0xFFFFC107), 'label': 'colorYellow'},
    {'color': Color(0xFFFF9800), 'label': 'colorOrange'},
    {'color': Color(0xFFFF5722), 'label': 'colorDeepOrange'},
  ];
}

ThemeData buildAppTheme(Color seed, Brightness brightness, {bool oled = false}) {
  final scheme = ColorScheme.fromSeed(
    seedColor: seed,
    brightness: brightness,
  );
  var base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    brightness: brightness,
  );
  if (oled && brightness == Brightness.dark) {
    base = base.copyWith(
      scaffoldBackgroundColor: Colors.black,
      colorScheme: base.colorScheme.copyWith(
        surface: Colors.black,
        onSurface: Colors.white,
        onPrimary: Colors.black,
        onSecondary: Colors.black,
      ),
    );
  }
  return base.copyWith(
    visualDensity: VisualDensity.standard,
    splashFactory: InkSparkle.splashFactory,
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: ZoomPageTransitionsBuilder(),
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
      },
    ),
    appBarTheme: AppBarTheme(
      centerTitle: false,
      elevation: 0,
      scrolledUnderElevation: 0,
      backgroundColor: base.colorScheme.surface,
      foregroundColor: base.colorScheme.onSurface,
      titleTextStyle: base.textTheme.titleLarge?.copyWith(
        fontWeight: FontWeight.w600,
        color: base.colorScheme.onSurface,
      ),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppStyle.cardRadius),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      elevation: 0,
      height: 64,
      backgroundColor: base.colorScheme.surface,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      indicatorShape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
      ),
    ),
    chipTheme: base.chipTheme.copyWith(
      side: BorderSide.none,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      isDense: true,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: base.colorScheme.primary, width: 1.4),
      ),
    ),
    snackBarTheme: const SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      insetPadding: EdgeInsets.fromLTRB(16, 0, 16, 16),
    ),
  );
}
