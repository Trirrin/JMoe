import 'package:flutter/material.dart';

import '../core/app_theme.dart';
import '../core/models.dart';
import '../core/source.dart';
import '../widgets/detail_route.dart';
import '../widgets/common_widgets.dart';
import 'unified_detail_page.dart';
import '../core/l10n.dart';

/// 通用「查看更多」列表页（JM / EH 共用）。
///
/// 加载策略：**一次性连续加载**（边加载边显示），
/// 加载到 [pauseThreshold] 条时暂停，等用户滚动接近底部再继续，
/// 避免一次性拉取上千条造成卡顿与耗流量。
class MoreListPage extends StatefulWidget {
  final ComicSource source;
  final String moreKey;
  final String title;

  /// 单次暂停阈值：加载到这么多条就暂停
  final int pauseThreshold;

  const MoreListPage({
    super.key,
    required this.source,
    required this.moreKey,
    required this.title,
    this.pauseThreshold = 60,
  });

  @override
  State<MoreListPage> createState() => _MoreListPageState();
}

class _MoreListPageState extends State<MoreListPage> {
  final _scroll = ScrollController();
  final _items = <Comic>[];
  int _page = 1;
  int _total = -1;
  bool _fetching = false;
  bool _hasMore = true;
  bool _paused = false; // 达到阈值暂停
  String? _error;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _pump();
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final nearBottom = _scroll.position.pixels >=
        _scroll.position.maxScrollExtent - 700;
    if (nearBottom) {
      if (_paused) {
        setState(() => _paused = false);
      }
      _pump();
    }
  }

  /// 连续加载直到：到达阈值 / 没有更多 / 出错。
  Future<void> _pump() async {
    if (_fetching || _paused || !_hasMore) return;
    _fetching = true;
    try {
      while (_hasMore && mounted && !_paused) {
        final r = await widget.source.more(
          key: widget.moreKey,
          page: _page,
        );
        if (!mounted) return;
        if (r.items.isEmpty) {
          setState(() {
            _hasMore = false;
            _fetching = false;
            if (_total < 0) _total = _items.length;
          });
          return;
        }
        setState(() {
          _items.addAll(r.items);
          if (r.total > 0) _total = r.total;
          _page = r.nextPage;
          _hasMore = r.hasMore;
          _error = null;
          // 达到阈值 → 暂停，等用户滚到底再继续
          if (_items.length >= widget.pauseThreshold) {
            _paused = true;
          }
        });
        if (_paused || !_hasMore) break;
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _hasMore = false;
        });
      }
    } finally {
      if (mounted) setState(() => _fetching = false);
    }
  }

  Widget _buildCount(ThemeData theme) {
    final scheme = theme.colorScheme;
    if (_total < 0 && _items.isEmpty) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 11,
            height: 11,
            child: CircularProgressIndicator(
              strokeWidth: 1.6,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            L.t('loading'),
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
          ),
        ],
      );
    }
    final totalText = _total > 0 ? '/$_total' : '';
    return Text(
      '${_items.length}$totalText',
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w600,
        color: scheme.onSurfaceVariant,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(child: _buildCount(theme)),
          ),
        ],
      ),
      body: _items.isEmpty
          ? (_error != null
              ? EmptyView(
                  message: L.tp('loadFailedWith', {'e': '$_error'}),
                  onRetry: () {
                    setState(() {
                      _hasMore = true;
                      _error = null;
                      _page = 1;
                    });
                    _pump();
                  },
                )
              : const Center(child: CircularProgressIndicator()))
          : NotificationListener<ScrollNotification>(
              onNotification: (n) {
                if (n.metrics.pixels > n.metrics.maxScrollExtent - 700) {
                  if (_paused) setState(() => _paused = false);
                  _pump();
                }
                return false;
              },
              child: CustomScrollView(
                controller: _scroll,
                slivers: [
                  SliverPadding(
                    padding: const EdgeInsets.all(AppStyle.pagePadding),
                    sliver: SliverGrid(
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 3,
                        mainAxisSpacing: 12,
                        crossAxisSpacing: 10,
                        childAspectRatio: 0.54,
                      ),
                      delegate: SliverChildBuilderDelegate(
                        (context, i) {
                          final c = _items[i];
                          return ComicCard(
                            title: c.name,
                            subtitle: c.author,
                            cover: widget.source.coverOf(c),
                            heat: c.heat?.toString(),
                            category: c.category,
                            onTap: () => Navigator.of(context).push(
                              detailRoute(builder: (_) => UnifiedDetailPage(
                                  source: widget.source,
                                  comic: c,
                                ),
                              ),
                            ),
                          );
                        },
                        childCount: _items.length,
                      ),
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.only(
                        top: 8,
                        bottom: MediaQuery.of(context).padding.bottom + 24,
                      ),
                      child: Center(
                        child: _fetching && !_paused
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : _paused
                                ? Text(
                                    L.tp('scrollForMoreOf', {'done': _items.length, 'total': _total}),
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: theme
                                          .colorScheme.onSurfaceVariant,
                                    ),
                                  )
                                : _hasMore
                                    ? const SizedBox.shrink()
                                    : Text(
                                        L.t('bottomReached'),
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: theme
                                              .colorScheme.onSurfaceVariant,
                                        ),
                                      ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}
