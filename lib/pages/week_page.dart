
import 'package:flutter/material.dart';

import '../core/app_theme.dart';
import '../core/jm_service.dart';
import '../core/models.dart';
import '../widgets/common_widgets.dart';
import '../widgets/detail_route.dart';
import 'unified_detail_page.dart';
import 'unified_home_page.dart';
import '../core/l10n.dart';

/// 每週必看：按週分类浏览。
///
/// # 交互设计
///
///  * 每一期是一个**整页**，切换时走 `PageView` 的滑动动画
///    （之前是「点了直接换内容」，没有过渡，观感很生硬）
///  * 加载完成前用**灰色骨架**占位，且**可以继续滑动**
///    —— 不必等这一期加载完才能切下一期
///  * 顶部周次横条跟随当前页高亮，并按需滚入视野
///    （哪怕只露出一点也要滚到完整可见）
///  * 每期的数据按 id 缓存在内存里，来回切不再重复请求
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

  /// 每期已加载的数据（id → 列表）。缓存避免来回切重复请求。
  final Map<String, List<Comic>> _cache = {};

  /// 每期是否已请求过（区分「还没请求」与「请求了但为空」）
  final Set<String> _requested = {};

  /// 每期是否正在加载
  final Set<String> _loading = {};

  /// 每期的错误信息
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
        // 首屏 + 预取相邻一期，滑动时不用等
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

  /// 按需加载某一期（幂等）。
  Future<void> _ensureLoaded(int i) async {
    if (i < 0 || i >= _weeks.length) return;
    final id = _weeks[i].id;
    if (_requested.contains(id) || _loading.contains(id)) return;
    _loading.add(id);
    if (mounted) setState(() {});
    try {
      // 先取第一页；翻到底再续（这里简化：一次取 60 条，够一屏浏览）
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

  /// 点击周次横条：翻到对应页（走 PageView 动画）。
  void _jumpToWeek(int i) {
    if (i < 0 || i >= _weeks.length) return;
    if (i == _index && _pageCtrl.hasClients) {
      // 已在该页，只需确保 chip 可见
      _scrollChipIntoView(i);
      return;
    }
    _pageCtrl.animateToPage(
      i,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
  }

  /// 把第 [i] 个周次 chip 滚到**完整可见**。
  ///
  /// 之前用固定 chipW=78 估算位置，实际 chip 宽度随文字变化，
  /// 于是「部分在屏幕外」时算出来仍算「可见」而不滚动。
  /// 现在用 GlobalKey 读真实位置，只要不是完整可见就滚。
  final Map<int, GlobalKey> _chipKeys = {};

  void _scrollChipIntoView(int i) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final key = _chipKeys[i];
      final ctx = key?.currentContext;
      if (ctx == null || !_chipCtrl.hasClients) return;
      final box = ctx.findRenderObject() as RenderBox?;
      if (box == null) return;
      final pos = _chipCtrl.position;
      // chip 相对视口的位置
      final offset = (box.localToGlobal(Offset.zero) -
              (context.findRenderObject() as RenderBox)
                  .localToGlobal(Offset.zero))
          .dx;
      final w = box.size.width;
      final viewport = pos.viewportDimension;
      final left = offset;
      final right = offset + w;
      // 完整可见 → 不动
      const pad = 8.0;
      if (left >= pad && right <= viewport - pad) return;
      // 需要滚动：让 chip 居中
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
                // 换类型后所有缓存失效
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
          // ---- 顶部周次横条 ----
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
          // ---- 每一期一整页（滑动切换）----
          Expanded(
            child: PageView.builder(
              controller: _pageCtrl,
              // 加载中也能继续滑：PageView 本身不阻塞
              itemCount: _weeks.length,
              onPageChanged: (i) {
                setState(() => _index = i);
                _ensureLoaded(i);
                // 预取前后各一期，滑动无缝
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

    // 加载中 / 还没请求 → 灰色骨架（可继续滑走）
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
    // 网格用 Wrap 与其它页面保持一致（卡片高度自然撑开、不裁切）
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

  /// 灰色骨架：与真实网格同尺寸，加载完成时位置不跳。
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
                      FractionallySizedBox(
                        widthFactor: 0.6,
                        child: const ShimmerBox(height: 11, radius: 4),
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
