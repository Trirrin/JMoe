import 'package:flutter/material.dart';

/// 底部导航栏的统一高度定义。
///
/// 导航栏现在渲染在 MaterialApp.builder 的 Stack 里（Navigator 之外），
/// 目的是让它盖住 Hero 飞行层的封面。但这样一来：
///  * 页面 body 需要自己留出等高占位
///  * 导航栏自身的高度必须和占位**完全一致**
///
/// 之前两边各写各的（64 / 64+安全区 / 80），反复对不齐，
/// 表现为「导航栏高出一头」「底部空一块」。
/// 现在统一到这里，只有一个真相来源。
class NavMetrics {
  NavMetrics._();

  /// 导航栏内容高度（不含底部安全区）
  static const double barHeight = 64;

  /// 含底部安全区的总高度
  static double totalHeight(BuildContext context) =>
      barHeight + MediaQuery.of(context).padding.bottom;
}
