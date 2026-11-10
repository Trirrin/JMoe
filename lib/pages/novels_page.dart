import 'package:flutter/material.dart';

import '../core/app_theme.dart';
import '../core/jm_service.dart';
import '../widgets/common_widgets.dart';
import '../core/l10n.dart';
import 'novel_pages.dart';

class NovelsPage extends StatefulWidget {
  const NovelsPage({super.key});

  @override
  State<NovelsPage> createState() => _NovelsPageState();
}

class _NovelsPageState extends State<NovelsPage> {
  final _service = JmService.instance;
  final _items = <Map<String, dynamic>>[];
  bool _loading = true;
  int _page = 1;
  String _order = 'mr';

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
    try {
      final list = await _service.fetchNovels(order: _order, page: _page);
      if (!mounted) return;
      setState(() {
        _items.addAll(list);
        _page++;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(L.t('novels')),
        actions: [
          PopupMenuButton<String>(
            initialValue: _order,
            onSelected: (v) {
              setState(() => _order = v);
              _load(reset: true);
            },
            itemBuilder: (_) =>  [
              PopupMenuItem(value: 'mr', child: Text(L.t('sortLatest'))),
              PopupMenuItem(value: 'mv', child: Text(L.t('sortPopular'))),
            ],
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => _load(reset: true),
        edgeOffset: MediaQuery.of(context).padding.top,
        child: _loading && _items.isEmpty
            ? const Center(child: CircularProgressIndicator())
            : _items.isEmpty
                ? ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: [
                      SizedBox(
                        height: MediaQuery.of(context).size.height * 0.3,
                      ),
                      EmptyView(message: L.t('noNovels')),
                    ],
                  )
                : NotificationListener<ScrollNotification>(
                    onNotification: (n) {
                      if (n.metrics.pixels + 400 >
                          n.metrics.maxScrollExtent) {
                        _load();
                      }
                      return false;
                    },
                    child: ListView.separated(
                      padding: const EdgeInsets.all(AppStyle.pagePadding),
                      physics: const AlwaysScrollableScrollPhysics(),
                      itemCount: _items.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, i) {
                        final n = _items[i];
                        final image = '${n['image'] ?? ''}';
                        return Card(
                          child: ListTile(
                            leading: SizedBox(
                              width: 52,
                              height: 70,
                              child: Hero(
                                tag: 'novel_${n['id']}',
                                flightShuttleBuilder:
                                    (ctx, anim, dir, from, to) {
                                  final t = Curves.easeInOutCubic
                                      .transform(anim.value);
                                  final a = dir == HeroFlightDirection.push
                                      ? t
                                      : 1 - t;
                                  return ClipRRect(
                                    borderRadius:
                                        BorderRadius.circular(6 + 4 * a),
                                    child: CoverImage(
                                      url: image.isEmpty ? null : image,
                                    ),
                                  );
                                },
                                child: CoverImage(
                                  url: image.isEmpty ? null : image,
                                  borderRadius: BorderRadius.circular(6),
                                ),
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
                              '${n['author'] ?? ''} · ${n['last_chapter_title'] ?? ''}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 11),
                            ),
                            trailing: const Icon(
                              Icons.chevron_right,
                              size: 18,
                            ),
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
      ),
    );
  }
}
