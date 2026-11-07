import 'dart:async';
import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/app_theme.dart';
import '../core/jm_service.dart';
import '../core/sync_service.dart';
import '../core/models.dart';
import '../widgets/common_widgets.dart';
import 'unified_detail_page.dart';
import 'login_page.dart';
import 'downloads_page.dart';
import 'unified_home_page.dart';
import '../core/l10n.dart';

/// 「书架」：收藏（云端/本地）+ 历史 + 入口集合。
class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage>
    with AutomaticKeepAliveClientMixin {
  final _service = JmService.instance;
  final _items = <Comic>[];
  bool _loading = true;

  /// 多选模式（长按进入）
  bool _selectionMode = false;
  final Set<String> _selectedIds = {};

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    AppState.instance.addListener(_onStateChanged);
    _load();
  }

  @override
  void dispose() {
    AppState.instance.removeListener(_onStateChanged);
    super.dispose();
  }

  void _onStateChanged() {
    if (mounted) setState(() {});
  }


  /// 批量移除选中的收藏。
  Future<void> _removeSelected() async {
    final ids = Set<String>.from(_selectedIds);
    setState(() {
      _items.removeWhere((e) => ids.contains('${e.id}'));
      _selectionMode = false;
      _selectedIds.clear();
    });
    for (final id in ids) {
      try {
        await JmService.instance.toggleFavorite(id);
      } catch (_) {}
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(L.tp('removedN', {'n': ids.length})),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    if (!AppState.instance.loggedIn) {
      // 未登录：只展示本地收藏（_buildLocalFavorites 直接读 AppState）
      if (!mounted) return;
      setState(() => _loading = false);
      return;
    }
    // 已登录：云端对账后拉取，失败则回落到本地
    try {
      await SyncService.instance.syncFavorites();
    } catch (_) {}
    try {
      final (list, total) = await _service.fetchFavorites(page: 1);
      if (!mounted) return;
      setState(() {
        _items
          ..clear()
          ..addAll(list);
        // 合并本地收藏里「云端没有」的条目，
        // 这样登录后也能看到本地新增的收藏（不再被云端列表覆盖）
        final cloudIds = _items.map((e) => '${e.id}').toSet();
        for (final fav in AppState.instance.localFavorites) {
          final id = '${fav['id'] ?? ''}';
          if (id.isEmpty || cloudIds.contains(id)) continue;
          _items.add(
            Comic(
              id: id,
              name: '${fav['name'] ?? ''}',
              author: '${fav['author'] ?? ''}',
              image: '${fav['cover'] ?? ''}',
              source: '${fav['source'] ?? 'jm'}',
              updateAt: fav['update_at'] is int
                  ? fav['update_at'] as int
                  : null,
            ),
          );
        }
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    final state = AppState.instance;
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          onRefresh: _load,
          // 扣除状态栏高度：刷新图标从状态栏下方出现
          edgeOffset: MediaQuery.of(context).padding.top,
          child: CustomScrollView(
            key: const PageStorageKey('library_scroll'),
            // 始终可滚动 + 回弹：保证下拉刷新能完整收回
            physics: const BouncingScrollPhysics(
              parent: AlwaysScrollableScrollPhysics(),
            ),
            slivers: [
              SliverAppBar(
                pinned: true,
                backgroundColor: theme.colorScheme.surface,
                title: Text(L.t('tabShelf')),
                actions: [
                  if (_selectionMode) ...[
                    IconButton(
                      tooltip: L.t('cancel'),
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () {
                        setState(() {
                          _selectionMode = false;
                          _selectedIds.clear();
                        });
                      },
                    ),
                    IconButton(
                      tooltip: L.t('selectAll'),
                      icon: const Icon(Icons.select_all_rounded),
                      onPressed: () {
                        setState(() {
                          _selectedIds
                            ..clear()
                            ..addAll(
                              _items.map((e) => '${e.id}'),
                            );
                        });
                      },
                    ),
                    IconButton(
                      tooltip: L.t('delete'),
                      icon: Icon(
                        Icons.delete_outline,
                        color: theme.colorScheme.error,
                      ),
                      onPressed: _selectedIds.isEmpty
                          ? null
                          : _removeSelected,
                    ),
                  ] else
                    IconButton(
                      tooltip: L.t('multiSelect'),
                      icon: const Icon(Icons.checklist_rounded),
                      onPressed: () =>
                          setState(() => _selectionMode = true),
                    ),
                  const SizedBox(width: 4),
                ],
              ),
              SliverToBoxAdapter(child: _buildEntryGrid(theme, state)),
              SliverToBoxAdapter(
                child: SectionHeader(
                  title: state.loggedIn ? L.t('cloudFavorites') : L.t('localFavorites'),
                  trailing: state.loggedIn
                      ? null
                      : TextButton(
                          onPressed: () async {
                            await Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => const LoginPage(),
                              ),
                            );
                            _load();
                          },
                          child: Text(L.t('loginSync')),
                        ),
                ),
              ),
              if (_loading && _items.isEmpty && state.localFavorites.isEmpty)
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.all(40),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                )
              else if (!state.loggedIn)
                SliverToBoxAdapter(
                  child: _buildLocalFavorites(theme, state),
                )
              else if (_items.isEmpty)
                 SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.all(40),
                    child: EmptyView(
                      message: L.t('noFavorites'),
                      icon: Icons.favorite_border,
                    ),
                  ),
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.all(AppStyle.pagePadding),
                  sliver: SliverGrid(
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 3,
                      mainAxisSpacing: 12,
                      crossAxisSpacing: 10,
                      childAspectRatio: 0.55,
                    ),
                    delegate: SliverChildBuilderDelegate(
                      (context, i) {
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
                      childCount: _items.length,
                    ),
                  ),
                ),
              const SliverToBoxAdapter(child: SizedBox(height: 24)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEntryGrid(ThemeData theme, AppState state) {
    final entries = <_Entry>[
      _Entry(
        icon: Icons.download_outlined,
        label: L.t('myDownloads'),
        color: const Color(0xFF009688),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const DownloadsPage()),
        ),
      ),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Row(
        children: entries
            .map(
              (e) => Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: InkWell(
                    onTap: e.onTap,
                    borderRadius: BorderRadius.circular(14),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      decoration: BoxDecoration(
                        color: e.color.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Column(
                        children: [
                          Icon(e.icon, color: e.color, size: 22),
                          const SizedBox(height: 6),
                          Text(
                            e.label,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: e.color,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            )
            .toList(),
      ),
    );
  }

  Widget _buildLocalFavorites(ThemeData theme, AppState state) {
    final list = state.localFavorites;
    if (list.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(40),
        child: EmptyView(
          message: L.t('emptyFavorites'),
          icon: Icons.favorite_border,
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.all(AppStyle.pagePadding),
      child: GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          mainAxisSpacing: 12,
          crossAxisSpacing: 10,
          childAspectRatio: 0.55,
        ),
        itemCount: list.length,
        itemBuilder: (context, i) {
          final m = list[i];
          final c = Comic(
            id: '${m['id']}',
            name: '${m['name']}',
            author: '${m['author'] ?? ''}',
            image: m['cover'] as String?,
            updateAt: m['update_at'] is num ? (m['update_at'] as num).toInt() : null,
            source: '${m['source'] ?? 'jm'}',
          );
          return ComicCard(
            title: c.name,
            subtitle: c.author,
            cover: m['cover'] as String?,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => UnifiedDetailPage(source: SourceRegistry.current, comic: c)),
            ),
          );
        },
      ),
    );
  }
}

class _Entry {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  _Entry({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });
}
