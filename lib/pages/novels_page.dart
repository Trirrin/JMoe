import 'package:flutter/material.dart';

import '../core/app_theme.dart';
import '../core/jm_service.dart';
import '../widgets/common_widgets.dart';
import '../core/l10n.dart';
import 'novel_pages.dart';

/// 小说列表（含搜索）。
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
  final _search = TextEditingController();
  bool _searching = false;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _load(reset: true);
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load({bool reset = false}) async {
    if (reset) {
      setState(() {
        _items.clear();
        _page = 1;
        _loading = true;
        _searching = false;
      });
    }
    try {
      if (_searching) {
        final list = await _service.searchNovels(_query);
        if (!mounted) return;
        setState(() {
          _items
            ..clear()
            ..addAll(list);
          _loading = false;
        });
        return;
      }
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
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: TextField(
              controller: _search,
              decoration: InputDecoration(
                hintText: L.t('searchNovelHint'),
                prefixIcon: const Icon(Icons.search, size: 20),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.arrow_forward, size: 18),
                  onPressed: () {
                    final q = _search.text.trim();
                    setState(() {
                      _query = q;
                      _searching = q.isNotEmpty;
                    });
                    _load(reset: true);
                  },
                ),
              ),
            ),
          ),
          Expanded(
            child: _loading && _items.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : _items.isEmpty
                    ? EmptyView(message: L.t('noNovels'))
                    : NotificationListener<ScrollNotification>(
                        onNotification: (n) {
                          if (n.metrics.pixels >
                              n.metrics.maxScrollExtent - 400) {
                            _load();
                          }
                          return false;
                        },
                        child: ListView.separated(
                          padding: const EdgeInsets.all(AppStyle.pagePadding),
                          itemCount: _items.length,
                          separatorBuilder: (_, __) => const SizedBox(height: 8),
                          itemBuilder: (context, i) {
                            final n = _items[i];
                            final image = '${n['image'] ?? ''}';
                            return Card(
                              child: ListTile(
                                leading: SizedBox(
                                  width: 52,
                                  height: 70,
                                  child: CoverImage(
                                    url: image.isEmpty ? null : image,
                                    borderRadius: BorderRadius.circular(6),
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
        ],
      ),
    );
  }
}

/// 小说详情 / 章节。
