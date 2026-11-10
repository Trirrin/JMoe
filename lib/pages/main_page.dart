import 'package:flutter/material.dart';
import '../core/models.dart';
import 'unified_detail_page.dart';
import 'package:flutter/services.dart';

import 'unified_categories_page.dart';
import 'unified_home_page.dart';
import 'library_page.dart';
import 'settings_page.dart';
import 'reader_data_page.dart';
import '../core/app_state.dart';
import '../core/l10n.dart';
import '../widgets/detail_route.dart';

class MainPage extends StatefulWidget {
  const MainPage({super.key});

  @override
  State<MainPage> createState() => _MainPageState();
}

class _MainPageState extends State<MainPage>
    with SingleTickerProviderStateMixin {
  static const _sysCh = MethodChannel('jmoe/reader');

  Future<void> _moveToBack() async {
    try {
      await _sysCh.invokeMethod('moveToBack');
    } catch (_) {}
  }

  int _index = 0;
  int _prevIndex = 0;
  bool _animating = false;
  bool _warmed = false;
  bool _initialTabApplied = false;

  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 280),
  );

  Animation<double>? _secondary;

  void _onSecondaryChanged() {
    if (!mounted) return;
    setState(() {});
  }
  static final _pages = <Widget>[
    const UnifiedHomePage(),
    UnifiedCategoriesPage(key: UnifiedCategoriesPage.catalogKey),
    const LibraryPage(),
    ReaderDataPage(key: ReaderDataPage.statsKey),
    const SettingsPage(),
  ];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final sec = ModalRoute.of(context)?.secondaryAnimation;
    if (sec != null && sec != _secondary) {
      _secondary?.removeListener(_onSecondaryChanged);
      _secondary = sec;
      sec.addListener(_onSecondaryChanged);
    }
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
          _ctrl.value = 1;
        });
      }
    }
    if (_warmed) return;
    _warmed = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      UnifiedCategoriesPage.precacheNow();
      ReaderDataPage.precacheNow();
      _checkClipboardShare();
    });
  }

  @override
  void dispose() {
    _secondary?.removeListener(_onSecondaryChanged);
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _checkClipboardShare() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text ?? '';
      if (text.isEmpty || !text.contains('【JMoe】')) return;

      String? comicId;
      String? sourceId;
      final jm = RegExp(r'JM(\d{3,})').firstMatch(text);
      if (jm != null) {
        comicId = jm.group(1);
        sourceId = 'jm';
      } else {
        final eh = RegExp(r'(\d{4,})\s*$').firstMatch(text.trim());
        if (eh != null) {
          comicId = eh.group(1);
          sourceId = 'ehentai';
        }
      }
      if (comicId == null || !mounted) return;

      final comic = Comic(
        id: sourceId == 'ehentai'
            ? 'eh:https://e-hentai.org/g/$comicId/'
            : comicId,
        name: '',
        author: '',
        source: sourceId!,
      );
      await Navigator.of(context).push(
        detailRoute(builder: (_) => UnifiedDetailPage(
            source: SourceRegistry.current,
            comic: comic,
          ),
        ),
      );
    } catch (_) {
    }
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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (_index != 0) {
          _onSelect(0);
          return;
        }
        _moveToBack();
      },
      child: Scaffold(
        body: ClipRect(
          child: AnimatedBuilder(
            animation: _ctrl,
            builder: (context, _) => _buildPageStack(),
          ),
        ),
        bottomNavigationBar: _buildNavBar(),
      ),
    );
  }

  Widget _buildNavBar() {
    return NavigationBar(
      selectedIndex: _index,
      onDestinationSelected: _onSelect,
      animationDuration: const Duration(milliseconds: 200),
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
    );
  }

  bool _heroInFlight(BuildContext context) {
    final sec = ModalRoute.of(context)?.secondaryAnimation;
    if (sec == null) return false;
    return sec.value > 0.001 && sec.value < 0.999;
  }

  Widget _buildPageStack() {
    final w = MediaQuery.of(context).size.width;
    final animating = _animating;
    final t = animating
        ? Curves.easeInOutCubic.transform(_ctrl.value)
        : 1.0;
    final dir = _index > _prevIndex ? -1.0 : 1.0;

    final holdPrev = _heroInFlight(context);

    return Stack(
      children: List.generate(_pages.length, (i) {
        double dx = 0;
        bool visible = false;
        if (i == _index) {
          visible = true;
          if (animating) dx = -dir * w * (1 - t);
        } else if (animating && i == _prevIndex) {
          visible = true;
          dx = dir * w * t;
        } else if (holdPrev && i == _prevIndex) {
          visible = true;
          dx = dir * w;
        }
        return Offstage(
          offstage: !visible,
          child: RepaintBoundary(
            child: TickerMode(
              enabled: visible,
              child: Transform.translate(
                offset: Offset(dx, 0),
                child: _pages[i],
              ),
            ),
          ),
        );
      }),
    );
  }
}

class ShelfIcon extends StatelessWidget {
  final bool filled;
  const ShelfIcon({super.key, required this.filled});

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
