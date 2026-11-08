import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/app_state.dart';
import '../core/app_theme.dart';
import '../core/jm_service.dart';
import '../core/jm_source.dart';
import '../core/l10n.dart';
import '../core/models.dart';
import '../core/source.dart';
import '../widgets/detail_route.dart';
import '../widgets/common_widgets.dart';
import '../widgets/scroll_top_fab.dart';
import 'anime_player_page.dart';
import 'novel_pages.dart';
import 'unified_detail_page.dart';
import 'unified_home_page.dart';

/// 搜索类型：漫画 / 作者 / 动漫 / 小说（同一个入口与界面，不割裂）。
///
/// `author` 是漫画的检索方式之一，不是独立板块 —— 它与「漫画」共用
/// 同一条结果网格，只是把 `search_type` 换成 `author`。
enum SearchKind { comic, author, anime, novel }

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

  ComicSource _source = SourceRegistry.current;

  /// 记住漫画板块用户选择的源（切到动漫/小说再切回时恢复）
  ComicSource? _comicSource;

  /// 排序（对应官方 `o` 参数）：`''` 最新 / `mv` 最多观看 / `mp` 最多图片 / `tf` 最多爱心
  String _order = '';

  /// 搜索方式（对应官方 `search_type`）：site / work / author / tag / character
  String _searchType = 'site';

  /// 年月筛选（对应官方 `y` / `m`，空串表示不限，仅 JM 源支持）
  String _year = '';
  String _month = '';

  bool _loading = false;

  /// 正在追加下一页（防止滚动到底时重复发请求）
  bool _loadingMore = false;
  String? _error;
  String _lastQuery = '';

  /// 当前搜索词是否来自点击标签（用于输入框内嵌胶囊显示）
  bool _tagMode = false;

  /// 拼成 JM 接口要求的标签查询串：`+tag1 +tag2`
  /// （实测：空格分隔 + 每个标签加号前缀才生效）
  String get _tagQuery => _tags.map((t) => '+$t').join(' ');

  /// 已锁定的标签（每个显示为一个胶囊）。
  /// 与 _controller 分离：胶囊是已确认的词，输入框是新词。
  final List<String> _tags = [];


  /// 当前滚动偏移（驱动「回到顶部」按钮）
  double _scrollOffset = 0;

  /// 当前活跃的滚动位置（由任意子列表的滚动通知写入），
  /// 供「回到顶部」使用 —— 因为不同板块用不同 ScrollController。
  ScrollPosition? _activeScroll;

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
    _focus.addListener(_onFocusChange);
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
        _searchType = 'author';
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
    _focus.removeListener(_onFocusChange);
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
    // 仅漫画板块（含作者检索）同步全局源切换
    if (!_isComic) return;
    if (next.id == _source.id) return;
    final q = _lastQuery;
    setState(() {
      _source = next;
      _comicSource = next;
      _clearResults();
    });
    // 切源后仍用同一个关键词继续搜索，不退回首页/建议页
    if (q.isNotEmpty) _resubmit();
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
    _comicTotal = 0;
    _animeTotal = 0;
  }

  /// 焦点变化：聚焦时显示文字输入，失焦时若无内容则保持原状。
  void _onFocusChange() {
    if (mounted) setState(() {});
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
    if (_isComic && _comicMore) _loadMoreComic();
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

  /// 搜索历史上限。**最多 12 条，超出直接丢弃**（不做「保留最近 N 条」
  /// 之外的任何处理）。
  ///
  /// 之前是 30 条 + 三行折叠展开，用户嫌多条、展开又多余。
  /// 现在硬上限 12：新词插入队首，多出来的尾部直接丢弃。
  static const int _maxHistory = 12;

  Future<void> _pushHistory(String q) async {
    if (q.trim().isEmpty) return;
    setState(() {
      _history.remove(q);
      _history.insert(0, q);
      if (_history.length > _maxHistory) {
        _history.removeRange(_maxHistory, _history.length);
      }
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
    if (AppState.instance.offlineMode) return;
    final tags = await _service.fetchHotTags();
    if (!mounted) return;
    setState(() => _hotTags = tags);
  }

  Future<void> _search({
    String? query,
    bool reset = true,
    bool asTag = false,
  }) async {
    final raw = query ?? _controller.text.trim();
    if (raw.isEmpty) return;

    // ---- 编号搜索：纯数字 或 JM+数字 → 直接打开作品详情 ----
    //
    // 必须放在**标签处理之前**判断。
    // 之前放在 asTag 分支之后，而输入框回车走的是 `_search(asTag: true)`，
    // 于是「350234」被当成标签拼成 `+350234` 去搜，永远搜不到东西 ——
    // 用户看到的就是「编号搜索无效」。
    final idMatch = RegExp(r'^(?:JM)?(\d{3,})$', caseSensitive: false)
        .firstMatch(raw.trim());
    if (idMatch != null) {
      // 编号只在 JM 源有意义（EH 的作品 ID 是 URL，不是数字）
      if (_source.id != 'jm') {
        setState(() {
          _error = L.t('idSearchJmOnly');
          _loading = false;
          _lastQuery = raw;
          _clearResults();
        });
        return;
      }
      final comicId = idMatch.group(1)!;
      setState(() {
        _lastQuery = raw;
        _loading = false;
        _error = null;
        _clearResults();
      });
      _pushHistory(raw);
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => UnifiedDetailPage(
            source: _source,
            comic: Comic(id: comicId, name: '', author: '', source: 'jm'),
          ),
        ),
      );
      return;
    }

    setState(() {
      // 用户输入的新词 → 加入标签列表并清空输入框，
      // 这样胶囊与「待输入区」不会重复显示同一个词。
      if (asTag) {
        if (!_tags.contains(raw)) _tags.add(raw);
        _tagMode = true;
        _controller.clear();
      }
      _lastQuery = asTag ? _tags.join(' / ') : raw;
      _loading = true;
      _error = null;
      if (reset) _clearResults();
    });
    _pushHistory(raw);

    // 实际搜索词：标签模式下用 +tag1 +tag2 格式
    final q = asTag ? _tagQuery : raw;
    if (q.isEmpty) return;

    // 不主动 unfocus：参照 Pixiv，键盘保持打开，胶囊与光标并存。

    switch (_kind) {
      case SearchKind.comic:
      case SearchKind.author:
        await _searchComic(q, reset: reset);
      case SearchKind.anime:
        await _searchAnime(query: q, reset: reset);
      case SearchKind.novel:
        await _searchNovel(q);
    }
  }

  /// 漫画结果翻页（不重置列表）。
  ///
  /// 之前复用了 `_search(reset:false)`，而它从输入框取词 —— 标签模式下
  /// 输入框已被清空，翻页会静默失败。
  void _loadMoreComic() {
    if (_loadingMore) return;
    final q = _tagMode ? _tagQuery : _lastQuery;
    if (q.isEmpty) return;
    _loadingMore = true;
    _searchComic(q, reset: false).whenComplete(() => _loadingMore = false);
  }

  /// 用**当前关键词/标签**原样重跑一次搜索（切源、改筛选条件时用）。
  ///
  /// 不写历史、不改输入框内容 —— 用户没输入新词，只是换了源或排序。
  Future<void> _resubmit() async {
    if (_tagMode) {
      final q = _tagQuery;
      if (q.isEmpty) return;
      setState(() {
        _loading = true;
        _error = null;
        _clearResults();
      });
      await _searchComic(q, reset: true);
      return;
    }
    if (_lastQuery.isEmpty) return;
    await _search(query: _lastQuery, reset: true);
  }

  Future<void> _searchComic(String q, {bool reset = true}) async {
    try {
      final r = await _source.search(
        q,
        page: _comicPage,
        order: _order,
        searchType: _searchType,
        year: _year,
        month: _month,
      );
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
    // 离开漫画板块前记住当前源（作者检索也属于漫画源）
    if (_isComic) _comicSource = _source;
    setState(() {
      _kind = k;
      _clearResults();
      _error = null;
      // 作者检索与漫画共用同一个源与同一条结果网格，只是 search_type 不同
      _searchType = k == SearchKind.author ? 'author' : 'site';
      // 动漫/小说为 JM 独有，强制 JM；漫画恢复用户先前选择的源
      if (_isComic) {
        _source = _comicSource ?? JmSource.instance;
      } else {
        _source = JmSource.instance;
      }
    });
    if (_lastQuery.isNotEmpty) _search(query: _lastQuery);
  }

  /// 当前板块是否走「漫画源」（漫画 / 作者）。
  bool get _isComic => _kind == SearchKind.comic || _kind == SearchKind.author;

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
              // 统一监听：无论漫画/小说/动漫/建议列表，都能驱动收起动画
              child: NotificationListener<ScrollNotification>(
                onNotification: (n) {
                  final o = n.metrics.pixels;
                  // 通过通知上下文拿到真正的 ScrollableState.position，
                  // 供「回到顶部」使用（不同板块用不同控制器）
                  final ctx = n.context;
                  if (ctx != null) {
                    final st = ctx.findAncestorStateOfType<ScrollableState>();
                    if (st != null && st.position.hasPixels) {
                      _activeScroll = st.position;
                    }
                  }
                  if ((o - _scrollOffset).abs() > 4) {
                    setState(() => _scrollOffset = o.clamp(0.0, 2000.0));
                  }
                  return false;
                },
                child: _lastQuery.isEmpty
                    ? _buildSuggestions(theme)
                    : _buildResults(theme),
              ),
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
              // 优先对「当前正在看的列表」滚动，而不是固定的 _scroll
              final pos = _activeScroll;
              if (pos != null && pos.hasPixels) {
                pos.animateTo(
                  0,
                  duration: const Duration(milliseconds: 380),
                  curve: Curves.easeOutCubic,
                );
                return;
              }
              if (_scroll.hasClients) {
                _scroll.animateTo(
                  0,
                  duration: const Duration(milliseconds: 380),
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




  /// 标签模式下的搜索框：内部以 #标签 胶囊呈现，可一键清除。
  /// 可收缩的搜索区：
  /// - 顶部时正常显示搜索框 + 类别栏
  /// - 上滑后搜索框缩小成一个靠右的胶囊按钮，点击回顶展开
  /// 搜索区：
  /// - 搜索框固定在顶部
  /// - 设置块向上平移，被搜索框底边裁切
  /// - 搜索按钮从「设置块首行右侧」平移到「搜索框右侧」
  ///
  /// 关键：按钮要跨越两个区域移动，因此放在**覆盖整个搜索区**的 Stack 顶层。
  /// 搜索区。
  ///
  /// - 输入框固定顶部
  /// - 设置块整体向上平移，被「输入框底边」裁切
  /// - 搜索按钮始终存在，在「作品行」与「输入框」之间连续平移
  /// 搜索区。
  ///
  /// 收缩原理：
  /// - 输入框固定在顶部
  /// - 设置块**不做位移**，就排在输入框下方
  /// - 容器高度从「输入框 + 间距 + 设置块」收缩到「输入框」
  /// - ClipRect 把超出部分裁掉 → 切线正好是输入框底边
  ///
  /// 因为设置块没有 transform，所以绝不会与输入框重叠。
  /// 搜索区。
  ///
  /// 三段式：输入框 / 设置块视口 / 悬浮按钮。
  /// 设置块视口高度随 t 收缩，内容向上移出 → 被输入框底边切断。
  /// 搜索区。
  ///
  /// 结构（零重叠保证）：
  /// - 输入框始终在右侧预留按钮宽度
  /// - 搜索按钮固定在输入框右侧，不做位置动画
  /// - 设置块在输入框下方，向上移出被裁切
  /// 搜索区。
  ///
  /// 按钮与设置块使用**同一位移节奏**（同一个 t、同一像素量）：
  ///   shift = -(gap + settingsH) * t
  /// 设置块整体上移被裁切；按钮同速上移，到位后钳制在输入框行。
  /// 搜索区。
  ///
  /// 无搜索按钮：用键盘回车（TextInputAction.search）提交。
  /// 滚动时设置块向上移出、被输入框底边裁切。
  /// 搜索区（参照 Pixiv）：
  /// [搜索框：图标 + #胶囊 + 光标] [筛选图标]
  /// 其下单独一行：类别
  Widget _buildCollapsibleSearchArea(ThemeData theme) {
    final scheme = theme.colorScheme;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // ============ 第一行：搜索框 + 筛选图标 ============
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 12, 4),
          child: Row(
            children: [
              // ---- 搜索框：胶囊与光标并存 ----
              Expanded(
                child: Container(
                  height: 46,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest.withValues(
                      alpha: 0.6,
                    ),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: _focus.hasFocus
                          ? scheme.primary.withValues(alpha: 0.6)
                          : Colors.transparent,
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.search_rounded,
                        size: 19,
                        color: scheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 8),
                      // 已锁定的标签 → 多个胶囊（始终存在，键盘收起也在）
                      for (final tag in _tags) ...[
                        _inlineTagChip(tag),
                        const SizedBox(width: 4),
                      ],
                      // TextField 始终存在 → 光标始终可见
                      Expanded(
                        child: TextField(
                          controller: _controller,
                          focusNode: _focus,
                          textInputAction: TextInputAction.search,
                          onSubmitted: (_) => _search(asTag: true),
                          style: const TextStyle(fontSize: 14),
                          decoration: InputDecoration(
                            isDense: true,
                            // 关闭 TextField 自带的填充/边框，
                            // 否则会在圆角容器里多出一块灰色方块
                            filled: false,
                            fillColor: Colors.transparent,
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            contentPadding: EdgeInsets.zero,
                            hintText: _tagMode
                                ? ''
                                : switch (_kind) {
                                    SearchKind.comic => L.t('searchWorkHint'),
                                    SearchKind.author =>
                                      L.t('searchAuthorHint'),
                                    SearchKind.anime =>
                                      L.t('searchVideoHint'),
                                    SearchKind.novel => L.t('searchNovelHint'),
                                  },
                            hintStyle: TextStyle(
                              fontSize: 13.5,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                          onChanged: (_) => setState(() {}),
                        ),
                      ),
                      // 清空按钮
                      if (_controller.text.isNotEmpty)
                        GestureDetector(
                          onTap: () {
                            _controller.clear();
                            setState(() {
                              _lastQuery = '';
                              _tagMode = false;
                              _clearResults();
                            });
                          },
                          child: Icon(
                            Icons.close_rounded,
                            size: 17,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 6),
              // ---- 筛选图标（仅在当前板块确实支持筛选时显示）----
              if (_hasFilter)
                IconButton(
                  tooltip: L.t('filter'),
                  onPressed: _showFilterSheet,
                  icon: Icon(
                    Icons.tune_rounded,
                    size: 22,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        ),

        // ============ 第二行：类别 ============
        _buildKindBar(theme),
      ],
    );
  }

  /// 输入框内的标签胶囊（#tag ×）。点击 × 移除该标签。
  /// 输入框内的标签胶囊：真胶囊形（大圆角）+ 更大的点击区域。
  Widget _inlineTagChip(String tag) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      // 上下留白更大 → 更饱满
      padding: const EdgeInsets.fromLTRB(10, 5, 4, 5),
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.15),
        // 半径给足 → 真胶囊形而非圆角矩形
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '#$tag',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: scheme.primary,
            ),
          ),
          const SizedBox(width: 2),
          // X 按钮：扩大热区到 22×22，便于点击
          InkResponse(
            onTap: () {
              setState(() => _tags.remove(tag));
              if (_tags.isNotEmpty) {
                _search(asTag: true);
              } else {
                setState(() {
                  _tagMode = false;
                  _lastQuery = '';
                  _clearResults();
                });
              }
            },
            radius: 14,
            child: SizedBox(
              width: 22,
              height: 22,
              child: Icon(
                Icons.close_rounded,
                size: 15,
                color: scheme.primary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 筛选面板：**底部半屏**（约 55% 屏高，可上滑看全部参数）。
  ///
  /// 官方客户端 `Search.tsx` 的全部参数都在这里：
  ///   * 搜索方式 `search_type`：综合 / 作品 / 作者 / 标签 / 角色
  ///   * 数据源（JM / EH）
  ///   * 排序 `o`：最新 / 最多观看 / 最多图片 / 最多爱心
  ///   * 年份 `y` / 月份 `m`
  ///
  /// 面板内是「草稿」状态，点「应用」才写回并重搜 —— 这样连续改几项
  /// 不会每改一项就发一次请求。
  /// 当前板块是否**有可筛选的维度**。
  ///
  /// 用户要求：「不知道视频和小说能不能用筛选，能用就保留按钮，不能用就删掉」。
  /// 实测：
  ///  * 漫画 —— 排序（最新/人气/图片数/爱心）、年份、月份、检索方式 都支持
  ///  * 作者 —— 与漫画共用 search_type，同样可排序/按年份筛
  ///  * 小说 —— 服务端小说接口不接受排序/年份参数，筛了也没有效果
  ///  * 动漫 —— 同上，只有分页，没有排序维度
  /// 所以只在「漫画 / 作者」板块显示筛选按钮，其余板块直接隐藏，
  /// 避免用户点了没反应。
  bool get _hasFilter {
    if (!_isComic) return false;
    return _source.id == 'jm';
  }

  void _showFilterSheet() {
    if (!_hasFilter) return;
    final jmOnly = _source.id == 'jm';
    var draftType = _searchType;
    var draftOrder = _order;
    var draftYear = _year;
    var draftMonth = _month;

    showModalBottomSheet<void>(
      context: context,
      // 半屏：屏幕高度的 58%，剩下的留给用户看到搜索结果
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) {
          final scheme = Theme.of(ctx).colorScheme;
          final years = <String>[
            '',
            for (var y = DateTime.now().year; y >= 2017; y--) '$y',
          ];
          final months = <String>['', for (var m = 1; m <= 12; m++) '$m'];

          Widget label(String text) => Padding(
                padding: const EdgeInsets.only(bottom: 8, top: 16),
                child: Text(
                  text,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurface,
                  ),
                ),
              );

          Widget chips({
            required List<(String, String)> options,
            required String value,
            required ValueChanged<String> onPick,
            VoidCallback? onAfter,
          }) {
            return Wrap(
              spacing: 8,
              runSpacing: 8,
              children: options
                  .map(
                    (o) => ChoiceChip(
                      label: Text(
                        o.$2,
                        style: const TextStyle(fontSize: 12),
                      ),
                      visualDensity: VisualDensity.compact,
                      selected: value == o.$1,
                      onSelected: (_) {
                        // 关键：**一次 setState 里完成所有修改**。
                        // 之前先 setS(onPick) 再单独 setS 清月份 —— 两次
                        // 重建之间会出现「已选中新值但月份还是旧值」的中间态，
                        // 用户看到整排 chip 闪一下。
                        setS(() {
                          onPick(o.$1);
                          onAfter?.call();
                        });
                      },
                    ),
                  )
                  .toList(),
            );
          }

          return SizedBox(
            height: MediaQuery.of(ctx).size.height * 0.58,
            child: Column(
              children: [
                // ---- 标题行 ----
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 8, 0),
                  child: Row(
                    children: [
                      Text(
                        L.t('filter'),
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: () => setS(() {
                          draftType = 'site';
                          draftOrder = '';
                          draftYear = '';
                          draftMonth = '';
                        }),
                        child: Text(L.t('resetFilter')),
                      ),
                    ],
                  ),
                ),
                // ---- 参数列表（可滚动） ----
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                    children: [
                      // 检索方式（站内/作品/作者/标签/角色）：
                      // 只在「漫画」板块显示。用户要求：「筛选里面有作者了，
                      // 那就不用 4 个大类了」—— 在作者板块再列一遍
                      // 作品/作者切换是重复且混乱的。
                      if (jmOnly &&
                          _isComic &&
                          _kind != SearchKind.author) ...[
                        label(L.t('searchType')),
                        chips(
                          value: draftType,
                          options: [
                            ('site', L.t('searchTypeSite')),
                            ('work', L.t('searchTypeWork')),
                            ('author', L.t('searchTypeAuthor')),
                            ('tag', L.t('searchTypeTag')),
                            ('character', L.t('searchTypeCharacter')),
                          ],
                          onPick: (v) => draftType = v,
                        ),
                      ],
                      if (_isComic) ...[
                        label(L.t('sort')),
                        chips(
                          value: draftOrder,
                          options: [
                            ('', L.t('sortLatest')),
                            ('mv', L.t('sortMostViews')),
                            ('mp', L.t('sortMostImages')),
                            ('tf', L.t('sortMostHearts')),
                          ],
                          onPick: (v) => draftOrder = v,
                        ),
                      ],
                      if (jmOnly && _isComic) ...[
                        label(L.t('yearLabel')),
                        chips(
                          value: draftYear,
                          options: [
                            for (final y in years)
                              (y, y.isEmpty ? L.t('all') : y),
                          ],
                          onPick: (v) => draftYear = v,
                          // 选「年份不限」时把月份一起清掉，
                          // 免得出现「不限年 + 3 月」这种无意义组合。
                          // 与 onPick 在同一次 setState 内完成，不闪。
                          onAfter: () {
                            if (draftYear.isEmpty) draftMonth = '';
                          },
                        ),
                        label(L.t('monthLabel')),
                        chips(
                          value: draftMonth,
                          options: [
                            for (final m in months)
                              (m, m.isEmpty ? L.t('all') : m),
                          ],
                          onPick: (v) => draftMonth = v,
                        ),
                      ],
                    ],
                  ),
                ),
                // ---- 应用 ----
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    20,
                    4,
                    20,
                    MediaQuery.of(ctx).padding.bottom + 12,
                  ),
                  child: SizedBox(
                    width: double.infinity,
                    height: 46,
                    child: FilledButton(
                      onPressed: () {
                        Navigator.pop(ctx);
                        final typeChanged = draftType != _searchType;
                        setState(() {
                          _order = draftOrder;
                          _year = draftYear;
                          _month = draftMonth;
                          if (typeChanged) {
                            // 「作者」与「作品」等检索方式共用同一网格，
                            // 只改 search_type，不换板块
                            _searchType = draftType;
                            _kind = draftType == 'author'
                                ? SearchKind.author
                                : SearchKind.comic;
                          }
                        });
                        _resubmit();
                      },
                      child: Text(L.t('applyFilter')),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// 类型切换 + 源切换（漫画时才显示源/排序）
  /// 类别栏（Pixiv 风格）：四等分 + 选中项下方横线。
  Widget _buildKindBar(ThemeData theme) {
    final scheme = theme.colorScheme;

    Widget tab(SearchKind k, String label) {
      final active = _kind == k;
      return Expanded(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _switchKind(k),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: active ? FontWeight.w700 : FontWeight.w400,
                    color: active
                        ? scheme.onSurface
                        : scheme.onSurfaceVariant,
                  ),
                ),
              ),
              // 选中指示线
              AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                height: 2.5,
                width: active ? 28 : 0,
                decoration: BoxDecoration(
                  color: scheme.primary,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        children: [
          // 作者检索并入漫画这一行（与官方 search_type=author 一致），
          // 不再藏进筛选面板 —— 4 个选项平铺，一眼可见。
          tab(SearchKind.comic, L.t('searchComic')),
          tab(SearchKind.author, L.t('searchAuthor')),
          tab(SearchKind.anime, L.t('anime')),
          tab(SearchKind.novel, L.t('novels')),
        ],
      ),
    );
  }

  /// 搜索历史胶囊：硬上限 12 条（见 [_maxHistory]），直接平铺，
  /// 不再做「三行折叠 / 展开」那套——12 条本来就摊得下。
  Widget _buildHistoryChips(ThemeData theme) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final h in _history)
          _SearchChip(
            label: h,
            onTap: () => _search(query: h, asTag: true),
            onDelete: () => _removeHistory(h),
          ),
      ],
    );
  }

  Widget _buildSuggestions(ThemeData theme) {
    // 离线模式：搜索完全依赖网络，给明确空态而不是转圈
    if (AppState.instance.offlineMode) {
      return EmptyView(
        message: L.t('offlineNoOnlineContent'),
        icon: Icons.cloud_off_rounded,
      );
    }
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
          // 搜索历史最多三行：超出部分裁掉，并给「展开/收起」。
          // 之前是全量平铺，历史攒到 20 条时把热词整个挤出屏幕。
          _buildHistoryChips(theme),
          const SizedBox(height: 18),
        ],
        // 热门标签只在「综合/作品」检索时显示。
        // 作者检索（_kind == author）下热门标签没有意义（那些是作品标签，
        // 不是作者名），显示出来只会误导。
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
        SearchKind.comic || SearchKind.author => _comics.isEmpty,
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
      // 作者检索的结果也是作品网格（官方 search_type=author 返回的同样是作品）
      case SearchKind.comic:
      case SearchKind.author:
        return _buildComicResults(theme);
      case SearchKind.anime:
        return _buildAnimeResults(theme);
      case SearchKind.novel:
        return _buildNovelResults(theme);
    }
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
            // 与详情页的 coverTag 前缀必须一致，否则 Hero 匹配不上
            heroPrefix: 'search',
            coverOf: _source.coverOf,
            loadingCount: _comicMore ? 3 : 0,
            onTap: (c) async {
              _pendingFabTag = 'fab_${_source.id}_${c.id}';
              setState(() {});
              await Navigator.of(context).push(
                detailRoute(builder: (_) => UnifiedDetailPage(
                    source: _source,
                    comic: c,
                    // 与 ComicGrid 内部生成的封面 tag 保持一致，
                    // 这样搜索结果点进去也有封面平滑转场
                    coverTag: 'search_${c.source}_${c.id}',
                  ),
                ),
              );
              // 返回后清空所有 pending tag，防止残留导致
              // 下次转场时封面飞向错误位置（如飞向屏幕底部）
              if (mounted) {
                setState(() {
                  _pendingFabTag = null;
                });
              }
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
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: 0.70,
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