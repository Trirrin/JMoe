import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/app_theme.dart';
import '../core/models.dart';
import '../core/source.dart';
import '../widgets/common_widgets.dart';
import '../widgets/scroll_top_fab.dart';
import '../widgets/marquee_text.dart';
import 'unified_detail_page.dart';
import 'unified_home_page.dart';
import '../core/l10n.dart';

class UnifiedCategoriesPage extends StatefulWidget {
  static final GlobalKey<State<UnifiedCategoriesPage>> catalogKey =
      GlobalKey<State<UnifiedCategoriesPage>>();

  static void precacheNow() {
    final st = catalogKey.currentState;
    if (st == null) return;
    (st as dynamic).precache();
  }

  const UnifiedCategoriesPage({super.key});

  @override
  State<UnifiedCategoriesPage> createState() => _UnifiedCategoriesPageState();
}

class _UnifiedCategoriesPageState extends State<UnifiedCategoriesPage>
    with AutomaticKeepAliveClientMixin {
  ComicSource _source = SourceRegistry.current;
  static final Map<String, List<BrowseCategory>> _catCache = {};
  static final Map<String, List<Comic>> _listCache = {};
  List<BrowseCategory> _cats = [];
  bool _loading = true;

  double _scrollOffset = 0;
  String? _error;

  BrowseCategory? _current;
  String? _currentSub;
  String _order = 'mr';

  final _items = <Comic>[];
  int _page = 1;
  int _total = 0;
  bool _listLoading = false;
  bool _hasMore = true;

  static final _orders = [
    ('mr', L.t('sortLatest')),
    ('mv', L.t('sortPopular')),
    ('tf', L.t('sortRating')),
    ('tr', L.t('sortNewest')),
  ];

  Future<void> precache() async {
    if (_catCache[_source.id]?.isNotEmpty == true &&
        (_listCache[_source.id]?.isNotEmpty == true)) {
      return;
    }
    try {
      if (_catCache[_source.id]?.isEmpty ?? true) {
        final cats = await _source.categories();
        _catCache[_source.id] = cats;
      }
      final cats = _catCache[_source.id];
      if (cats == null || cats.isEmpty) return;
      final first = _current ?? cats.first;
      _current = first;
      _listCache[_source.id] ??= [];
      if (_listCache[_source.id]!.isEmpty) {
        final r = await _source.browse(
          category: first.slug,
          sub: _currentSub,
          page: 1,
          order: _order,
        );
        _listCache[_source.id] = r.items;
      }
      if (mounted) {
        setState(() {
          _cats = cats;
          _current = first;
          if (_items.isEmpty) _items.addAll(_listCache[_source.id] ?? const []);
          _loading = false;
        });
      }
    } catch (_) {}
  }

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    SourceRegistry.addListener(_onSourceChanged);
    _loadCats();
  }

  @override
  void dispose() {
    SourceRegistry.removeListener(_onSourceChanged);
    super.dispose();
  }

  void _onSourceChanged() {
    if (!mounted) return;
    final next = SourceRegistry.current;
    if (next.id == _source.id) return;
    final cachedCats = _catCache[next.id];
    if (cachedCats != null && cachedCats.isNotEmpty) {
      setState(() {
        _source = next;
        _cats = cachedCats;
        _current = cachedCats.first;
        _currentSub = null;
        _items
          ..clear()
          ..addAll(_listCache[next.id] ?? const []);
        _loading = false;
      });
      if (_items.isEmpty) _loadList(reset: true);
      return;
    }
    setState(() {
      _source = next;
      _cats = [];
      _current = null;
      _currentSub = null;
      _items.clear();
      _loading = true;
    });
    _loadCats();
  }

  Future<void> _loadCats() async {
    try {
      final cats = await _source.categories();
      if (!mounted) return;
      _catCache[_source.id] = cats;
      setState(() {
        _cats = cats;
        _loading = false;
        _current = cats.isNotEmpty ? cats.first : null;
      });
      if (_current != null) _loadList(reset: true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _loadList({bool reset = false}) async {
    if (_current == null || _listLoading) return;
    if (reset) {
      setState(() {
        _items.clear();
        _page = 1;
        _hasMore = true;
        _total = 0;
      });
    }
    if (!_hasMore && !reset) return;
    setState(() => _listLoading = true);
    final r = await _source.browse(
      category: _current!.slug,
      sub: _currentSub,
      page: _page,
      order: _order,
    );
    if (!mounted) return;
    setState(() {
      _items.addAll(r.items);
      _listCache[_source.id] = List.of(_items);
      _total = r.total;
      _page = r.nextPage;
      _hasMore = r.hasMore && r.items.isNotEmpty;
      _listLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    if (AppState.instance.offlineMode) {
      return Scaffold(
        body: EmptyView(
          message: L.t('offlineNoOnlineContent'),
          icon: Icons.cloud_off_rounded,
        ),
      );
    }
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_error != null) {
      return Scaffold(
        body: EmptyView(message: L.tp('categoryLoadFailed', {'e': '$_error'}), onRetry: _loadCats),
      );
    }
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Stack(
          children: [
            Row(
              children: [
                _buildSidebar(theme),
                Expanded(
                  child: RefreshIndicator(
                    onRefresh: () async {
                      await _loadCats();
                      await _loadList(reset: true);
                    },
                    edgeOffset: MediaQuery.of(context).padding.top,
                    child: NotificationListener<ScrollNotification>(
                      onNotification: (n) {
                        final o = n.metrics.pixels;
                        final cross = (o > 400) != (_scrollOffset > 400);
                        if (cross || (o - _scrollOffset).abs() > 80) {
                          setState(() => _scrollOffset = o);
                        }
                        return false;
                      },
                      child: _buildContent(theme),
                    ),
                  ),
                ),
              ],
            ),
            Positioned(
              right: 16,
              bottom: 16,
              child: ScrollTopFab(
                scrollOffset: _scrollOffset,
                onAction: () => _scrollToListTop(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _scrollToListTop() {
    final pos = PrimaryScrollController.maybeOf(context);
    if (pos != null && pos.hasClients) {
      pos.animateTo(
        0,
        duration: const Duration(milliseconds: 420),
        curve: Curves.easeOutCubic,
      );
      return;
    }
    final states = Scrollable.maybeOf(context);
    states?.position.animateTo(
      0,
      duration: const Duration(milliseconds: 420),
      curve: Curves.easeOutCubic,
    );
  }

  Widget _buildSidebar(ThemeData theme) {
    final scheme = theme.colorScheme;
    final wide = _cats.any((c) => c.label.contains('\n'));
    return Container(
      width: wide ? 96 : 88,
      color: scheme.surfaceContainerLow,
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 8),
        cacheExtent: 600,
        itemCount: _cats.length,
        itemBuilder: (context, i) {
          final c = _cats[i];
          final active = _current?.id == c.id;
          final lines = c.label.split('\n');
          return InkWell(
            onTap: () {
              setState(() {
                _current = c;
                _currentSub = null;
              });
              _loadList(reset: true);
            },
            child: AnimatedContainer(
              duration: AppStyle.animFast,
              margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 11),
              decoration: BoxDecoration(
                color: active ? scheme.primaryContainer : Colors.transparent,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  MarqueeText(
                    lines.first,
                    velocity: 18,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                      color: active
                          ? scheme.onPrimaryContainer
                          : scheme.onSurfaceVariant,
                    ),
                  ),
                  if (lines.length > 1)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        lines[1],
                        style: TextStyle(
                          fontSize: 10,
                          color:
                              scheme.onSurfaceVariant.withValues(alpha: 0.75),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildContent(ThemeData theme) {
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _current?.label.split('\n').first ?? '',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              PopupMenuButton<String>(
                initialValue: _order,
                onSelected: (v) {
                  setState(() => _order = v);
                  _loadList(reset: true);
                },
                itemBuilder: (_) => _orders
                    .map(
                      (o) => PopupMenuItem(value: o.$1, child: Text(o.$2)),
                    )
                    .toList(),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _orders
                            .firstWhere(
                              (o) => o.$1 == _order,
                              orElse: () => _orders.first,
                            )
                            .$2,
                        style: const TextStyle(fontSize: 12),
                      ),
                      const Icon(Icons.arrow_drop_down, size: 16),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        if (_current != null && _current!.subs.isNotEmpty)
          SizedBox(
            height: 42,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.symmetric(horizontal: 12),
              children: [
                Padding(
                  padding: EdgeInsets.only(right: 8, top: 6),
                  child: ChoiceChip(
                    label: Text(L.t('all'), style: TextStyle(fontSize: 12)),
                    selected: _currentSub == null,
                    onSelected: (_) {
                      setState(() => _currentSub = null);
                      _loadList(reset: true);
                    },
                  ),
                ),
                ..._current!.subs.map(
                  (s) => Padding(
                    padding: const EdgeInsets.only(right: 8, top: 6),
                    child: ChoiceChip(
                      label: Text(
                        s.label,
                        style: const TextStyle(fontSize: 12),
                      ),
                      selected: _currentSub == s.slug,
                      onSelected: (_) {
                        setState(() => _currentSub = s.slug);
                        _loadList(reset: true);
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
        if (_total > 0)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
            child: Text(
              L.tp('totalWorksN', {'n': _total}),
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
          ),
        Expanded(
          child: NotificationListener<ScrollNotification>(
            onNotification: (n) {
              if (n.metrics.pixels > n.metrics.maxScrollExtent - 500) {
                _loadList();
              }
              return false;
            },
            child: _items.isEmpty && _listLoading
                ? Center(child: CircularProgressIndicator())
                : _items.isEmpty
                    ? EmptyView(message: L.t('empty'))
                    : AnimatedSwitcher(
                        duration: const Duration(milliseconds: 220),
                        child: ComicGrid(
                          key: PageStorageKey(
                            'catalog_${_current?.id}_$_currentSub',
                          ),
                          items: _items,
                          coverOf: _source.coverOf,
                          crossAxisCount: 2,
                          loadingCount: _hasMore ? 2 : 0,
                          onTap: (c) => Navigator.of(context).push(
                            MaterialPageRoute(builder: (_) =>
                                  UnifiedDetailPage(source: _source, comic: c),
                            ),
                          ),
                        ),
                      ),
          ),
        ),
      ],
    );
  }
}
