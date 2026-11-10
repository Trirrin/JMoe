import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
    /// 是否在搜索后保持输入框焦点（不收起键盘）。
    ///
    /// 删除胶囊时用 true：用户还在输入区操作，键盘不该被收走。
    bool keepFocus = false,
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

    // 请求保持焦点：搜索过程里的 setState 有可能让输入框失焦，
    // 这里在结果回来后把焦点还回去（键盘不会收起）。
    if (keepFocus && mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_focus.hasFocus) _focus.requestFocus();
      });
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
                      // 已锁定的标签 → 多个胶囊（恢复原来的独立控件样式）
                      for (var ti = 0; ti < _tags.length; ti++) ...[
                        _inlineTagChip(_tags[ti], ti),
                        const SizedBox(width: 4),
                      ],
                      Expanded(
                        // 用 Focus.onKeyEvent 而**不是** Shortcuts/Actions：
                        //
                        // Shortcuts+Actions 一旦匹配就会把按键"消费"掉，
                        // 原生 TextField 再也收不到退格 —— 于是
                        // 「把胶囊变成文字后，剩下的文字删不掉」。
                        //
                        // Focus.onKeyEvent 可以返回 KeyEventResult.ignored，
                        // 把事件继续向下传，原生退格就能正常工作。
                        child: Focus(
                          onKeyEvent: (node, event) {
                            if (event is! KeyDownEvent &&
                                event is! KeyRepeatEvent) {
                              return KeyEventResult.ignored;
                            }
                            if (event.logicalKey !=
                                LogicalKeyboardKey.backspace) {
                              return KeyEventResult.ignored;
                            }
                            // 只有真的处理了胶囊才拦截，其余一律放行
                            return _onBackspace()
                                ? KeyEventResult.handled
                                : KeyEventResult.ignored;
                          },
                          child: TextField(
                          // 稳定 key：删除/新增胶囊时前面的兄弟节点数量会变，
                          // 没有 key 的话 Flutter 可能把 TextField 的 Element
                          // 复用到别的位置，导致它被重建 → 丢焦点 → 键盘收起。
                          // 有了固定 key，它永远绑定同一个 Element，
                          // 焦点和键盘都不会被影响。
                          key: const ValueKey('search_input_field'),
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
                        ),
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
  /// 正在被编辑的胶囊序号（null = 没有在编辑）。
  ///
  /// 用户要求「一次最多只能更改一个胶囊」—— 用单个索引即可保证。
  int? _editingTagIndex;

  /// 编辑胶囊时的临时输入框控制器
  TextEditingController? _tagEditCtrl;

  /// 让某个胶囊进入「编辑态」（胶囊拆散成文字）。
  ///
  /// 用户要求：**像删除一样直接拆散** —— 点一下胶囊它就不再是胶囊，
  /// 而是变成输入框里的普通文字，可以随时改、随时退格。
  ///
  /// 同一时间只能有一个胶囊处于编辑态：
  /// 正在编辑 A 又点了 B 时，先把 A 的文字变回胶囊，再让 B 变成文字。
  void _beginEditTag(int index) {
    if (index < 0 || index >= _tags.length) return;

    // 已有别的胶囊在编辑 → 先把它提交（变回胶囊）。
    // 注意：提交只改写文字/或删除空项，不改变已有索引顺序，
    // 所以这里直接用原 index 继续即可。
    if (_editingTagIndex != null && _editingTagIndex != index) {
      _commitEditTagQuiet();
      if (index >= _tags.length) return;
    }

    _tagEditCtrl?.dispose();
    _tagEditCtrl = TextEditingController(text: _tags[index]);
    _tagEditCtrl!.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _tags[index].length,
    );
    setState(() => _editingTagIndex = index);
  }

  /// 提交当前编辑但不触发重新搜索（用于切换编辑目标时）。
  void _commitEditTagQuiet() {
    final i = _editingTagIndex;
    final ctrl = _tagEditCtrl;
    if (i == null || ctrl == null) return;
    final v = ctrl.text.trim();
    if (i < _tags.length) {
      if (v.isEmpty) {
        _tags.removeAt(i);
      } else {
        _tags[i] = v;
      }
    }
    ctrl.dispose();
    _tagEditCtrl = null;
    _editingTagIndex = null;
  }

  /// 结束编辑并应用。
  ///
  /// 规则（按用户要求）：
  ///  * 有内容 → 写回该胶囊（搜索时自动变回胶囊）
  ///  * 清空后确认 → **整个胶囊删掉，文字也不保留**
  ///  * 一次只编辑一个胶囊
  void _commitEditTag() {
    final i = _editingTagIndex;
    final ctrl = _tagEditCtrl;
    if (i == null || ctrl == null) return;
    final v = ctrl.text.trim();
    setState(() {
      if (v.isEmpty) {
        // 文字清空 → 胶囊一并删除，不把文字留在输入框里
        if (i < _tags.length) _tags.removeAt(i);
      } else if (i < _tags.length) {
        _tags[i] = v;
      }
      _editingTagIndex = null;
    });
    ctrl.dispose();
    _tagEditCtrl = null;
    if (_tags.isNotEmpty) {
      _search(asTag: true);
    } else {
      setState(() {
        _tagMode = false;
        _lastQuery = '';
        _clearResults();
      });
    }
  }

  /// 退格键处理。
  ///
  /// 用户要求的完整规则：
  ///  1. 若**已有胶囊处于「文字编辑态」** → 先把它变回胶囊（本次退格只做这一件事）
  ///  2. 否则：把最后一个胶囊取出、变成输入框里的**可编辑文字**，
  ///     并立即删掉它的最后一个字；之后继续退格就是正常的逐字删除
  ///
  /// 关键：这个拦截器**只在真的要处理胶囊时才拦截**，
  /// 其他情况必须返回 false，把退格交还给原生 TextField。
  ///
  /// 之前无条件拦下所有退格（`if (_controller.text.isNotEmpty) return;`
  /// 之后仍然被 Shortcuts 吃掉），导致「取出胶囊后剩下的文字删不掉」。
  bool _onBackspace() {
    // 输入框有内容 → 完全不干预，交给原生逐字删除
    if (_controller.text.isNotEmpty) return false;
    // 没有胶囊可处理 → 也不干预
    if (_tags.isEmpty && _editingTagIndex == null) return false;

    // 步骤 1：有正在编辑的胶囊 → 先变回胶囊
    if (_editingTagIndex != null) {
      _commitEditTag();
      return true;
    }

    // 步骤 2：取出最后一个胶囊 → 变成输入框文字 → 删掉最后一个字
    final last = _tags.removeLast();
    final remain = last.length > 1 ? last.substring(0, last.length - 1) : '';
    setState(() {});
    _controller.text = remain;
    _controller.selection = TextSelection.collapsed(offset: remain.length);
    // 剩余为空说明删完了，退出标签模式
    if (remain.isEmpty) {
      setState(() {
        _tagMode = _tags.isNotEmpty;
        if (_tags.isEmpty) {
          _lastQuery = '';
          _clearResults();
        }
      });
    }
    return true;
  }

  /// 输入框内的标签胶囊。
  ///
  /// 普通态：胶囊外观（可双击进入文字编辑）
  /// 编辑态：变成可直接输入的文本框
  Widget _inlineTagChip(String tag, int index) {
    final scheme = Theme.of(context).colorScheme;
    final editing = _editingTagIndex == index;

    // 编辑态：胶囊变成可直接输入的文本框（用户的「胶囊变文字」）
    if (editing) {
      // **编辑态 = 普通文字**（不是"胶囊里放输入框"）。
      //
      // 用户要求：「编辑胶囊需要转换成文字」—— 双击胶囊后它就不再
      // 是胶囊形状，而是变成一行可编辑的普通文本（无背景、无边框、
      // 与输入框文字同样式），改完回车/失焦后再变回胶囊。
      return IntrinsicWidth(
        child: TextField(
          // key 绑定索引：切到别的胶囊时是不同的 TextField，
          // 各自 autofocus 会正确接管，不会两个同时抢焦点。
          key: ValueKey('tag_edit_field_$index'),
          controller: _tagEditCtrl,
          autofocus: true,
          style: TextStyle(
            fontSize: 13.5,
            color: scheme.onSurface,
          ),
          decoration: const InputDecoration(
            isDense: true,
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            contentPadding: EdgeInsets.zero,
            isCollapsed: true,
          ),
          onSubmitted: (_) => _commitEditTag(),
          onTapOutside: (_) => _commitEditTag(),
        ),
      );
    }

    return GestureDetector(
      // 单击胶囊 → **直接拆散成文字**进入编辑（用户要求：
      // 「像删除一样直接拆散就可以编辑了」）。
      // 只有右侧 × 负责删除，点胶囊本体就是编辑。
      onTap: () => _beginEditTag(index),
      child: Container(
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
                // 记下删除前是否持有焦点，用于删除后精确恢复
                final hadFocus = _focus.hasFocus;

                setState(() {
                  _tags.removeAt(index);
                  // 删掉的正是正在编辑的那个 → 退出编辑态
                  if (_editingTagIndex == index) {
                    _editingTagIndex = null;
                    _tagEditCtrl?.dispose();
                    _tagEditCtrl = null;
                  } else if (_editingTagIndex != null &&
                      _editingTagIndex! > index) {
                    _editingTagIndex = _editingTagIndex! - 1;
                  }
                });

                // **删除胶囊不该收起键盘。**
                //
                // 关键改动：删除后不再走 `_search()`。
                // `_search` 内部会连续做多次 setState（改 _tagMode、
                // _lastQuery、清结果、再填结果），连续的树重建会让
                // TextField 在某一帧失焦 —— 键盘随即收起。
                //
                // 现在改用 `_resubmit()`：它用「当前关键词原样重跑」，
                // 只更新结果列表，完全不碰输入区的状态。
                if (_tags.isNotEmpty) {
                  _resubmit();
                } else {
                  setState(() {
                    _tagMode = false;
                    _lastQuery = '';
                    _clearResults();
                  });
                }

                // 立即恢复焦点（同一帧），下一帧再确认一次 ——
                // 双保险，确保键盘不会闪一下再弹出。
                if (hadFocus && mounted) _focus.requestFocus();
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted && hadFocus) _focus.requestFocus();
                });
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
            Key? key,
          }) {
            // _ChipRow 是无动画自绘组件：切换时没有内部动画可重播，
            // 所以可以让面板正常 setS 重建（不需要额外的局部状态）。
            return _ChipRow(
              key: key,
              options: options,
              value: value,
              onPick: (v) {
                setS(() => onPick(v));
                onAfter?.call();
              },
              onAfter: null,
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
                          onAfter: () {
                            if (draftYear.isEmpty) draftMonth = '';
                            // 月份那排是独立 State，必须显式重建它
                            // 才能反映「被联动清空」的结果。
                            setS(() {});
                          },
                        ),
                        label(L.t('monthLabel')),
                        chips(
                          // key 绑定 draftYear：年份一变，月份行重建，
                          // 从而正确显示被清空后的选中态。
                          key: ValueKey('month_row_$draftYear'),
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
                            // 只改 search_type，**不换板块**。
                            //
                            // 顶部已去掉「作者」分类（只保留漫画/动漫/小说
                            // 三大类），所以这里绝不能把 _kind 设成
                            // SearchKind.author —— 那会让三大类全都不高亮
                            // （用户反馈的「搜索方式消失、三大类都不选中」）。
                            // 作者检索就是「漫画按作者搜」，仍属漫画板块。
                            _searchType = draftType;
                            _kind = SearchKind.comic;
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
          // 只保留**三大类**：漫画 / 动漫 / 小说。
          //
          // 作者检索不再作为顶部分类：它本质是「漫画按作者检索」，
          // 已并入漫画板块（筛选面板里可选检索方式）。
          // 顶部平铺 4 项会让用户误以为作者是独立内容类型。
          tab(SearchKind.comic, L.t('searchComic')),
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
              // 跳转前收起键盘并清掉编辑态。
              //
              // 否则从详情页返回时会**再次弹出输入法**：
              // 搜索框的 FocusNode 仍持有焦点，页面重新可见后
              // Flutter 会恢复它，键盘就自己弹出来了。
              // 若此时还有胶囊处于编辑态（autofocus TextField），
              // 情况更明显。这里统一先失焦 + 退出编辑态。
              _focus.unfocus();
              if (_editingTagIndex != null) {
                _tagEditCtrl?.dispose();
                _tagEditCtrl = null;
              }
              _pendingFabTag = 'fab_${_source.id}_${c.id}';
              setState(() {
                _editingTagIndex = null;
              });
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

/// 筛选面板里的一排选项 chip。
///
/// # 为什么自绘而不用 ChoiceChip
///
/// ChoiceChip 的选中态切换带 200ms 内部动画（对勾缩放 + 背景渐变）。
/// 放在 `showModalBottomSheet` 的 `StatefulBuilder` 里时，任何一次
/// `setS` 都会重建整块面板 —— 十几个 chip 的 Element 重新挂载，
/// 动画全部从初始态重播 → 用户看到的「切换排序时整排闪一下」。
///
/// 换成**无动画自绘**：背景色/边框/文字色直接由选中态决定，
/// 没有中间帧可闪。外观与原来的 ChoiceChip 保持一致。
class _ChipRow extends StatelessWidget {
  const _ChipRow({
    super.key,
    required this.options,
    required this.value,
    required this.onPick,
    required this.onAfter,
  });

  final List<(String, String)> options;
  final String value;
  final ValueChanged<String> onPick;
  final VoidCallback? onAfter;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: options.map((o) {
        final sel = value == o.$1;
        return Material(
          color: sel
              ? scheme.secondaryContainer
              : scheme.surfaceContainerHighest,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () {
              if (sel) return;
              onPick(o.$1);
              onAfter?.call();
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 7,
              ),
              child: Text(
                o.$2,
                style: TextStyle(
                  fontSize: 12,
                  color: sel
                      ? scheme.onSecondaryContainer
                      : scheme.onSurfaceVariant,
                  fontWeight: sel ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}