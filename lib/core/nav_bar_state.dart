import 'package:flutter/foundation.dart';

/// 底部导航栏的全局状态。
///
/// 为什么需要它：封面 Hero 的飞行层画在 **Navigator 的 Overlay** 里，
/// 层级高于 Scaffold 的任何内容（包括 bottomNavigationBar）。
/// 想让导航栏「挡住飞行的封面」，唯一可靠的办法是把它画在
/// **Navigator 之外、更上层**——也就是 MaterialApp.builder 里的 Stack。
///
/// 但导航栏的选中项与点击回调属于 MainPage，所以用一个全局 notifier
/// 把状态从 MainPage 传到根层渲染。
class NavBarState extends ChangeNotifier {
  NavBarState._();
  static final NavBarState instance = NavBarState._();

  int index = 0;

  /// 当前是否显示（启动页等非主界面时不显示）
  bool visible = false;

  /// 由 MainPage 注入的点击回调
  void Function(int)? onSelect;

  void update({int? index, bool? visible, void Function(int)? onSelect}) {
    if (index != null) this.index = index;
    if (visible != null) this.visible = visible;
    if (onSelect != null) this.onSelect = onSelect;
    notifyListeners();
  }
}
