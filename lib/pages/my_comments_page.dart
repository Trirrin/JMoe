import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/app_theme.dart';
import '../core/jm_service.dart';
import '../core/l10n.dart';
import '../core/models.dart';
import '../widgets/detail_route.dart';
import '../widgets/common_widgets.dart';
import 'unified_detail_page.dart';
import 'unified_home_page.dart';

class MyCommentsPage extends StatefulWidget {
  const MyCommentsPage({super.key});

  @override
  State<MyCommentsPage> createState() => _MyCommentsPageState();
}

class _MyCommentsPageState extends State<MyCommentsPage> {
  final _service = JmService.instance;
  final _scroll = ScrollController();
  final _items = <Map<String, dynamic>>[];

  int _page = 1;
  int _total = 0;
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  String? _error;

  final Set<String> _deleting = {};

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

  String get _uid => '${AppState.instance.member?['uid'] ?? ''}';

  void _onScroll() {
    if (!_scroll.hasClients) return;
    if (_scroll.position.pixels <
        _scroll.position.maxScrollExtent - 400) {
      return;
    }
    if (_hasMore && !_loadingMore) _load(reset: false);
  }

  Future<void> _load({required bool reset}) async {
    if (reset) {
      setState(() {
        _loading = true;
        _error = null;
        _items.clear();
        _page = 1;
        _hasMore = true;
        _total = 0;
      });
    } else {
      if (_loadingMore || !_hasMore) return;
      setState(() => _loadingMore = true);
    }
    if (_uid.isEmpty) {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadingMore = false;
          _error = L.t('notLoggedIn');
        });
      }
      return;
    }
    try {
      final (list, total) = await _service.fetchUserComments(
        uid: _uid,
        page: _page,
      );
      if (!mounted) return;
      setState(() {
        _items.addAll(list);
        _total = total;
        _page++;
        _hasMore = list.isNotEmpty &&
            list.length >= 10 &&
            (total <= 0 || _items.length < total);
        _loading = false;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
        _loadingMore = false;
      });
    }
  }

  Future<void> _delete(Map<String, dynamic> c) async {
    final cid = '${c['CID'] ?? c['cid'] ?? ''}';
    if (cid.isEmpty || _deleting.contains(cid)) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(L.t('delete')),
        content: Text(L.t('deleteCommentConfirm')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(L.t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(L.t('delete')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _deleting.add(cid));
    final r = await _service.deleteComment(cid);
    if (!mounted) return;
    setState(() => _deleting.remove(cid));
    if (r['code'] == 200) {
      setState(() {
        _items.removeWhere((e) => '${e['CID'] ?? e['cid']}' == cid);
        if (_total > 0) _total--;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(L.t('commentDeleted')),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${r['errorMsg'] ?? L.t('operationFailed')}'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  void _openComic(Map<String, dynamic> c) {
    final aid = '${c['AID'] ?? c['aid'] ?? ''}';
    if (aid.isEmpty || aid == 'null' || aid == '0') return;
    Navigator.of(context).push(
      detailRoute(builder: (_) => UnifiedDetailPage(
          source: SourceRegistry.current,
          comic: Comic(id: aid, name: '', author: '', source: 'jm'),
        ),
      ),
    );
  }

  String _plain(String html) {
    var s = html;
    s = s.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');
    s = s.replaceAll(
      RegExp(r'</(?:div|p|li)>', caseSensitive: false),
      '\n',
    );
    s = s.replaceAll(RegExp(r'<[^>]*>'), '');
    s = s
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"');
    return s.trim();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(L.t('myComments')),
        actions: [
          if (_total > 0)
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Center(
                child: Text(
                  '${_items.length}/$_total',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => _load(reset: true),
        edgeOffset: MediaQuery.of(context).padding.top,
        child: _buildBody(theme),
      ),
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final err = _error;
    if (err != null && _items.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          SizedBox(height: MediaQuery.of(context).size.height * 0.25),
          EmptyView(
            message: err,
            icon: Icons.forum_outlined,
            onRetry: () => _load(reset: true),
          ),
        ],
      );
    }
    if (_items.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          SizedBox(height: MediaQuery.of(context).size.height * 0.25),
          EmptyView(
            message: L.t('noCommentsMine'),
            icon: Icons.forum_outlined,
          ),
        ],
      );
    }
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.all(AppStyle.pagePadding),
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: _items.length + 1,
      itemBuilder: (context, i) {
        if (i >= _items.length) {
          return Padding(
            padding: EdgeInsets.only(
              top: 12,
              bottom: MediaQuery.of(context).padding.bottom + 12,
            ),
            child: Center(
              child: _loadingMore
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : _hasMore
                      ? const SizedBox.shrink()
                      : Text(
                          L.t('bottomReached'),
                          style: TextStyle(
                            fontSize: 11,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
            ),
          );
        }
        return _commentTile(theme, _items[i]);
      },
    );
  }

  Widget _commentTile(ThemeData theme, Map<String, dynamic> c) {
    final scheme = theme.colorScheme;
    final cid = '${c['CID'] ?? c['cid'] ?? ''}';
    final aid = '${c['AID'] ?? c['aid'] ?? ''}';
    final hasComic = aid.isNotEmpty && aid != 'null' && aid != '0';
    final rawName = '${c['name'] ?? ''}';
    final text = _plain('${c['content'] ?? ''}');
    final likes = int.tryParse('${c['likes'] ?? 0}') ?? 0;
    final time = '${c['addtime'] ?? ''}';
    final deleting = _deleting.contains(cid);

    return Card(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      margin: const EdgeInsets.only(bottom: 10),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: hasComic ? () => _openComic(c) : null,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    hasComic
                        ? Icons.menu_book_outlined
                        : Icons.chat_bubble_outline,
                    size: 14,
                    color: scheme.primary,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      hasComic
                          ? (rawName.isEmpty ? 'JM$aid' : rawName)
                          : L.t('chatHall'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color: scheme.primary,
                      ),
                    ),
                  ),
                  if (time.isNotEmpty)
                    Text(
                      time,
                      style: TextStyle(
                        fontSize: 10,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  SizedBox(
                    width: 32,
                    height: 32,
                    child: deleting
                        ? const Padding(
                            padding: EdgeInsets.all(9),
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : IconButton(
                            tooltip: L.t('delete'),
                            padding: EdgeInsets.zero,
                            iconSize: 16,
                            icon: Icon(
                              Icons.delete_outline_rounded,
                              color: scheme.error,
                            ),
                            onPressed: () => _delete(c),
                          ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                text.isEmpty ? '—' : text,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12.5, height: 1.5),
              ),
              if (likes > 0) ...[
                const SizedBox(height: 6),
                Row(
                  children: [
                    const Icon(
                      Icons.favorite_rounded,
                      size: 11,
                      color: Color(0xFFFF6B81),
                    ),
                    const SizedBox(width: 3),
                    Text(
                      '$likes',
                      style: TextStyle(
                        fontSize: 10,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
