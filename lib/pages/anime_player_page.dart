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

class AnimePlayerPage extends StatefulWidget {
  final String id;
  final String title;
  final String videoType;

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

  bool _showControls = true;
  bool _locked = false;
  bool _fullscreen = false;
  Timer? _hideTimer;

  double _brightness = 0.5;
  double _volume = 0.5;
  double? _seekPreview;
  double? _dragStartMs;
  String? _hud;

  bool _longPressing = false;
  double _rateAtLongPress = 1.0;

  double? _tmpRate;

  double _vertBase = 0;
  bool _vertIsBrightness = true;

  bool _caching = false;
  int _cacheDone = 0;
  int _cacheTotal = 0;
  bool _cancelCache = false;

  int _lastStatPosition = 0;
  bool _statRecorded = false;

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

  bool _switching = false;

  Future<void> _load({String? id, String? title}) async {
    if (_switching) return;
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
      _switching = false;
    }
  }

  void _onTick() {
    final v = _c?.value;
    if (v == null || !mounted) return;

    if (v.isPlaying) {
      final cur = v.position.inMilliseconds;
      final delta = cur - _lastStatPosition;
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
        await sp.remove(_progressKey);
      } else if (ms > 1000) {
        await sp.setInt(_progressKey, ms);
      }
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

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final videoArea = _fullscreen
        ? SizedBox.expand(child: _buildVideoLayer())
        : AspectRatio(
            aspectRatio: 16 / 9,
            child: _buildVideoLayer(),
          );

    final lightTheme = ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF4CAF50),
        brightness: Brightness.light,
      ),
    );

    return PopScope(
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

  Widget _buildCacheOverlay() {
    final pct = _cacheTotal <= 0 ? 0.0 : _cacheDone / _cacheTotal;
    return Container(
      color: Colors.black.withValues(alpha: 0.55),
      child: SafeArea(
        child: Column(
          children: [
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
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
              child: OutlinedButton(
                onPressed: () {
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
      onLongPressStart: (d) {
        if (_locked || c == null) return;
        _longPressing = true;
        _rateAtLongPress = 2.0;
        c.setPlaybackSpeed(_rateAtLongPress);
        _toast('2.0x');
      },
      onLongPressMoveUpdate: (d) {
        if (!_longPressing || c == null) return;
        final w = context.size?.width ?? 400;
        final frac = (d.offsetFromOrigin.dx / w).clamp(-1.0, 1.0);
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
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Text(
                  _fmt(v.position),
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _BufferedProgressBar(
                    progress: progress.clamp(0.0, 1.0),
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

bool get isAndroid => Platform.isAndroid;

class _BufferedProgressBar extends StatefulWidget {
  final double progress;
  final double buffered;
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

    canvas.drawRRect(
      RRect.fromRectAndRadius(barRect, radius),
      Paint()..color = Colors.white24,
    );

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
