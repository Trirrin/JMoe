import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/app_state.dart';
import '../core/app_theme.dart';
import '../core/jm_service.dart';
import '../core/jm_source.dart';
import '../core/l10n.dart';
import '../core/models.dart';
import '../core/source.dart';
import '../widgets/common_widgets.dart';
import '../widgets/tag_chip.dart';
import '../widgets/scroll_top_fab.dart';
import 'anime_player_page.dart';
import 'novel_pages.dart';
import 'unified_detail_page.dart';
import 'unified_home_page.dart';

/// 搜索类型：漫画 / 动漫 / 小说（同一个入口与界面，不割裂）。
enum SearchKind { comic, anime, novel }

/// 搜索目标：作品 / 作者（仅漫画板块支持作者检索）
enum SearchTarget { work, author }

/// 统一搜索页：一个入口，切换类型分别检索漫画、动漫、小说。
class SearchPage extends StatefulWidget {
  final bool embedded;

  /// 初始搜索词（从详情页标签跳转时传入）。
  final String? initialQuery;

  /// 初始搜索词是否按「标签」呈现（搜索框内显示为胶囊）。
  final bool initialAsTag;

  /// 初始是否按「作者」检索（从详情页点作者名进入时）。
  final bool initialAuthorMode;

  const SearchPage({
    super.key,
    this.embedded = true,
    this.initialQuery,
    this.initialAsTag = false,
    this.initialAuthorMode = false,
  });

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage>
    with AutomaticKeepAliveClientMixin {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  final _scroll = ScrollController();
  final _service = JmService.instance;

  /// 当前搜索类型
  SearchKind _kind = SearchKind.comic;

  /// 当前搜索目标（作品 / 作者）
  SearchTarget _target = SearchTarget.work;

  /// 作者搜索结果
  final _authors = <Map<String, dynamic>>[];
  bool _authorSearched = false;

  ComicSource _source = SourceRegistry.current;

  /// 记住漫画板块用户选择的源（切到动漫/小说再切回时恢复）
  ComicSource? _comicSource;

  String _order = 'mr';
  bool _loading = false;
  String? _error;
  String _lastQuery = '';

  /// 当前搜索词是否来自点击标签（用于输入框内嵌胶囊显示）
  bool _tagMode = false;

  /// 当前滚动偏移（驱动「回到顶部」按钮）
  double _scrollOffset = 0;

  /// 即将打开的详情页 FAB tag（用于 Hero 衔接）
  String? _pendingFabTag;

  /// 漫画结果
  final _comics = <Comic>[];
  int _comicPage = 1;
  int _comicTotal = 0;
  bool _comicMore = true;

  /// 动漫结果
  final _animes = <Map<String, dynamic>>[];
  int _animePage = 1;
  int _animeTotal = 0;
  bool _animeMore = true;

  /// 小说结果
  final _novels = <Map<String, dynamic>>[];
  bool _novelSearched = false;

  List<String> _hotTags = [];
  final List<String> _history = [];
  static const _historyKey = 'search_history';

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    SourceRegistry.addListener(_onSourceChanged);
    AppState.instance.pendingSearch.addListener(_onPendingSearch);
    _scroll.addListener(_onScroll);
    _comicSource = _source;
    _loadHotTags();
    _loadHistory();
    // 从详情页标签进入：自动填入并检索
    final q0 = widget.initialQuery;
    if (q0 != null && q0.trim().isNotEmpty) {
      _controller.text = q0;
      // 作者模式：切到漫画板块 + 作者检索
      if (widget.initialAuthorMode) {
        _kind = SearchKind.comic;
        _target = SearchTarget.author;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _search(query: q0, asTag: widget.initialAsTag);
      });
    }
  }

  @override
  void dispose() {
    SourceRegistry.removeListener(_onSourceChanged);
    AppState.instance.pendingSearch.removeListener(_onPendingSearch);
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onPendingSearch() {
    final q = AppState.instance.pendingSearch.value;
    if (q == null || q.isEmpty || !mounted || q == _lastQuery) return;
    _controller.text = q;
    _search(query: q, asTag: AppState.instance.pendingSearchAsTag);
  }

  void _onSourceChanged() {
    if (!mounted) return;
    final next = SourceRegistry.current;
    // 仅在漫画板块同步全局源切换
    if (_kind != SearchKind.comic) return;
    if (next.id == _source.id) return;
    setState(() {
      _source = next;
      _comicSource = next;
      _clearResults();
      _lastQuery = '';
    });
  }

  void _clearResults() {
    _comics.clear();
    _animes.clear();
    _novels.clear();
    _comicPage = 1;
    _animePage = 1;
    _comicMore = true;
    _animeMore = true;
    _novelSearched = false;
    _authors.clear();
    _authorSearched = false;
    _comicTotal = 0;
    _animeTotal = 0;
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    // 让「回到顶部」按钮随滚动状态出现/隐藏
    final o = _scroll.position.pixels;
    final cross = (o > 400) != (_scrollOffset > 400);
    if (cross || (o - _scrollOffset).abs() > 80) {
      setState(() => _scrollOffset = o);
    }
    if (o < _scroll.position.maxScrollExtent - 500) {
      return;
    }
    if (_kind == SearchKind.comic && _comicMore) _search(reset: false);
    if (_kind == SearchKind.anime && _animeMore) _searchAnime(reset: false);
  }

  Future<void> _loadHistory() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final list = sp.getStringList(_historyKey) ?? const <String>[];
      if (!mounted) return;
      setState(() {
        _history
          ..clear()
          ..addAll(list);
      });
    } catch (_) {}
  }

  Future<void> _persistHistory() async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setStringList(_historyKey, _history);
    } catch (_) {}
  }

  Future<void> _pushHistory(String q) async {
    if (q.trim().isEmpty) return;
    setState(() {
      _history.remove(q);
      _history.insert(0, q);
      if (_history.length > 30) _history.removeRange(30, _history.length);
    });
    await _persistHistory();
  }

  Future<void> _removeHistory(String q) async {
    setState(() => _history.remove(q));
    await _persistHistory();
  }

  Future<void> _clearHistory() async {
    setState(() => _history.clear());
    await _persistHistory();
  }

  Future<void> _loadHotTags() async {
    final tags = await _service.fetchHotTags();
    if (!mounted) return;
    setState(() => _hotTags = tags);
  }

  Future<void> _search({
    String? query,
    bool reset = true,
    bool asTag = false,
  }) async {
    final q = query ?? _controller.text.trim();
    if (q.isEmpty) return;
    _controller.text = q;
    _focus.unfocus();
    _pushHistory(q);
    setState(() {
      _lastQuery = q;
      _tagMode = asTag;
      _loading = true;
      _error = null;
      if (reset) _clearResults();
    });

    switch (_kind) {
      case SearchKind.comic:
        if (_target == SearchTarget.author) {
          await _searchAuthor(q);
        } else {
          await _searchComic(q, reset: reset);
        }
      case SearchKind.anime:
        await _searchAnime(query: q, reset: reset);
      case SearchKind.novel:
        await _searchNovel(q);
    }
  }

  Future<void> _searchComic(String q, {bool reset = true}) async {
    try {
      final r = await _source.search(q, page: _comicPage, order: _order);
      if (!mounted) return;
      setState(() {
        _comics.addAll(r.items);
        _comicTotal = r.total;
        _comicPage = r.nextPage;
        _comicMore = r.hasMore && r.items.isNotEmpty;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  /// 作者检索（creator_author 接口）。
  Future<void> _searchAuthor(String q) async {
    try {
      final list = await _service.fetchCreators(q);
      if (!mounted) return;
      setState(() {
        _authors
          ..clear()
          ..addAll(list);
        _authorSearched = true;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _searchAnime({String? query, bool reset = true}) async {
    final q = query ?? _lastQuery;
    try {
      final r = await _service.fetchVideosPaged(
        page: _animePage,
        query: q,
        videoType: 'hanime',
      );
      if (!mounted) return;
      setState(() {
        _animes.addAll(r.$1);
        _animeTotal = r.$3;
        _animePage++;
        _animeMore = r.$2;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _searchNovel(String q) async {
    try {
      final list = await _service.searchNovels(q);
      if (!mounted) return;
      setState(() {
        _novels
          ..clear()
          ..addAll(list);
        _novelSearched = true;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  void _switchKind(SearchKind k) {
    if (_kind == k) return;
    // 离开漫画板块前记住当前源
    if (_kind == SearchKind.comic) _comicSource = _source;
    setState(() {
      _kind = k;
      _clearResults();
      _error = null;
      // 动漫/小说为 JM 独有，强制 JM；漫画恢复用户先前选择的源
      if (k == SearchKind.comic) {
        _source = _comicSource ?? JmSource.instance;
      } else {
        _source = JmSource.instance;
      }
    });
    if (_lastQuery.isNotEmpty) _search(query: _lastQuery);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    final body = Stack(
      children: [
        Column(
          children: [
            // 滚动后：搜索栏收缩为右侧小胶囊；类别栏淡出
            _buildCollapsibleSearchArea(theme),
            Expanded(
              child: _lastQuery.isEmpty
                  ? _buildSuggestions(theme)
                  : _buildResults(theme),
            ),
          ],
        ),
        // 右下角：回到顶部（未进入详情时）
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
    );
    if (!widget.embedded) {
      return Scaffold(
        appBar: AppBar(title: Text(L.t('tabSearch'))),
        body: SafeArea(child: body),
      );
    }
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
              child: Row(
                children: [
                  Text(
                    L.t('tabSearch'),
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(child: body),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchBar(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
            child: _tagMode && _controller.text.isNotEmpty
                ? _buildTagInputField()
                : TextField(
                    controller: _controller,
                    focusNode: _focus,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => _search(asTag: true),
                    decoration: InputDecoration(
                      hintText: _kind == SearchKind.comic
                          ? (_target == SearchTarget.work
                              ? L.t('searchWorkHint')
                              : L.t('searchAuthorHint'))
                          : (_kind == SearchKind.anime
                              ? L.t('searchVideoHint')
                              : L.t('searchNovelHint')),
                      prefixIcon: const Icon(Icons.search, size: 20),
                      suffixIcon: _controller.text.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.clear, size: 18),
                              onPressed: () {
                                _controller.clear();
                                setState(() {
                                  _lastQuery = '';
                                  _tagMode = false;
                                  _clearResults();
                                });
                              },
                            ),
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              // 作品 / 作者 单选（仅漫画板块）
              if (_kind == SearchKind.comic) _targetToggle(),
              const Spacer(),
              FilledButton(
                onPressed: () => _search(asTag: true),
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, 40),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 22, vertical: 10),
                ),
                child: Text(L.t('tabSearch')),
              ),
            ],
          ),
        ],
      ),
    );
  }


  /// 标签模式下的搜索框：内部以 #标签 胶囊呈现，可一键清除。
  /// 可收缩的搜索区：
  /// - 顶部时正常显示搜索框 + 类别栏
  /// - 上滑后搜索框缩小成一个靠右的胶囊按钮，点击回顶展开
  Widget _buildCollapsibleSearchArea(ThemeData theme) {
    final collapsed = _scrollOffset > 160;
    final t = ((_scrollOffset - 120) / 240).clamp(0.0, 1.0);

    if (collapsed) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
        child: Align(
          alignment: Alignment.centerRight,
          child: GestureDetector(
            onTap: () {
              if (_scroll.hasClients) {
                _scroll.animateTo(
                  0,
                  duration: const Duration(milliseconds: 420),
                  curve: Curves.easeOutCubic,
                );
              }
              _focus.requestFocus();
            },
            child: Material(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(999),
              elevation: 2,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.search_rounded,
                      size: 17,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    if (_controller.text.isNotEmpty) ...[
                      const SizedBox(width: 6),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 130),
                        child: Text(
                          _controller.text,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Opacity(
      // 接近收缩阈值时淡出，避免突变
      opacity: 1 - t,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildSearchBar(theme),
          _buildKindBar(theme),
        ],
      ),
    );
  }

  Widget _buildTagInputField() {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        children: [
          Icon(Icons.search, size: 18, color: scheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Flexible(
            child: Align(
              alignment: Alignment.centerLeft,
              child: TagChip(tag: _controller.text),
            ),
          ),
          const Spacer(),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: Icon(
              Icons.close_rounded,
              size: 17,
              color: scheme.onSurfaceVariant,
            ),
            onPressed: () {
              _controller.clear();
              setState(() {
                _lastQuery = '';
                _tagMode = false;
                _clearResults();
              });
              _focus.requestFocus();
            },
          ),
        ],
      ),
    );
  }

  /// 作品 / 作者 切换：两段式，高亮块在两者之间平滑滑动。
  Widget _targetToggle() {
    final scheme = Theme.of(context).colorScheme;
    const segW = 52.0;
    const segH = 26.0;
    final idx = _target == SearchTarget.work ? 0 : 1;
    const labels = <String>['searchWork', 'searchAuthor'];

    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(9),
      ),
      child: SizedBox(
        width: segW * 2,
        height: segH,
        child: Stack(
          children: [
            // 高亮块：easeInOutCubic 平滑滑动
            AnimatedPositioned(
              duration: const Duration(milliseconds: 280),
              curve: Curves.easeInOutCubic,
              left: idx * segW,
              top: 0,
              bottom: 0,
              width: segW,
              child: Container(
                decoration: BoxDecoration(
                  color: scheme.primary,
                  borderRadius: BorderRadius.circular(7),
                ),
              ),
            ),
            Row(
              children: List.generate(2, (i) {
                final active = i == idx;
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    if (active) return;
                    setState(() {
                      _target = i == 0
                          ? SearchTarget.work
                          : SearchTarget.author;
                      _clearResults();
                      _authorSearched = false;
                    });
                    if (_lastQuery.isNotEmpty) _search(query: _lastQuery);
                  },
                  child: SizedBox(
                    width: segW,
                    height: segH,
                    child: Center(
                      child: AnimatedDefaultTextStyle(
                        duration: const Duration(milliseconds: 280),
                        curve: Curves.easeInOutCubic,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: active
                              ? scheme.onPrimary
                              : scheme.onSurfaceVariant,
                        ),
                        child: Text(L.t(labels[i])),
                      ),
                    ),
                  ),
                );
              }),
            ),
          ],
        ),
      ),
    );
  }

  /// 类型切换 + 源切换（漫画时才显示源/排序）
  Widget _buildKindBar(ThemeData theme) {
    final scheme = theme.colorScheme;
    Widget chip(SearchKind k, String label) {
      final active = _kind == k;
      return Padding(
        padding: const EdgeInsets.only(right: 8),
        child: ChoiceChip(
          label: Text(label, style: const TextStyle(fontSize: 12)),
          selected: active,
          onSelected: (_) => _switchKind(k),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 6),
      child: Row(
        children: [
          chip(SearchKind.comic, L.t('searchComic')),
          chip(SearchKind.anime, L.t('anime')),
          chip(SearchKind.novel, L.t('novels')),
          const Spacer(),
          // 动漫与小说为 JM 独有：此时仍显示源切换但 EH 置灰
          if (_kind == SearchKind.comic)
            SourceSwitcher(activeId: _source.id)
          else
            IgnorePointer(
              child: Opacity(
                opacity: 0.4,
                child: SourceSwitcher(activeId: _source.id),
              ),
            ),
          if (_kind == SearchKind.comic) ...[
            const SizedBox(width: 6),
            const SizedBox(width: 6),
            PopupMenuButton<String>(
              initialValue: _order,
              onSelected: (v) {
                setState(() => _order = v);
                if (_lastQuery.isNotEmpty) _search(query: _lastQuery);
              },
              itemBuilder: (_) => [
                PopupMenuItem(value: 'mr', child: Text(L.t('sortLatest'))),
                PopupMenuItem(value: 'mv', child: Text(L.t('sortPopular'))),
                PopupMenuItem(value: 'tf', child: Text(L.t('sortRating'))),
              ],
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      {
                        'mr': L.t('sortLatest'),
                        'mv': L.t('sortPopular'),
                        'tf': L.t('sortRating'),
                      }[_order]!,
                      style: const TextStyle(fontSize: 11),
                    ),
                    const Icon(Icons.arrow_drop_down, size: 15),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSuggestions(ThemeData theme) {
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      children: [
        if (_history.isNotEmpty) ...[
          Row(
            children: [
              Text(
                L.t('searchHistory'),
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              TextButton(
                onPressed: _clearHistory,
                child: Text(L.t('clear')),
              ),
            ],
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _history
                .map(
                  (h) => _SearchChip(
                    label: h,
                    onTap: () => _search(query: h, asTag: true),
                    onDelete: () => _removeHistory(h),
                  ),
                )
                .toList(),
          ),
          const SizedBox(height: 18),
        ],
        if (_hotTags.isNotEmpty && _kind == SearchKind.comic) ...[
          Text(
            L.t('hotTags'),
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _hotTags
                .map(
                  (t) => _SearchChip(
                    label: t,
                    onTap: () => _search(query: t, asTag: true),
                  ),
                )
                .toList(),
          ),
        ],
      ],
    );
  }

  Widget _buildResults(ThemeData theme) {
    if (_loading) {
      final empty = switch (_kind) {
        SearchKind.comic => _comics.isEmpty,
        SearchKind.anime => _animes.isEmpty,
        SearchKind.novel => !_novelSearched,
      };
      if (empty) return const Center(child: CircularProgressIndicator());
    }
    final err = _error;
    if (err != null) {
      return EmptyView(message: err, onRetry: () => _search());
    }
    switch (_kind) {
      case SearchKind.comic:
        if (_target == SearchTarget.author) return _buildAuthorResults(theme);
        return _buildComicResults(theme);
      case SearchKind.anime:
        return _buildAnimeResults(theme);
      case SearchKind.novel:
        return _buildNovelResults(theme);
    }
  }

  /// 作者列表（点击进入该作者的作品列表）。
  Widget _buildAuthorResults(ThemeData theme) {
    if (!_authorSearched) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_authors.isEmpty) {
      return EmptyView(
        message: L.t('noSearchResult'),
        icon: Icons.person_search_outlined,
      );
    }
    final host = JmService.instance.imgHost;
    return ListView.separated(
      padding: const EdgeInsets.all(AppStyle.pagePadding),
      itemCount: _authors.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, i) {
        final a = _authors[i];
        final avatar = '${a['avatar'] ?? a['photo'] ?? ''}';
        final url = avatar.isEmpty
            ? null
            : (avatar.startsWith('http') ? avatar : '$host/media/user/$avatar');
        final name = '${a['name'] ?? a['author'] ?? a['username'] ?? ''}';
        final works = '${a['works_count'] ?? a['count'] ?? ''}';
        return Card(
          child: ListTile(
            leading: SizedBox(
              width: 40,
              height: 40,
              child: CoverImage(
                url: url,
                borderRadius: BorderRadius.circular(20),
                memCacheWidth: 120,
              ),
            ),
            title: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            subtitle: works.isNotEmpty
                ? Text(
                    L.tp('worksCount', {'n': works}),
                    style: const TextStyle(fontSize: 11),
                  )
                : null,
            trailing: const Icon(Icons.chevron_right, size: 18),
            onTap: () {
              // 用作者名做作品搜索
              setState(() => _target = SearchTarget.work);
              _search(query: name);
            },
          ),
        );
      },
    );
  }

  Widget _buildComicResults(ThemeData theme) {
    if (_comics.isEmpty) {
      return EmptyView(
        message: L.t('noSearchResult'),
        icon: Icons.search_off,
      );
    }
    return Column(
      children: [
        if (_comicTotal > 0)
          _countBar(theme, L.tp('searchResultCount', {'n': _comicTotal})),
        Expanded(
          child: ComicGrid(
            items: _comics,
            coverOf: _source.coverOf,
            loadingCount: _comicMore ? 3 : 0,
            onTap: (c) async {
              _pendingFabTag = 'fab_${_source.id}_${c.id}';
              setState(() {});
              await Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => UnifiedDetailPage(
                    source: _source,
                    comic: c,
                    // 与 ComicGrid 内部生成的封面 tag 保持一致，
                    // 这样搜索结果点进去也有封面平滑转场
                    coverTag: 'cover_${c.source}_${c.id}',
                  ),
                ),
              );
              // 返回后立即清空，防止 tag 残留影响后续转场
              if (mounted) setState(() => _pendingFabTag = null);
            },
          ),
        ),
      ],
    );
  }

  Widget _buildAnimeResults(ThemeData theme) {
    if (_animes.isEmpty) {
      return EmptyView(message: L.t('noAnime'), icon: Icons.movie_outlined);
    }
    final host = JmService.instance.imgHost;
    return Column(
      children: [
        if (_animeTotal > 0)
          _countBar(theme, '${_animes.length}/$_animeTotal'),
        Expanded(
          child: GridView.builder(
            controller: _scroll,
            padding: const EdgeInsets.all(AppStyle.pagePadding),
            cacheExtent: 1000,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              mainAxisSpacing: 12,
              crossAxisSpacing: 10,
              childAspectRatio: 0.74,
            ),
            itemCount: _animes.length + (_animeMore ? 2 : 0),
            itemBuilder: (context, i) {
              if (i >= _animes.length) return const ShimmerBox();
              final v = _animes[i];
              final p = '${v['photo'] ?? v['photo_str'] ?? ''}';
              final cover = p.isEmpty
                  ? null
                  : (p.startsWith('http') ? p : '$host$p');
              return InkWell(
                borderRadius: BorderRadius.circular(AppStyle.cardRadius),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => AnimePlayerPage(
                      id: '${v['id']}',
                      title: '${v['title'] ?? ''}',
                      playlist: _animes
                          .map((e) => {
                                'id': '${e['id']}',
                                'title': '${e['title'] ?? ''}',
                              })
                          .toList(),
                      playlistIndex: i,
                    ),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          CoverImage(
                            url: cover,
                            borderRadius: BorderRadius.circular(
                              AppStyle.cardRadius,
                            ),
                          ),
                          const Center(
                            child: Icon(
                              Icons.play_circle_fill_rounded,
                              color: Colors.white70,
                              size: 40,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '${v['title'] ?? ''}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        height: 1.3,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildNovelResults(ThemeData theme) {
    if (!_novelSearched || _novels.isEmpty) {
      return EmptyView(
        message: L.t('noSearchResult'),
        icon: Icons.search_off,
      );
    }
    return Column(
      children: [
        _countBar(theme, '${_novels.length}'),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.all(AppStyle.pagePadding),
            itemCount: _novels.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (context, i) {
              final n = _novels[i];
              final img = '${n['image'] ?? ''}';
              return Card(
                child: ListTile(
                  leading: SizedBox(
                    width: 48,
                    height: 64,
                    child: CoverImage(
                      url: img.isEmpty ? null : img,
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                  title: Text(
                    '${n['name'] ?? ''}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  subtitle: Text(
                    '${n['author'] ?? ''}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11),
                  ),
                  trailing: const Icon(Icons.chevron_right, size: 18),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => NovelDetailPage(
                        nid: '${n['id']}',
                        title: '${n['name'] ?? ''}',
                        cover: '${n['image'] ?? ''}',
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _countBar(ThemeData theme, String text) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 11,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

/// 搜索历史 / 热词胶囊：小块背景 + 可选删除按钮。
class _SearchChip extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  final VoidCallback? onDelete;
  const _SearchChip({required this.label, required this.onTap, this.onDelete});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.primaryContainer.withValues(alpha: 0.55),
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.fromLTRB(13, 7, onDelete == null ? 13 : 6, 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 180),
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.2,
                    fontWeight: FontWeight.w500,
                    color: scheme.onPrimaryContainer,
                  ),
                ),
              ),
              if (onDelete != null) ...[
                const SizedBox(width: 2),
                GestureDetector(
                  onTap: onDelete,
                  behavior: HitTestBehavior.opaque,
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Icon(
                      Icons.close_rounded,
                      size: 13,
                      color: scheme.onPrimaryContainer.withValues(alpha: 0.7),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
