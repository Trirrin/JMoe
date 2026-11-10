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

enum SearchKind { comic, author, anime, novel }

class SearchPage extends StatefulWidget {
  final bool embedded;

  final String? initialQuery;

  final bool initialAsTag;

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

  SearchKind _kind = SearchKind.comic;

  ComicSource _source = SourceRegistry.current;

  ComicSource? _comicSource;

  String _order = '';

  String _searchType = 'site';

  String _year = '';
  String _month = '';

  bool _loading = false;

  bool _loadingMore = false;
  String? _error;
  String _lastQuery = '';

  bool _tagMode = false;

  String get _tagQuery => _tags.map((t) => '+$t').join(' ');

  final List<String> _tags = [];

  double _scrollOffset = 0;

  ScrollPosition? _activeScroll;

  String? _pendingFabTag;

  final _comics = <Comic>[];
  int _comicPage = 1;
  int _comicTotal = 0;
  bool _comicMore = true;

  final _animes = <Map<String, dynamic>>[];
  int _animePage = 1;
  int _animeTotal = 0;
  bool _animeMore = true;

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
    final q0 = widget.initialQuery;
    if (q0 != null && q0.trim().isNotEmpty) {
      _controller.text = q0;
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
    if (!_isComic) return;
    if (next.id == _source.id) return;
    final q = _lastQuery;
    setState(() {
      _source = next;
      _comicSource = next;
      _clearResults();
    });
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

  void _onFocusChange() {
    if (mounted) setState(() {});
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
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
    bool keepFocus = false,
  }) async {
    final raw = query ?? _controller.text.trim();
    if (raw.isEmpty) return;

    final idMatch = RegExp(r'^(?:JM)?(\d{3,})$', caseSensitive: false)
        .firstMatch(raw.trim());
    if (idMatch != null) {
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

    final q = asTag ? _tagQuery : raw;
    if (q.isEmpty) return;

    switch (_kind) {
      case SearchKind.comic:
      case SearchKind.author:
        await _searchComic(q, reset: reset);
      case SearchKind.anime:
        await _searchAnime(query: q, reset: reset);
      case SearchKind.novel:
        await _searchNovel(q);
    }

    if (keepFocus && mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_focus.hasFocus) _focus.requestFocus();
      });
    }
  }

  void _loadMoreComic() {
    if (_loadingMore) return;
    final q = _tagMode ? _tagQuery : _lastQuery;
    if (q.isEmpty) return;
    _loadingMore = true;
    _searchComic(q, reset: false).whenComplete(() => _loadingMore = false);
  }

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
    if (_isComic) _comicSource = _source;
    setState(() {
      _kind = k;
      _clearResults();
      _error = null;
      _searchType = k == SearchKind.author ? 'author' : 'site';
      if (_isComic) {
        _source = _comicSource ?? JmSource.instance;
      } else {
        _source = JmSource.instance;
      }
    });
    if (_lastQuery.isNotEmpty) _search(query: _lastQuery);
  }

  bool get _isComic => _kind == SearchKind.comic || _kind == SearchKind.author;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    final body = Stack(
      children: [
        Column(
          children: [
            _buildCollapsibleSearchArea(theme),
            Expanded(
              child: NotificationListener<ScrollNotification>(
                onNotification: (n) {
                  final o = n.metrics.pixels;
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
        Positioned(
          right: 16,
          bottom: 16,
          child: ScrollTopFab(
            scrollOffset: _scrollOffset,
            heroTag: _pendingFabTag,
            onAction: () {
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

  Widget _buildCollapsibleSearchArea(ThemeData theme) {
    final scheme = theme.colorScheme;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 12, 4),
          child: Row(
            children: [
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
                      for (var ti = 0; ti < _tags.length; ti++) ...[
                        _inlineTagChip(_tags[ti], ti),
                        const SizedBox(width: 4),
                      ],
                      Expanded(
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
                            return _onBackspace()
                                ? KeyEventResult.handled
                                : KeyEventResult.ignored;
                          },
                          child: TextField(
                          key: const ValueKey('search_input_field'),
                          controller: _controller,
                          focusNode: _focus,
                          textInputAction: TextInputAction.search,
                          onSubmitted: (_) => _search(asTag: true),
                          style: const TextStyle(fontSize: 14),
                          decoration: InputDecoration(
                            isDense: true,
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

        _buildKindBar(theme),
      ],
    );
  }

  int? _editingTagIndex;

  TextEditingController? _tagEditCtrl;

  void _beginEditTag(int index) {
    if (index < 0 || index >= _tags.length) return;

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

  void _commitEditTag() {
    final i = _editingTagIndex;
    final ctrl = _tagEditCtrl;
    if (i == null || ctrl == null) return;
    final v = ctrl.text.trim();
    setState(() {
      if (v.isEmpty) {
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

  bool _onBackspace() {
    if (_controller.text.isNotEmpty) return false;
    if (_tags.isEmpty && _editingTagIndex == null) return false;

    if (_editingTagIndex != null) {
      _commitEditTag();
      return true;
    }

    final last = _tags.removeLast();
    final remain = last.length > 1 ? last.substring(0, last.length - 1) : '';
    setState(() {});
    _controller.text = remain;
    _controller.selection = TextSelection.collapsed(offset: remain.length);
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

  Widget _inlineTagChip(String tag, int index) {
    final scheme = Theme.of(context).colorScheme;
    final editing = _editingTagIndex == index;

    if (editing) {
      return IntrinsicWidth(
        child: TextField(
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
      onTap: () => _beginEditTag(index),
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 5, 4, 5),
        decoration: BoxDecoration(
          color: scheme.primary.withValues(alpha: 0.15),
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
            InkResponse(
              onTap: () {
                final hadFocus = _focus.hasFocus;

                setState(() {
                  _tags.removeAt(index);
                  if (_editingTagIndex == index) {
                    _editingTagIndex = null;
                    _tagEditCtrl?.dispose();
                    _tagEditCtrl = null;
                  } else if (_editingTagIndex != null &&
                      _editingTagIndex! > index) {
                    _editingTagIndex = _editingTagIndex! - 1;
                  }
                });

                if (_tags.isNotEmpty) {
                  _resubmit();
                } else {
                  setState(() {
                    _tagMode = false;
                    _lastQuery = '';
                    _clearResults();
                  });
                }

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
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                    children: [
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
                          onAfter: () {
                            if (draftYear.isEmpty) draftMonth = '';
                            setS(() {});
                          },
                        ),
                        label(L.t('monthLabel')),
                        chips(
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
          tab(SearchKind.comic, L.t('searchComic')),
          tab(SearchKind.anime, L.t('anime')),
          tab(SearchKind.novel, L.t('novels')),
        ],
      ),
    );
  }

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
          _buildHistoryChips(theme),
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
            heroPrefix: 'search',
            coverOf: _source.coverOf,
            loadingCount: _comicMore ? 3 : 0,
            onTap: (c) async {
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
                    coverTag: 'search_${c.source}_${c.id}',
                  ),
                ),
              );
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
