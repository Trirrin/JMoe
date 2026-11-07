import 'package:flutter/material.dart';

import '../core/app_theme.dart';
import '../core/jm_service.dart';
import '../core/models.dart';
import '../widgets/common_widgets.dart';
import 'unified_detail_page.dart';
import 'unified_home_page.dart';
import '../core/l10n.dart';

/// 每週必看：按週分类浏览。
class WeekPage extends StatefulWidget {
  const WeekPage({super.key});

  @override
  State<WeekPage> createState() => _WeekPageState();
}

class _WeekPageState extends State<WeekPage> {
  final _service = JmService.instance;
  final _weeks = <WeekItem>[];
  final _items = <Comic>[];
  bool _loading = true;
  String? _selectedId;
  int _page = 1;
  bool _hasMore = true;

  static final _types = [
    ('all', 'all'),
    ('manga', 'manga'),
    ('hanime', 'hanime'),
  ];
  String _type = 'all';

  @override
  void initState() {
    super.initState();
    _loadWeeks();
  }

  Future<void> _loadWeeks() async {
    final weeks = await _service.fetchWeek();
    if (!mounted) return;
    setState(() {
      _weeks
        ..clear()
        ..addAll(weeks.map((w) => WeekItem(w.id, w.title, w.time)));
      _loading = false;
      if (_weeks.isNotEmpty) {
        _selectedId = _weeks.first.id;
      }
    });
    if (_selectedId != null) _loadItems(reset: true);
  }

  Future<void> _loadItems({bool reset = false}) async {
    if (_selectedId == null) return;
    if (reset) {
      setState(() {
        _items.clear();
        _page = 1;
        _hasMore = true;
      });
    }
    if (!_hasMore && !reset) return;
    final (list, total) = await _service.fetchWeekFilter(
      _selectedId!,
      _type,
      _page,
    );
    if (!mounted) return;
    setState(() {
      _items.addAll(list);
      _page++;
      _hasMore = list.isNotEmpty && (total == 0 || _items.length < total);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(L.t('weeklyMustSee')),
        actions: [
          PopupMenuButton<String>(
            initialValue: _type,
            onSelected: (v) {
              setState(() => _type = v);
              _loadItems(reset: true);
            },
            itemBuilder: (_) => _types
                .map(
                  (t) => PopupMenuItem(
                    value: t.$1,
                    child: Text(L.t(t.$2)),
                  ),
                )
                .toList(),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                SizedBox(
                  height: 44,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppStyle.pagePadding,
                      vertical: 4,
                    ),
                    itemCount: _weeks.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 8),
                    itemBuilder: (context, i) {
                      final w = _weeks[i];
                      final active = w.id == _selectedId;
                      return ChoiceChip(
                        label: Text(
                          w.time.isEmpty
                              ? L.tp('weekN', {'n': w.id})
                              : w.time,
                          style: const TextStyle(fontSize: 11),
                        ),
                        selected: active,
                        onSelected: (_) {
                          setState(() => _selectedId = w.id);
                          _loadItems(reset: true);
                        },
                      );
                    },
                  ),
                ),
                Expanded(
                  child: NotificationListener<ScrollNotification>(
                    onNotification: (n) {
                      if (n.metrics.pixels > n.metrics.maxScrollExtent - 400) {
                        _loadItems();
                      }
                      return false;
                    },
                    child: _items.isEmpty
                        ? EmptyView(message: L.t('empty'))
                        : GridView.builder(
                            padding: const EdgeInsets.all(AppStyle.pagePadding),
                            gridDelegate:
                                const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 3,
                              mainAxisSpacing: 12,
                              crossAxisSpacing: 10,
                              childAspectRatio: 0.55,
                            ),
                            itemCount: _items.length,
                            itemBuilder: (context, i) {
                              final c = _items[i];
                              return ComicCard(
                                title: c.name,
                                subtitle: c.author,
                                cover: _service.coverUrl(c),
                                onTap: () => Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) => UnifiedDetailPage(source: SourceRegistry.current, comic: c),
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

class WeekItem {
  final String id;
  final String title;
  final String time;
  WeekItem(this.id, this.title, this.time);
}
