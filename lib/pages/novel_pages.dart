import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/app_state.dart';
import '../core/jm_service.dart';
import '../core/l10n.dart';
import '../core/reader_native.dart';
import '../core/novel_cache.dart';
import '../core/reader_paginator.dart';
import '../core/reader_settings.dart';
import '../core/reader_store.dart';
import '../core/reading_stats.dart';
import '../widgets/app_toast.dart';
import '../widgets/common_widgets.dart';
import '../widgets/novel_catalog_overlay.dart';
import '../widgets/novel_theme_sheet.dart';
import '../widgets/novel_text_view.dart';
import '../widgets/novel_tts_sheet.dart';
import '../widgets/novel_typography_sheet.dart';
import '../widgets/novel_menu_overlay.dart';

/// 小说详情页：封面、简介、标签、章节列表（来自 `novel` 详情的 series 字段）。
class NovelDetailPage extends StatefulWidget {
  final String nid;
  final String title;
  final String? cover;

  const NovelDetailPage({
    super.key,
    required this.nid,
    required this.title,
    this.cover,
  });

  @override
  State<NovelDetailPage> createState() => _NovelDetailPageState();
}

class _NovelDetailPageState extends State<NovelDetailPage> {
  final _service = JmService.instance;
  final _store = ReaderStore.instance;
  Map<String, dynamic>? _detail;
  List<Map<String, dynamic>> _chapters = [];
  bool _descExpanded = false;
  int _resumeIndex = 0;
  bool _resumeLoaded = false;

  /// 本地收藏状态
  bool _novelFav = false;

  @override
  void initState() {
    super.initState();
    _novelFav = AppState.instance.isLocalFavorite(widget.nid);
    _load();
  }

  /// 收藏 / 取消收藏（本地优先，百分百成功）。
  Future<void> _toggleNovelFav() async {
    final target = !_novelFav;
    setState(() => _novelFav = target);
    await AppState.instance.setLocalFavorite(
      {
        'id': widget.nid,
        'name': _displayTitle,
        'author': '${_detail?['author'] ?? ''}',
        'cover': _coverUrl ?? '',
        'source': 'jm',
        'type': 'novel',
      },
      target,
    );
    if (!mounted) return;
    // 与漫画详情页统一：自绘 Toast（有入场/出场动画）
    AppToast.show(
      context,
      target ? L.t('favorited') : L.t('unfavorited'),
      icon: target ? Icons.favorite_rounded : Icons.favorite_border_rounded,
      accent: target ? const Color(0xFFFF6B81) : null,
    );
  }

  Future<void> _load() async {
    final d = await _service.fetchNovelDetail(widget.nid);
    final chapters = JmService.chaptersFromDetail(d);
    await _store.loadBook(widget.nid);
    final p = _store.progress(widget.nid);
    var resume = 0;
    if (p != null && p.chapterIndex >= 0 && p.chapterIndex < chapters.length) {
      resume = p.chapterIndex;
    }
    if (!mounted) return;
    setState(() {
      _detail = d;
      _chapters = chapters;
      _resumeIndex = resume;
      _resumeLoaded = p != null;
    });
  }

  (String, String) _splitTitle(String raw) {
    final parts = raw.split('|');
    if (parts.length >= 2) {
      return (parts[0].trim(), parts.sublist(1).join('|').trim());
    }
    return (raw.trim(), '');
  }

  String get _displayTitle =>
      _splitTitle('${_detail?['name'] ?? widget.title}').$1;

  String? get _coverUrl {
    final img = '${_detail?['images'] ?? ''}';
    if (img.isNotEmpty) {
      if (img.startsWith('http')) return img;
      final host = _service.imgHost ?? 'https://cdn-msp.jmapiproxy3.cc';
      return '$host$img';
    }
    return widget.cover;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final desc = '${_detail?['description'] ?? ''}';
    final tags = (_detail?['tags'] as List?)
            ?.whereType<Object>()
            .map((e) => '$e')
            .toList() ??
        const <String>[];
    final author = '${_detail?['author'] ?? ''}';
    final views = '${_detail?['total_views'] ?? ''}';

    return Scaffold(
      appBar: AppBar(
        title: Text(_displayTitle, maxLines: 1),
        actions: [
          IconButton(
            tooltip: L.t('favorite'),
            icon: Icon(
              _novelFav ? Icons.favorite : Icons.favorite_border,
              color: _novelFav ? theme.colorScheme.error : null,
            ),
            onPressed: _toggleNovelFav,
          ),
        ],
      ),
      body: ListView(
        // 不再让整个 body 等接口：首帧就用**列表页带来的**封面/标题渲染，
        // 这样 Hero 转场有落点，封面能一路飞进详情页。
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 32),
        children: [
          // 头部：左侧封面 + 右侧信息。
          //
          // # 为什么用固定高度而不是 IntrinsicHeight
          //
          // 之前用 `IntrinsicHeight + spaceBetween`：右侧标题行数变化
          // （加载前只有列表页带来的短标题，加载完变成完整长标题 → 从 1 行
          // 变 2 行）会撑高整个 Row，于是封面被往下推、Hero 落地后又「上移」，
          // 用户看到明显的跳变。
          //
          // 现在整块高度**钉死**为封面高度（139），内部一律不溢出：
          //  * 右侧标题固定最多 2 行
          //  * 作者 / 播放量单行省略
          //  * 按钮贴底
          // 无论加载前后，封面位置都完全不动。
          SizedBox(
            height: 139,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Hero(
                  // 与列表项封面的 tag 对应
                  tag: 'novel_${widget.nid}',
                  // 飞行层用与详情页**完全相同**的圆角（10），
                  // 这样落地瞬间不会从 6 跳到 10 而产生「到位后才跳变」。
                  flightShuttleBuilder: (ctx, anim, dir, from, to) {
                    return ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: CoverImage(url: _coverUrl),
                    );
                  },
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: SizedBox(
                      width: 104,
                      height: 139,
                      child: _coverUrl == null
                          ? Container(
                              color: theme.colorScheme.surfaceContainerHighest,
                              child: const Icon(
                                Icons.menu_book_rounded,
                                size: 32,
                              ),
                            )
                          : CoverImage(url: _coverUrl),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    // 标题组在上、按钮贴底：两者之间用 Spacer 吃掉剩余空间，
                    // 整块高度由外层 SizedBox 钉死，不会被内容撑开。
                    mainAxisAlignment: MainAxisAlignment.start,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // 标题最多两行：多了就省略，不去挤按钮
                          Text(
                            _displayTitle,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                              height: 1.3,
                            ),
                          ),
                          if (author.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Row(
                              children: [
                                Icon(
                                  Icons.person_outline_rounded,
                                  size: 12,
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                                const SizedBox(width: 3),
                                Expanded(
                                  child: Text(
                                    author,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 11,
                                      color:
                                          theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                          if (views.isNotEmpty) ...[
                            const SizedBox(height: 2),
                            Row(
                              children: [
                                Icon(
                                  Icons.visibility_outlined,
                                  size: 12,
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                                const SizedBox(width: 3),
                                Text(
                                  views,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color:
                                        theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                      // 吃掉标题组与按钮之间的剩余空间，
                      // 让按钮贴住封面底沿（整块高度已被钉死，不会溢出）
                      const Spacer(),
                      // 按钮：与封面底边对齐
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: _chapters.isEmpty
                              ? null
                              : () => _open(_resumeIndex),
                          icon: const Icon(Icons.play_arrow_rounded, size: 17),
                          label: Text(
                            _resumeLoaded && _resumeIndex > 0
                                ? L.t('continueReading')
                                : L.t('startReading'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          style: FilledButton.styleFrom(
                            minimumSize: const Size(0, 34),
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            textStyle: const TextStyle(fontSize: 12.5),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // ---- 标签 / 简介：未加载时用灰块占位 ----
          //
          // 之前这里是「什么都不画」，等接口回来才突然插入整段简介 +
          // 标签 + 章节列表，把下面的内容整体推下去（用户看到「跳」）。
          // 现在先用灰色占位撑住同样的高度，数据到了原地替换。
          if (_detail == null) ...[
            const SizedBox(height: 14),
            // 标签占位（两枚灰胶囊）
            Row(
              children: const [
                ShimmerBox(width: 56, height: 22, radius: 11),
                SizedBox(width: 6),
                ShimmerBox(width: 72, height: 22, radius: 11),
              ],
            ),
            const SizedBox(height: 16),
            // 简介占位（四行）
            const ShimmerBox(height: 13, radius: 4),
            const SizedBox(height: 7),
            const ShimmerBox(height: 13, radius: 4),
            const SizedBox(height: 7),
            ShimmerBox(
              height: 13,
              radius: 4,
              width: MediaQuery.of(context).size.width * 0.62,
            ),
          ] else ...[
            if (tags.isNotEmpty) ...[
              const SizedBox(height: 14),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: tags
                    .map(
                      (t) => Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 9,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          t,
                          style: const TextStyle(fontSize: 11),
                        ),
                      ),
                    )
                    .toList(),
              ),
            ],
            if (desc.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(
                desc,
                maxLines: _descExpanded ? null : 4,
                overflow: _descExpanded ? null : TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.7,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.85),
                ),
              ),
              if (desc.length > 90)
                GestureDetector(
                  onTap: () =>
                      setState(() => _descExpanded = !_descExpanded),
                  child: Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      _descExpanded ? L.t('collapse') : L.t('expandAll'),
                      style: TextStyle(
                        fontSize: 12,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ),
                ),
            ],
          ],
                const SizedBox(height: 18),
                Row(
                  children: [
                    Text(
                      L.t('chapters'),
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '${_chapters.length}',
                      style: TextStyle(
                        fontSize: 12,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                // 章节还在加载时的占位（不再是整页转圈，
                // 详情内容与封面先出来，用户能立刻看到"这是什么"）
                if (_detail == null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Center(
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  ),
                ...List.generate(_chapters.length, (i) {
                  final c = _chapters[i];
                  final active = i == _resumeIndex && _resumeLoaded;
                  return Card(
                    margin: const EdgeInsets.only(bottom: 6),
                    elevation: 0,
                    color: active
                        ? theme.colorScheme.primaryContainer.withValues(alpha: 0.5)
                        : theme.colorScheme.surfaceContainerHighest
                            .withValues(alpha: 0.5),
                    child: ListTile(
                      dense: true,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      title: Text(
                        '${c['title'] ?? ''}',
                        style: const TextStyle(fontSize: 13),
                      ),
                      subtitle: null,
                      trailing:
                          const Icon(Icons.chevron_right_rounded, size: 18),
                      onTap: () => _open(i),
                    ),
                  );
                }),
                if (_chapters.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Center(
                      child: Text(
                        L.t('empty'),
                        style: TextStyle(
                          fontSize: 13,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
    );
  }

  void _open(int index) {
    // 带入该章的阅读进度，实现「继续阅读」
    final p = ReaderStore.instance.progress(widget.nid);
    final ratio = (p != null && p.chapterIndex == index) ? p.ratio : null;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => NovelReadPage(
          nid: widget.nid,
          chapters: _chapters,
          index: index,
          initialRatio: ratio,
          // 带上标题与封面，阅读页写历史时才不是空白
          novelTitle: _displayTitle,
          cover: _coverUrl,
        ),
      ),
    );
  }
}

/// 小说阅读页（参照 legado / KOReader 的能力集）：
/// 分页/滚动双模式、翻页动画、排版面板、主题、目录、书内搜索、
/// 书签、划线批注、TTS 朗读、进度记忆、阅读时长统计、亮度/常亮。
class NovelReadPage extends StatefulWidget {
  final String nid;
  final List<Map<String, dynamic>> chapters;

  /// 作品标题（写阅读历史用；为空时历史里显示空名）
  final String novelTitle;

  /// 作品封面（写阅读历史用）
  final String? cover;

  /// 上次读到的章内比例（0~1）。null = 从头开始。
  final double? initialRatio;
  final int index;

  const NovelReadPage({
    super.key,
    required this.nid,
    required this.chapters,
    required this.index,
    this.initialRatio,
    this.novelTitle = '',
    this.cover,
  });

  @override
  State<NovelReadPage> createState() => _NovelReadPageState();
}

class _NovelReadPageState extends State<NovelReadPage>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  final _service = JmService.instance;
  final _settings = ReaderSettings.instance;
  final _store = ReaderStore.instance;

  // ---- 当前章节 ----
  late int _index;
  Map<String, dynamic>? _data;
  String _text = '';
  bool _loading = true;
  String? _error;

  /// 当前章是否命中本地缓存
  bool _cacheHit = false;

  /// 当前章是否正在写入缓存
  bool _cachingNow = false;

  /// 是否已注册过重排回调（防止 build 内重复注册导致递归）
  bool _rebuildScheduled = false;

  /// 是否正在追加下一话（滚动到底自动续读时防止重复触发）
  bool _appendingNext = false;

  /// 是否已还原过初始进度（只做一次）
  bool _restoredOnce = false;

  // ---- 无缝拼接 ----
  /// 合并后的全文（当前章 + 已预取的后续章节）
  String _mergedText = '';

  /// 合并文本中每章的起始偏移：[{index, start, title}]
  final List<({int index, int start, String title})> _chapterStarts = [];

  /// 已合并进来的最后一章索引
  int _mergedUpto = -1;

  /// 是否正在扩展合并文本
  bool _extending = false;

  // ---- 分页状态 ----
  final List<PageSlice> _pages = [];
  int _page = 0;
  Size _pageArea = Size.zero;

  // ---- 滚动模式 ----
  final _scroll = ScrollController();
  double _scrollRatio = 0;

  // ---- UI 状态 ----
  bool _showMenu = false;

  /// 菜单进出动画（1 = 完全展开，0 = 完全收起）
  late final AnimationController _menuCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 240),
    value: 0,
  );
  bool _showCatalog = false;
  bool _searching = false;
  String _searchQuery = '';
  List<({int chapterIndex, String chapterTitle, int offset, String excerpt})>
      _searchHits = [];

  // ---- 选中/批注 ----
  int? _selStart;
  int? _selEnd;
  TextPainter? _painter;

  // ---- TTS ----
  bool _ttsOn = false;

  /// 自动滚动开关与计时器
  bool _autoScrollOn = false;
  Timer? _autoScrollTimer;
  double _ttsRate = 1.0;
  int _ttsCursor = 0;

  // ---- 统计 ----
  Timer? _statTimer;
  int _statAccum = 0;

  static const _prefsRate = 'tts_rate';

  ReaderTheme get _theme => _settings.theme;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _index = widget.index;
    _settings.addListener(_onSettings);
    _store.loadBook(widget.nid).then((_) {
      if (mounted) setState(() {});
    });
    _load();
    _startStatTimer();
    _restoreTtsRate();
    if (_settings.keepScreenOn) ReaderNative.instance.keepScreenOn(true);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _settings.removeListener(_onSettings);
    _statTimer?.cancel();
    _flushStat();
    _autoScrollTimer?.cancel();
    _menuCtrl.dispose();
    _scroll.dispose();
    _painter?.dispose();
    ReaderNative.instance.ttsStop();
    ReaderNative.instance.keepScreenOn(false);
    ReaderNative.instance.setBrightness(-1);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) _flushStat();
  }

  void _onSettings() {
    if (!mounted) return;
    setState(() {});
    // 排版参数（字号/行距/边距等）变化后需要重排
    _scheduleRebuild();
  }

  Future<void> _restoreTtsRate() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final v = sp.getDouble(_prefsRate);
      if (v != null && mounted) setState(() => _ttsRate = v);
    } catch (_) {}
  }

  // ---------------- 阅读时长 ----------------

  void _startStatTimer() {
    _statTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      _statAccum += 10;
      _settings.addReadingSeconds(10);
      ReadingStats.instance.addSeconds(StatType.novel, 10);
    });
  }

  void _flushStat() {
    if (_statAccum > 0) _statAccum = 0;
  }

  // ---------------- 加载 ----------------

  String _langCode() {
    switch (AppState.instance.lang) {
      case 'CN':
        return 'CN';
      case 'JP':
        return 'JP';
      case 'EN':
        return 'EN';
      default:
        return 'TW';
    }
  }

  String get _chapterKey => '${widget.chapters[_index]['ncid'] ?? ''}';

  String get _chapterTitle {
    final t = '${widget.chapters[_index]['title'] ?? ''}';
    if (t.isNotEmpty) return t;
    return '${_data?['title'] ?? _data?['name'] ?? ''}';
  }

  Future<void> _load({int? jumpToChapter}) async {
    if (jumpToChapter != null) {
      setState(() => _index = jumpToChapter);
    }
    setState(() {
      _loading = true;
      _error = null;
      _pages.clear();
      _page = 0;
      _selStart = null;
      _selEnd = null;
    });
    try {
      // ---- 先缓存再看：命中本地缓存直接读取 ----
      final ncid = _chapterKey;
      final cached = await NovelCacheManager.instance.get(widget.nid, ncid);
      if (cached != null && '${cached['text'] ?? ''}'.isNotEmpty) {
        if (!mounted) return;
        setState(() {
          _data = {'title': cached['title']};
          _text = '${cached['text']}';
          _loading = false;
          _cacheHit = true;
          _cachingNow = false;
        });
        // 命中缓存：同样构建合并文本
        _mergedText = '${cached['text']}';
        _chapterStarts.clear();
        _chapterStarts.add((
          index: _index,
          start: 0,
          title: _chapterTitle,
        ));
        _mergedUpto = _index;
        _rebuildPages();
        _saveProgress();
        if (_scroll.hasClients) _scroll.jumpTo(0);
        unawaited(() async {
          await _extendMerged(count: 3);
          if (mounted) _scheduleRebuild();
        }());
        return;
      }

      // 未命中：下载后落盘，再显示（保证「先缓存再看」）
      setState(() {
        _cacheHit = false;
        _cachingNow = true;
      });
      final d = await _service.fetchNovelContent(
        ncid: ncid,
        lang: _langCode(),
      );
      if (!mounted) return;
      final raw = _htmlToText('${d?['content'] ?? ''}');
      if (!mounted) return;

      // 流式：先立刻渲染正文，不等加密落盘
      setState(() {
        _data = d;
        _text = raw;
        _loading = false;
        _cachingNow = raw.isNotEmpty; // 后台写盘中
        _cacheHit = false;
      });
      // 构建合并文本：本章 + 后续预取章节（实现无缝续读）
      _mergedText = raw;
      _chapterStarts.clear();
      _chapterStarts.add((
        index: _index,
        start: 0,
        title: _chapterTitle,
      ));
      _mergedUpto = _index;
      if (raw.isNotEmpty) {
        // 后台补齐后续章节并重新分页
        unawaited(() async {
          await _extendMerged(count: 3);
          if (mounted) _scheduleRebuild();
        }());
      }

      _scheduleRebuild();
      _saveProgress();
      // 统计：记录一次小说阅读（按类型 'novel'）
      if (raw.isNotEmpty) {
        ReadingStats.instance.recordChapter(
          type: StatType.novel,
          workId: widget.nid,
        );
        // 写入阅读历史：之前小说**从不写历史**，所以历史列表里
        // 永远没有小说、也就谈不上「保存进度」。
        _recordHistory(ncid, raw);
      }
      if (_scroll.hasClients) _scroll.jumpTo(0);

      // 后台写入加密缓存（不阻塞阅读）
      if (raw.isNotEmpty) {
        unawaited(() async {
          try {
            await NovelCacheManager.instance.put(
              widget.nid,
              ncid,
              _chapterTitle,
              raw,
            );
          } catch (_) {}
          if (mounted) {
            setState(() {
              _cacheHit = true;
              _cachingNow = false;
            });
          }
        }());
      } else {
        setState(() => _cachingNow = false);
      }

      _prefetchNext();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }


  /// 后台预取下一章（动态加载）：静默下载并落盘，翻页时直接命中。
  ///
  /// 顺序约定：始终只预取「当前章 + 1」，因此缓存推进必然是
  /// 从第一章往后连续进行，不会出现随机顺序。

  /// 预取后续 [count] 章并拼接到合并文本。
  Future<void> _extendMerged({int count = 3}) async {
    if (_extending) return;
    _extending = true;
    try {
      final end = (_mergedUpto + count).clamp(0, widget.chapters.length - 1);
      for (var i = _mergedUpto + 1; i <= end; i++) {
        final ncid = '${widget.chapters[i]['ncid'] ?? ''}';
        if (ncid.isEmpty) continue;
        final title = '${widget.chapters[i]['title'] ?? ''}';

        String body = '';
        final cached = await NovelCacheManager.instance.get(widget.nid, ncid);
        if (cached != null && '${cached['text'] ?? ''}'.isNotEmpty) {
          body = '${cached['text']}';
        } else {
          try {
            final d = await _service.fetchNovelContent(
              ncid: ncid,
              lang: _langCode(),
            );
            body = _htmlToText('${d?['content'] ?? ''}');
            if (body.isNotEmpty) {
              unawaited(
                NovelCacheManager.instance.put(widget.nid, ncid, title, body),
              );
            }
          } catch (_) {
            break; // 网络失败则停止续接
          }
        }
        if (body.isEmpty) break;

        // 记录本章在合并文本中的起点
        _chapterStarts.add((
          index: i,
          start: _mergedText.length,
          title: title,
        ));
        // 章间插入分隔（标题 + 空行）
        if (_mergedText.isNotEmpty) {
          _mergedText += '\n\n\u2014\u2014 $title \u2014\u2014\n\n';
          // 起点应为标题之后
          final last = _chapterStarts.removeLast();
          _chapterStarts.add((
            index: last.index,
            start: _mergedText.length,
            title: last.title,
          ));
        }
        _mergedText += body;
        _mergedUpto = i;
      }
    } finally {
      _extending = false;
    }
  }

  Future<void> _prefetchNext() async {
    // 用户可关闭自动预取（省流量/省电）
    if (!AppState.instance.prefetchNextChapter) return;
    final next = _index + 1;
    if (next >= widget.chapters.length) return;
    final ncid = '${widget.chapters[next]['ncid'] ?? ''}';
    if (ncid.isEmpty) return;
    if (await NovelCacheManager.instance.has(widget.nid, ncid)) return;
    try {
      final d = await _service.fetchNovelContent(ncid: ncid, lang: _langCode());
      final raw = _htmlToText('${d?['content'] ?? ''}');
      if (raw.isEmpty) return;
      await NovelCacheManager.instance.put(
        widget.nid,
        ncid,
        '${widget.chapters[next]['title'] ?? ''}',
        raw,
      );
    } catch (_) {}
  }

  /// HTML → 纯文本（保留段落）。
  String _htmlToText(String html) {
    if (html.trim().isEmpty) return '';
    var s = html;
    s = s.replaceAll(RegExp(r'<\s*br\s*/?\s*>', caseSensitive: false), '\n');
    s = s.replaceAll(RegExp(r'</\s*p\s*>', caseSensitive: false), '\n\n');
    s = s.replaceAll(RegExp(r'<\s*p[^>]*>', caseSensitive: false), '');
    s = s.replaceAll(RegExp(r'<[^>]+>'), '');
    s = s
        .replaceAll('&hellip;', '…')
        .replaceAll('&mdash;', '—')
        .replaceAll('&ndash;', '–')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&apos;', "'")
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&amp;', '&');
    s = s
        .split('\n')
        .map((l) => l.replaceAll(RegExp(r'^[\s\u3000]+|[\s\u3000]+$'), ''))
        .join('\n');
    s = s.replaceAll(RegExp(r'\n{3,}'), '\n\n');
    return s.trim();
  }

  // ---------------- 分页 ----------------

  /// 安排一次重排（幂等）：同一帧内多次调用只会执行一次。
  void _scheduleRebuild() {
    if (_loading) return;
    if (_settings.pageMode == PageMode.scroll) return;
    if (_rebuildScheduled) return;
    _rebuildScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _rebuildScheduled = false;
      if (!mounted) return;
      if (_pageArea.width <= 0 || _pageArea.height <= 0) return;
      _rebuildPages();
      _restoreInitialRatioOnce();
    });
  }

  /// 首次渲染后，把阅读位置还原到上次保存的比例。
  void _restoreInitialRatioOnce() {
    if (_restoredOnce) return;
    final ratio = widget.initialRatio;
    if (ratio == null || ratio <= 0) {
      _restoredOnce = true;
      return;
    }
    _restoredOnce = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_settings.pageMode == PageMode.scroll) {
        if (!_scroll.hasClients) return;
        final max = _scroll.position.maxScrollExtent;
        _scroll.jumpTo((max * ratio).clamp(0.0, max));
      } else {
        if (_pages.isEmpty) return;
        final target =
            (ratio * (_pages.length - 1)).round().clamp(0, _pages.length - 1);
        setState(() => _page = target);
      }
    });
  }

  /// 分页所用的正文：优先用合并文本（无缝续读），否则用单章文本
  String get _pageSource =>
      _mergedText.isNotEmpty ? _mergedText : _text;

  void _rebuildPages() {
    final src = _pageSource;
    if (src.isEmpty) return;
    if (_pageArea.width <= 0 || _pageArea.height <= 0) return;
    final style = _settings.textStyleFor(_theme);
    final w = _pageArea.width - _settings.marginH * 2;
    // 顶部扣掉状态栏，底部扣掉进度栏，避免正文被遮挡/离得太远
    // SafeArea 已避开状态栏，这里只扣边距与进度栏
    final bottomInset = _settings.showProgress ? 34.0 : 0.0;
    final h = _pageArea.height - _settings.marginV * 2 - bottomInset;
    if (w <= 0 || h <= 0) return;

    final paginator = const TextPaginator();
    final pages = paginator.paginate(
      text: src,
      style: style,
      maxWidth: w,
      maxHeight: h,
      align: _settings.align,
      paragraphSpacing: _settings.paragraphSpacing,
      indentEm: _settings.indent,
    );


    // 尝试恢复章节内进度
    final prev = _store.progress(widget.nid);
    var startPage = 0;
    if (prev != null && prev.chapterIndex == _index && pages.isNotEmpty) {
      startPage = (prev.ratio * pages.length).floor().clamp(0, pages.length - 1);
    }

    setState(() {
      _pages
        ..clear()
        ..addAll(pages);
      _page = startPage;
    });
  }

  // ---------------- 进度 ----------------

  double get _chapterRatio {
    if (_settings.pageMode == PageMode.scroll) return _scrollRatio;
    if (_pages.isEmpty) return 0;
    return (_page + 1) / _pages.length;
  }

  Future<void> _saveProgress() async {
    try {
      await _store.saveProgress(
        widget.nid,
        chapterIndex: _index,
        ratio: _chapterRatio.clamp(0.0, 1.0),
        chapterTitle: _chapterTitle,
      );
    } catch (_) {}
    // 同步刷新阅读历史里的页码（页号用「当前页 / 总页」近似）
    final total = _pages.isEmpty ? 0 : _pages.length;
    final cur = _pages.isEmpty ? 0 : (_page + 1).clamp(0, total);
    AppState.instance.updateHistoryProgress(
      comicId: widget.nid,
      chapterId: _chapterKey,
      page: cur,
      totalPage: total,
    );
  }

  /// 把当前小说章节写入阅读历史（kind = novel）。
  void _recordHistory(String ncid, String text) {
    final total = _pages.isEmpty ? 0 : _pages.length;
    AppState.instance.recordHistory(
      ReadHistoryEntry(
        comicId: widget.nid,
        chapterId: ncid,
        comicName: widget.novelTitle,
        chapterName: _chapterTitle,
        cover: widget.cover,
        source: 'jm',
        kind: 'novel',
        page: _pages.isEmpty ? 1 : (_page + 1).clamp(1, total),
        totalPage: total > 0 ? total : text.length,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  /// 进度文案：分页模式显示「页/总页」，滚动模式显示百分比
  String _pageLabel() {
    if (_settings.pageMode == PageMode.scroll) {
      return '${(_scrollRatio * 100).toStringAsFixed(0)}%';
    }
    if (_pages.isEmpty) return '—';
    return '${_page + 1}/${_pages.length}';
  }

  /// 跳转到指定页（滑块拖动用）
  void _turnTo(int index) {
    if (_settings.pageMode == PageMode.scroll) {
      // 滚动模式：按比例滚到对应位置
      if (!_scroll.hasClients || _pages.isEmpty) return;
      final ratio = _pages.length <= 1
          ? 0.0
          : (index / (_pages.length - 1)).clamp(0.0, 1.0);
      _scroll.animateTo(
        ratio * _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
      );
      return;
    }
    if (index < 0 || index >= _pages.length) return;
    setState(() => _page = index);
    _saveProgress();
  }

  void _turnPage(int delta) {
    // 滚动模式：按「一屏高度」滚动，而不是直接返回
    if (_settings.pageMode == PageMode.scroll) {
      if (!_scroll.hasClients) return;
      final viewport = _scroll.position.viewportDimension;
      final target = (_scroll.offset + delta * viewport * 0.92)
          .clamp(0.0, _scroll.position.maxScrollExtent);
      _scroll.animateTo(
        target,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
      );
      return;
    }
    final target = _page + delta;
    if (target >= 0 && target < _pages.length) {
      setState(() => _page = target);
      _saveProgress();
      return;
    }
    // 越界：自动衔接上一话 / 下一话（全话连续阅读，无需手动切换）
    final ni = _index + delta;
    if (ni < 0 || ni >= widget.chapters.length) return;
    _load(jumpToChapter: ni);
  }

  // ---------------- 菜单动作 ----------------

  void _toggleMenu() {
    if (_showMenu) {
      // 收起：反向滑出，动画结束后再移除
      _menuCtrl.reverse().then((_) {
        if (!mounted) return;
        setState(() {
          _showMenu = false;
          _showCatalog = false;
        });
      });
    } else {
      setState(() => _showMenu = true);
      _menuCtrl.forward(from: 0);
    }
  }

  Future<void> _addBookmark() async {
    final offset = _settings.pageMode == PageMode.scroll
        ? 0
        : (_pages.isNotEmpty ? _pages[_page].start : 0);
    final excerpt = _text.length > offset + 60
        ? _text.substring(offset, offset + 60)
        : (offset < _text.length ? _text.substring(offset) : '');
    await _store.addBookmark(
      widget.nid,
      ReaderBookmark(
        bookId: widget.nid,
        chapterKey: _chapterKey,
        chapterTitle: _chapterTitle,
        offset: offset,
        excerpt: excerpt.replaceAll('\n', ' '),
        createdAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    // 同时写入**全局章节书签**：这样小说书签也能在书架「书签」页
    // 和漫画书签一起统一浏览（含页码与批注）。
    await AppState.instance.setChapterBookmark(
      comicId: widget.nid,
      chapterId: _chapterKey,
      comicName: widget.novelTitle,
      chapterName: _chapterTitle,
      cover: widget.cover ?? '',
      source: 'jm',
      on: true,
      page: _pages.isEmpty ? 1 : (_page + 1).clamp(1, _pages.length),
      kind: 'novel',
      note: excerpt.replaceAll('\n', ' '),
    );
    if (!mounted) return;
    setState(() {});
    _toast(L.t('bookmarkAdded'));
  }

  Future<void> _searchInBook(String q) async {
    final query = q.trim();
    if (query.isEmpty) return;
    setState(() {
      _searching = true;
      _searchQuery = query;
      _searchHits = [];
    });

    final hits =
        <({int chapterIndex, String chapterTitle, int offset, String excerpt})>[];
    final lock = Object();

    // 并发拉取（限流 4），已缓存章节直接读本地，避免打爆服务端
    var cursor = 0;

    Future<void> worker() async {
      while (true) {
        final i = cursor++;
        if (i >= widget.chapters.length) return;
        if (!mounted) return;

        final ncid = '${widget.chapters[i]['ncid'] ?? ''}';
        if (ncid.isEmpty) continue;

        String text = '';
        try {
          // 优先读本地缓存
          final cached = await NovelCacheManager.instance.get(widget.nid, ncid);
          if (cached != null && '${cached['text'] ?? ''}'.isNotEmpty) {
            text = '${cached['text']}';
          } else if (i == _index) {
            text = _text;
          } else {
            final d =
                await _service.fetchNovelContent(ncid: ncid, lang: _langCode());
            text = _htmlToText('${d?['content'] ?? ''}');
          }
        } catch (_) {
          continue;
        }
        if (text.isEmpty) continue;

        var from = 0;
        var count = 0;
        while (count < 20) {
          final at = text.indexOf(query, from);
          if (at < 0) break;
          final st = math.max(0, at - 24);
          final en = math.min(text.length, at + query.length + 24);
          final hit = (
            chapterIndex: i,
            chapterTitle: '${widget.chapters[i]['title'] ?? ''}',
            offset: at,
            excerpt: text.substring(st, en).replaceAll('\n', ' '),
          );
          synchronized(lock, () => hits.add(hit));
          from = at + query.length;
          count++;
        }

        if (mounted) {
          setState(() => _searchHits = List.of(hits));
        }
        if (hits.length > 300) return;
      }
    }

    await Future.wait(
      List.generate(4.clamp(1, widget.chapters.length), (_) => worker()),
    );

    if (!mounted) return;
    setState(() {
      _searching = false;
      _searchHits = hits;
    });
  }

  /// 极简同步锁：保证并发写 hits 时不会错乱。
  void synchronized(Object lock, void Function() fn) {
    // Dart 单线程事件循环下，同步代码块本身即为原子操作
    fn();
  }

  void _jumpToHit(int chapterIndex, int offset) {
    setState(() {
      _showCatalog = false;
      _showMenu = false;
    });
    if (chapterIndex != _index) {
      _load(jumpToChapter: chapterIndex).then((_) => _pageOfOffset(offset));
    } else {
      _pageOfOffset(offset);
    }
  }

  void _pageOfOffset(int offset) {
    // 滚动模式：按「字符偏移占全文的比例」滚动到对应位置
    if (_settings.pageMode == PageMode.scroll) {
      if (!_scroll.hasClients) return;
      final total = _pageSource.length;
      if (total <= 0) return;
      final ratio = (offset / total).clamp(0.0, 1.0);
      final target = ratio * _scroll.position.maxScrollExtent;
      _scroll.animateTo(
        target,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
      );
      return;
    }
    if (_pages.isEmpty) return;
    final i = _pages.indexWhere((p) => offset >= p.start && offset < p.end);
    if (i >= 0 && mounted) setState(() => _page = i);
  }

  // ---------------- TTS ----------------

  /// 朗读按钮：已开 → 停止；未开 → 先打开设置面板再开始
  /// 自动滚动：定时器按速度推进滚动位置。
  void _toggleAutoScroll() {
    if (_autoScrollOn) {
      _autoScrollTimer?.cancel();
      _autoScrollTimer = null;
      setState(() => _autoScrollOn = false);
      return;
    }
    // 分页模式下自动滚动无意义，先切到滚动模式
    if (_settings.pageMode != PageMode.scroll) {
      _settings.update(() => _settings.pageMode = PageMode.scroll);
      _rebuildPages();
    }
    setState(() => _autoScrollOn = true);
    // 每 50ms 推进一次，速度来自设置（像素/秒）
    _autoScrollTimer =
        Timer.periodic(const Duration(milliseconds: 50), (_) {
      if (!mounted || !_autoScrollOn) return;
      if (!_scroll.hasClients) return;
      final step = _settings.autoScrollSpeed * 0.05;
      final next = _scroll.offset + step;
      final max = _scroll.position.maxScrollExtent;
      if (next >= max) {
        // 到底：尝试追加下一话
        _maybeLoadNextOnScroll(max, max);
        return;
      }
      _scroll.jumpTo(next);
    });
  }

  void _stopAutoScroll() {
    _autoScrollTimer?.cancel();
    _autoScrollTimer = null;
    if (_autoScrollOn && mounted) setState(() => _autoScrollOn = false);
  }

  Future<void> _onTtsPressed() async {
    if (_ttsOn) {
      await _toggleTts();
      return;
    }
    _showTtsSheet();
  }

  void _showTtsSheet() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: _theme.bg,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => NovelTtsSheet(
        settings: _settings,
        theme: _theme,
        onChanged: () => setState(() {}),
        onStart: () => _toggleTts(),
      ),
    );
  }

  Future<void> _toggleTts() async {
    if (_ttsOn) {
      await ReaderNative.instance.ttsStop();
      setState(() => _ttsOn = false);
      return;
    }
    final ok = await ReaderNative.instance.ttsInit();
    if (!ok) {
      if (mounted) _toast(L.t('ttsUnavailable'));
      return;
    }
    // 应用已保存的朗读参数
    await ReaderNative.instance.ttsSetRate(_settings.ttsRate);
    await ReaderNative.instance.ttsSetPitch(_settings.ttsPitch);
    if (_settings.ttsVoiceName.isNotEmpty) {
      await ReaderNative.instance.ttsSetVoice(_settings.ttsVoiceName);
    }
    // 从「当前屏幕第一个可见字」开始朗读
    _ttsCursor = _visibleStartOffset();
    setState(() => _ttsOn = true);
    _speakFrom(_ttsCursor);
  }

  /// 当前屏幕可见内容的起始字符偏移。
  ///
  /// - 分页模式：当前页起点
  /// - 滚动模式：按滚动比例换算到全文字符位置，并退到段落起点
  int _visibleStartOffset() {
    final src = _pageSource;
    if (src.isEmpty) return 0;

    if (_settings.pageMode == PageMode.scroll) {
      final ratio = _scrollRatio.clamp(0.0, 1.0);
      final at = (src.length * ratio).round().clamp(0, src.length - 1);
      final nl = src.lastIndexOf('\n', at);
      return (nl >= 0 ? nl + 1 : at).clamp(0, src.length - 1);
    }
    if (_pages.isEmpty) return 0;
    return _pages[_page].start.clamp(0, src.length - 1);
  }

  void _speakFrom(int offset) {
    if (!_ttsOn) return;
    final chunk = _text.substring(math.min(offset, _text.length));
    if (chunk.trim().isEmpty) {
      // 本章读完 → 下一章
      if (_index < widget.chapters.length - 1) {
        _load(jumpToChapter: _index + 1).then((_) {
          _ttsCursor = 0;
          Future.delayed(const Duration(milliseconds: 400), () {
            if (_ttsOn) _speakFrom(0);
          });
        });
      } else {
        setState(() => _ttsOn = false);
      }
      return;
    }
    // 一次最多播 400 字，播完继续
    final piece = chunk.length > 400 ? chunk.substring(0, 400) : chunk;
    ReaderNative.instance.onUtteranceDone = () {
      if (!mounted || !_ttsOn) return;
      _ttsCursor = offset + piece.length;
      if (_settings.pageMode != PageMode.scroll) _pageOfOffset(_ttsCursor);
      Future.delayed(const Duration(milliseconds: 150), () {
        if (_ttsOn) _speakFrom(_ttsCursor);
      });
    };
    ReaderNative.instance.ttsSpeak(
      text: piece,
      rate: _ttsRate,
      locale: _ttsLocale(),
    );
  }

  String _ttsLocale() {
    switch (AppState.instance.lang) {
      case 'JP':
        return 'ja-JP';
      case 'EN':
        return 'en-US';
      default:
        return 'zh-CN';
    }
  }


  // ---------------- 选中与批注 ----------------

  void _handleSelection(TextSelection sel) {
    if (sel.isCollapsed) {
      setState(() {
        _selStart = null;
        _selEnd = null;
      });
      return;
    }
    // 选区偏移相对当前页文本 → 转全局
    final base = _pages.isNotEmpty ? _pages[_page].start : 0;
    setState(() {
      _selStart = base + sel.start;
      _selEnd = base + sel.end;
    });
  }

  Future<void> _addHighlight({String note = '', int colorIndex = 0}) async {
    final s = _selStart;
    final e = _selEnd;
    if (s == null || e == null || e <= s) return;
    final a = ReaderAnnotation(
      id: '${DateTime.now().microsecondsSinceEpoch}',
      bookId: widget.nid,
      chapterKey: _chapterKey,
      chapterTitle: _chapterTitle,
      start: s,
      end: e,
      text: _text.substring(s.clamp(0, _text.length), e.clamp(0, _text.length)),
      note: note,
      colorIndex: colorIndex,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    await _store.addAnnotation(widget.nid, a);
    if (!mounted) return;
    setState(() {
      _selStart = null;
      _selEnd = null;
    });
    _toast(L.t('highlightAdded'));
  }

  Future<void> _copySelection() async {
    final s = _selStart;
    final e = _selEnd;
    if (s == null || e == null || e <= s) return;
    await Clipboard.setData(
      ClipboardData(
        text: _text.substring(s.clamp(0, _text.length), e.clamp(0, _text.length)),
      ),
    );
    if (!mounted) return;
    setState(() {
      _selStart = null;
      _selEnd = null;
    });
    _toast(L.t('copied'));
  }

  void _toast(String s) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(s),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(milliseconds: 1400),
      ),
    );
  }

  // ---------------- 构建 ----------------

  @override
  Widget build(BuildContext context) {
    final bg = _theme.bg;
    // 阅读器主题可能和 App 主题不同（例如 App 深色 + 阅读米色），
    // 因此这里按「阅读主题」的亮度单独声明状态栏样式，
    // 避免状态栏图标与正文底色割裂。
    final readerIsDark = bg.computeLuminance() < 0.5;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness:
            readerIsDark ? Brightness.light : Brightness.dark,
        statusBarBrightness:
            readerIsDark ? Brightness.dark : Brightness.light,
        systemNavigationBarColor: bg,
        systemNavigationBarIconBrightness:
            readerIsDark ? Brightness.light : Brightness.dark,
      ),
      child: Scaffold(
      backgroundColor: bg,
      // 用 SafeArea 让正文避开状态栏（比手动累加 padding 可靠，
      // 之前直接算 MediaQuery.padding.top 仍会被遮挡）
      body: SafeArea(
        bottom: false,
        child: LayoutBuilder(
        builder: (context, constraints) {
          // 只记录尺寸（纯赋值，无副作用）。
          // 真正的重排由 _scheduleRebuild() 在明确时机触发，
          // 避免在 build 里注册回调造成递归重排。
          final size = Size(constraints.maxWidth, constraints.maxHeight);
          if (size != _pageArea) {
            _pageArea = size;
            _scheduleRebuild();
          }
          return Stack(
            children: [
              Positioned.fill(child: _buildContent(size)),
              if (_settings.brightness != 0)
                Positioned.fill(
                  child: IgnorePointer(
                    child: ColoredBox(
                      color: overlayFor(_settings.brightness),
                    ),
                  ),
                ),
              if (_showMenu)
                Positioned.fill(
                  child: NovelMenuOverlay(
                    animation: _menuCtrl,
                    theme: _theme,
                    title: _chapterTitle,
                    chapterIndex: _index,
                    chapterCount: widget.chapters.length,
                    pageLabel: _pageLabel(),
                    onClose: _toggleMenu,
                    onBack: () => Navigator.of(context).maybePop(),
                    onCatalog: () {
                      setState(() {
                        _showMenu = false;
                        _showCatalog = true;
                      });
                    },
                    onSearch: () {
                      setState(() {
                        _showMenu = false;
                        _showCatalog = true;
                        _searching = true;
                      });
                    },
                    onTypography: _showSettingsSheet,
                    onTheme: _showThemeSheet,
                    onBookmark: _addBookmark,
                    onTts: _onTtsPressed,
                    ttsOn: _ttsOn,
                    onAutoScroll: _toggleAutoScroll,
                    autoScrolling: _autoScrollOn,
                    progress: _chapterRatio,
                    onProgressChanged: (v) {
                      final total = _pages.isNotEmpty
                          ? _pages.length
                          : 1;
                      final target =
                          (v * (total - 1)).round().clamp(0, total - 1);
                      _turnTo(target);
                    },
                  ),
                ),
              if (_showCatalog)
                Positioned.fill(
                  child: NovelCatalogOverlay(
                    theme: _theme,
                    chapters: widget.chapters,
                    currentIndex: _index,
                    onClose: () => setState(() {
                      _showCatalog = false;
                      _searching = false;
                    }),
                    onPick: (i) {
                      setState(() {
                        _showCatalog = false;
                        _searching = false;
                      });
                      if (i != _index) _load(jumpToChapter: i);
                    },
                    searchQuery: _searchQuery,
                    onSearchChanged: (q) {
                      setState(() => _searchQuery = q);
                      if (q.trim().isNotEmpty) _searchInBook(q);
                    },
                    searching: _searching,
                    hits: _searchHits,
                    onPickHit: _jumpToHit,
                  ),
                ),
              if (_settings.showProgress && !_showMenu)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 6,
                  child: IgnorePointer(child: _buildFooter()),
                ),
            ],
          );
        },
        ),
      ),
    ),
    );
  }

  Widget _buildContent(Size size) {
    if (_loading) {
      return Center(
        child: CircularProgressIndicator(color: _theme.subtle),
      );
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(L.t('loadFailed'), style: TextStyle(color: _theme.subtle)),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: () => _load(),
              style: OutlinedButton.styleFrom(
                foregroundColor: _theme.fg,
                side: BorderSide(color: _theme.subtle),
              ),
              child: Text(L.t('retry')),
            ),
          ],
        ),
      );
    }
    if (_text.isEmpty) {
      return Center(
        child: Text(L.t('needLoginBuy'), style: TextStyle(color: _theme.subtle)),
      );
    }
    // 正文渲染交给独立的 NovelTextView（分页 / 滚动两种模式内部处理），
    // 外层再套翻页动画
    return _withPageAnimation(
      NovelTextView(
      settings: _settings,
      theme: _theme,
      pageSource: _pageSource,
      pages: _pages,
      currentPage: _page,
      scrollController: _scroll,
      scrollRatio: _scrollRatio,
      highlightRanges: _currentHighlightRanges(),
      onTurn: _turnPage,
      onTap: () {
        // 用户主动操作 → 暂停自动滚动
        _stopAutoScroll();
        _toggleMenu();
      },
      onSelectionChanged: _handleSelection,
      onContextMenu: _buildSelectionMenu,
      onScrollNearBottom: _maybeLoadNextOnScroll,
      onScrollRatioChanged: (r) {
        setState(() => _scrollRatio = r);
        _saveProgress();
      },
      bookId: widget.nid,
      chapterKey: _chapterKey,
      chapterTitle: _chapterTitle,
      highlights: _store.annotations(widget.nid, chapterKey: _chapterKey),
      ),
    );
  }

  /// 翻页动画包装：按 PageMode 为每页加上切换效果。
  ///
  /// 解耦后动画曾丢失，这里恢复：
  /// - slide：横向滑动
  /// - cover：新页从右覆盖旧页
  /// - none：无动画
  /// - scroll：不需要（整章连续滚动）
  Widget _withPageAnimation(Widget child) {
    if (_settings.pageMode == PageMode.scroll) return child;

    switch (_settings.pageMode) {
      case PageMode.none:
        return child;

      case PageMode.cover:
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 280),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.linear,
          transitionBuilder: (c, animation) {
            final incoming = c.key == ValueKey('pg$_page');
            if (!incoming) return c; // 旧页定格，被新页覆盖
            return SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(1, 0),
                end: Offset.zero,
              ).animate(animation),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: _theme.bg,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.25),
                      blurRadius: 14,
                      offset: const Offset(-6, 0),
                    ),
                  ],
                ),
                child: c,
              ),
            );
          },
          layoutBuilder: (current, previous) => Stack(
            alignment: Alignment.topLeft,
            children: [...previous, if (current != null) current],
          ),
          child: KeyedSubtree(key: ValueKey('pg$_page'), child: child),
        );

      case PageMode.slide:
      default:
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 240),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          transitionBuilder: (c, animation) {
            final incoming = c.key == ValueKey('pg$_page');
            final begin = incoming
                ? const Offset(0.12, 0)
                : const Offset(-0.06, 0);
            return FadeTransition(
              opacity: animation,
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: begin,
                  end: Offset.zero,
                ).animate(animation),
                child: c,
              ),
            );
          },
          layoutBuilder: (current, previous) => Stack(
            alignment: Alignment.topLeft,
            children: [...previous, if (current != null) current],
          ),
          child: KeyedSubtree(key: ValueKey('pg$_page'), child: child),
        );
    }
  }

  /// 当前页（或滚动位置）对应的高亮范围。
  List<({int start, int end, Color color, bool underline})>
      _currentHighlightRanges() {
    final anns = _store.annotations(widget.nid, chapterKey: _chapterKey);
    if (anns.isEmpty) return const [];

    // 滚动模式：全文范围；分页模式：当前页范围
    int baseStart = 0;
    int baseEnd = _pageSource.length;
    if (_settings.pageMode != PageMode.scroll && _pages.isNotEmpty) {
      baseStart = _pages[_page].start;
      baseEnd = _pages[_page].end;
    }

    final out = <({int start, int end, Color color, bool underline})>[];
    for (final a in anns) {
      if (a.end <= baseStart || a.start >= baseEnd) continue;
      out.add((
        start: (a.start - baseStart).clamp(0, baseEnd - baseStart),
        end: (a.end - baseStart).clamp(0, baseEnd - baseStart),
        color: _highlightColors[a.colorIndex % _highlightColors.length]
            .withValues(alpha: 0.35),
        underline: a.note.isNotEmpty,
      ));
    }
    return out;
  }

  Widget _buildFooter() {
    final total = widget.chapters.length;
    final percent = (_chapterRatio * 100).toStringAsFixed(1);
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          '$_chapterTitle  ·  $percent%',
          style: TextStyle(fontSize: 10.5, color: _theme.subtle),
        ),
        if (_pages.isNotEmpty && _settings.pageMode != PageMode.scroll) ...[
          Text(
            '  ·  ${_page + 1}/${_pages.length}',
            style: TextStyle(fontSize: 10.5, color: _theme.subtle),
          ),
        ],
        Text(
          '  ·  ${_index + 1}/$total',
          style: TextStyle(fontSize: 10.5, color: _theme.subtle),
        ),
        if (_cachingNow)
          Text(
            '  ·  ${L.t('caching')}',
            style: TextStyle(fontSize: 10.5, color: _theme.subtle),
          )
        else if (_cacheHit)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(width: 6),
              Icon(Icons.offline_pin_rounded,
                  size: 11, color: _theme.subtle),
            ],
          ),
      ],
    );
  }

  // ---- 分页模式 ----


  Widget _buildSelectionMenu(
    BuildContext context,
    EditableTextState editableTextState,
  ) {
    final items = <ContextMenuButtonItem>[
      ContextMenuButtonItem(
        label: L.t('copy'),
        onPressed: () {
          editableTextState.copySelection(SelectionChangedCause.toolbar);
          _copySelection();
        },
      ),
      ContextMenuButtonItem(
        label: L.t('highlight'),
        onPressed: () {
          _addHighlight();
          editableTextState.hideToolbar();
        },
      ),
      ContextMenuButtonItem(
        label: L.t('annotate'),
        onPressed: () {
          editableTextState.hideToolbar();
          _askNote();
        },
      ),
    ];
    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: editableTextState.contextMenuAnchors,
      buttonItems: items,
    );
  }

  Future<void> _askNote() async {
    final ctrl = TextEditingController();
    final note = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(L.t('annotate')),
        content: TextField(
          controller: ctrl,
          maxLines: 4,
          autofocus: true,
          decoration: InputDecoration(hintText: L.t('noteHint')),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(L.t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: Text(L.t('ok')),
          ),
        ],
      ),
    );
    if (note != null && note.isNotEmpty) {
      await _addHighlight(note: note, colorIndex: 1);
    }
  }

  static const List<Color> _highlightColors = [
    Color(0xFFFFEB3B),
    Color(0xFF4CAF50),
    Color(0xFF2196F3),
    Color(0xFFE91E63),
  ];

  // ---- 滚动模式 ----

  /// 滚动模式下，接近底部时自动加载下一话（连续阅读）。
  /// 滚动接近底部时，把下一话**追加**到当前正文末尾。
  ///
  /// 注意：不是 `_load(jumpToChapter)`（那会替换正文、把用户传送走），
  /// 而是延长 `_mergedText` 并重新分页，滚动位置保持不变。
  void _maybeLoadNextOnScroll(double pixels, double maxExtent) {
    if (_settings.pageMode != PageMode.scroll) return;
    if (maxExtent <= 0) return;
    // 距底部 200px 内开始预加载，保证无缝
    if (pixels < maxExtent - 200) return;
    if (_mergedUpto >= widget.chapters.length - 1) return;
    if (_appendingNext) return;

    _appendingNext = true;
    final keepOffset = _scroll.hasClients ? _scroll.offset : null;

    _appendNextChapter().whenComplete(() {
      _appendingNext = false;
      // 追加后内容变长，保持原阅读位置不跳
      if (keepOffset != null && mounted && _scroll.hasClients) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !_scroll.hasClients) return;
          final max = _scroll.position.maxScrollExtent;
          _scroll.jumpTo(keepOffset.clamp(0.0, max));
        });
      }
    });
  }

  /// 把下一话正文拼接到 `_mergedText` 末尾（带分隔线）。
  Future<void> _appendNextChapter() async {
    final next = _mergedUpto + 1;
    if (next >= widget.chapters.length) return;

    final ncid = '${widget.chapters[next]['ncid'] ?? ''}';
    if (ncid.isEmpty) return;
    final nextTitle = '${widget.chapters[next]['title'] ?? ''}';

    // 取正文：优先缓存，否则网络
    var body = '';
    try {
      final cached = await NovelCacheManager.instance.get(widget.nid, ncid);
      body = '${cached?['text'] ?? ''}';
      if (body.isEmpty) {
        final d = await _service.fetchNovelContent(
          ncid: ncid,
          lang: _langCode(),
        );
        body = _htmlToText('${d?['content'] ?? ''}');
        if (body.isNotEmpty) {
          unawaited(NovelCacheManager.instance.put(
            widget.nid,
            ncid,
            nextTitle,
            body,
          ));
        }
      }
    } catch (_) {
      return;
    }
    if (body.isEmpty || !mounted) return;

    setState(() {
      // 章间分隔线
      _mergedText += '\n\n\n'
          '──────── $nextTitle ────────'
          '\n\n';
      _chapterStarts.add((
        index: next,
        start: _mergedText.length,
        title: nextTitle,
      ));
      _mergedText += body;
      _mergedUpto = next;
    });
    _scheduleRebuild();
  }


  // ---- 菜单 ----



  // ---- 目录 / 搜索抽屉 ----




  // ---- 设置面板 ----

  void _showSettingsSheet() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: _theme.bg,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setS) => NovelTypographySheet(
          settings: _settings,
          theme: _theme,
          onChanged: () {
            setS(() {});
            setState(() {});
            _scheduleRebuild();
          },
          onOpenPageMode: () {
            Navigator.pop(ctx);
            _showPageModeSheet();
          },
        ),
      ),
    );
  }


  void _showThemeSheet() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: _theme.bg,
      showDragHandle: true,
      builder: (_) => NovelThemeSheet(
        settings: _settings,
        theme: _theme,
        onChanged: () => setState(() {}),
      ),
    );
  }


  void _showPageModeSheet() {
    final modes = [
      (PageMode.slide, L.t('modeSlide'), Icons.swap_horiz_rounded),
      (PageMode.cover, L.t('modeCover'), Icons.filter_none_rounded),
      (PageMode.none, L.t('modeNone'), Icons.flash_on_rounded),
      (PageMode.scroll, L.t('modeScroll'), Icons.swap_vert_rounded),
    ];
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: _theme.bg,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                L.t('pageMode'),
                style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: _theme.fg),
              ),
            ),
            ...modes.map(
              (m) => ListTile(
                dense: true,
                leading: Icon(m.$3,
                    size: 20,
                    color: _settings.pageMode == m.$1
                        ? Theme.of(context).colorScheme.primary
                        : _theme.subtle),
                title: Text(
                  m.$2,
                  style: TextStyle(
                    fontSize: 13,
                    color: _theme.fg,
                    fontWeight: _settings.pageMode == m.$1
                        ? FontWeight.w600
                        : FontWeight.w400,
                  ),
                ),
                trailing: _settings.pageMode == m.$1
                    ? Icon(Icons.check_rounded,
                        size: 18, color: Theme.of(context).colorScheme.primary)
                    : null,
                onTap: () {
                  Navigator.pop(context);
                  setState(() {
                    _settings.update(() => _settings.pageMode = m.$1);
                  });
                  if (m.$1 != PageMode.scroll) {
                    Future.delayed(const Duration(milliseconds: 80), () {
                      if (mounted) _rebuildPages();
                    });
                  }
                },
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
