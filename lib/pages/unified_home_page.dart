import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/app_theme.dart';
import '../widgets/detail_route.dart';
import '../widgets/app_icons.dart';
import '../core/models.dart';
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

class UnifiedHomePage extends StatefulWidget {
  const UnifiedHomePage({super.key});

  @override
  State<UnifiedHomePage> createState() => UnifiedHomePageState();
}

class UnifiedHomePageState extends State<UnifiedHomePage>
    with AutomaticKeepAliveClientMixin {
  final _scroll = ScrollController();

  double _scrollOffset = 0;

  String? _pendingFabTag;

  String? _pendingCoverTag;

  late final PageController _bannerCtrl =
      PageController(viewportFraction: 0.88);
  Timer? _bannerTimer;
  int _bannerIndex = 0;

  bool _bannerAutoTurning = false;

  static final Map<String, HomeFeed> _cache = {};

  static final Set<String> _cacheComplete = {};

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

  bool _bannerTickerOn = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
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
    final hasCache = cached != null && cached.sections.isNotEmpty;
    setState(() {
      _source = next;
      _error = null;
      _feed = hasCache ? cached : null;
      _loading = !hasCache;
      _deferredLoading = hasCache && !_cacheComplete.contains(next.id);
    });
    _load();
  }

  Future<void> _load({bool force = false}) async {
    if (!mounted) return;
    if (AppState.instance.offlineMode) {
      setState(() {
        _loading = false;
        _feed = null;
        _error = null;
      });
      return;
    }

    final cached = _cache[_source.id];
    final hasCache = !force && cached != null && cached.sections.isNotEmpty;
    if (hasCache) {
      setState(() {
        _feed = cached;
        _loading = false;
        _error = null;
        _deferredLoading = !_cacheComplete.contains(_source.id);
      });
    } else {
      setState(() {
        _loading = true;
        _feed = null;
        _error = null;
      });
    }

    try {
      final feed = await _source.home();
      if (!mounted) return;
      _cache[_source.id] = feed;
      if (_source is! JmSource) _cacheComplete.add(_source.id);
      setState(() {
        _feed = feed;
        _loading = false;
        _deferredLoading = _source is JmSource;
      });
      if (_source is JmSource) _loadDeferred();
    } catch (e) {
      if (!mounted) return;
      if (hasCache) {
        setState(() => _deferredLoading = false);
        return;
      }
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

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
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    await Navigator.of(context).push(
      detailRoute(builder: (_) => UnifiedDetailPage(
          source: _source,
          comic: c,
          coverTag: _pendingCoverTag,
        ),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 620));
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
            edgeOffset: MediaQuery.of(context).padding.top,
            child: CustomScrollView(
              key: const PageStorageKey('home_scroll'),
              controller: _scroll,
              physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
              slivers: [
                _buildAppBar(),
                if (_loading)
                  SliverToBoxAdapter(child: _buildSkeleton())
                else if (_error != null)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: EmptyView(
                      message: L.tp('loadFailedWith', {'e': '$_error'}),
                      icon: Icons.cloud_off_outlined,
                      onRetry: _load,
                    ),
                  )
                else if (AppState.instance.offlineMode)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: EmptyView(
                      message: L.t('offlineNoOnlineContent'),
                      icon: Icons.cloud_off_rounded,
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
        titlePadding: const EdgeInsets.only(left: 16, bottom: 14, right: 72),
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedBuilder(
              animation: _scroll,
              builder: (context, _) {
                final v = _scroll.hasClients ? _scroll.position.pixels : 0.0;
                final t = (v / 46.0).clamp(0.0, 1.0).toDouble();
                final size = lerpDouble(28, 19, t)!;
                return Text(
                  L.t('tabDiscover'),
                  style: theme.textTheme.headlineMedium?.copyWith(
                    fontSize: size,
                    fontWeight: FontWeight.w700,
                    color: theme.colorScheme.onSurface,
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildQuickEntries() {
    final items = <(Widget Function(Color), String, Widget)>[
      ((c) => AppIcons.anime(size: 21, color: c), L.t('anime'), AnimePage()),
      ((c) => AppIcons.novel(size: 21, color: c), L.t('novels'), NovelsPage()),
      ((c) => Icon(Icons.auto_awesome_rounded, size: 20, color: c),
          L.t('weeklyMustSee'), WeekPage()),      ((c) => Icon(Icons.history_rounded, size: 20, color: c),
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

  void _startBannerTimer() {
    _bannerTimer?.cancel();
    if (!AppState.instance.bannerAutoPlay) return;
    final items = _feed?.hero ?? const [];
    if (items.length <= 1) return;
    _bannerTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted) return;
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

  Widget _buildSkeleton() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppStyle.pagePadding,
        8,
        AppStyle.pagePadding,
        0,
      ),
      child: LayoutBuilder(
        builder: (context, box) {
          const cols = 3;
          const gap = 8.0;
          final cardW = (box.maxWidth - gap * (cols - 1)) / cols;
          return Wrap(
            spacing: gap,
            runSpacing: 10,
            children: [
              for (var i = 0; i < 9; i++)
                SizedBox(
                  width: cardW,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AspectRatio(
                        aspectRatio: 3 / 4,
                        child: ClipRRect(
                          borderRadius:
                              BorderRadius.circular(AppStyle.cardRadius),
                          child: const ShimmerBox(),
                        ),
                      ),
                      const SizedBox(height: 6),
                      const ShimmerBox(height: 14, radius: 4),
                      const SizedBox(height: 4),
                      FractionallySizedBox(
                        widthFactor: 0.6,
                        child: const ShimmerBox(height: 11, radius: 4),
                      ),
                      const SizedBox(height: 6),
                      FractionallySizedBox(
                        widthFactor: 0.4,
                        child: const ShimmerBox(height: 11, radius: 4),
                      ),
                    ],
                  ),
                ),
            ],
          );
        },
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
              child: LayoutBuilder(
                builder: (context, box) {
                  const cols = 3;
                  const gap = 8.0;
                  final cardW = (box.maxWidth - gap * (cols - 1)) / cols;
                  final items = s.items.length > 12 ? 12 : s.items.length;
                  return Wrap(
                    spacing: gap,
                    runSpacing: 10,
                    children: [
                      for (var i = 0; i < items; i++)
                        SizedBox(
                          width: cardW,
                          child: Builder(
                            builder: (context) {
                              final c = s.items[i];
                              final tag =
                                  'cover_${_source.id}_${c.id}_${s.title}';
                              return ComicCard(
                                title: c.name,
                                subtitle: c.author,
                                cover: _source.coverOf(c),
                                heat: c.heat == null ? null : '${c.heat}',
                                category: c.category,
                                heroTag: tag,
                                onTap: () =>
                                    _openComic(c, coverTag: tag),
                              );
                            },
                          ),
                        ),
                    ],
                  );
                },
              ),
            )
          else
            SizedBox(
              height: 208,
              child: ListView.separated(
                key: PageStorageKey('hrow_${_source.id}_${s.title}'),
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

class SourceRegistry {
  SourceRegistry._();
  static final ValueNotifier<ComicSource> notifier =
      ValueNotifier<ComicSource>(JmSource.instance);

  static ComicSource get current => JmSource.instance;
  static void set(ComicSource s) {
    if (s.id != 'jm') return;
    notifier.value = s;
  }

  static void addListener(VoidCallback fn) => notifier.addListener(fn);
  static void removeListener(VoidCallback fn) => notifier.removeListener(fn);
}

class SourceSwitcher extends StatelessWidget {
  final String activeId;
  const SourceSwitcher({super.key, required this.activeId});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: scheme.primary,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        'JM',
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: scheme.onPrimary,
        ),
      ),
    );
  }
}
class _HeroCard extends StatelessWidget {
  final Comic comic;
  final String? cover;
  final String badge;
  final VoidCallback onTap;

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
