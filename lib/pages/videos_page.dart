import 'package:flutter/material.dart';

import '../core/app_theme.dart';
import '../core/jm_service.dart';
import '../widgets/common_widgets.dart';
import 'anime_player_page.dart';
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
                        // 统一用完整的播放器（AnimePlayerPage）：
                        // 之前这里用的是 VideoPlayerPage —— 一个只有
                        // 「播放/暂停/±10s」的简化实现，手势、倍速、全屏、
                        // 断点续播、预缓存全都没有。同一份视频点进来
                        // 功能却不一样，用户自然会觉得「割裂」。
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => AnimePlayerPage(
                              id: '${v['id']}',
                              title: '${v['title'] ?? ''}',
                              videoType: '${v['video_type'] ?? 'hanime'}',
                              playlist: _items
                                  .map(
                                    (e) => {
                                      'id': '${e['id']}',
                                      'title': '${e['title'] ?? ''}',
                                    },
                                  )
                                  .toList(),
                              playlistIndex: i,
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
