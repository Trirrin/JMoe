import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/app_theme.dart';
import '../widgets/app_icons.dart';
import '../core/models.dart';
import '../core/eh_source.dart';
import '../core/jm_source.dart';
import '../core/source.dart';
import '../widgets/common_widgets.dart';
import '../widgets/scroll_top_fab.dart';
import 'anime_page.dart';
import 'history_page.dart';
import 'novels_page.dart';
import 'more_list_page.dart';
import 'search_page.dart';
import 'unified_detail_page.dart';
import 'week_page.dart';
import '../core/l10n.dart';

/// 统一首页：JM 与 e-hentai 共用同一套布局，仅数据源不同。
class UnifiedHomePage extends StatefulWidget {
  const UnifiedHomePage({super.key});

  @override
  State<UnifiedHomePage> createState() => UnifiedHomePageState();
}

class UnifiedHomePageState extends State<UnifiedHomePage>
    with AutomaticKeepAliveClientMixin {
  final _scroll = ScrollController();

  /// 当前滚动偏移（驱动「回到顶部」按钮）
  double _scrollOffset = 0;

  /// 即将打开的详情页 FAB tag（用于 Hero 衔接）
  String? _pendingFabTag;

  /// 即将打开的封面 Hero tag（与被点击卡片一致，保证起点正确）
  String? _pendingCoverTag;

  /// 海报轮播控制器与自动播放计时器
  late final PageController _bannerCtrl =
      PageController(viewportFraction: 0.88);
  Timer? _bannerTimer;
  int _bannerIndex = 0;

  /// 当前翻页是否由自动轮播触发（用于区分手动滑动）
  bool _bannerAutoTurning = false;

  /// 每个数据源各自的首页缓存（切源时直接复用，不重新请求）
  static final Map<String, HomeFeed> _cache = {};

  /// 已补齐推荐分区的源（true 表示缓存完整，切回时无需任何请求）
  static final Set<String> _cacheComplete = {};

  /// 清空首页缓存（切换内容语言后调用）。
  static void clearCache() {
    _cache.clear();
    _cacheComplete.clear();
  }
  HomeFeed? _feed;
  bool _loading = true;
  bool _deferredLoading = false;
  String? _error;
  ComicSource _source = SourceRegistry.current;

  @override
  bool get wantKeepAlive => true;

  void _onScrollFab() {
    if (!_scroll.hasClients) return;
    final v = _scroll.position.pixels;
    // 仅在「显示/隐藏」边界或较大变化时刷新，避免每帧 setState
    final cross = (v > 400) != (_scrollOffset > 400);
    if (cross || (v - _scrollOffset).abs() > 80) {
      setState(() => _scrollOffset = v);
    }
  }

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScrollFab);
    SourceRegistry.addListener(_onSourceChanged);
    _load();
  }

  /// 上一次的 TickerMode 状态，用于检测「切回发现页」
  bool _bannerTickerOn = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Offstage 会切换 TickerMode；重新可见时重启轮播
    final on = TickerMode.of(context);
    if (on != _bannerTickerOn) {
      _bannerTickerOn = on;
      if (on) {
        _startBannerTimer();
      } else {
        _stopBannerTimer();
      }
    }
  }

  @override
  void dispose() {
    _stopBannerTimer();
    _bannerCtrl.dispose();
    _scroll.removeListener(_onScrollFab);
    SourceRegistry.removeListener(_onSourceChanged);
    _scroll.dispose();
    super.dispose();
  }

  void _onSourceChanged() {
    if (!mounted) return;
    final next = SourceRegistry.current;
    if (next.id == _source.id) return;
    final cached = _cache[next.id];
    final complete = _cacheComplete.contains(next.id);
    setState(() {
      _source = next;
      _error = null;
      if (cached != null) {
        // 命中缓存：立即显示（不闪骨架屏）
        _feed = cached;
        _loading = false;
        _deferredLoading = !complete;
      } else {
        _feed = null;
        _loading = true;
        _deferredLoading = false;
      }
    });
    if (cached == null) {
      _load();
    } else if (!complete) {
      // 缓存不完整：后台静默补齐，界面保持已有内容
      _loadDeferred();
    }
  }

  Future<void> _load({bool force = false}) async {
    if (!mounted) return;
    if (!force) {
      final cached = _cache[_source.id];
      if (cached != null) {
        setState(() {
          _feed = cached;
          _loading = false;
        });
        return;
      }
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final feed = await _source.home();
      if (!mounted) return;
      _cache[_source.id] = feed;
      // 非 JM 源（无 promote 分区）天然完整
      if (_source is! JmSource) _cacheComplete.add(_source.id);
      setState(() {
        _feed = feed;
        _loading = false;
        _deferredLoading = _source is JmSource;
      });
      if (_source is JmSource) _loadDeferred();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  /// 异步补齐推荐分区（promote 响应很大，不阻塞首屏）。
  Future<void> _loadDeferred() async {
    if (_source is! JmSource) {
      _cacheComplete.add(_source.id);
      if (mounted) setState(() => _deferredLoading = false);
      return;
    }
    try {
      final more = await (_source as JmSource).homeDeferred();
      if (!mounted) return;
      final base = _feed;
      if (base == null) return;
      final merged = HomeFeed(
        hero: base.hero,
        sections: [...more, ...base.sections],
        hasMore: base.hasMore,
        nextPage: base.nextPage,
      );
      _cache[_source.id] = merged;
      _cacheComplete.add(_source.id);
      setState(() {
        _feed = merged;
        _deferredLoading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _deferredLoading = false);
    }
  }

  Future<void> _openComic(Comic c, {String? coverTag}) async {
    _pendingFabTag = 'fab_${_source.id}_${c.id}';
    _pendingCoverTag = coverTag ?? 'cover_${_source.id}_${c.id}';
    setState(() {});
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => UnifiedDetailPage(
                      source: _source,
                      comic: c,
                      coverTag: _pendingCoverTag,
                    ),
      ),
    );
    // 返回后清空，避免 tag 残留导致后续转场飞向错误位置
    if (mounted) {
      setState(() {
        _pendingFabTag = null;
        _pendingCoverTag = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Scaffold(
      body: Stack(
        children: [
          RefreshIndicator(
            onRefresh: () => _load(force: true),
            // 扣除状态栏高度：刷新图标从状态栏下方出现
            edgeOffset: MediaQuery.of(context).padding.top,
            child: CustomScrollView(
              key: const PageStorageKey('home_scroll'),
              controller: _scroll,
              physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
              slivers: [
                _buildAppBar(),
                if (_loading)
                  SliverPadding(
                    padding: const EdgeInsets.all(AppStyle.pagePadding),
                    sliver: SliverGrid(
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 3,
                        mainAxisSpacing: 12,
                        crossAxisSpacing: 10,
                        childAspectRatio: 0.54,
                      ),
                      delegate: SliverChildBuilderDelegate(
                        (_, _) => const ShimmerBox(),
                        childCount: 9,
                      ),
                    ),
                  )
                else if (_error != null)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: EmptyView(
                      message: L.tp('loadFailedWith', {'e': '$_error'}),
                      icon: Icons.cloud_off_outlined,
                      onRetry: _load,
                    ),
                  )
                else if (_feed != null) ...[
                  if (_feed!.hero.isNotEmpty) _buildHero(),
                  if (_source.id == 'jm') _buildQuickEntries(),
                  for (final sec in _feed!.sections) _buildSection(sec),
                  if (_deferredLoading)
                    const SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.symmetric(vertical: 24),
                        child: Center(
                          child: SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                      ),
                    ),
                  const SliverToBoxAdapter(child: SizedBox(height: 24)),
                ],
              ],
            ),
          ),
          // 右下角：回到顶部
          Positioned(
            right: 16,
            bottom: 16,
            child: ScrollTopFab(
              scrollOffset: _scrollOffset,
              heroTag: _pendingFabTag,
              onAction: () {
                if (_scroll.hasClients) {
                  _scroll.animateTo(
                    0,
                    duration: const Duration(milliseconds: 420),
                    curve: Curves.easeOutCubic,
                  );
                }
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAppBar() {
    final theme = Theme.of(context);
    return SliverAppBar(
      pinned: true,
      stretch: true,
      expandedHeight: 112,
      titleSpacing: 0,
      backgroundColor: theme.colorScheme.surface,
      surfaceTintColor: Colors.transparent,
      actions: [
        // 关掉水波纹：默认 InkSparkle 在页面 push 期间 splash 不会被清理，
        // 从搜索页返回时会短暂残留「按下」高亮。
        IconButton(
          tooltip: L.t('tabSearch'),
          style: IconButton.styleFrom(
            splashFactory: NoSplash.splashFactory,
            highlightColor: Colors.transparent,
          ),
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const SearchPage(embedded: false)),
          ),
          icon: const Icon(Icons.search_rounded),
        ),
        const SizedBox(width: 4),
      ],
      flexibleSpace: FlexibleSpaceBar(
        collapseMode: CollapseMode.pin,
        titlePadding: const EdgeInsets.only(left: 16, bottom: 14, right: 80),
        title: LayoutBuilder(
          builder: (context, constraints) {
            final t = (1 -
                    ((constraints.maxHeight - kToolbarHeight) / 46.0)
                        .clamp(0.0, 1.0))
                .toDouble();
            final size = lerpDouble(28, 19, t)!;
            return Row(
              children: [
                Text(
                  L.t('tabDiscover'),
                  style: theme.textTheme.headlineMedium?.copyWith(
                    fontSize: size,
                    fontWeight: t < 0.5 ? FontWeight.w700 : FontWeight.w500,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                const SizedBox(width: 10),
                SourceSwitcher(activeId: _source.id),
              ],
            );
          },
        ),
      ),
    );
  }

  /// 快捷入口：动漫 / 小说 / 每周必看 / 书库。
  Widget _buildQuickEntries() {
    // 用 (图标构建器, 文字, 页面) 三元组，避免 Material 图标的斜边瑕疵
    final items = <(Widget Function(Color), String, Widget)>[
      ((c) => AppIcons.anime(size: 21, color: c), L.t('anime'), AnimePage()),
      ((c) => AppIcons.novel(size: 21, color: c), L.t('novels'), NovelsPage()),
      ((c) => Icon(Icons.calendar_view_week_outlined, size: 20, color: c),
          L.t('weeklyMustSee'), WeekPage()),
      ((c) => Icon(Icons.history_rounded, size: 20, color: c),
          L.t('history'), HistoryPage()),
    ];
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 2),
        child: Row(
          children: items.map((e) {
            final scheme = Theme.of(context).colorScheme;
            return Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => e.$3),
                  ),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      children: [
                        e.$1(scheme.primary),
                        const SizedBox(height: 5),
                        Text(
                          e.$2,
                          style: const TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }


  /// 启动海报自动轮播（每 5 秒切一张）。
  void _startBannerTimer() {
    _bannerTimer?.cancel();
    if (!AppState.instance.bannerAutoPlay) return;
    final items = _feed?.hero ?? const [];
    if (items.length <= 1) return;
    _bannerTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted) return;
      // 页面不可见时 Ticker 被禁用，动画不会推进，
      // 此时跳过，等重新可见后由 didChangeDependencies 重启
      if (!TickerMode.of(context)) return;
      if (!_bannerCtrl.hasClients) return;
      final next = (_bannerIndex + 1) % items.length;
      _bannerAutoTurning = true;
      _bannerCtrl
          .animateToPage(
            next,
            duration: const Duration(milliseconds: 520),
            curve: Curves.easeInOutCubic,
          )
          .then((_) => _bannerAutoTurning = false);
    });
  }

  void _stopBannerTimer() => _bannerTimer?.cancel();
  Widget _buildHero() {
    final items = _feed!.hero;
    return SliverToBoxAdapter(
      child: SizedBox(
        height: 250,
        child: PageView.builder(
          controller: _bannerCtrl,
          padEnds: false,
          onPageChanged: (i) {
            _bannerIndex = i;
            // 只有「用户手动滑动」才重置计时；
            // 自动轮播引起的翻页不重置，否则节拍会被不断打断。
            if (!_bannerAutoTurning) _startBannerTimer();
          },
          itemCount: items.length,
          itemBuilder: (context, i) {
            final c = items[i];
            return Padding(
              padding: EdgeInsets.only(
                left: i == 0 ? 16 : 8,
                right: 8,
                top: 6,
                bottom: 6,
              ),
              child: _HeroCard(
                comic: c,
                cover: _source.coverOf(c),
                badge: _source.label,
                heroTag: 'cover_${_source.id}_${c.id}_banner',
                onTap: () => _openComic(
                  c,
                  coverTag: 'cover_${_source.id}_${c.id}_banner',
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildSection(HomeSection s) {
    if (s.items.isEmpty) return const SliverToBoxAdapter();
    return SliverToBoxAdapter(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader(
            title: s.title,
            actionLabel: s.moreKey != null ? L.t('more') : null,
            onAction: s.moreKey == null
                ? null
                : () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => MoreListPage(
                          source: _source,
                          moreKey: s.moreKey!,
                          title: s.title,
                        ),
                      ),
                    ),
          ),
          if (s.grid)
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppStyle.pagePadding,
              ),
              child: GridView.builder(
                shrinkWrap: true,
                // shrinkWrap 网格不允许滚动，否则高度计算异常
                physics: const NeverScrollableScrollPhysics(),
                padding: EdgeInsets.zero,
                gridDelegate:
                    const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 10,
                  // 3:4 封面 + 两行标题 ≈ 0.52
                  childAspectRatio: 0.52,
                ),
                itemCount: s.items.length > 12 ? 12 : s.items.length,
                itemBuilder: (context, i) {
                  final c = s.items[i];
                  return ComicCard(
                    title: c.name,
                    subtitle: c.author,
                    cover: _source.coverOf(c),
                    heat: c.heat == null ? null : '${c.heat}',
                    category: c.category,
                    heroTag: 'cover_${_source.id}_${c.id}_${s.title}',
                    onTap: () => _openComic(
                      c,
                      coverTag: 'cover_${_source.id}_${c.id}_${s.title}',
                    ),
                  );
                },
              ),
            )
          else
            SizedBox(
              height: 208,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(
                  horizontal: AppStyle.pagePadding + 4,
                ),
                cacheExtent: 800,
                itemCount: s.items.length,
                separatorBuilder: (_, _) => const SizedBox(width: 10),
                itemBuilder: (context, i) {
                  final c = s.items[i];
                  return SizedBox(
                    width: 114,
                    child: ComicCard(
                      title: c.name,
                      subtitle: c.author,
                      cover: _source.coverOf(c),
                      heat: c.heat == null ? null : '${c.heat}',
                      category: c.category,
                      heroTag: 'cover_${_source.id}_${c.id}_h_${s.title}',
                      onTap: () => _openComic(
                        c,
                        coverTag: 'cover_${_source.id}_${c.id}_h_${s.title}',
                      ),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

/// 全局数据源注册表（JM / EH 切换，全局共享）。
class SourceRegistry {
  SourceRegistry._();
  static final ValueNotifier<ComicSource> notifier =
      ValueNotifier<ComicSource>(JmSource.instance);

  static ComicSource get current => notifier.value;
  static void set(ComicSource s) => notifier.value = s;
  static void addListener(VoidCallback fn) => notifier.addListener(fn);
  static void removeListener(VoidCallback fn) => notifier.removeListener(fn);
}

/// 统一的源切换控件：高亮块以**非线性缓动平移**（而非淡出淡入）。
class SourceSwitcher extends StatefulWidget {
  final String activeId;
  const SourceSwitcher({super.key, required this.activeId});

  @override
  State<SourceSwitcher> createState() => _SourceSwitcherState();
}

class _SourceSwitcherState extends State<SourceSwitcher> {
  static const _sources = <(String, String)>[
    ('jm', 'JM'),
    ('ehentai', 'EH'),
  ];

  static const _pad = EdgeInsets.symmetric(horizontal: 10, vertical: 4);
  static const _fontSize = 11.0;

  int get _index =>
      _sources.indexWhere((s) => s.$1 == widget.activeId).clamp(0, 1);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(20),
      ),
      child: LayoutBuilder(
        builder: (context, c) {
          // 两段等宽（用文本测量保证宽度自然）
          final widths = _sources.map((s) {
            final tp = TextPainter(
              text: TextSpan(
                text: s.$2,
                style: TextStyle(
                  fontSize: _fontSize,
                  fontWeight: FontWeight.w700,
                ),
              ),
              textDirection: TextDirection.ltr,
            )..layout();
            return tp.width + _pad.horizontal;
          }).toList();
          final segW = widths[_index];
          final totalW = widths.reduce((a, b) => a + b);
          // 高亮块左偏移 = 前面所有段的宽度累加（两段不等宽也准确）
          final leftOffset = _index == 0 ? 0.0 : widths.first;

          return SizedBox(
            height: _fontSize + _pad.vertical + 2,
            width: totalW,
            child: Stack(
              children: [
                // 平移高亮块：easeInOutCubic 非线性缓动
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 380),
                  curve: Curves.easeInOutCubic,
                  left: leftOffset,
                  top: 0,
                  bottom: 0,
                  width: segW,
                  child: Container(
                    decoration: BoxDecoration(
                      color: scheme.primary,
                      borderRadius: BorderRadius.circular(18),
                    ),
                  ),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: _sources.asMap().entries.map((e) {
                    final active = e.key == _index;
                    return GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () {
                        if (active) return;
                        final target = e.value.$1 == 'jm'
                            ? JmSource.instance
                            : EhSource.instance;
                        SourceRegistry.set(target);
                      },
                      child: SizedBox(
                        width: widths[e.key],
                        child: AnimatedDefaultTextStyle(
                          duration: const Duration(milliseconds: 380),
                          curve: Curves.easeInOutCubic,
                          style: TextStyle(
                            fontSize: _fontSize,
                            fontWeight: FontWeight.w700,
                            color: active
                                ? scheme.onPrimary
                                : scheme.onSurfaceVariant,
                          ),
                          child: Padding(
                            padding: _pad,
                            child: Text(
                              e.value.$2,
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _HeroCard extends StatelessWidget {
  final Comic comic;
  final String? cover;
  final String badge;
  final VoidCallback onTap;

  /// 与详情页封面共用的 Hero tag（平滑转场）。
  final String? heroTag;

  const _HeroCard({
    required this.comic,
    required this.cover,
    required this.badge,
    required this.onTap,
    this.heroTag,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (heroTag == null || heroTag!.isEmpty)
            CoverImage(url: cover)
          else
            Hero(
              tag: heroTag!,
              // 飞行层必须带上与卡片相同的圆角，否则转场中会先显示直角，
              // 落地后才被 ClipRRect 裁成圆角（视觉上突变）。
              flightShuttleBuilder:
                  (context, animation, direction, fromCtx, toCtx) => ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: CoverImage(url: cover),
                      ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: CoverImage(url: cover),
              ),
            ),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.transparent, Colors.black87],
                stops: [0.4, 1.0],
              ),
            ),
          ),
          Positioned(
            left: 14,
            right: 14,
            bottom: 12,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (comic.category != null && comic.category!.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      comic.category!,
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: theme.colorScheme.onPrimary,
                      ),
                    ),
                  ),
                const SizedBox(height: 6),
                Text(
                  comic.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    height: 1.3,
                    shadows: [Shadow(blurRadius: 8, color: Colors.black54)],
                  ),
                ),
                if (comic.author.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(
                      comic.author,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 11,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Positioned.fill(
            child: Material(
              color: Colors.transparent,
              child: InkWell(onTap: onTap),
            ),
          ),
        ],
      ),
    );
  }

}