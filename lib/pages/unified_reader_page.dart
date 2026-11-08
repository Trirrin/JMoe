import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/app_state.dart';
import '../core/cache_manager.dart';
import '../core/chapter_cache.dart';
import '../core/reading_stats.dart';
import '../core/image_cache.dart';
import '../core/jm_protocol.dart';
import '../core/jm_service.dart';
import '../core/image_scrambler.dart';
import '../core/models.dart';
import '../core/source.dart';
import '../core/temp_store.dart';
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

  /// **离线模式**：直接读这个目录里的图片文件，不发起任何网络请求。
  ///
  /// 用户明确要求「离线看漫画界面要和在线一致，复用在线播放器，
  /// 不要另写一个」。所以离线不再走独立的 OfflineReaderPage，
  /// 而是让本页接管：顶栏/底栏/翻页模式/缩放手势/进度保存全部相同，
  /// 只是页面数据来源从网络换成磁盘。
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
  /// 竖向滚动控制器
  final _scroll = ScrollController();

  /// 横向翻页控制器
  late PageController _pageController;

  /// 音量键翻页通道
  static const _volChannel = MethodChannel('jmoe/reader');

  /// 是否已启用音量键翻页（离开页面时关闭）
  bool _volKeyOn = false;

  /// 音量键回调：向下 = 下一页，向上 = 上一页
  Future<void> _onVolumeKey(MethodCall call) async {
    if (call.method != 'onVolumeKey') return;
    final dir = (call.arguments as num?)?.toInt() ?? 0;
    if (dir == 0) return;
    final total = _isLocal ? _localFiles.length : (_bundle?.length ?? 0);
    if (total <= 0) return;
    final target = (_currentPage + dir).clamp(1, total);
    if (target == _currentPage) return;
    if (_vertical) {
      // 竖向：滚到目标页
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

  /// 离线页面文件（非空表示处于离线模式）
  List<File> _localFiles = const [];

  bool get _isLocal => widget.localDir != null;

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
    // 横向翻页：**初始页必须指向续读位置**。
    // 之前固定 PageController() 从第 0 页开始，所以即使 _currentPage
    // 算对了（进度条也对），实际显示的还是第 1 页 —— 用户看到的就是
    // 「进度条位置对，但漫画位置错误」。
    final startIndex = (widget.initialPage - 1).clamp(0, 1 << 30);
    _pageController = PageController(initialPage: startIndex);
    _scroll.addListener(_onScroll);
    ChapterCacheManager.instance.revision.addListener(_onCacheTick);
    // ---- 音量键翻页 ----
    // 阅读页启用：音量键改为翻页而不是调音量。
    // 仅当用户开启了该设置（默认开启）时才拦。
    if (AppState.instance.volumeKeyPage) {
      _volKeyOn = true;
      _volChannel.setMethodCallHandler(_onVolumeKey);
      unawaited(
        _volChannel
            .invokeMethod('setVolumeKeyPage', {'on': true})
            .catchError((_) => null),
      );
    }
    // 阅读时长计时：漫画阅读器原先从不累加秒数（只有动漫/小说有），
    // 导致统计页「漫画」一栏的时长永远为 0。这里按真实停留时间累计。
    _startReadingClock();
    // 回到前台 / 切到后台时暂停或恢复计时，避免把挂后台的时间算进去
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

  // ---- 阅读时长计时 ----

  /// 每 10 秒结算一次（与小说/动漫的粒度一致）
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
        // 已结算的部分清零基准，剩下的秒数留到下一次
        _clockSince = DateTime.now();
        ReadingStats.instance.addSeconds(StatType.comic, sec);
      }
    });
  }

  /// 结算剩余秒数并停止计时（不足 10 秒也记，避免频繁进出丢时间）
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
    // 离开阅读页 → 先把当前页进度**强制**写一次。
    // 之前只有换页且有 3s 节流才保存，用户「翻两页就退出」时
    // 最后一次翻页落在节流窗口内 → 进度丢失，下次进来还是旧页。
    _saveProgress(_currentPage, force: true);
    // 离开阅读页 → 结算剩余阅读时长
    _stopReadingClock();
    _lifecycle?.dispose();
    // 离开阅读页 → 释放临时目录占用，开始计空闲时间（超时后自动回收）
    _releaseTemp();
    TempStore.instance.sweep();
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _pageController.dispose();
    // 释放进度 notifier（滚动期间高频更新的对象，必须显式释放）
    _progressNotifier.dispose();
    _pageNotifier.dispose();
    ChapterCacheManager.instance.revision.removeListener(_onCacheTick);
    // 离开阅读页 → 关闭音量键拦截，恢复系统音量调节
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

  void _onCacheTick() {
    if (mounted) setState(() {});
  }

  /// 滚动监听：**不 setState**，避免每帧重建整页导致卡死。
  ///
  /// 之前的写法在滚动里直接 setState，等于每一帧都重建整个阅读器
  /// （含上千个 ReaderPageView），滚动越长越卡，最终 ANR。
  ///
  /// 现在用 ValueNotifier 只驱动底栏那一小块重绘；
  /// 页码真正变化时才更新，且保存进度有独立节流。
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
    // 只推给进度条（值相同不会触发重建）
    _progressNotifier.value = p;
    _pageNotifier.value = page;
    if (page != _currentPage) {
      _currentPage = page;
      // 保存进度本身有 3 秒节流，不会每帧写盘
      _saveProgress(page);
    }
  }

  /// 竖向滚动进度（0~1），驱动底栏进度条，不重建整页。
  final _progressNotifier = ValueNotifier<double>(0);

  /// 当前页码，驱动底栏页码文本。
  final _pageNotifier = ValueNotifier<int>(1);

  /// 保存阅读进度（节流：每 3 秒或换页时）。
  DateTime _lastProgressSave = DateTime.fromMillisecondsSinceEpoch(0);
  void _saveProgress(int page, {bool force = false}) {
    final ch = _chapter;
    // 总页数按模式取：离线时 _bundle 为 null，之前这里直接 return，
    // 导致离线阅读的进度完全存不下来。
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

  /// 离线加载：扫描目录里的图片文件。
  ///
  /// 复用在线阅读器的一切（顶栏/底栏/翻页模式/缩放/进度），
  /// 只是数据源换成磁盘。这样用户不会感到「离线是另一个 App」。
  Future<void> _loadLocal() async {
    try {
      final dir = Directory(widget.localDir!);
      if (!await dir.exists()) {
        if (!mounted) return;
        setState(() {
          _loading = false;
          _error = L.t('offlineEmpty');
        });
        return;
      }
      // 只取图片，按文件名排序（001.png, 002.png …）
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
      // 离线也记历史与统计（用户要求统计要算离线资源）
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
    // ---- 离线模式：扫目录取图片，界面与在线完全一致 ----
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
        // 续读：跳到详情页指定的页（夹在本章范围内）
        final want = widget.initialPage;
        _currentPage = (want >= 1 && want <= b.length) ? want : 1;
        _progressNotifier.value = b.length <= 0 ? 0 : (_currentPage - 1) / b.length;
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
          kind: 'comic',
          // 关键：记下**续读起始页**，否则每次记录都用默认值 1，
          // 进度条永远是 0，下次进来也从第 1 页开始。
          page: _currentPage,
          totalPage: b.length,
          updatedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );

      // 启动整章缓存（后台持续）
      // 若该章此前已完整缓存（磁盘仍在 / 已有临时目录），
      // 直接进入阅读，不再显示缓存蒙版
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
        // 从用户当前所在页向两侧扩散加载，优先保证眼前这一页
        startPage: _currentPage,
      );
      if (!mounted) return;
      // 大章节：临时目录就绪后再「占用」，离开阅读页才释放。
      // 占用期间不做空闲回收，避免边看边被清扫。
      if (task.tempDirReady != null) {
        await task.tempDirReady;
        final td = task.tempDir;
        if (td != null && td.isNotEmpty) TempStore.instance.acquire(td);
      }
      if (!mounted) return;
      setState(() {
        _task = task;
        // 已缓存完成 / 空章节 / 今天已勾选「不再询问」→ 不显示蒙版
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

  /// 释放当前章的临时目录占用（交给空闲回收）。
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
                    // 进度条右侧显示**百分比**。
                    // 「已缓存/总缓存」在顶栏已经显示，这里不重复。
                    Text(
                      '${(task.progress * 100).round()}%',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        fontFeatures: [FontFeature.tabularFigures()],
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
    // ---- 离线模式：走同一套 UI，只是页面源换成磁盘文件 ----
    if (_isLocal) {
      if (_localFiles.isEmpty) {
        return Center(
          child: Text(
            L.t('noImages'),
            style: const TextStyle(color: Colors.white70),
          ),
        );
      }
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _showUi = !_showUi),
        child: _vertical ? _buildLocalVertical() : _buildLocalHorizontal(),
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

  /// 离线竖向。
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
      controller: _scroll,
      itemCount: _localFiles.length,
      cacheExtent: 6000,
      physics: const ClampingScrollPhysics(),
      itemBuilder: (context, i) => _buildLocalPage(i),
    );
  }

  /// 离线横向。
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

  /// 各离线页的真实比例（用于占位与滚动估算）
  final Map<int, double> _localRatios = {};

  Widget _buildLocalPage(int i) {
    return _LocalImageView(
      key: ValueKey('local_${widget.localDir}_$i'),
      file: _localFiles[i],
      fallbackRatio: _localRatios[i] ?? 0.72,
      onLoaded: (r) {
        if (!_localRatios.containsKey(i)) {
          // 只记录一次，避免重复 setState
          _localRatios[i] = r;
        }
      },
    );
  }

  /// 大章节临时目录（任务创建后才有值；非空时页面从这里读）
  String? get _tempDir => _task?.tempDir;

  Widget _buildVertical(ReadBundle b) {
    // 竖向条漫：**恢复滚动位置到续读页**。
    //
    // 之前 ListView 从不滚动到 _currentPage，所以续读时总是从第 1 页
    // 顶部开始 —— 而进度条（_progress）是用 _currentPage 算的，
    // 于是出现「进度条位置对、实际画面错」的矛盾。
    //
    // 做法：首帧后用 estimated 高度把目标页滚到视口顶部。
    // 各页高度未知（图片比例不同），因此用 fallbackRatio 估算，
    // 并在每页载入真实比例后由 _rememberRatio 修正后续估算。
    if (!_restoredScroll && _currentPage > 1) {
      _restoredScroll = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scroll.hasClients) return;
        final target = _estimateOffsetFor(b, _currentPage - 1);
        _scroll.jumpTo(target.clamp(0.0, _scroll.position.maxScrollExtent));
      });
    }
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
          chapterId: b.chapterId,
          tempDir: _tempDir,
          // 占位高度沿用「上一页真实比例」，图片载入时就不会跳
          fallbackRatio: _ratioAt(i),
          onLoaded: (r) => _rememberRatio(i, r),
        );
      },
    );
  }

  /// 是否已经恢复过竖向滚动位置（只做一次，避免用户手动滚动后被拉回）。
  bool _restoredScroll = false;

  /// 估算第 [index] 页在竖向列表中的滚动偏移。
  ///
  /// 每页高度 = 屏宽 / 该页比例（宽/高），再加上页间距。
  /// 比例未知时用 fallbackRatio，已载入的页用真实比例。
  double _estimateOffsetFor(ReadBundle b, int index) {
    final width = MediaQuery.of(context).size.width;
    var offset = 0.0;
    for (var i = 0; i < index && i < b.length; i++) {
      final r = _ratioAt(i);
      // 防止比例为 0 导致无穷大
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

  /// 每页的真实宽高比（加载完成后记录）。
  final Map<int, double> _ratios = {};

  /// 第 [i] 页的占位比例：优先用相邻已加载页的真实比例，
  /// 让「占位 → 真图」的尺寸变化尽可能为 0（用户感知不到跳变）。
  double _ratioAt(int i) {
    final self = _ratios[i];
    if (self != null) return self;
    // 向前找最近一页
    for (var k = i - 1; k >= 0; k--) {
      final r = _ratios[k];
      if (r != null) return r;
    }
    // 向后找最近一页
    for (var k = i + 1; k < (_bundle?.length ?? 0); k++) {
      final r = _ratios[k];
      if (r != null) return r;
    }
    // 漫画页面的常见比例（约 A5 竖版）
    return 0.72;
  }

  void _rememberRatio(int i, double r) {
    if (r <= 0 || !r.isFinite) return;
    if (_ratios[i] == r) return;
    // 不 setState：占位已被真实图片取代，重生整棵列表反而会掉帧
    _ratios[i] = r;
  }

  /// 跳到指定页（目录/上一章下一章用；页内不再提供「跳过」按钮）。
  void _skipTo(int index) {
    // 总页数按当前模式取（离线用 _localFiles）
    final total = _isLocal ? _localFiles.length : (_bundle?.length ?? 0);
    if (total <= 0 || index < 0 || index >= total) return;
    final p = total <= 1 ? 0.0 : index / (total - 1);
    _currentPage = index + 1;
    // 只更新进度条，不 setState 重建整页
    _progressNotifier.value = p;
    _pageNotifier.value = index + 1;
    if (_vertical) {
      // 竖向：按页估算位置直接跳（jumpTo 比 animateTo 轻，拖动时不卡）
      if (_scroll.hasClients) {
        final max = _scroll.position.maxScrollExtent;
        if (max > 0) _scroll.jumpTo(max * p);
      }
    } else {
      // 横向：拖动时用 jumpToPage 避免动画排队（快速滑动会卡）
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

  /// 当前页是否已被加为书签
  bool get _bookmarkedThisPage {
    final ch = _chapter;
    if (ch == null) return false;
    return AppState.instance.isChapterBookmarked(
      widget.comic.id,
      ch.id,
      page: _currentPage,
    );
  }

  /// 添加 / 移除当前页书签（可附批注）。
  Future<void> _togglePageBookmark() async {
    final ch = _chapter;
    if (ch == null) return;
    final on = !_bookmarkedThisPage;
    final chapterName = ch.name.trim().isNotEmpty
        ? ch.name
        : L.tp('episodeN', {'n': ch.sort > 0 ? ch.sort : 1});

    if (on) {
      // 加书签时问一句批注（可以不填）
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

  /// 弹一个输入框收批注；返回 null 表示用户取消。
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
    // 总页数要按当前模式取：
    //  * 在线 → _bundle.length
    //  * 离线 → _localFiles.length
    //
    // 之前只取 _bundle，离线模式下 _bundle 是 null → total 恒为 0，
    // 于是底栏显示「1/0」、滑块无效。
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
                // 页码只在滚动时变化 → 用 ValueListenableBuilder 局部重建，
                // 不牵动整个阅读器（这是之前滚动卡死的主因）。
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
                // 书签：把「当前章节 + 当前页」加入书签，可附批注
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

/// 单页：优先使用已缓存解码图，未就绪则实时加载（边看边缓存）。
class ReaderPageView extends StatefulWidget {
  final PageRef ref;
  final String? scrambleId;
  final String scrambleAid;
  final String albumId;
  final ComicSource source;
  final String cacheKey;
  final BoxFit fit;

  /// 占位比例（宽/高）：用于「图片未到」时的骨架高度。
  ///
  /// 与真实图片比例越接近，加载完成时的位移越小。
  final double fallbackRatio;

  /// 大章节的临时目录（非空时优先从这里读，避免整章驻留内存）。
  final String? tempDir;

  /// 章节 id（读临时目录时用来派生解密键）
  final String chapterId;

  /// 图片解码完成后回调真实比例，供后续页面作为占位比例复用。
  final ValueChanged<double>? onLoaded;

  const ReaderPageView({
    super.key,
    required this.ref,
    required this.scrambleId,
    required this.scrambleAid,
    required this.albumId,
    required this.source,
    required this.cacheKey,
    this.chapterId = '',
    this.tempDir,
    this.fit = BoxFit.fitWidth,
    this.fallbackRatio = 0.72,
    this.onLoaded,
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

    // ---- 大章节：直接从临时目录读（内存只留当前解码页）----
    final tempDir = widget.tempDir;
    if (tempDir != null && tempDir.isNotEmpty) {
      final bytes = await TempStore.instance.get(
        tempDir,
        widget.ref.index,
        sourceId: widget.source.id,
        chapterId: widget.chapterId,
      );
      if (bytes != null && bytes.isNotEmpty) {
        final img = await ImageCacheManager.decode(bytes);
        if (!mounted) return;
        setState(() {
          _image = img;
          _failed = img == null;
        });
        if (img == null) _started = false;
        return;
      }
      // 临时目录还没写到这一页 → 落到下面走「网络/缓存」路径
    }

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
      // 阅读页图片同样可能在死域名上（服务端下发的直链），
      // 失败后换镜像再试，与封面同一套自愈逻辑。
      fetcher: (u) async {
        final b = await JmApi.instance.fetchBytes(
          u,
          referer: widget.source.id == 'ehentai' ? widget.ref.resolveUrl : null,
        );
        if (b != null) return b;
        for (final alt in JmService.instance.imageUrlCandidates(u)) {
          final r = await JmApi.instance.fetchBytes(
            alt,
            referer:
                widget.source.id == 'ehentai' ? widget.ref.resolveUrl : null,
          );
          if (r != null) return r;
        }
        return null;
      },
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
      // 占位：用 fallbackRatio 撑出与真实图片近似的尺寸，
      // 图片到达时高度基本不变 → 用户感知不到跳变。
      // （原来固定 0.7，遇到跨页大图会整页往上弹一大截）
      return AspectRatio(
        aspectRatio: widget.fallbackRatio <= 0 ? 0.72 : widget.fallbackRatio,
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
            ],
          ),
        ),
      );
    }
    final ratio = img.width / img.height <= 0 ? 0.72 : img.width / img.height;
    // 回调真实比例（不重建）：后续未加载的页用它作为占位比例
    widget.onLoaded?.call(ratio);
    return AspectRatio(
      aspectRatio: ratio,
      child: RawImage(
        image: img,
        fit: widget.fit,
        filterQuality: FilterQuality.low,
      ),
    );
  }
}



/// 离线单页图片（从磁盘文件读取）。
///
/// 与在线 ReaderPageView 视觉一致：同样的占位比例、同样的 fit、
/// 同样在解码后回调真实比例。区别只是数据来自 File 而不是网络。
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
      // 占位：与真实比例一致，图片到位时不跳
      return AspectRatio(
        aspectRatio:
            widget.fallbackRatio <= 0.01 ? 0.72 : widget.fallbackRatio,
        child: const SizedBox.expand(),
      );
    }
    return RawImage(image: img, fit: BoxFit.fitWidth);
  }
}