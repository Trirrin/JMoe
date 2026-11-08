import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

import '../core/l10n.dart';
import '../core/jm_service.dart';
import '../core/reader_native.dart';
import '../core/app_state.dart';
import '../core/reading_stats.dart';
import '../core/video_cache.dart';

/// 动漫 / 影片播放页（完整功能）：
/// - 手势：垂直左亮度右音量、水平拖动进度、双击左右快进/快退、长按 3 倍速
/// - 控制条：播放/暂停、±10s、进度条、倍速、画面模式、全屏、锁屏
/// - 断点续播、播放完成自动下一集（同系列）
/// - 底部：标题、来源、简介、标签、相关推荐
class AnimePlayerPage extends StatefulWidget {
  final String id;
  final String title;
  final String videoType;

  /// 同系列（多集）播放列表：每项 {id, title, photo?}
  final List<Map<String, dynamic>> playlist;
  final int playlistIndex;

  const AnimePlayerPage({
    super.key,
    required this.id,
    required this.title,
    this.videoType = 'hanime',
    this.playlist = const [],
    this.playlistIndex = 0,
  });

  @override
  State<AnimePlayerPage> createState() => _AnimePlayerPageState();
}

class _AnimePlayerPageState extends State<AnimePlayerPage>
    with WidgetsBindingObserver {
  VideoPlayerController? _controller;
  bool _loading = true;
  String? _error;
  Map<String, dynamic>? _info;

  late String _currentId;
  late String _currentTitle;

  // 控制层
  bool _showControls = true;
  bool _locked = false;
  bool _fullscreen = false;
  Timer? _hideTimer;

  // 手势
  double _brightness = 0.5; // 0..1 当前亮度（真实值）
  double _volume = 0.5; // 0..1 当前媒体音量（真实值）
  double? _seekPreview; // 拖动中的预览位置（毫秒）
  double? _dragStartMs;
  String? _hud; // 瞬时提示文字

  // 长按倍速模式：长按后左右滑动改倍速
  bool _longPressing = false;
  double _rateAtLongPress = 1.0;

  /// 长按期间临时倍速（仅用于 HUD 显示，不持久化）
  double? _tmpRate;

  // 垂直滑动基准
  double _vertBase = 0;
  bool _vertIsBrightness = true;

  // 预缓存状态
  bool _caching = false;
  int _cacheDone = 0;
  int _cacheTotal = 0;
  bool _cancelCache = false;

  // ---- 统计埋点 ----
  /// 上次已计入统计的播放位置（毫秒），用于按增量累计时长
  int _lastStatPosition = 0;
  bool _statRecorded = false;

  // 设置
  double _rate = 1.0;
  BoxFit _fit = BoxFit.contain;

  static const _prefsRate = 'player_rate';
  static const _prefsFit = 'player_fit';

  VideoPlayerController? get _c => _controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _currentId = widget.id;
    _currentTitle = widget.title;
    _restorePrefs();
    _loadInitialLevels();
    _load();
    _scheduleHide();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _hideTimer?.cancel();
    _controller?.dispose();
    _restoreSystemUi();
    // 退出播放器恢复系统亮度（-1 = 跟随系统）
    ReaderNative.instance.setBrightness(-1);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _c?.pause();
      _saveProgress();
    }
  }


  /// 读取当前系统亮度与媒体音量，作为手势起点。
  Future<void> _loadInitialLevels() async {
    final b = await ReaderNative.instance.getBrightness();
    final v = await ReaderNative.instance.getVolume();
    if (!mounted) return;
    setState(() {
      _brightness = b.clamp(0.0, 1.0);
      _volume = v.clamp(0.0, 1.0);
    });
  }

  Future<void> _restorePrefs() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final r = sp.getDouble(_prefsRate);
      final f = sp.getString(_prefsFit);
      if (!mounted) return;
      setState(() {
        if (r != null) _rate = r.clamp(0.5, 3.0);
        _fit = switch (f) {
          'cover' => BoxFit.cover,
          'fill' => BoxFit.fill,
          _ => BoxFit.contain,
        };
      });
      await _c?.setPlaybackSpeed(_rate);
    } catch (_) {}
  }

  Future<void> _savePrefs() async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setDouble(_prefsRate, _rate);
      await sp.setString(
        _prefsFit,
        _fit == BoxFit.cover ? 'cover' : (_fit == BoxFit.fill ? 'fill' : 'contain'),
      );
    } catch (_) {}
  }

  /// 正在切换选集（加载/缓存中）。
  ///
  /// 切换过程包含「取播放地址 → 下载缓存 → 初始化播放器」几步，
  /// 期间若再点别的选集，会把 `_currentId` 改成新值但旧流程仍在跑，
  /// 最后两边都去初始化 `_controller` → 相互打断、界面错乱。
  /// 因此切换期间**忽略新的切换请求**。
  bool _switching = false;

  Future<void> _load({String? id, String? title}) async {
    if (_switching) return; // 动画/加载中，不接受新的切换
    _switching = true;
    if (id != null) _currentId = id;
    if (title != null) _currentTitle = title;
    setState(() {
      _loading = true;
      _error = null;
    });
    await _controller?.dispose();
    _controller = null;

    final info = await JmService.instance.fetchVideoInfo(
      _currentId,
      videoType: widget.videoType,
    );
    if (!mounted) return;
    _info = info;
    final video = info?['video'];
    String? src;
    if (video is Map) src = '${video['video_src'] ?? ''}';
    if (src == null || src.isEmpty || !src.startsWith('http')) {
      setState(() {
        _loading = false;
        _error = L.t('noPlayUrl');
      });
      _switching = false;
      return;
    }
    if (title == null && video is Map) {
      final t = '${video['title'] ?? ''}';
      if (t.isNotEmpty) _currentTitle = t;
    }

    // ---- 播放前缓存：命中本地直接播，未命中先下载 ----
    String playSrc = src;
    final local = await VideoCacheManager.instance.cachedPath(src);
    if (local != null) {
      playSrc = local;
      if (mounted) {
        setState(() {
          _caching = false;
        });
      }
    } else {
      // 进入缓存阶段（UI 显示进度）
      if (mounted) {
        setState(() {
          _caching = true;
          _cacheDone = 0;
          _cacheTotal = 0;
          _cancelCache = false;
        });
      }
      final path = await VideoCacheManager.instance.fetchHls(
        url: src,
        onProgress: (doneBytes, totalBytes) {
          if (!mounted) return;
          // 字节级进度：直接映射到 0..1，不再按分片数跳变
          setState(() {
            _cacheDone = doneBytes;
            _cacheTotal = totalBytes;
          });
        },
        isCancelled: () => _cancelCache,
      );
      if (!mounted) {
        _switching = false;
        return;
      }
      if (path != null) {
        playSrc = path;
        setState(() {
          _caching = false;
        });
      } else {
        // 缓存失败/取消：回落为直接网络播放
        setState(() {
          _caching = false;
          _cancelCache = false;
        });
      }
    }

    final c = VideoPlayerController.networkUrl(
      Uri.parse(playSrc),
      videoPlayerOptions: VideoPlayerOptions(mixWithOthers: false),
    );
    _controller = c;
    c.addListener(_onTick);
    try {
      await c.initialize();
      await c.setPlaybackSpeed(_rate);
      await _restoreProgress();
      await c.play();
      if (!mounted) return;
      setState(() => _loading = false);

      // ---- 统计：记录一次视频观看 ----
      if (!_statRecorded) {
        _statRecorded = true;
        _lastStatPosition = c.value.position.inMilliseconds;
        ReadingStats.instance.recordChapter(
          type: StatType.video,
          workId: _currentId,
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = L.tp('playFailed', {'e': e});
      });
    } finally {
      // 无论成功失败都解除「切换中」；失败的集数可以再点一次重试
      _switching = false;
    }
  }

  void _onTick() {
    final v = _c?.value;
    if (v == null || !mounted) return;

    // ---- 统计：按实际播放增量累计时长 ----
    if (v.isPlaying) {
      final cur = v.position.inMilliseconds;
      final delta = cur - _lastStatPosition;
      // 只排除「明显拖动」造成的跳变（>15s），
      // 缓冲卡顿后的正常增量要照常累计，否则时长永远为 0。
      if (delta > 0 && delta < 15000) {
        final sec = delta ~/ 1000;
        if (sec > 0) {
          ReadingStats.instance.addSeconds(StatType.video, sec);
        }
      }
      _lastStatPosition = cur;
    } else {
      _lastStatPosition = v.position.inMilliseconds;
    }
    if (v.isCompleted && v.position >= v.duration) {
      _saveProgress(force: true);
      _autoNext();
      return;
    }
    // 每 5 秒保存一次进度
    final ms = v.position.inMilliseconds;
    if ((ms ~/ 5000) != (_lastSavedBucket)) {
      _lastSavedBucket = ms ~/ 5000;
      _saveProgress();
    }
    setState(() {});
  }

  int _lastSavedBucket = -1;

  String get _progressKey => 'video_pos_${widget.videoType}_$_currentId';

  Future<void> _restoreProgress() async {
    final c = _c;
    if (c == null) return;
    try {
      final sp = await SharedPreferences.getInstance();
      final ms = sp.getInt(_progressKey);
      if (ms != null && ms > 3000) {
        final dur = c.value.duration.inMilliseconds;
        if (dur == 0 || ms < dur - 3000) {
          await c.seekTo(Duration(milliseconds: ms));
        }
      }
    } catch (_) {}
  }

  Future<void> _saveProgress({bool force = false}) async {
    final c = _c;
    if (c == null) return;
    try {
      final sp = await SharedPreferences.getInstance();
      final ms = c.value.position.inMilliseconds;
      final dur = c.value.duration.inMilliseconds;
      if (dur > 0 && ms >= dur - 2000) {
        await sp.remove(_progressKey); // 看完清掉
      } else if (ms > 1000) {
        await sp.setInt(_progressKey, ms);
      }
      // 同步写阅读历史（kind = video）：用「秒」当页单位，
      // 这样历史里也能算出「看了多少 / 共多少」的占比。
      if (dur > 0) {
        AppState.instance.recordHistory(
          ReadHistoryEntry(
            comicId: _currentId,
            chapterId: _currentId,
            comicName: _currentTitle,
            chapterName: _currentTitle,
            cover: null,
            source: 'jm',
            kind: 'video',
            page: (ms ~/ 1000).clamp(0, dur ~/ 1000),
            totalPage: dur ~/ 1000,
            updatedAt: DateTime.now().millisecondsSinceEpoch,
          ),
        );
      }
    } catch (_) {}
  }

  void _autoNext() {
    final list = widget.playlist;
    if (list.isEmpty) return;
    final cur = list.indexWhere((e) => '${e['id']}' == _currentId);
    final next = cur >= 0 ? cur + 1 : widget.playlistIndex + 1;
    if (next > 0 && next < list.length) {
      _toast(L.tp('autoNextTip', {'t': '${list[next]['title'] ?? ''}'}));
      _load(id: '${list[next]['id']}', title: '${list[next]['title'] ?? ''}');
    }
  }

  // ---------------- 控制 ----------------

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (!mounted) return;
      if (_c?.value.isPlaying == true && !_locked) {
        setState(() => _showControls = false);
      }
    });
  }

  void _toggleControls() {
    setState(() => _showControls = !_showControls);
    if (_showControls) _scheduleHide();
  }

  void _togglePlay() {
    final c = _c;
    if (c == null) return;
    setState(() {
      if (c.value.isPlaying) {
        c.pause();
        _showControls = true;
        _hideTimer?.cancel();
      } else {
        c.play();
        _scheduleHide();
      }
    });
  }

  void _seekRel(int seconds) {
    final c = _c;
    if (c == null) return;
    var t = c.value.position + Duration(seconds: seconds);
    if (t < Duration.zero) t = Duration.zero;
    if (t > c.value.duration) t = c.value.duration;
    c.seekTo(t);
    _toast(seconds > 0 ? '+${seconds}s' : '${seconds}s');
    _scheduleHide();
  }

  void _toast(String msg) {
    setState(() => _hud = msg);
    Future.delayed(const Duration(milliseconds: 900), () {
      if (mounted && _hud == msg) setState(() => _hud = null);
    });
  }

  void _setRate(double r) {
    setState(() => _rate = r);
    _c?.setPlaybackSpeed(r);
    _savePrefs();
    _toast('${r}x');
  }

  void _cycleFit() {
    setState(() {
      _fit = _fit == BoxFit.contain
          ? BoxFit.cover
          : (_fit == BoxFit.cover ? BoxFit.fill : BoxFit.contain);
    });
    _savePrefs();
    _toast(_fit == BoxFit.contain
        ? L.t('fitContain')
        : (_fit == BoxFit.cover ? L.t('fitCover') : L.t('fitFill')));
  }

  void _toggleFullscreen() {
    setState(() => _fullscreen = !_fullscreen);
    if (_fullscreen) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    } else {
      _restoreSystemUi();
    }
  }

  void _restoreSystemUi() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
  }
  /// 字节 → 人类可读（缓存进度用）。
  String _fmtBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    String two(int v) => v.toString().padLeft(2, '0');
    return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
  }

  // ---------------- UI ----------------

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final videoArea = _fullscreen
        ? SizedBox.expand(child: _buildVideoLayer())
        : AspectRatio(
            aspectRatio: 16 / 9,
            child: _buildVideoLayer(),
          );

    // 信息面板固定浅色主题，避免跟随系统深色导致整页发黑
    final lightTheme = ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF4CAF50),
        brightness: Brightness.light,
      ),
    );

    return PopScope(
      // 全屏时拦截系统返回：先退出全屏，而不是直接 pop 掉播放页
      // （否则会一路退回详情页的上一页）
      canPop: !_fullscreen,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_fullscreen) _toggleFullscreen();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
      body: SafeArea(
        top: !_fullscreen,
        bottom: !_fullscreen,
        child: _fullscreen
            ? videoArea
            : Column(
                children: [
                  // 不再有独立标题栏：标题只保留在播放器控制层里
                  // （避免出现两行标题）
                  // 视频区不占满剩余空间：16:9 高度即可，
                  // 让下方信息面板有足够位置（之前 Expanded 撑太大）
                  AspectRatio(
                    aspectRatio: 16 / 9,
                    child: videoArea,
                  ),
                  Expanded(
                    child: Theme(
                      data: lightTheme,
                      child: Container(
                        color: lightTheme.colorScheme.surface,
                        child: _buildInfoPanel(media),
                      ),
                    ),
                  ),
                ],
              ),
        ),
      ),
    );
  }


  /// 播放前的缓存蒙层：进度条 + 百分比 + 「边下边播」。
  ///
  /// 布局要点（修过两个问题）：
  ///  * **标题与退出按钮同一行**：以前返回按钮用 `Positioned` 贴在左上，
  ///    标题在 `Center` 列里，两者基线永远对不齐。现在统一放进顶部 Row。
  ///  * **按钮不贴底边**：蒙层高度取决于视频区域，内容居中时按钮可能
  ///    紧贴下沿。改成「顶部标题栏 + 中间信息 + 底部安全间距」，
  ///    并给整块加 `SafeArea`，任何屏幕比例下都不贴边。
  Widget _buildCacheOverlay() {
    // 用分片完成比例作为进度（比字节估算稳定）
    final pct = _cacheTotal <= 0 ? 0.0 : _cacheDone / _cacheTotal;
    return Container(
      color: Colors.black.withValues(alpha: 0.55),
      child: SafeArea(
        child: Column(
          children: [
            // ---- 顶部：返回 + 标题（同一行，垂直居中）----
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 16, 4),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(
                      Icons.arrow_back_rounded,
                      color: Colors.white,
                      size: 22,
                    ),
                    tooltip: L.t('back'),
                    onPressed: () {
                      _cancelCache = true;
                      Navigator.of(context).maybePop();
                    },
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      _currentTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // ---- 中间：进度信息 ----
            Expanded(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.download_rounded,
                        color: Colors.white70,
                        size: 34,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        L.t('preparingVideo'),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 14),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: _cacheTotal <= 0 ? null : pct,
                          minHeight: 5,
                          backgroundColor: Colors.white24,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          // 只显示已下载量：HLS 没有准确总大小，
                          // 用「均值×片数」估算会一直跳动。
                          Text(
                            _fmtBytes(_cacheDone),
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 11.5,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '${(pct * 100).toStringAsFixed(0)}%',
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 11.5,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
            // ---- 底部：边下边播（与下边缘留出间距，不再贴边）----
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
              child: OutlinedButton(
                onPressed: () {
                  // 放弃缓存，立刻用网络流播放
                  _cancelCache = true;
                  setState(() => _caching = false);
                },
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: Colors.white38),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 10,
                  ),
                  minimumSize: const Size(double.infinity, 40),
                ),
                child: Text(
                  L.t('playWhileCaching'),
                  style: const TextStyle(fontSize: 12.5),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVideoLayer() {
    final c = _c;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _locked ? null : _toggleControls,
      onDoubleTapDown: (d) {
        if (_locked || c == null) return;
        final w = context.size?.width ?? 1;
        if (d.localPosition.dx < w / 2) {
          _seekRel(-10);
        } else {
          _seekRel(10);
        }
      },
      // 长按临时调倍速：不改动持久化的 _rate，松手即还原
      onLongPressStart: (d) {
        if (_locked || c == null) return;
        _longPressing = true;
        // 长按**固定以 2 倍速为起点**（与行业通行做法一致：
        // 长按就是「加速看」，不该跟随用户平时设的倍速）。
        // 之后左右滑动再以 2x 为基准增减。
        _rateAtLongPress = 2.0;
        c.setPlaybackSpeed(_rateAtLongPress);
        _toast('2.0x');
      },
      onLongPressMoveUpdate: (d) {
        if (!_longPressing || c == null) return;
        // 按**滑动比例**换算，滑过屏幕宽度 100% 覆盖 0.5x~3.0x 全量程。
        // 基准点 = 2.0x（长按起点）：右滑加速、左滑减速。
        final w = context.size?.width ?? 400;
        final frac = (d.offsetFromOrigin.dx / w).clamp(-1.0, 1.0);
        // frac: -1 → 0.5x，0 → 2.0x（起点），+1 → 3.0x
        // 右滑空间只有 1.0x，左滑有 1.5x，所以两侧斜率分开算。
        final raw = frac >= 0
            ? 2.0 + frac * (3.0 - 2.0)
            : 2.0 + frac * (2.0 - 0.5);
        final stepped =
            ((raw * 10).round() / 10).clamp(0.5, 3.0).toDouble();
        c.setPlaybackSpeed(stepped);
        setState(() {
          _hud = '${stepped.toStringAsFixed(1)}x';
          _tmpRate = stepped;
        });
      },
      onLongPressEnd: (_) {
        if (!_longPressing) return;
        _longPressing = false;
        // 还原为长按前的倍速，不写偏好
        _c?.setPlaybackSpeed(_rate);
        setState(() {
          _hud = null;
          _tmpRate = null;
        });
      },
      onVerticalDragStart: (d) {
        if (_locked || c == null) return;
        final w = context.size?.width ?? 1;
        final left = d.localPosition.dx < w / 2;
        _vertIsBrightness = left;
        _vertBase = left ? _brightness : _volume;
      },
      onVerticalDragUpdate: (d) {
        if (_locked || c == null) return;
        final delta = -d.delta.dy / 260;
        final next = (_vertBase + delta).clamp(0.0, 1.0);
        _vertBase = next;
        if (_vertIsBrightness) {
          _brightness = next;
          ReaderNative.instance.setBrightness(next);
          _toast('☀ ${(next * 100).round()}%');
        } else {
          _volume = next;
          ReaderNative.instance.setVolume(next);
          _toast('🔊 ${(next * 100).round()}%');
        }
      },
      onVerticalDragEnd: (_) {
        // 亮度持久化到本次会话，退出播放器时恢复系统默认
        _scheduleHide();
      },
      onHorizontalDragStart: (d) {
        if (_locked || c == null) return;
        _dragStartMs = c.value.position.inMilliseconds.toDouble();
      },
      onHorizontalDragUpdate: (d) {
        if (_locked || _dragStartMs == null || c == null) return;
        final dur = c.value.duration.inMilliseconds.toDouble();
        _dragStartMs = (_dragStartMs! + d.delta.dx * 60).clamp(0.0, dur);
        setState(() => _seekPreview = _dragStartMs);
      },
      onHorizontalDragEnd: (_) {
        if (_seekPreview != null && c != null) {
          c.seekTo(Duration(milliseconds: _seekPreview!.round()));
        }
        setState(() {
          _seekPreview = null;
          _dragStartMs = null;
        });
        _scheduleHide();
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (_loading)
            _caching
                ? _buildCacheOverlay()
                : const Center(child: CircularProgressIndicator())
          else if (_error != null)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.error_outline_rounded,
                        color: Colors.white54, size: 40),
                    const SizedBox(height: 10),
                    Text(
                      _error!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white70, fontSize: 13),
                    ),
                    const SizedBox(height: 14),
                    OutlinedButton(
                      onPressed: () => _load(),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: const BorderSide(color: Colors.white38),
                      ),
                      child: Text(L.t('retry')),
                    ),
                  ],
                ),
              ),
            )
          else if (c == null)
            Center(
              child: Text(L.t('noVideoSource'),
                  style: const TextStyle(color: Colors.white70)),
            )
          else
            // 单层 FittedBox 铺满整个视频区（之前嵌套两层，
            // 外层先按原生尺寸收缩，导致画面填不满、四周留黑边）
            SizedBox.expand(
              child: FittedBox(
                fit: _fit,
                child: SizedBox(
                  width: c.value.size.width,
                  height: c.value.size.height,
                  child: VideoPlayer(c),
                ),
              ),
            ),

          // 缓冲指示
          if (c != null && c.value.isBuffering && !_loading)
            const Center(
              child: SizedBox(
                width: 34,
                height: 34,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: Colors.white70,
                ),
              ),
            ),

          // HUD 提示
          if (_hud != null)
            Center(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.62),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  _hud!,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),

          // 拖动进度预览
          if (_seekPreview != null && c != null)
            Center(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.62),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '${_fmt(Duration(milliseconds: _seekPreview!.round()))}'
                  ' / ${_fmt(c.value.duration)}',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w600),
                ),
              ),
            ),

          // 中央播放按钮（暂停时）
          if (c != null && !_loading && _error == null && !c.value.isPlaying)
            Center(
              child: GestureDetector(
                onTap: _togglePlay,
                child: Container(
                  width: 62,
                  height: 62,
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.45),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.play_arrow_rounded,
                      color: Colors.white, size: 38),
                ),
              ),
            ),

          // 顶部栏 + 底部控制条
          if (_showControls && !_loading && _error == null)
            Positioned.fill(child: _buildOverlayControls()),
        ],
      ),
    );
  }

  Widget _buildOverlayControls() {
    final c = _c;
    if (c == null) return const SizedBox.shrink();
    final v = c.value;
    final total = v.duration.inMilliseconds.toDouble();
    final pos = (v.position.inMilliseconds.toDouble()).clamp(0.0, total);
    final progress = total <= 0 ? 0.0 : pos / total;

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.black.withValues(alpha: 0.45),
            Colors.transparent,
            Colors.black.withValues(alpha: 0.62),
          ],
          stops: const [0, 0.45, 1],
        ),
      ),
      child: Column(
        children: [
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
                onPressed: () => Navigator.of(context).maybePop(),
              ),
              Expanded(
                child: Text(
                  _currentTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 13.5),
                ),
              ),

            ],
          ),
          const Spacer(),
          // 中央控制按钮
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                iconSize: 30,
                icon: const Icon(Icons.replay_10_rounded, color: Colors.white),
                onPressed: () => _seekRel(-10),
              ),
              IconButton(
                iconSize: 54,
                icon: Icon(
                  v.isPlaying
                      ? Icons.pause_circle_filled_rounded
                      : Icons.play_circle_fill_rounded,
                  color: Colors.white,
                ),
                onPressed: _togglePlay,
              ),
              IconButton(
                iconSize: 30,
                icon: const Icon(Icons.forward_10_rounded, color: Colors.white),
                onPressed: () => _seekRel(10),
              ),
            ],
          ),
          const Spacer(),
          // 进度 + 时间
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Text(
                  _fmt(v.position),
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
                // 时间与进度条之间留出间距：之前两者紧贴，
                // 进度条起止点看起来像压在数字上
                const SizedBox(width: 10),
                Expanded(
                  child: _BufferedProgressBar(
                    progress: progress.clamp(0.0, 1.0),
                    // 已缓冲到的位置（灰色段）
                    buffered: total <= 0
                        ? 0.0
                        : (v.buffered.isEmpty
                                ? progress
                                : (v.buffered.last.end.inMilliseconds /
                                        total))
                            .clamp(0.0, 1.0),
                    onSeek: (x) {
                      c.seekTo(Duration(milliseconds: (total * x).round()));
                    },
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  _fmt(v.duration),
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
              ],
            ),
          ),
          // 底部工具条
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
            child: Row(
              children: [
                _chipBtn(
                  '${(_tmpRate ?? _rate).toStringAsFixed(1)}x',
                  () => _showRateSheet(),
                ),
                const SizedBox(width: 8),
                _chipBtn(
                  _fit == BoxFit.contain
                      ? L.t('fitContain')
                      : (_fit == BoxFit.cover
                          ? L.t('fitCover')
                          : L.t('fitFill')),
                  _cycleFit,
                ),
                const Spacer(),
                IconButton(
                  tooltip: L.t('lockScreen'),
                  icon: Icon(
                    _locked ? Icons.lock_rounded : Icons.lock_open_rounded,
                    color: Colors.white,
                    size: 20,
                  ),
                  onPressed: () {
                    setState(() {
                      _locked = !_locked;
                      if (_locked) _showControls = false;
                    });
                  },
                ),
                // 全屏：右下角
                IconButton(
                  tooltip: _fullscreen
                      ? L.t('exitFullscreen')
                      : L.t('enterFullscreen'),
                  icon: Icon(
                    _fullscreen
                        ? Icons.fullscreen_exit_rounded
                        : Icons.fullscreen_rounded,
                    color: Colors.white,
                    size: 24,
                  ),
                  onPressed: _toggleFullscreen,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _chipBtn(String text, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          text,
          style: const TextStyle(color: Colors.white, fontSize: 11.5),
        ),
      ),
    );
  }

  void _showRateSheet() {
    const rates = [0.5, 0.7, 0.8, 1.0, 1.2, 1.5, 1.8, 2.0, 2.5, 3.0];
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1C1C1E),
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                L.t('speed'),
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            ...rates.map(
              (r) => ListTile(
                dense: true,
                title: Text(
                  '${r}x',
                  style: TextStyle(
                    color: r == _rate ? Colors.white : Colors.white70,
                    fontSize: 14,
                    fontWeight:
                        r == _rate ? FontWeight.w700 : FontWeight.w400,
                  ),
                ),
                trailing: r == _rate
                    ? const Icon(Icons.check_rounded,
                        color: Colors.white, size: 18)
                    : null,
                onTap: () {
                  Navigator.of(ctx).pop();
                  _setRate(r);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------- 信息面板 ----------------

  Widget _buildInfoPanel(MediaQueryData media) {
    final theme = Theme.of(context);
    final video = _info?['video'];
    final desc = video is Map ? '${video['description'] ?? ''}' : '';
    final tags = video is Map
        ? (video['tags'] as List?)?.whereType<Object>().map((e) => '$e').toList() ??
            const <String>[]
        : const <String>[];
    final views = video is Map ? '${video['view'] ?? ''}' : '';
    final factory = video is Map ? '${video['factory'] ?? ''}' : '';
    final related = (_info?['related_videos'] as List?) ?? const [];
    final series = (_info?['videoSeries'] as List?) ?? const [];

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 28),
      children: [
        // 标题栏已显示标题，这里不再重复（避免两行标题）
        const SizedBox(height: 4),
        Wrap(
          spacing: 10,
          runSpacing: 4,
          children: [
            if (views.isNotEmpty && views != '0')
              _metaText(Icons.visibility_outlined, views, theme),
            if (factory.isNotEmpty)
              _metaText(Icons.business_rounded, factory, theme),
            _metaText(
              widget.videoType == 'movie' ? Icons.movie_outlined : Icons.tv_rounded,
              widget.videoType == 'movie' ? 'AV' : 'Anime',
              theme,
            ),
          ],
        ),
        if (tags.isNotEmpty) ...[
          const SizedBox(height: 12),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: tags
                .map(
                  (t) => Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(t, style: const TextStyle(fontSize: 11)),
                  ),
                )
                .toList(),
          ),
        ],
        if (desc.isNotEmpty) ...[
          const SizedBox(height: 14),
          Text(
            desc,
            style: TextStyle(
              fontSize: 13,
              height: 1.7,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.82),
            ),
          ),
        ],
        if (series.length > 1) ...[
          const SizedBox(height: 20),
          Text(
            L.t('chapters'),
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          ...series.take(30).map((e) {
            final m = e is Map ? e : const {};
            final id = '${m['id'] ?? m['vid'] ?? ''}';
            final t = '${m['title'] ?? m['name'] ?? ''}';
            final active = id == _currentId;
            return Card(
              margin: const EdgeInsets.only(bottom: 6),
              elevation: 0,
              color: active
                  ? theme.colorScheme.primaryContainer.withValues(alpha: 0.5)
                  : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
              child: ListTile(
                dense: true,
                leading: Icon(
                  active
                      ? Icons.equalizer_rounded
                      : Icons.play_circle_outline_rounded,
                  size: 18,
                  color: active ? theme.colorScheme.primary : null,
                ),
                title: Text(t, style: const TextStyle(fontSize: 12.5)),
                onTap: () => _load(id: id, title: t),
              ),
            );
          }),
        ],
        if (related.isNotEmpty) ...[
          const SizedBox(height: 20),
          Text(
            L.t('relatedRecommend'),
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          ...related.take(12).map((e) {
            final m = e is Map ? Map<String, dynamic>.from(e) : <String, dynamic>{};
            final id = '${m['id'] ?? ''}';
            final t = '${m['title'] ?? ''}';
            final photo = '${m['photo'] ?? m['photo_str'] ?? ''}';
            return Card(
              margin: const EdgeInsets.only(bottom: 6),
              elevation: 0,
              color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
              child: ListTile(
                dense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                leading: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: SizedBox(
                    width: 64,
                    height: 38,
                    child: photo.isEmpty
                        ? Container(color: theme.colorScheme.surfaceContainerHighest)
                        : Image.network(
                            photo.startsWith('http')
                                ? photo
                                : '${JmService.instance.imgHost ?? ''}$photo',
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => Container(
                              color: theme.colorScheme.surfaceContainerHighest,
                            ),
                          ),
                  ),
                ),
                title: Text(
                  t,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, height: 1.35),
                ),
                onTap: () => _load(id: id, title: t),
              ),
            );
          }),
        ],
      ],
    );
  }

  Widget _metaText(IconData icon, String text, ThemeData theme) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 3),
        Text(
          text,
          style: TextStyle(
            fontSize: 11.5,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// 供外部判断是否横屏设备（保留工具，未强制使用）。
bool get isAndroid => Platform.isAndroid;

/// 带缓冲进度的播放进度条：
/// 白色 = 已播放，灰色 = 已缓冲未播放，暗色 = 未缓冲。
class _BufferedProgressBar extends StatefulWidget {
  final double progress; // 0..1 播放位置
  final double buffered; // 0..1 缓冲位置
  final ValueChanged<double> onSeek;

  const _BufferedProgressBar({
    required this.progress,
    required this.buffered,
    required this.onSeek,
  });

  @override
  State<_BufferedProgressBar> createState() => _BufferedProgressBarState();
}

class _BufferedProgressBarState extends State<_BufferedProgressBar> {
  bool _dragging = false;
  double _dragValue = 0;

  @override
  Widget build(BuildContext context) {
    final shown = _dragging ? _dragValue : widget.progress;
    return LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth;
        void seekTo(double dx) {
          final x = (dx / w).clamp(0.0, 1.0);
          setState(() => _dragValue = x);
          widget.onSeek(x);
        }

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) => seekTo(d.localPosition.dx),
          onHorizontalDragStart: (d) {
            setState(() {
              _dragging = true;
              _dragValue = (d.localPosition.dx / w).clamp(0.0, 1.0);
            });
          },
          onHorizontalDragUpdate: (d) {
            setState(() {
              _dragValue = (d.localPosition.dx / w).clamp(0.0, 1.0);
            });
          },
          onHorizontalDragEnd: (_) {
            widget.onSeek(_dragValue);
            setState(() => _dragging = false);
          },
          child: SizedBox(
            height: 24,
            child: CustomPaint(
              painter: _ProgressPainter(
                progress: shown,
                buffered: widget.buffered.clamp(0.0, 1.0),
                thumbRadius: _dragging ? 7 : 5,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ProgressPainter extends CustomPainter {
  final double progress;
  final double buffered;
  final double thumbRadius;

  _ProgressPainter({
    required this.progress,
    required this.buffered,
    required this.thumbRadius,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final cy = size.height / 2;
    final w = size.width;
    const h = 3.5;
    final barRect = Rect.fromLTWH(0, cy - h / 2, w, h);
    final radius = Radius.circular(h / 2);

    // 未缓冲底轨
    canvas.drawRRect(
      RRect.fromRectAndRadius(barRect, radius),
      Paint()..color = Colors.white24,
    );

    // 已缓冲（灰色）
    final bufW = (w * buffered).clamp(0.0, w);
    if (bufW > 0.5) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(0, cy - h / 2, bufW, h),
          radius,
        ),
        Paint()..color = Colors.white.withValues(alpha: 0.42),
      );
    }

    // 已播放（白色）
    final progW = (w * progress).clamp(0.0, w);
    if (progW > 0.5) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(0, cy - h / 2, progW, h),
          radius,
        ),
        Paint()..color = Colors.white,
      );
    }

    // 滑块圆点
    canvas.drawCircle(
      Offset(progW, cy),
      thumbRadius,
      Paint()..color = Colors.white,
    );
  }

  @override
  bool shouldRepaint(_ProgressPainter old) =>
      old.progress != progress ||
      old.buffered != buffered ||
      old.thumbRadius != thumbRadius;
}
