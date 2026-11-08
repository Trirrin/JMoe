import 'package:flutter/material.dart';

import '../core/app_theme.dart';
import '../core/jm_service.dart';
import '../widgets/common_widgets.dart';
import '../core/l10n.dart';
import 'novel_pages.dart';

/// 小说列表。
///
/// 搜索入口已移除：全站统一用发现页的搜索（切到「小说」板块即可）。
/// 板块内再放一个搜索框只会让用户分不清该用哪个。
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
                    // 空态也要可下拉：用 ListView 包一层保证有滚动体
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
                                // 与详情页封面一致，实现平滑转场
                                tag: 'novel_${n['id']}',
                                // 飞行层独立构造：不依赖卡片实例，
                                // 卡片滚出缓存区也能飞完
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

/// 小说详情 / 章节。
