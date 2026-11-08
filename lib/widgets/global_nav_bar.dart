import 'package:flutter/material.dart';

import '../core/l10n.dart';
import '../core/nav_bar_state.dart';
import '../pages/main_page.dart';

/// 全局底部导航栏。
///
/// 渲染在 MaterialApp.builder 的 Stack 里 —— 也就是 **Navigator 之外**。
/// 这样它的层级高于 Hero 飞行层（飞行层在 Navigator 的 Overlay 内），
/// 封面从列表飞进详情时会被它挡住，符合「导航栏不动、遮挡封面」的要求。
///
/// 状态（选中项/点击回调）由 MainPage 通过 [NavBarState] 注入。
class GlobalNavBar extends StatelessWidget {
  const GlobalNavBar({super.key});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: NavBarState.instance,
      builder: (context, _) {
        final s = NavBarState.instance;
        if (!s.visible) return const SizedBox.shrink();
        // 底部安全区由这里统一处理：外层 Padding 让出安全区，
        // 内部的 MediaQuery.removePadding 阻止 NavigationBar 再加一次。
        // 总高度 = 64（主题）+ 安全区，与 MainPage 的占位严格一致。
        final bottomInset = MediaQuery.of(context).padding.bottom;
        return Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: Container(
            color: Theme.of(context).colorScheme.surface,
            padding: EdgeInsets.only(bottom: bottomInset),
            child: MediaQuery.removePadding(
              context: context,
              removeBottom: true,
              child: NavigationBar(
                selectedIndex: s.index,
                onDestinationSelected: (i) => s.onSelect?.call(i),
                animationDuration: const Duration(milliseconds: 200),
                labelBehavior:
                    NavigationDestinationLabelBehavior.alwaysShow,
                destinations: [
                  NavigationDestination(
                    icon: const Icon(Icons.explore_outlined),
                    selectedIcon: const Icon(Icons.explore),
                    label: L.t('tabDiscover'),
                  ),
                  NavigationDestination(
                    icon: const Icon(Icons.grid_view_outlined),
                    selectedIcon: const Icon(Icons.grid_view),
                    label: L.t('tabCategories'),
                  ),
                  NavigationDestination(
                    icon: const ShelfIcon(filled: false),
                    selectedIcon: const ShelfIcon(filled: true),
                    label: L.t('tabShelf'),
                  ),
                  NavigationDestination(
                    icon: const Icon(Icons.insights_outlined),
                    selectedIcon: const Icon(Icons.insights),
                    label: L.t('tabStats'),
                  ),
                  NavigationDestination(
                    icon: const Icon(Icons.settings_outlined),
                    selectedIcon: const Icon(Icons.settings),
                    label: L.t('tabSettings'),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
