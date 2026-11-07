import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../core/app_theme.dart';
import '../core/jm_service.dart';
import '../widgets/common_widgets.dart';
import '../core/l10n.dart';

/// 视频列表。
class VideosPage extends StatefulWidget {
  const VideosPage({super.key});

  @override
  State<VideosPage> createState() => _VideosPageState();
}

class _VideosPageState extends State<VideosPage> {
  final _service = JmService.instance;
  final _items = <Map<String, dynamic>>[];
  bool _loading = true;
  int _page = 1;

  @override
  void initState() {
    super.initState();
    _load(reset: true);
  }

  Future<void> _load({bool reset = false}) async {
    if (reset) {
      setState(() {
        _items.clear();
        _page = 1;
        _loading = true;
      });
    }
    final list = await _service.fetchVideos(page: _page);
    if (!mounted) return;
    setState(() {
      _items.addAll(list);
      _page++;
      _loading = false;
    });
  }

  String? _photo(Map<String, dynamic> v) {
    final host = JmService.instance.imgHost;
    final p = '${v['photo'] ?? v['photo_str'] ?? ''}';
    if (p.isEmpty) return null;
    if (p.startsWith('http')) return p;
    return '$host$p';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(L.t('anime'))),
      body: _loading && _items.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : _items.isEmpty
              ? EmptyView(message: L.t('noVideos'))
              : NotificationListener<ScrollNotification>(
                  onNotification: (n) {
                    if (n.metrics.pixels > n.metrics.maxScrollExtent - 400) {
                      _load();
                    }
                    return false;
                  },
                  child: GridView.builder(
                    padding: const EdgeInsets.all(AppStyle.pagePadding),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2,
                      mainAxisSpacing: 12,
                      crossAxisSpacing: 10,
                      childAspectRatio: 0.78,
                    ),
                    itemCount: _items.length,
                    itemBuilder: (context, i) {
                      final v = _items[i];
                      return InkWell(
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => VideoPlayerPage(
                              id: '${v['id']}',
                              title: '${v['title'] ?? ''}',
                            ),
                          ),
                        ),
                        borderRadius: BorderRadius.circular(AppStyle.cardRadius),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: CoverImage(
                                url: _photo(v),
                                borderRadius: BorderRadius.circular(
                                  AppStyle.cardRadius,
                                ),
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
    );
  }
}

/// 视频播放页。
class VideoPlayerPage extends StatefulWidget {
  final String id;
  final String title;
  const VideoPlayerPage({super.key, required this.id, required this.title});

  @override
  State<VideoPlayerPage> createState() => _VideoPlayerPageState();
}

class _VideoPlayerPageState extends State<VideoPlayerPage> {
  VideoPlayerController? _controller;
  bool _loading = true;
  String? _error;
  String? _src;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final info = await JmService.instance.fetchVideoInfo(widget.id);
    if (!mounted) return;
    final video = info?['video'];
    if (video is Map) {
      _src = '${video['video_src'] ?? ''}';
    }
    if (_src == null || _src!.isEmpty) {
      setState(() {
        _loading = false;
        _error = L.t('noPlayUrl');
      });
      return;
    }
    final c = VideoPlayerController.networkUrl(Uri.parse(_src!));
    _controller = c;
    try {
      await c.initialize();
      await c.play();
      if (!mounted) return;
      setState(() => _loading = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = L.tp('playFailedE', {'e': '$e'});
      });
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(widget.title, maxLines: 1),
      ),
      body: Center(
        child: _loading
            ? const CircularProgressIndicator()
            : _error != null
                ? Text(_error!, style: const TextStyle(color: Colors.white70))
                : _controller == null
                    ?  Text(
                        L.t('noVideoSource'),
                        style: TextStyle(color: Colors.white70),
                      )
                    : Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          AspectRatio(
                            aspectRatio: _controller!.value.aspectRatio == 0
                                ? 16 / 9
                                : _controller!.value.aspectRatio,
                            child: VideoPlayer(_controller!),
                          ),
                          const SizedBox(height: 12),
                          VideoProgressIndicator(
                            _controller!,
                            allowScrubbing: true,
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                          ),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              IconButton(
                                icon: const Icon(
                                  Icons.replay_10,
                                  color: Colors.white,
                                ),
                                onPressed: () => _controller!.seekTo(
                                  _controller!.value.position -
                                      const Duration(seconds: 10),
                                ),
                              ),
                              IconButton(
                                iconSize: 42,
                                icon: Icon(
                                  _controller!.value.isPlaying
                                      ? Icons.pause_circle_filled
                                      : Icons.play_circle_filled,
                                  color: Colors.white,
                                ),
                                onPressed: () {
                                  setState(() {
                                    _controller!.value.isPlaying
                                        ? _controller!.pause()
                                        : _controller!.play();
                                  });
                                },
                              ),
                              IconButton(
                                icon: const Icon(
                                  Icons.forward_10,
                                  color: Colors.white,
                                ),
                                onPressed: () => _controller!.seekTo(
                                  _controller!.value.position +
                                      const Duration(seconds: 10),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
      ),
    );
  }
}
