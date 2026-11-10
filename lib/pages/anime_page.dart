import 'package:flutter/material.dart';

import '../core/app_theme.dart';
import '../core/jm_service.dart';
import '../core/l10n.dart';
import '../widgets/common_widgets.dart';
import 'anime_player_page.dart';

class AnimePage extends StatefulWidget {
  const AnimePage({super.key});

  @override
  State<AnimePage> createState() => _AnimePageState();
}

class _AnimePageState extends State<AnimePage> {
  final _service = JmService.instance;
  final _items = <Map<String, dynamic>>[];
  final _scroll = ScrollController();

  bool _loading = true;
  bool _hasMore = true;
  int _page = 1;
  int _total = 0;
  String? _error;
  String _type = 'hanime';

  static const _types = <(String, String)>[
    ('hanime', 'animeTypeHanime'),
    ('movie', 'animeTypeMovie'),
  ];

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _load(reset: true);
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 600) {
      _load();
    }
  }

  Future<void> _load({bool reset = false}) async {
    if (reset) {
      setState(() {
        _items.clear();
        _page = 1;
        _hasMore = true;
        _loading = true;
        _error = null;
      });
    }
    if (!_hasMore && !reset) return;
    try {
      final r = await _service.fetchVideosPaged(
        page: _page,
        query: null,
        videoType: _type,
      );
      if (!mounted) return;
      setState(() {
        _items.addAll(r.$1);
        _total = r.$3;
        _page++;
        _loading = false;
        _hasMore = r.$1.isNotEmpty;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
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
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(L.t('anime')),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(42),
          child: SizedBox(
            height: 42,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
              children: _types.map((t) {
                final active = _type == t.$1;
                return Padding(
                  padding: const EdgeInsets.only(right: 8, bottom: 2),
                  child: ChoiceChip(
                    label: Text(
                      L.t(t.$2),
                      style: const TextStyle(fontSize: 12),
                    ),
                    selected: active,
                    onSelected: (_) {
                      if (active) return;
                      setState(() => _type = t.$1);
                      _load(reset: true);
                    },
                  ),
                );
              }).toList(),
            ),
          ),
        ),
        actions: [
          if (_total > 0)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Center(
                child: Text(
                  '${_items.length}/$_total',
                  style: TextStyle(
                    fontSize: 11,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
        ],
      ),
      body: _loading && _items.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : _error != null && _items.isEmpty
              ? EmptyView(
                  message: '${L.t('loadFailed')}\n$_error',
                  onRetry: () => _load(reset: true),
                )
              : _items.isEmpty
                  ? EmptyView(
                      message: L.t('noAnime'),
                      icon: Icons.movie_outlined,
                    )
                  : GridView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.all(AppStyle.pagePadding),
                      cacheExtent: 1200,
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 2,
                        mainAxisSpacing: 12,
                        crossAxisSpacing: 10,
                        childAspectRatio: 0.74,
                      ),
                      itemCount: _items.length + (_hasMore ? 2 : 0),
                      itemBuilder: (context, i) {
                        if (i >= _items.length) return const ShimmerBox();
                        final v = _items[i];
                        final tags = (v['tags'] as List?)
                                ?.take(2)
                                .map((e) => e.toString().trim())
                                .where((e) => e.isNotEmpty)
                                .join(' · ') ??
                            '';
                        return InkWell(
                          borderRadius:
                              BorderRadius.circular(AppStyle.cardRadius),
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => AnimePlayerPage(
                                id: '${v['id']}',
                                title: '${v['title'] ?? ''}',
                                videoType: _type,
                                playlist: _items
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
                                      url: _photo(v),
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
                              if (tags.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(top: 2),
                                  child: Text(
                                    tags,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 10,
                                      color:
                                          theme.colorScheme.onSurfaceVariant,
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
}
