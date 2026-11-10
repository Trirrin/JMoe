import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/app_state.dart';
import '../core/cache_manager.dart';
import '../core/chapter_cache.dart';
import '../core/reading_stats.dart';
import '../core/models.dart';
import '../core/source.dart';
import '../core/image_scrambler.dart';
import '../core/image_cache.dart';
import '../core/image_worker.dart';
import '../core/jm_protocol.dart';
import '../core/platform_caps.dart';
import '../core/prefetch_controller.dart';
import '../core/temp_store.dart';
import '../core/zip_packer.dart';
import 'widgets/cache_overlay.dart';
import '../widgets/reader_page_view.dart';
import '../core/l10n.dart';

class UnifiedReaderPage extends StatefulWidget {
  final ComicSource source;
  final Comic comic;
  final List<Chapter> chapters;
  final int initialIndex;

  final int initialPage;
  final String albumName;

  final String? localDir;

  const UnifiedReaderPage({
    super.key,
    required this.source,
    required this.comic,
    required this.chapters,
    this.initialIndex = 0,
    this.initialPage = 1,
    this.albumName = '',
    this.localDir,
  });

  @override
  State<UnifiedReaderPage> createState() => _UnifiedReaderPageState();
}

class _UnifiedReaderPageState extends State<UnifiedReaderPage> {
  final _scroll = ScrollController();

  late PageController _pageController;

  static const _volChannel = MethodChannel('jmoe/reader');

  bool _volKeyOn = false;

  Future<void> _onVolumeKey(MethodCall call) async {
    if (call.method != 'onVolumeKey') return;
    final dir = (call.arguments as num?)?.toInt() ?? 0;
    if (dir == 0) return;
    final total = _isLocal ? _localFiles.length : (_bundle?.length ?? 0);
    if (total <= 0) return;
    final target = (_currentPage + dir).clamp(1, total);
    if (target == _currentPage) return;
    if (_vertical) {
      final b = _bundle;
      final w = MediaQuery.of(context).size.width;
      double off = 0;
      for (var k = 0; k < target - 1; k++) {
        final r = _isLocal ? (_localRatios[k] ?? 0.72) : _ratioAt(k);
        off += w / (r <= 0.01 ? 0.72 : r);
      }
      if (_scroll.hasClients) {
        _scroll.animateTo(
          off.clamp(0.0, _scroll.position.maxScrollExtent),
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
        );
      }
      setState(() {
        _currentPage = target;
        _progressNotifier.value = total <= 1 ? 0 : (target - 1) / total;
      });
      _saveProgress(target);
      if (b != null) unawaited(Future<void>.value());
    } else {
      _pageController.animateToPage(
        target - 1,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    }
  }

  ReadBundle? _bundle;
  ChapterCacheTask? _task;
  bool _loading = true;
  String? _error;
  bool _vertical = true;
  bool _showUi = true;
  int _currentPage = 1;

  List<File> _localFiles = const [];

  bool get _isLocal => widget.localDir != null;

  late int _index = widget.initialIndex;

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
    final startIndex = (widget.initialPage - 1).clamp(0, 1 << 30);
    _pageController = PageController(initialPage: startIndex);
    _scroll.addListener(_onScroll);
    ChapterCacheManager.instance.revision.addListener(_onCacheTick);
    if (PlatformCaps.supportsVolumeKeyPaging &&
        AppState.instance.volumeKeyPage) {
      _volKeyOn = true;
      _volChannel.setMethodCallHandler(_onVolumeKey);
      unawaited(
        _volChannel
            .invokeMethod('setVolumeKeyPage', {'on': true})
            .catchError((_) => null),
      );
    }
    _startReadingClock();
    _lifecycle = AppLifecycleListener(
      onStateChange: (s) {
        final foreground = s == AppLifecycleState.resumed;
        if (foreground) {
          _startReadingClock();
        } else {
          _stopReadingClock();
        }
      },
    );
    _load();
  }

  Timer? _clock;
  DateTime? _clockSince;
  AppLifecycleListener? _lifecycle;

  void _startReadingClock() {
    _clockSince = DateTime.now();
    _clock?.cancel();
    _clock = Timer.periodic(const Duration(seconds: 10), (_) {
      final since = _clockSince;
      if (since == null) return;
      final sec = DateTime.now().difference(since).inSeconds;
      if (sec >= 10) {
        _clockSince = DateTime.now();
        ReadingStats.instance.addSeconds(StatType.comic, sec);
      }
    });
  }

  void _stopReadingClock() {
    _clock?.cancel();
    _clock = null;
    final since = _clockSince;
    _clockSince = null;
    if (since == null) return;
    final sec = DateTime.now().difference(since).inSeconds;
    if (sec > 0) ReadingStats.instance.addSeconds(StatType.comic, sec);
  }

  @override
  void dispose() {
    _saveProgress(_currentPage, force: true);
    _stopReadingClock();
    _lifecycle?.dispose();
    _releaseTemp();
    TempStore.instance.sweep();
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _pageController.dispose();
    _progressNotifier.dispose();
    _pageNotifier.dispose();
    ChapterCacheManager.instance.revision.removeListener(_onCacheTick);
    if (_task != null && !_task!.persistToDisk) {
      ChapterCacheManager.instance.cancel(
        widget.source.id,
        _task!.bundle.chapterId,
      );
    }
    if (_volKeyOn) {
      _volChannel.setMethodCallHandler(null);
      unawaited(
        _volChannel
            .invokeMethod('setVolumeKeyPage', {'on': false})
            .catchError((_) => null),
      );
    }
    super.dispose();
  }

  int _cacheReady = 0;
  int _cacheTotal = 0;
  final _cacheNotifier = ValueNotifier<int>(0);

  void _onCacheTick() {
    final t = _task;
    if (t == null) return;
    final ready = t.readyOrDone;
    if (ready == _cacheReady && t.total == _cacheTotal) return;
    _cacheReady = ready;
    _cacheTotal = t.total;
    _cacheNotifier.value = ready;
  }

  void _onScroll() {
    if (!_vertical) return;
    if (!_scroll.hasClients) return;

    final pos = _scroll.position;
    if (!pos.hasContentDimensions) return;
    final max = pos.maxScrollExtent;
    if (max <= 0) return;
    final p = (pos.pixels / max).clamp(0.0, 1.0);
    final total = _isLocal
        ? (_localFiles.isEmpty ? 1 : _localFiles.length)
        : (_bundle?.length ?? 1);
    final page = (p * (total - 1)).round() + 1;
    _progressNotifier.value = p;
    _pageNotifier.value = page;

    final delta = pos.pixels - _lastScrollPixels;
    _lastScrollPixels = pos.pixels;
    if (delta.abs() > 0.5) prefetch.noteScroll(delta);

    if (page != _currentPage) {
      _currentPage = page;
      _saveProgress(page);
      _task?.startPage = page - 1;
      _schedulePrefetch(page - 1, total);
    }
  }

  double _lastScrollPixels = 0;
  Timer? _settleTimer;

  void _schedulePrefetch(int index, int total) {
    if (_isLocal) return;
    prefetch.settle();
    _settleTimer?.cancel();
    _settleTimer = Timer(const Duration(milliseconds: 250), () {
      if (mounted) prefetch.settle();
    });
    prefetch.trimUiCache();
    _warmPages();
  }

  void _warmPages() {
    final b = _bundle;
    if (b == null) return;
    final total = b.length;
    if (total == 0) return;
    final cur = (_currentPage - 1).clamp(0, total - 1);
    final window = prefetch.windowFor(cur, total);
    for (final i in window) {
      final page = b.pages[i];
      final url = page.directUrl ?? page.resolveUrl;
      if (url == null || url.isEmpty) continue;
      if (ImageCacheManager.instance.getUiSync(url) != null) continue;
      prefetch.submit('${b.chapterId}:$i', () async {
        final bytes = await ImageCacheManager.instance.load(
          url,
          fetcher: (u) => JmApi.instance.fetchBytes(u),
        );
        if (bytes == null) return null;
        var data = bytes;
        final sid = b.scrambleId;
        if (sid != null &&
            ImageScrambler.needScramble(b.scrambleAid, sid, url)) {
          final pk = ImageScrambler.pageKeyFromUrl(url, page.index);
          final seg = ImageScrambler.segments(b.scrambleAid, pk);
          final jpg = await ImageWorker.instance.unscrambleToJpeg(
            bytes: bytes,
            segments: seg,
            maxWidth: _decodeWidthPx,
          );
          if (jpg != null) data = jpg;
        }
        final img = await ImageCacheManager.decodeScaled(
          data,
          targetWidth: _decodeWidthPx,
        );
        if (img != null) ImageCacheManager.instance.putUi(url, img);
        return null;
      });
    }
  }

  int get _decodeWidthPx =>
      (_lastDecodeWidth > 0 ? _lastDecodeWidth : 720);

  int _lastDecodeWidth = 0;

  final _progressNotifier = ValueNotifier<double>(0);

  final _pageNotifier = ValueNotifier<int>(1);

  DateTime _lastProgressSave = DateTime.fromMillisecondsSinceEpoch(0);
  void _saveProgress(int page, {bool force = false}) {
    final ch = _chapter;
    final totalPage =
        _isLocal ? _localFiles.length : (_bundle?.length ?? 0);
    if (totalPage <= 0 || ch == null) return;
    final now = DateTime.now();
    if (!force &&
        now.difference(_lastProgressSave) < const Duration(seconds: 3)) {
      return;
    }
    _lastProgressSave = now;
    AppState.instance.updateHistoryProgress(
      comicId: widget.comic.id,
      chapterId: ch.id,
      page: page,
      totalPage: totalPage,
    );
  }

  Future<void> _loadLocal() async {
    try {
      var lp = widget.localDir!;
      if (lp.toLowerCase().endsWith('.zip')) {
        final extracted = await ZipReader.extractToCache(lp);
        if (extracted == null) {
          if (!mounted) return;
          setState(() {
            _loading = false;
            _error = L.t('offlineEmpty');
          });
          return;
        }
        lp = extracted;
      }
      final dir = Directory(lp);
      if (!await dir.exists()) {
        if (!mounted) return;
        setState(() {
          _loading = false;
          _error = L.t('offlineEmpty');
        });
        return;
      }
      final files = dir
          .listSync()
          .whereType<File>()
          .where((f) {
            final p = f.path.toLowerCase();
            return p.endsWith('.png') ||
                p.endsWith('.jpg') ||
                p.endsWith('.jpeg') ||
                p.endsWith('.webp');
          })
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      if (!mounted) return;
      if (files.isEmpty) {
        setState(() {
          _loading = false;
          _error = L.t('offlineEmpty');
        });
        return;
      }
      setState(() {
        _localFiles = files;
        _loading = false;
        final want = widget.initialPage;
        _currentPage =
            (want >= 1 && want <= files.length) ? want : 1;
        _progressNotifier.value = files.length <= 1 ? 0 : (_currentPage - 1) / files.length;
      });
      final ch = _chapter;
      if (ch != null) {
        ReadingStats.instance.recordChapter(
          type: StatType.comic,
          workId: widget.comic.id,
          pages: files.length,
        );
        AppState.instance.recordHistory(
          ReadHistoryEntry(
            comicId: widget.comic.id,
            chapterId: ch.id,
            comicName: widget.albumName.isEmpty
                ? widget.comic.name
                : widget.albumName,
            chapterName: ch.name.trim().isNotEmpty
                ? ch.name
                : L.tp('episodeN', {'n': ch.sort > 0 ? ch.sort : 1}),
            cover: widget.source.coverOf(widget.comic),
            source: widget.source.id,
            kind: 'comic',
            page: _currentPage,
            totalPage: files.length,
            updatedAt: DateTime.now().millisecondsSinceEpoch,
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  Future<void> _load() async {
    if (_isLocal) {
      await _loadLocal();
      return;
    }
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
        final want = widget.initialPage;
        _currentPage = (want >= 1 && want <= b.length) ? want : 1;
        _progressNotifier.value = b.length <= 0 ? 0 : (_currentPage - 1) / b.length;
      });

      ReadingStats.instance.recordChapter(
        type: StatType.comic,
        workId: widget.comic.id,
        pages: b.length,
      );

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
          kind: 'comic',
          page: _currentPage,
          totalPage: b.length,
          updatedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );

      final alreadyCached = CacheManager.instance.hasChapter(
            widget.source.id,
            b.chapterId,
          ) ||
          await TempStore.instance.hasChapter(widget.source.id, b.chapterId);
      final task = ChapterCacheManager.instance.start(
        source: widget.source,
        comic: widget.comic,
        bundle: b,
        skipIfCached: alreadyCached,
        startPage: _currentPage,
        decodeWidth:
            (MediaQuery.of(context).size.width *
                    MediaQuery.of(context).devicePixelRatio)
                .round(),
      );
      if (!mounted) return;
      if (task.tempDirReady != null) {
        await task.tempDirReady;
        final td = task.tempDir;
        if (td != null && td.isNotEmpty) TempStore.instance.acquire(td);
      }
      if (!mounted) return;
      setState(() {
        _task = task;
        _overlayDismissed = task.isCompleted ||
            b.length == 0 ||
            AppState.instance.cacheSkipToday;
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
    _releaseTemp();
    setState(() {
      _index = target;
      _bundle = null;
      _task = null;
      _ratios.clear();
    });
    if (_vertical) {
      _scroll.jumpTo(0);
    } else {
      _pageController.jumpToPage(0);
    }
    _load();
  }

  void _releaseTemp() {
    final td = _task?.tempDir;
    if (td != null && td.isNotEmpty) TempStore.instance.release(td);
  }

  void _toggleMode() {
    setState(() {
      _vertical = !_vertical;
      _progressNotifier.value = 0;
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
                child: ValueListenableBuilder<int>(
                  valueListenable: _cacheNotifier,
                  builder: (context, ready, _) {
                    final prog =
                        task.total == 0 ? 0.0 : (ready / task.total).clamp(0.0, 1.0);
                    return Row(
                      children: [
                        Expanded(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(2),
                            child: LinearProgressIndicator(
                              value: prog,
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
                          '${(prog * 100).round()}%',
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          _buildBottomBar(),
          if (showOverlay)
            Positioned.fill(
              child: CacheOverlay(
                task: task,
                onWait: () =>
                    setState(() => _overlayDismissed = true),
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
    if (_isLocal) {
      if (_localFiles.isEmpty) {
        return Center(
          child: Text(
            L.t('noImages'),
            style: const TextStyle(color: Colors.white70),
          ),
        );
      }
      return _TapToToggleUi(
        onTap: () => setState(() => _showUi = !_showUi),
        child: _vertical ? _buildLocalVertical() : _buildLocalHorizontal(),
      );
    }
    final b = _bundle!;
    if (b.length == 0) {
      return  Center(
        child: Text(L.t('noImages'), style: const TextStyle(color: Colors.white70)),
      );
    }
    return _TapToToggleUi(
      onTap: () => setState(() => _showUi = !_showUi),
      child: _vertical ? _buildVertical(b) : _buildHorizontal(b),
    );
  }

  Widget _buildLocalVertical() {
    if (!_restoredScroll && _currentPage > 1) {
      _restoredScroll = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scroll.hasClients) return;
        final w = MediaQuery.of(context).size.width;
        var off = 0.0;
        for (var k = 0; k < _currentPage - 1; k++) {
          final r = _localRatios[k] ?? 0.72;
          off += w / (r <= 0.01 ? 0.72 : r);
        }
        _scroll.jumpTo(off.clamp(0.0, _scroll.position.maxScrollExtent));
      });
    }
    return ListView.builder(
      cacheExtent: 2000, controller: _scroll,
      itemCount: _localFiles.length,
      physics: const ClampingScrollPhysics(),
      itemBuilder: (context, i) => _buildLocalPage(i),
    );
  }

  Widget _buildLocalHorizontal() {
    return PageView.builder(
      controller: _pageController,
      itemCount: _localFiles.length,
      onPageChanged: (i) {
        setState(() {
          _currentPage = i + 1;
          _progressNotifier.value = _localFiles.length <= 1
              ? 0
              : i / (_localFiles.length - 1);
        });
        _saveProgress(i + 1);
      },
      itemBuilder: (context, i) => InteractiveViewer(
        maxScale: 4,
        child: Center(child: _buildLocalPage(i)),
      ),
    );
  }

  final Map<int, double> _localRatios = {};

  Widget _buildLocalPage(int i) {
    return _LocalImageView(
      key: ValueKey('local_${widget.localDir}_$i'),
      file: _localFiles[i],
      fallbackRatio: _localRatios[i] ?? 0.72,
      onLoaded: (r) {
        if (!_localRatios.containsKey(i)) {
          _localRatios[i] = r;
        }
      },
    );
  }

  String? get _tempDir => _task?.tempDir;

  Widget _buildVertical(ReadBundle b) {
    if (!_restoredScroll && _currentPage > 1) {
      _restoredScroll = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scroll.hasClients) return;
        final target = _estimateOffsetFor(b, _currentPage - 1);
        _scroll.jumpTo(target.clamp(0.0, _scroll.position.maxScrollExtent));
      });
    }
    final decodeW =
        (MediaQuery.of(context).size.width *
                MediaQuery.of(context).devicePixelRatio)
            .round();
    _lastDecodeWidth = decodeW;
    return ListView.builder(
      cacheExtent: 2000, controller: _scroll,
      itemCount: b.length,
      physics: const ClampingScrollPhysics(),
      itemBuilder: (context, i) {
        return RepaintBoundary(
          child: ReaderPageView(
            key: ValueKey('${b.chapterId}_${i}_${b.pages[i].index}'),
            ref: b.pages[i],
            decodeWidth: decodeW,
            scrambleId: b.scrambleId,
            scrambleAid: b.scrambleAid,
            albumId: widget.comic.id,
            source: widget.source,
            cacheKey: b.pages[i].directUrl ??
                b.pages[i].resolveUrl ??
                'page_${b.pages[i].index}',
            chapterId: b.chapterId,
            tempDir: _tempDir,
            fallbackRatio: _ratioAt(i),
            onLoaded: (r) => _rememberRatio(i, r),
          ),
        );
      },
    );
  }

  bool _restoredScroll = false;

  double _estimateOffsetFor(ReadBundle b, int index) {
    final width = MediaQuery.of(context).size.width;
    var offset = 0.0;
    for (var i = 0; i < index && i < b.length; i++) {
      final r = _ratioAt(i);
      final safe = r <= 0.01 ? 0.72 : r;
      offset += width / safe;
    }
    return offset;
  }

  Widget _buildHorizontal(ReadBundle b) {
    return PageView.builder(
      controller: _pageController,
      itemCount: b.length,
      onPageChanged: (i) {
        setState(() {
          _currentPage = i + 1;
          _progressNotifier.value = b.length <= 1 ? 0 : i / (b.length - 1);
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
              decodeWidth:
                  (MediaQuery.of(context).size.width *
                          MediaQuery.of(context).devicePixelRatio)
                      .round(),
              scrambleId: b.scrambleId,
              scrambleAid: b.scrambleAid,
              albumId: widget.comic.id,
              source: widget.source,
              cacheKey: b.pages[i].directUrl ??
                  b.pages[i].resolveUrl ??
                  'page_${b.pages[i].index}',
              chapterId: b.chapterId,
              tempDir: _tempDir,
              fit: BoxFit.contain,
              fallbackRatio: _ratioAt(i),
              onLoaded: (r) => _rememberRatio(i, r),
            ),
          ),
        );
      },
    );
  }

  final Map<int, double> _ratios = {};

  double _ratioAt(int i) {
    final self = _ratios[i];
    if (self != null) return self;
    for (var k = i - 1; k >= 0; k--) {
      final r = _ratios[k];
      if (r != null) return r;
    }
    for (var k = i + 1; k < (_bundle?.length ?? 0); k++) {
      final r = _ratios[k];
      if (r != null) return r;
    }
    return 0.72;
  }

  void _rememberRatio(int i, double r) {
    if (r <= 0 || !r.isFinite) return;
    if (_ratios[i] == r) return;
    _ratios[i] = r;
  }

  void _skipTo(int index) {
    final total = _isLocal ? _localFiles.length : (_bundle?.length ?? 0);
    if (total <= 0 || index < 0 || index >= total) return;
    final p = total <= 1 ? 0.0 : index / (total - 1);
    _currentPage = index + 1;
    _progressNotifier.value = p;
    _pageNotifier.value = index + 1;
    if (_vertical) {
      if (_scroll.hasClients) {
        final max = _scroll.position.maxScrollExtent;
        if (max > 0) _scroll.jumpTo(max * p);
      }
    } else {
      if (_pageController.hasClients) _pageController.jumpToPage(index);
    }
    _saveProgress(index + 1);
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
            if (_task != null && !_task!.isCompleted)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: ValueListenableBuilder<int>(
                  valueListenable: _cacheNotifier,
                  builder: (context, ready, _) => Text(
                    '$ready/${_task!.total}',
                    style:
                        const TextStyle(color: Colors.white60, fontSize: 11),
                  ),
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

  bool get _bookmarkedThisPage {
    final ch = _chapter;
    if (ch == null) return false;
    return AppState.instance.isChapterBookmarked(
      widget.comic.id,
      ch.id,
      page: _currentPage,
    );
  }

  Future<void> _togglePageBookmark() async {
    final ch = _chapter;
    if (ch == null) return;
    final on = !_bookmarkedThisPage;
    final chapterName = ch.name.trim().isNotEmpty
        ? ch.name
        : L.tp('episodeN', {'n': ch.sort > 0 ? ch.sort : 1});

    if (on) {
      final note = await _askNote();
      if (!mounted) return;
      await AppState.instance.setChapterBookmark(
        comicId: widget.comic.id,
        chapterId: ch.id,
        comicName:
            widget.albumName.isEmpty ? widget.comic.name : widget.albumName,
        chapterName: chapterName,
        cover: widget.source.coverOf(widget.comic) ?? '',
        source: widget.source.id,
        on: true,
        page: _currentPage,
        kind: 'comic',
        note: note ?? '',
      );
    } else {
      await AppState.instance.setChapterBookmark(
        comicId: widget.comic.id,
        chapterId: ch.id,
        comicName: '',
        chapterName: '',
        cover: '',
        source: '',
        on: false,
        page: _currentPage,
      );
    }
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(on ? L.t('bookmarkAdded') : L.t('bookmarkRemoved')),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(milliseconds: 1500),
      ),
    );
  }

  Future<String?> _askNote() async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(L.t('bookmarkNote')),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLines: 3,
          decoration: InputDecoration(
            hintText: L.t('bookmarkNoteHint'),
            border: const OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(L.t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(L.t('save')),
          ),
        ],
      ),
    );
    final text = ctrl.text;
    ctrl.dispose();
    if (ok != true) return null;
    return text.trim();
  }

  Widget _buildBottomBar() {
    final total = _isLocal ? _localFiles.length : (_bundle?.length ?? 0);
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
                ValueListenableBuilder<int>(
                  valueListenable: _pageNotifier,
                  builder: (context, page, _) => Text(
                    '$page',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                    ),
                  ),
                ),
                Expanded(
                  child: SliderTheme(
                    data: const SliderThemeData(
                      trackHeight: 2,
                      thumbShape: RoundSliderThumbShape(enabledThumbRadius: 6),
                      overlayShape: RoundSliderOverlayShape(overlayRadius: 14),
                    ),
                    child: ValueListenableBuilder<double>(
                      valueListenable: _progressNotifier,
                      builder: (context, prog, _) => Slider(
                        value: prog.clamp(0.0, 1.0),
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
                ),
                Text(
                  '$total',
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
                const SizedBox(width: 4),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: L.t('bookmarkThisPage'),
                  icon: Icon(
                    _bookmarkedThisPage
                        ? Icons.bookmark_rounded
                        : Icons.bookmark_border_rounded,
                    size: 20,
                    color: _bookmarkedThisPage
                        ? Theme.of(context).colorScheme.primary
                        : Colors.white70,
                  ),
                  onPressed: _togglePageBookmark,
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
                _releaseTemp();
                setState(() {
                  _index = i;
                  _bundle = null;
                  _task = null;
                  _ratios.clear();
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

class _LocalImageView extends StatefulWidget {
  const _LocalImageView({
    super.key,
    required this.file,
    required this.fallbackRatio,
    this.onLoaded,
  });

  final File file;
  final double fallbackRatio;
  final ValueChanged<double>? onLoaded;

  @override
  State<_LocalImageView> createState() => _LocalImageViewState();
}

class _LocalImageViewState extends State<_LocalImageView> {
  ui.Image? _image;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _decode();
  }

  Future<void> _decode() async {
    try {
      final bytes = await widget.file.readAsBytes();
      final img = await decodeImageFromList(bytes);
      if (!mounted) {
        img.dispose();
        return;
      }
      setState(() => _image = img);
      if (img.height > 0) {
        widget.onLoaded?.call(img.width / img.height);
      }
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) {
      return AspectRatio(
        aspectRatio: widget.fallbackRatio <= 0.01 ? 0.72 : widget.fallbackRatio,
        child: const Center(
          child: Icon(Icons.broken_image_outlined, color: Colors.white38),
        ),
      );
    }
    final img = _image;
    if (img == null) {
      return AspectRatio(
        aspectRatio:
            widget.fallbackRatio <= 0.01 ? 0.72 : widget.fallbackRatio,
        child: const SizedBox.expand(),
      );
    }
    return RawImage(image: img, fit: BoxFit.fitWidth);
  }
}

class _TapToToggleUi extends StatefulWidget {
  const _TapToToggleUi({required this.onTap, required this.child});

  final VoidCallback onTap;
  final Widget child;

  @override
  State<_TapToToggleUi> createState() => _TapToToggleUiState();
}

class _TapToToggleUiState extends State<_TapToToggleUi> {
  Offset? _downPos;

  static const double _slop = 12;

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (e) => _downPos = e.position,
      onPointerUp: (e) {
        final d = _downPos;
        _downPos = null;
        if (d == null) return;
        if ((e.position - d).distance <= _slop) widget.onTap();
      },
      onPointerCancel: (_) => _downPos = null,
      child: widget.child,
    );
  }
}
