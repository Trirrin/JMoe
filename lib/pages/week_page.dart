
import 'package:flutter/material.dart';

import '../core/app_theme.dart';
import '../core/jm_service.dart';
import '../core/models.dart';
import '../widgets/common_widgets.dart';
import '../widgets/detail_route.dart';
import 'unified_detail_page.dart';
import 'unified_home_page.dart';
import '../core/l10n.dart';

class WeekPage extends StatefulWidget {
  const WeekPage({super.key});

  @override
  State<WeekPage> createState() => _WeekPageState();
}

class _WeekPageState extends State<WeekPage> {
  final _service = JmService.instance;
  final _pageCtrl = PageController();
  final _chipCtrl = ScrollController();

  final _weeks = <WeekItem>[];

  final Map<String, List<Comic>> _cache = {};

  final Set<String> _requested = {};

  final Set<String> _loading = {};

  final Map<String, String> _errors = {};

  int _index = 0;
  bool _bootLoading = true;
  String? _bootError;

  static const _types = [
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

  @override
  void dispose() {
    _pageCtrl.dispose();
    _chipCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadWeeks() async {
    setState(() {
      _bootLoading = true;
      _bootError = null;
    });
    try {
      final weeks = await _service.fetchWeek();
      if (!mounted) return;
      setState(() {
        _weeks
          ..clear()
          ..addAll(weeks.map((w) => WeekItem(w.id, w.title, w.time)));
        _bootLoading = false;
      });
      if (_weeks.isNotEmpty) {
        _ensureLoaded(0);
        _ensureLoaded(1);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _bootLoading = false;
        _bootError = '$e';
      });
    }
  }

  Future<void> _ensureLoaded(int i) async {
    if (i < 0 || i >= _weeks.length) return;
    final id = _weeks[i].id;
    if (_requested.contains(id) || _loading.contains(id)) return;
    _loading.add(id);
    if (mounted) setState(() {});
    try {
      final (list, _) = await _service.fetchWeekFilter(id, _type, 1);
      if (!mounted) return;
      setState(() {
        _cache[id] = list;
        _requested.add(id);
        _loading.remove(id);
        _errors.remove(id);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading.remove(id);
        _errors[id] = '$e';
      });
    }
  }

  void _jumpToWeek(int i) {
    if (i < 0 || i >= _weeks.length) return;
    if (i == _index && _pageCtrl.hasClients) {
      _scrollChipIntoView(i);
      return;
    }
    _pageCtrl.animateToPage(
      i,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
  }

  final Map<int, GlobalKey> _chipKeys = {};

  void _scrollChipIntoView(int i) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final key = _chipKeys[i];
      final ctx = key?.currentContext;
      if (ctx == null || !_chipCtrl.hasClients) return;
      final box = ctx.findRenderObject() as RenderBox?;
      if (box == null) return;
      final pos = _chipCtrl.position;
      final offset = (box.localToGlobal(Offset.zero) -
              (context.findRenderObject() as RenderBox)
                  .localToGlobal(Offset.zero))
          .dx;
      final w = box.size.width;
      final viewport = pos.viewportDimension;
      final left = offset;
      final right = offset + w;
      const pad = 8.0;
      if (left >= pad && right <= viewport - pad) return;
      final target = (pos.pixels + left - (viewport - w) / 2)
          .clamp(0.0, pos.maxScrollExtent);
      _chipCtrl.animateTo(
        target,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (_bootLoading) {
      return Scaffold(
        appBar: AppBar(title: Text(L.t('weeklyMustSee'))),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    if (_bootError != null || _weeks.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: Text(L.t('weeklyMustSee'))),
        body: EmptyView(
          message: '${L.t('loadFailed')}\n${_bootError ?? ''}',
          onRetry: _loadWeeks,
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(L.t('weeklyMustSee')),
        actions: [
          PopupMenuButton<String>(
            initialValue: _type,
            tooltip: L.t('sort'),
            onSelected: (v) {
              if (v == _type) return;
              setState(() {
                _type = v;
                _cache.clear();
                _requested.clear();
                _errors.clear();
              });
              _ensureLoaded(_index);
            },
            itemBuilder: (_) => _types
                .map(
                  (t) => PopupMenuItem(value: t.$1, child: Text(L.t(t.$2))),
                )
                .toList(),
          ),
        ],
      ),
      body: Column(
        children: [
          SizedBox(
            height: 46,
            child: ListView.separated(
              controller: _chipCtrl,
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(
                horizontal: AppStyle.pagePadding,
                vertical: 4,
              ),
              itemCount: _weeks.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, i) {
                final w = _weeks[i];
                final active = i == _index;
                return ChoiceChip(
                  key: _chipKeys.putIfAbsent(i, () => GlobalKey()),
                  label: Text(
                    w.time.isEmpty ? L.tp('weekN', {'n': w.id}) : w.time,
                    style: const TextStyle(fontSize: 11),
                  ),
                  selected: active,
                  onSelected: (_) => _jumpToWeek(i),
                );
              },
            ),
          ),
          Expanded(
            child: PageView.builder(
              controller: _pageCtrl,
              itemCount: _weeks.length,
              onPageChanged: (i) {
                setState(() => _index = i);
                _ensureLoaded(i);
                _ensureLoaded(i + 1);
                _ensureLoaded(i - 1);
                _scrollChipIntoView(i);
              },
              itemBuilder: (context, i) => _buildWeekPage(theme, i),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWeekPage(ThemeData theme, int i) {
    final id = _weeks[i].id;
    final err = _errors[id];
    final items = _cache[id];

    if (items == null && err == null) {
      return _buildSkeleton(theme);
    }
    if (err != null) {
      return EmptyView(
        message: '${L.t('loadFailed')}\n$err',
        onRetry: () {
          _requested.remove(id);
          _ensureLoaded(i);
        },
      );
    }
    if (items == null || items.isEmpty) {
      return EmptyView(message: L.t('empty'));
    }
    return LayoutBuilder(
      builder: (context, box) {
        const cols = 3;
        const gap = 10.0;
        final cardW = (box.maxWidth - gap * (cols - 1) - 24) / cols;
        return SingleChildScrollView(
          padding: const EdgeInsets.all(AppStyle.pagePadding),
          child: Wrap(
            spacing: gap,
            runSpacing: 12,
            children: [
              for (final c in items)
                SizedBox(
                  width: cardW,
                  child: ComicCard(
                    title: c.name,
                    subtitle: c.author,
                    cover: _service.coverUrl(c),
                    onTap: () => Navigator.of(context).push(
                      detailRoute(
                        builder: (_) => UnifiedDetailPage(
                          source: SourceRegistry.current,
                          comic: c,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSkeleton(ThemeData theme) {
    return LayoutBuilder(
      builder: (context, box) {
        const cols = 3;
        const gap = 10.0;
        final cardW = (box.maxWidth - gap * (cols - 1) - 24) / cols;
        return SingleChildScrollView(
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.all(AppStyle.pagePadding),
          child: Wrap(
            spacing: gap,
            runSpacing: 12,
            children: [
              for (var k = 0; k < 9; k++)
                SizedBox(
                  width: cardW,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AspectRatio(
                        aspectRatio: 3 / 4,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(
                            AppStyle.cardRadius,
                          ),
                          child: const ShimmerBox(),
                        ),
                      ),
                      const SizedBox(height: 6),
                      const ShimmerBox(height: 13, radius: 4),
                      const SizedBox(height: 4),
                      const FractionallySizedBox(
                        widthFactor: 0.6,
                        child: ShimmerBox(height: 11, radius: 4),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class WeekItem {
  final String id;
  final String title;
  final String time;
  WeekItem(this.id, this.title, this.time);
}
