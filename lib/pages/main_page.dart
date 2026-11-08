import 'package:flutter/material.dart';
import '../core/models.dart';
import 'unified_detail_page.dart';
import 'package:flutter/services.dart';
import '../core/nav_bar_state.dart';
import '../core/nav_metrics.dart';

import 'unified_categories_page.dart';
import 'unified_home_page.dart';
import 'library_page.dart';
import 'settings_page.dart';
import 'reader_data_page.dart';
import '../core/app_state.dart';
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

  /// 导航栏的 OverlayPortal 控制器（用于压住 Hero 飞行层）
  final _navOverlay = OverlayPortalController();

  void _onSecondaryChanged() {
    if (!mounted) return;
    // 详情页开始 push 时 secondaryAnimation 从 0 上升 → 导航栏此时
    // 必须立刻隐藏（否则飞行过程中底部还留一条导航栏）。
    // pop 回到 0 时恢复显示。
    final sec = _secondary?.value ?? 0;
    final top = sec < 0.001;
    if (NavBarState.instance.visible != top) {
      NavBarState.instance.update(visible: top);
    }
    setState(() {});
  }

  static final _pages = <Widget>[
    const UnifiedHomePage(),
    UnifiedCategoriesPage(key: UnifiedCategoriesPage.catalogKey),
    const LibraryPage(),
    ReaderDataPage(key: ReaderDataPage.statsKey),
    const SettingsPage(),
  ];

  /// 本页是否是当前栈顶路由。
  ///
  /// 只有当主界面在栈顶时才显示导航栏；push 了详情页/阅读器等之后，
  /// 导航栏必须隐藏（否则详情页底部会多出一条导航栏）。
  bool get _isTopRoute {
    final r = ModalRoute.of(context);
    return r?.isCurrent ?? true;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 主界面可见 → 显示全局导航栏，并把点击回调交出去。
    //
    // 导航栏渲染在 MaterialApp.builder 的 Stack 里（Navigator 之外），
    // 层级高于 Hero 飞行层，从而能挡住飞过的封面。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      NavBarState.instance.update(
        index: _index,
        // 只要本页还有别的东西盖在上面（详情页等 push 进来的路由），
        // 就不显示导航栏 —— 否则详情页下面会同时出现一条导航栏。
        visible: _isTopRoute,
        onSelect: _onSelect,
      );
    });
    // 监听 route 的 secondaryAnimation（详情页进出时变化），
    // 这样 Hero 飞行期间页面能持续重建 —— 落位瞬间才能把旧页隐藏掉。
    final sec = ModalRoute.of(context)?.secondaryAnimation;
    if (sec != null && sec != _secondary) {
      _secondary?.removeListener(_onSecondaryChanged);
      _secondary = sec;
      sec.addListener(_onSecondaryChanged);
    }
    // 导航栏通过 OverlayPortal 挂在 Overlay 顶层，需要显式显示。
    if (!_navOverlay.isShowing) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_navOverlay.isShowing) _navOverlay.show();
      });
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
    if (i == _index || _animating) return;
    // 允许立即切换（用户要求「就是要切」）。
    //
    // 闪烁由 _buildPageStack 里的「Hero 未落位则保留旧页」解决，
    // 不需要在这里拦截或排队。
    setState(() {
      _prevIndex = _index;
      _index = i;
      _animating = true;
    });
    // 同步给全局导航栏（它渲染在 Navigator 之外，用来遮挡 Hero 飞行层）
    NavBarState.instance.update(index: i, onSelect: _onSelect);
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
      child: Scaffold(
        body: ClipRect(
          child: AnimatedBuilder(
            animation: _ctrl,
            builder: (context, _) => _buildPageStack(),
          ),
        ),
        // 导航栏**不在这里渲染**（见 GlobalNavBar）。
        //
        // 占位高度必须与 GlobalNavBar 的**总高度**完全一致：
        //   NavigationBar 自身 64（主题 navigationBarTheme.height）
        //   + 底部安全区（手势条）
        // 少算就会让页面内容延伸到导航栏下方并露出来。
        bottomNavigationBar: SizedBox(
          height: NavMetrics.totalHeight(context),
        ),
      ),
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