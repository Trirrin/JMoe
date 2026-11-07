import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/cache_manager.dart';
import '../core/chapter_cache.dart';
import '../core/reading_stats.dart';
import '../core/image_cache.dart';
import '../core/jm_protocol.dart';
import '../core/image_scrambler.dart';
import '../core/models.dart';
import '../core/source.dart';
import 'widgets/cache_overlay.dart';
import '../core/l10n.dart';

/// 统一阅读器：JM 与 e-hentai 共用。
///
/// 缓存策略（以整章为粒度）：
///  1. 进入即启动整章缓存任务（后台持续，离开页面也继续）
///  2. 显示统一蒙版：进度条 + `xx/xx`，可选择「等待完成」或「边看边缓存」
///  3. 缓存完成后蒙版自动消失，之后翻页全部命中内存，零延迟
class UnifiedReaderPage extends StatefulWidget {
  final ComicSource source;
  final Comic comic;
  final List<Chapter> chapters;
  final int initialIndex;

  /// 初始页码（从详情页续读时指定；<=0 表示沿用默认逻辑）。
  final int initialPage;
  final String albumName;

  const UnifiedReaderPage({
    super.key,
    required this.source,
    required this.comic,
    required this.chapters,
    this.initialIndex = 0,
    this.initialPage = 1,
    this.albumName = '',
  });

  @override
  State<UnifiedReaderPage> createState() => _UnifiedReaderPageState();
}

class _UnifiedReaderPageState extends State<UnifiedReaderPage> {
  final _scroll = ScrollController();
  late PageController _pageController;

  ReadBundle? _bundle;
  ChapterCacheTask? _task;
  bool _loading = true;
  String? _error;
  bool _vertical = true;
  bool _showUi = true;
  int _currentPage = 1;
  double _progress = 0;

  late int _index = widget.initialIndex;

  /// 蒙版：等待缓存完成 或 已选择边看边缓存
  bool _overlayDismissed = false;

  Chapter? get _chapter =>
      _index >= 0 && _index < widget.chapters.length
          ? widget.chapters[_index]
          : null;

  bool get _hasPrev => _index > 0;
  bool get _hasNext => _index < widget.chapters.length - 1;

  @override
  void initState() {
    super.initState();
    _vertical = AppState.instance.readerMode != 'horizontal';
    _pageController = PageController();
    _scroll.addListener(_onScroll);
    ChapterCacheManager.instance.revision.addListener(_onCacheTick);
    _load();
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _pageController.dispose();
    ChapterCacheManager.instance.revision.removeListener(_onCacheTick);
    super.dispose();
  }

  void _onCacheTick() {
    if (mounted) setState(() {});
  }

  void _onScroll() {
    if (!_vertical) return;
    final pos = _scroll.position;
    if (!pos.hasContentDimensions) return;
    final max = pos.maxScrollExtent;
    if (max <= 0) return;
    final p = (pos.pixels / max).clamp(0.0, 1.0);
    final total = _bundle?.length ?? 1;
    final page = (p * (total - 1)).round() + 1;
    if (page != _currentPage) {
      setState(() {
        _progress = p;
        _currentPage = page;
      });
      _saveProgress(page);
    }
  }

  /// 保存阅读进度（节流：每 3 秒或换页时）。
  DateTime _lastProgressSave = DateTime.fromMillisecondsSinceEpoch(0);
  void _saveProgress(int page) {
    final b = _bundle;
    final ch = _chapter;
    if (b == null || ch == null) return;
    final now = DateTime.now();
    if (now.difference(_lastProgressSave) < const Duration(seconds: 3)) return;
    _lastProgressSave = now;
    AppState.instance.updateHistoryProgress(
      comicId: widget.comic.id,
      chapterId: ch.id,
      page: page,
      totalPage: b.length,
    );
  }

  Future<void> _load() async {
    final ch = _chapter;
    if (ch == null) {
      setState(() {
        _loading = false;
        _error = L.t('noChapter');
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
      _overlayDismissed = false;
    });
    try {
      final b = await widget.source.read(widget.comic, ch);
      if (!mounted) return;
      setState(() {
        _bundle = b;
        _loading = false;
        // 续读：跳到详情页指定的页（夹在本章范围内）
        final want = widget.initialPage;
        _currentPage = (want >= 1 && want <= b.length) ? want : 1;
        _progress = b.length <= 0 ? 0 : (_currentPage - 1) / b.length;
      });

      // 记录统计（章节 + 页数 + 来源 + 类型）
      ReadingStats.instance.recordChapter(
        type: StatType.comic,
        workId: widget.comic.id,
        pages: b.length,
      );

      // 记录历史
      AppState.instance.recordHistory(
        ReadHistoryEntry(
          comicId: widget.comic.id,
          chapterId: ch.id,
          comicName:
              widget.albumName.isEmpty ? widget.comic.name : widget.albumName,
          chapterName: b.chapterName.isNotEmpty
              ? b.chapterName
              : (ch.name.trim().isNotEmpty
                  ? ch.name
                  : L.tp('episodeN', {'n': ch.sort > 0 ? ch.sort : 1})),
          cover: widget.source.coverOf(widget.comic),
          source: widget.source.id,
          totalPage: b.length,
          updatedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );

      // 启动整章缓存（后台持续）
      // 若该章此前已完整缓存（磁盘仍在），直接进入阅读，不再显示缓存蒙版
      final alreadyCached = CacheManager.instance.hasChapter(
        widget.source.id,
        b.chapterId,
      );
      final task = ChapterCacheManager.instance.start(
        source: widget.source,
        comic: widget.comic,
        bundle: b,
        skipIfCached: alreadyCached,
        // 从用户当前所在页向两侧扩散加载，优先保证眼前这一页
        startPage: _currentPage,
      );
      if (!mounted) return;
      setState(() {
        _task = task;
        // 已缓存完成则无需蒙版
        _overlayDismissed = task.isCompleted || b.length == 0;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = L.tp('chapterLoadFailed', {'e': '$e'});
        _loading = false;
      });
    }
  }

  void _goChapter(int delta) {
    final target = _index + delta;
    if (target < 0 || target >= widget.chapters.length) return;
    setState(() {
      _index = target;
      _bundle = null;
      _task = null;
    });
    if (_vertical) {
      _scroll.jumpTo(0);
    } else {
      _pageController.jumpToPage(0);
    }
    _load();
  }

  void _toggleMode() {
    setState(() {
      _vertical = !_vertical;
      _progress = 0;
      _currentPage = 1;
    });
    AppState.instance.setReaderMode(_vertical ? 'vertical' : 'horizontal');
  }

  @override
  Widget build(BuildContext context) {
    final task = _task;
    final showOverlay = !_loading &&
        _error == null &&
        task != null &&
        !_overlayDismissed &&
        !task.isCompleted;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(child: _buildBody()),
          _buildTopBar(),
          // 缓存进度：位于标题工具栏下方，边看边缓存/后台缓存时持续显示
          // 与顶栏/底栏一起受 _showUi 控制，隐藏界面时同步隐藏
          if (_showUi &&
              task != null &&
              !task.isCompleted &&
              (_overlayDismissed || !showOverlay))
            Positioned(
              top: MediaQuery.of(context).padding.top + 56,
              left: 0,
              right: 0,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(2),
                        child: LinearProgressIndicator(
                          value: task.progress,
                          minHeight: 2.5,
                          backgroundColor: Colors.white24,
                          valueColor: AlwaysStoppedAnimation(
                            Theme.of(context).colorScheme.primary,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '${task.done}/${task.total}',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          _buildBottomBar(),
          if (showOverlay)
            Positioned.fill(
              child: CacheOverlay(
                task: task,
                // 缓存完成 → 自动关闭蒙版进入阅读
                onWait: () =>
                    setState(() => _overlayDismissed = true),
                // 用户选择边看边缓存 → 立即进入（任务在后台继续）
                onReadNow: () =>
                    setState(() => _overlayDismissed = true),
                onCancel: () {
                  ChapterCacheManager.instance.cancel(
                    widget.source.id,
                    task.bundle.chapterId,
                  );
                  setState(() => _overlayDismissed = true);
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white70),
      );
    }
    final err = _error;
    if (err != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.cloud_off_outlined,
                color: Colors.white54,
                size: 44,
              ),
              const SizedBox(height: 12),
              Text(
                err,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
              const SizedBox(height: 16),
              FilledButton.tonal(onPressed: _load, child: Text(L.t('retry'))),
            ],
          ),
        ),
      );
    }
    final b = _bundle!;
    if (b.length == 0) {
      return  Center(
        child: Text(L.t('noImages'), style: TextStyle(color: Colors.white70)),
      );
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => setState(() => _showUi = !_showUi),
      child: _vertical ? _buildVertical(b) : _buildHorizontal(b),
    );
  }

  Widget _buildVertical(ReadBundle b) {
    return ListView.builder(
      controller: _scroll,
      itemCount: b.length,
      cacheExtent: 6000,
      physics: const ClampingScrollPhysics(),
      itemBuilder: (context, i) {
        return ReaderPageView(
          key: ValueKey('${b.chapterId}_${i}_${b.pages[i].index}'),
          ref: b.pages[i],
          scrambleId: b.scrambleId,
          scrambleAid: b.scrambleAid,
          albumId: widget.comic.id,
          source: widget.source,
          cacheKey: b.pages[i].directUrl ??
              b.pages[i].resolveUrl ??
              'page_${b.pages[i].index}',
          onSkip: i + 1 < b.length ? () => _skipTo(i + 1) : null,
        );
      },
    );
  }

  Widget _buildHorizontal(ReadBundle b) {
    return PageView.builder(
      controller: _pageController,
      itemCount: b.length,
      onPageChanged: (i) {
        setState(() {
          _currentPage = i + 1;
          _progress = b.length <= 1 ? 0 : i / (b.length - 1);
        });
        _saveProgress(i + 1);
      },
      itemBuilder: (context, i) {
        return InteractiveViewer(
          maxScale: 4,
          child: Center(
            child: ReaderPageView(
              key: ValueKey('${b.chapterId}_${i}_${b.pages[i].index}'),
              ref: b.pages[i],
              scrambleId: b.scrambleId,
              scrambleAid: b.scrambleAid,
              albumId: widget.comic.id,
              source: widget.source,
              cacheKey: b.pages[i].directUrl ??
                  b.pages[i].resolveUrl ??
                  'page_${b.pages[i].index}',
              fit: BoxFit.contain,
              onSkip: i + 1 < b.length ? () => _skipTo(i + 1) : null,
            ),
          ),
        );
      },
    );
  }

  void _skipTo(int index) {
    final b = _bundle;
    if (b == null || index < 0 || index >= b.length) return;
    setState(() {
      _currentPage = index + 1;
      _progress = b.length <= 1 ? 0 : index / (b.length - 1);
    });
    if (_vertical) {
      final max = _scroll.hasClients ? _scroll.position.maxScrollExtent : 0.0;
      if (max > 0) _scroll.jumpTo(max * _progress);
    } else {
      _pageController.jumpToPage(index);
    }
  }

  Widget _buildTopBar() {
    return AnimatedPositioned(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
      top: _showUi ? 0 : -140,
      left: 0,
      right: 0,
      child: Container(
        padding: EdgeInsets.only(
          top: MediaQuery.of(context).padding.top + 4,
          bottom: 8,
          left: 4,
          right: 8,
        ),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.black87, Colors.transparent],
          ),
        ),
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.arrow_back, color: Colors.white),
              onPressed: () => Navigator.of(context).pop(),
            ),
            Expanded(
              child: Text(
                _bundle?.chapterName.isNotEmpty == true
                    ? _bundle!.chapterName
                    : widget.comic.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                ),
              ),
            ),
            // 顶栏缓存指示（xx/xx），后台缓存时也能看到
            if (_task != null && !_task!.isCompleted)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Text(
                  '${_task!.done}/${_task!.total}',
                  style: const TextStyle(color: Colors.white60, fontSize: 11),
                ),
              )
            else if (_task?.isCompleted == true)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 6),
                child: Icon(
                  Icons.offline_pin,
                  color: Colors.white54,
                  size: 16,
                ),
              ),
            IconButton(
              tooltip: _vertical ? L.t('switchToHorizontal') : L.t('switchToVertical'),
              icon: Icon(
                _vertical ? Icons.swap_horiz : Icons.swap_vert,
                color: Colors.white,
              ),
              onPressed: _toggleMode,
            ),
            if (widget.chapters.length > 1)
              IconButton(
                tooltip: L.t('chapters'),
                icon: const Icon(Icons.list_alt, color: Colors.white),
                onPressed: _showChapterSheet,
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomBar() {
    final total = _bundle?.length ?? 0;
    return AnimatedPositioned(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
      bottom: _showUi ? 0 : -220,
      left: 0,
      right: 0,
      child: Container(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 10,
          bottom: MediaQuery.of(context).padding.bottom + 12,
        ),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [Colors.black87, Colors.transparent],
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Text(
                  '$_currentPage',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
                Expanded(
                  child: SliderTheme(
                    data: const SliderThemeData(
                      trackHeight: 2,
                      thumbShape: RoundSliderThumbShape(enabledThumbRadius: 6),
                      overlayShape: RoundSliderOverlayShape(overlayRadius: 14),
                    ),
                    child: Slider(
                      value: _progress.clamp(0.0, 1.0),
                      onChanged: total <= 1
                          ? null
                          : (v) {
                              final target = (v * (total - 1))
                                  .round()
                                  .clamp(0, total - 1);
                              _skipTo(target);
                            },
                    ),
                  ),
                ),
                Text(
                  '$total',
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ],
            ),
            if (widget.chapters.length > 1)
              Row(
                children: [
                  Expanded(
                    child: TextButton.icon(
                      onPressed: _hasPrev ? () => _goChapter(-1) : null,
                      icon: Icon(
                        Icons.skip_previous,
                        size: 18,
                        color: _hasPrev ? Colors.white : Colors.white30,
                      ),
                      label: Text(
                        L.t('prevChapter'),
                        style: TextStyle(
                          color: _hasPrev ? Colors.white : Colors.white30,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: TextButton.icon(
                      onPressed: _hasNext ? () => _goChapter(1) : null,
                      icon: Icon(
                        Icons.skip_next,
                        size: 18,
                        color: _hasNext ? Colors.white : Colors.white30,
                      ),
                      label: Text(
                        L.t('nextChapter'),
                        style: TextStyle(
                          color: _hasNext ? Colors.white : Colors.white30,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  void _showChapterSheet() {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.9,
        builder: (context, controller) => ListView.builder(
          controller: controller,
          itemCount: widget.chapters.length,
          itemBuilder: (context, i) {
            final c = widget.chapters[i];
            final selected = i == _index;
            final cached = ChapterCacheManager.instance
                .isComplete(widget.source.id, c.id);
            return ListTile(
              selected: selected,
              leading: CircleAvatar(
                radius: 14,
                backgroundColor: selected
                    ? Theme.of(context).colorScheme.primary
                    : null,
                child: Text(
                  '${c.sort}',
                  style: TextStyle(
                    fontSize: 11,
                    color: selected
                        ? Theme.of(context).colorScheme.onPrimary
                        : null,
                  ),
                ),
              ),
              title: Text(
                c.hasName ? c.name : L.tp('episodeN', {'n': c.sort}),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13),
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (cached)
                    const Icon(Icons.offline_pin, size: 15, color: Colors.grey),
                  if (selected)
                    const Padding(
                      padding: EdgeInsets.only(left: 4),
                      child: Icon(Icons.play_arrow, size: 18),
                    ),
                ],
              ),
              onTap: () {
                Navigator.pop(context);
                if (selected) return;
                setState(() {
                  _index = i;
                  _bundle = null;
                  _task = null;
                });
                _scroll.jumpTo(0);
                _load();
              },
            );
          },
        ),
      ),
    );
  }
}

/// 单页：优先使用已缓存解码图，未就绪则实时加载（边看边缓存）。
class ReaderPageView extends StatefulWidget {
  final PageRef ref;
  final String? scrambleId;
  final String scrambleAid;
  final String albumId;
  final ComicSource source;
  final String cacheKey;
  final BoxFit fit;
  final VoidCallback? onSkip;

  const ReaderPageView({
    super.key,
    required this.ref,
    required this.scrambleId,
    required this.scrambleAid,
    required this.albumId,
    required this.source,
    required this.cacheKey,
    this.fit = BoxFit.fitWidth,
    this.onSkip,
  });

  @override
  State<ReaderPageView> createState() => _ReaderPageViewState();
}

class _ReaderPageViewState extends State<ReaderPageView> {
  ui.Image? _image;
  bool _failed = false;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    _syncHit();
  }

  void _syncHit() {
    // 仅当 cacheKey 就是最终图片地址（JM 源）时才能同步命中；
    // EH 源需先解析页面地址，统一走 _start()。
    final key = widget.cacheKey;
    if (key.startsWith('http') && widget.ref.directUrl != null) {
      final cached = ImageCacheManager.instance.getUiSync(key);
      if (cached != null) {
        _image = cached;
        return;
      }
    }
    _start();
  }

  @override
  void didUpdateWidget(covariant ReaderPageView old) {
    super.didUpdateWidget(old);
    if (old.cacheKey != widget.cacheKey) {
      _image = null;
      _failed = false;
      _started = false;
      _syncHit();
    }
  }

  Future<void> _start() async {
    if (_started) return;
    _started = true;

    var url = widget.ref.directUrl;
    if (url == null && widget.ref.resolveUrl != null) {
      url = await widget.source.resolvePageUrl(widget.ref.resolveUrl!);
    }
    if (url == null || url.isEmpty) {
      if (mounted) setState(() => _failed = true);
      _started = false;
      return;
    }

    final cached = ImageCacheManager.instance.getUiSync(url);
    if (cached != null) {
      if (mounted) setState(() => _image = cached);
      return;
    }

    final bytes = await ImageCacheManager.instance.load(
      url,
      fetcher: (u) => JmApi.instance.fetchBytes(
        u,
        referer: widget.source.id == 'ehentai' ? widget.ref.resolveUrl : null,
      ),
    );
    if (bytes == null) {
      if (mounted) setState(() => _failed = true);
      _started = false;
      return;
    }

    var data = bytes;
    final sid = widget.scrambleId;
    if (sid != null &&
        ImageScrambler.needScramble(widget.scrambleAid, sid, url)) {
      final pk = ImageScrambler.pageKeyFromUrl(url, widget.ref.index);
      final seg = ImageScrambler.segments(widget.scrambleAid, pk);
      data = await ChapterCacheManager.unscramble(bytes, seg);
    }

    final img = await ImageCacheManager.decode(data);
    if (img != null) ImageCacheManager.instance.putUi(url, img);
    if (!mounted) return;
    setState(() {
      _image = img;
      _failed = img == null;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) {
      return GestureDetector(
        onTap: () {
          setState(() {
            _failed = false;
            _started = false;
          });
          _start();
        },
        child: Container(
          height: 200,
          alignment: Alignment.center,
          color: Colors.transparent,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.broken_image_outlined,
                color: Colors.white38,
                size: 28,
              ),
              const SizedBox(height: 6),
              Text(
                L.tp('pageNFailed', {'n': widget.ref.index}),
                style: const TextStyle(color: Colors.white38, fontSize: 11),
              ),
            ],
          ),
        ),
      );
    }
    final img = _image;
    if (img == null) {
      // 无背景、无灰块，仅细转圈 + 页码
      return AspectRatio(
        aspectRatio: 0.7,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 1.5,
                  color: Colors.white24,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                L.tp('pageN', {'n': widget.ref.index}),
                style: const TextStyle(color: Colors.white24, fontSize: 11),
              ),
              if (widget.onSkip != null)
                TextButton(
                  onPressed: widget.onSkip,
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    foregroundColor: Colors.white38,
                  ),
                  child: Text(L.t('skip'), style: TextStyle(fontSize: 11)),
                ),
            ],
          ),
        ),
      );
    }
    return AspectRatio(
      aspectRatio: img.width / img.height <= 0 ? 0.7 : img.width / img.height,
      child: RawImage(
        image: img,
        fit: widget.fit,
        filterQuality: FilterQuality.low,
      ),
    );
  }
}

