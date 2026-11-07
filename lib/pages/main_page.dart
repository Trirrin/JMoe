import 'package:flutter/material.dart';

import 'unified_categories_page.dart';
import 'unified_home_page.dart';
import 'library_page.dart';
import 'settings_page.dart';
import 'reader_data_page.dart';
import '../core/app_state.dart';
import '../core/l10n.dart';

/// 底部导航宿主。
///
/// 切换大类别时只让**两个页面**参与动画：
/// 旧页滑出、新页滑入，中间页不参与（不会像 PageView 那样逐页掠过，
/// 也就不会导致底部导航标签一个个亮起来）。
///
/// 性能说明：
/// - 4 个页面各只 inflate 一次，之后靠复用同一 Widget 实例避免重建；
/// - 非参与动画的页面用 Offstage 挂起（保留 State / 滚动位置）；
/// - 每帧只更新 Transform 偏移，不重建子树。
class MainPage extends StatefulWidget {
  const MainPage({super.key});

  @override
  State<MainPage> createState() => _MainPageState();
}

class _MainPageState extends State<MainPage>
    with SingleTickerProviderStateMixin {
  int _index = 0;
  int _prevIndex = 0;
  bool _animating = false;
  bool _warmed = false;
  bool _initialTabApplied = false;

  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 280),
  );

  static final _pages = <Widget>[
    const UnifiedHomePage(),
    UnifiedCategoriesPage(key: UnifiedCategoriesPage.catalogKey),
    const LibraryPage(),
    const ReaderDataPage(),
    const SettingsPage(),
  ];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 应用「启动默认页」设置（仅一次）
    if (!_initialTabApplied) {
      _initialTabApplied = true;
      final tab = AppState.instance.startTab;
      if (tab > 0 && tab < _pages.length) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          setState(() {
            _prevIndex = _index;
            _index = tab;
          });
          // 直接到位，不做滑动（启动时不该有转场动画）
          _ctrl.value = 1;
        });
      }
    }
    if (_warmed) return;
    _warmed = true;
    // 首帧后预热分类页，切换过去时不会看到加载中
    WidgetsBinding.instance.addPostFrameCallback((_) {
      UnifiedCategoriesPage.precacheNow();
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _onSelect(int i) async {
    if (i == _index || _animating) return;
    setState(() {
      _prevIndex = _index;
      _index = i;
      _animating = true;
    });
    await _ctrl.forward(from: 0);
    if (!mounted) return;
    setState(() => _animating = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ClipRect(
        child: AnimatedBuilder(
          animation: _ctrl,
          // child 固定为「全部页面」的 Stack，保证不随动画重建
          child: _buildPageStack(),
          builder: (context, child) {
            if (!_animating) return child!;

            final w = MediaQuery.of(context).size.width;
            final t = Curves.easeInOutCubic.transform(_ctrl.value);
            // 目标在右侧 → dir = -1（旧页左移，新页从右进入）
            final dir = _index > _prevIndex ? -1.0 : 1.0;

            return Stack(
              children: List.generate(_pages.length, (i) {
                // 只有起点页与终点页参与动画
                if (i != _prevIndex && i != _index) {
                  return Offstage(offstage: true, child: _pages[i]);
                }
                final isPrev = i == _prevIndex;
                final offset = isPrev
                    ? Offset(dir * w * t, 0) // 旧页：0 → dir*w
                    : Offset(-dir * w * (1 - t), 0); // 新页：-dir*w → 0
                return Transform.translate(
                  offset: offset,
                  child: _pages[i],
                );
              }),
            );
          },
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: _onSelect,
        animationDuration: const Duration(milliseconds: 420),
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
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
            icon: const _ShelfIcon(filled: false),
            selectedIcon: const _ShelfIcon(filled: true),
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
    );
  }

  /// 静止态：只显示当前页（其余 Offstage 保留 State）。
  Widget _buildPageStack() {
    return Stack(
      children: List.generate(_pages.length, (i) {
        return Offstage(offstage: i != _index, child: _pages[i]);
      }),
    );
  }
}

/// 书架图标：三本并排竖立的书（经典「书架」语义）。
///
/// 用自绘保证「选中/未选中」两种状态几何完全一致，
/// 只切换描边 ↔ 填充，避免 Material 图标两套字形基线不同导致错位。
class _ShelfIcon extends StatelessWidget {
  final bool filled;
  const _ShelfIcon({required this.filled});

  @override
  Widget build(BuildContext context) {
    final color = IconTheme.of(context).color ??
        Theme.of(context).colorScheme.onSurfaceVariant;
    return SizedBox(
      width: 24,
      height: 24,
      child: CustomPaint(painter: _ShelfPainter(filled: filled, color: color)),
    );
  }
}

class _ShelfPainter extends CustomPainter {
  final bool filled;
  final Color color;
  const _ShelfPainter({required this.filled, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;
    final fill = Paint()..color = color;

    // 三本书并排
    final books = <RRect>[
      RRect.fromRectAndRadius(
        Rect.fromLTWH(w * 0.14, h * 0.18, w * 0.20, h * 0.64),
        const Radius.circular(1.4),
      ),
      RRect.fromRectAndRadius(
        Rect.fromLTWH(w * 0.38, h * 0.18, w * 0.20, h * 0.64),
        const Radius.circular(1.4),
      ),
      RRect.fromRectAndRadius(
        Rect.fromLTWH(w * 0.62, h * 0.18, w * 0.20, h * 0.64),
        const Radius.circular(1.4),
      ),
    ];

    for (final b in books) {
      if (filled) {
        canvas.drawRRect(b, fill);
      } else {
        canvas.drawRRect(b, stroke);
      }
    }
  }

  @override
  bool shouldRepaint(_ShelfPainter old) =>
      old.filled != filled || old.color != color;
}
