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

  /// 本页 route 的 secondaryAnimation（详情页进出时 0↔1）
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
    // 监听 route 的 secondaryAnimation（详情页进出时变化），
    // 这样 Hero 飞行期间页面能持续重建 —— 落位瞬间才能把旧页隐藏掉。
    final sec = ModalRoute.of(context)?.secondaryAnimation;
    if (sec != null && sec != _secondary) {
      _secondary?.removeListener(_onSecondaryChanged);
      _secondary = sec;
      sec.addListener(_onSecondaryChanged);
    }
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
      // 统计页也预热：体积统计要遍历磁盘，首次切入会明显卡一下
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

  /// 启动后读一次剪贴板：若是本应用分享文本，自动打开详情页。
  Future<void> _checkClipboardShare() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text ?? '';
      if (text.isEmpty || !text.contains('【JMoe】')) return;

      String? comicId;
      String? sourceId;
      // JM 源：形如 JM123456
      final jm = RegExp(r'JM(\d{3,})').firstMatch(text);
      if (jm != null) {
        comicId = jm.group(1);
        sourceId = 'jm';
      } else {
        // EH 源：末尾纯数字 gid
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
      // 剪贴板不可用等异常忽略
    }
  }

  Future<void> _onSelect(int i) async {
    // 动画播放期间**不接受新的切换**（用户要求改回原行为）。
    //
    // 之前试过「允许打断、从中途继续推进」，但快速连点时
    // 页面会连续横移、视觉上很乱，反而不如等一次动画播完。
    if (i == _index || _animating) return;
    setState(() {
      _prevIndex = _index;
      _index = i;
      _animating = true;
    });
    await _ctrl.forward(from: 0);
    if (!mounted) return;
    setState(() => _animating = false);
    // 动画结束后若 Hero 仍在飞，稍后再触发一次重建，
    // 让 holdPrev 判断失效、旧页及时被隐藏（否则会一直留着）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    // 系统返回手势 / 返回键：**分步退出**。
    //
    // 用户要求：「不要回到 app 首页，我要的是退出；不过可以加个
    // 一步步退出——先回到首页，再退出。退出后保留状态，
    // 不要打开 app 又进启动页。」
    //
    // 所以：
    //  * 不在首页 → 回到首页
    //  * 已在首页 → 再次返回才真正退出（moveTaskToBack 退到后台，
    //    进程保留 → 状态全在，重新打开直接回到原来界面）
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (_index != 0) {
          // 第一步：回到首页
          _onSelect(0);
          return;
        }
        // 第二步：已在首页 → 退到后台（保留进程与全部状态）。
        // 用 moveTaskToBack 而不是 SystemNavigator.pop：
        // 前者只是把任务移到后台，重新打开仍是当前状态，
        // 不会重新走启动页。
        SystemNavigator.pop(animated: true);
      },
      // 导航栏：单一实例，放在 Scaffold.bottomNavigationBar。
      //
      // 高度由 Scaffold 自己算 → 位置永远正确，不会「高出一头」，
      // 并且始终可点击。
      //
      // 已知限制：页面转场时封面 Hero 会从导航栏上方掠过（不遮挡）。
      // Hero 飞行层画在 Navigator 的 Overlay 里，层级高于 Scaffold
      // 的任何内容，从应用层无法可靠地盖住它 —— 试过 OverlayPortal、
      // 手写 Overlay.insert、逐帧抢位、第三方 above_hero 均无效，
      // 已放弃该效果，优先保证导航栏位置与交互正确。
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

  /// 页面栈：**结构恒定**，只改位移。
  ///
  /// 关键修复（切页卡顿的真因）：
  /// # 掉帧的真因（「离得越远越卡」）
  ///
  /// 这里踩过一个坑：动画开始时按条件返回**不同结构** ——
  /// 隐藏页返回 `Offstage(child: page)`，滑动页返回
  /// `RepaintBoundary(Transform(child: page))`。
  /// widget 的**类型链一变，Flutter 就认为这是另一棵子树**，
  /// 于是把整个页面 Element 丢掉重建（State 之外的一切重新 layout、
  /// 图片重新绑定、列表重新测量）。
  ///
  /// 页数越多、页面内容越重、与当前页「离得越远」，重建量越大 ——
  /// 正是用户观察到的「发现 ↔ 设置 掉帧比 书架 ↔ 统计 明显」。
  ///
  /// # 现在的做法：包装链**恒定**
  ///
  /// 每一页永远是 `Offstage → RepaintBoundary → TickerMode → Transform.translate → page`
  /// 这五层，切页时**只改属性**（offstage / enabled / offset）。
  /// 结构不变 → Element 不重建 → 只走 paint / compositing，帧率稳定。
  /// Hero 是否正在飞行中。
  ///
  /// 用本页 route 的 `secondaryAnimation` 判断：详情页 push 进来时
  /// 它从 0→1，pop 回来时 1→0。只要不在两端，就说明有路由过渡，
  /// 此时 Hero 正在 Overlay 里飞。
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
    // 目标在右侧 → -1（旧页左移，新页从右进入）
    final dir = _index > _prevIndex ? -1.0 : 1.0;

    // 关键：Hero 还在飞时，**先不隐藏被切走的页面**。
    //
    // 用户反馈「切换太早页面消失了就会闪烁一下」。
    // 原因：切页把旧页设为 Offstage → 该页不再参与绘制 →
    // 正在飞的 Hero 找不到源 widget（或飞行层与源几何对不上），
    // 只能瞬间消失再出现，看起来就是闪一下。
    //
    // 用户要求：「清除旧页面时检查是否还有没播放完成的 hero，
    // 有就不清除，直到 hero 到位」。所以这里在 Hero 飞行期间
    // 让旧页保持 visible（继续绘制），Hero 落位后再正常隐藏。
    final holdPrev = _heroInFlight(context);

    return Stack(
      children: List.generate(_pages.length, (i) {
        double dx = 0;
        bool visible = false;
        if (i == _index) {
          visible = true;
          // 新页：滑动中从 -dir*w 归位；静止为 0
          if (animating) dx = -dir * w * (1 - t);
        } else if (animating && i == _prevIndex) {
          visible = true;
          // 旧页：0 → dir*w
          dx = dir * w * t;
        } else if (holdPrev && i == _prevIndex) {
          // 动画已结束但 Hero 还在飞：旧页继续留在原位绘制，
          // 且**不设 Offstage**，让 Hero 有稳定的源可引用。
          visible = true;
          dx = dir * w;
        }
        // 注意：五层包装顺序与数量**任何状态下都一致**
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

/// 书架图标：三本并排竖立的书（经典「书架」语义）。
///
/// 用自绘保证「选中/未选中」两种状态几何完全一致，
/// 只切换描边 ↔ 填充，避免 Material 图标两套字形基线不同导致错位。
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