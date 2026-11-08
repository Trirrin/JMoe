import 'package:flutter/material.dart';

import '../core/app_theme.dart';
import '../core/collect_store.dart';
import '../core/jm_service.dart';
import '../core/l10n.dart';
import '../core/models.dart';
import '../widgets/common_widgets.dart';
import 'unified_detail_page.dart';
import 'unified_home_page.dart';

/// 关注 + 专辑页。
///
/// 两个标签页：
///  * **关注**：关注的作者 / 标签，点进去看该关键词下的所有作品
///  * **专辑**：可手工编辑关键词的作品合集（解决同作者多笔名/工作室）
class CollectPage extends StatefulWidget {
  const CollectPage({super.key, this.initialTab = 0});

  final int initialTab;

  @override
  State<CollectPage> createState() => _CollectPageState();
}

class _CollectPageState extends State<CollectPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tab =
      TabController(length: 2, vsync: this, initialIndex: widget.initialTab);

  @override
  void initState() {
    super.initState();
    CollectStore.instance.addListener(_onChanged);
  }

  @override
  void dispose() {
    CollectStore.instance.removeListener(_onChanged);
    _tab.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(L.t('followAndAlbums')),
        bottom: TabBar(
          controller: _tab,
          tabs: [
            Tab(text: L.t('following')),
            Tab(text: L.t('albums')),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tab,
        children: const [
          _FollowingTab(),
          _AlbumsTab(),
        ],
      ),
    );
  }
}

/// 关注列表：作者 / 标签，点击查看该关键词下的作品。
class _FollowingTab extends StatelessWidget {
  const _FollowingTab();

  Future<void> _open(
    BuildContext context,
    FollowItem f,
  ) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _KeywordResultsPage(
          kind: f.kind,
          keyword: f.keyword,
          title: f.displayName,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final authors = CollectStore.instance.followAuthors;
    final tags = CollectStore.instance.followTags;

    if (authors.isEmpty && tags.isEmpty) {
      return EmptyView(
        message: L.t('followingEmpty'),
        icon: Icons.person_add_alt_rounded,
      );
    }

    Widget section(String title, List<FollowItem> items) {
      if (items.isEmpty) return const SizedBox.shrink();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
            child: Text(
              '$title (${items.length})',
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final f in items)
                  ActionChip(
                    avatar: Icon(
                      f.kind == 'author'
                          ? Icons.person_outline_rounded
                          : Icons.tag_rounded,
                      size: 15,
                    ),
                    label: Text(
                      f.displayName,
                      style: const TextStyle(fontSize: 12),
                    ),
                    onPressed: () => _open(context, f),
                  ),
              ],
            ),
          ),
        ],
      );
    }

    return ListView(
      children: [
        section(L.t('followingAuthors'), authors),
        section(L.t('followingTags'), tags),
        const SizedBox(height: 20),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            L.t('followingHint'),
            style: TextStyle(
              fontSize: 11,
              height: 1.6,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
        const SizedBox(height: 30),
      ],
    );
  }
}

/// 专辑列表。
class _AlbumsTab extends StatelessWidget {
  const _AlbumsTab();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final albums = CollectStore.instance.albums;

    return Scaffold(
      body: albums.isEmpty
          ? EmptyView(
              message: L.t('albumsEmpty'),
              icon: Icons.collections_bookmark_outlined,
            )
          : ListView.separated(
              padding: const EdgeInsets.all(AppStyle.pagePadding),
              itemCount: albums.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, i) {
                final a = albums[i];
                return Material(
                  color: scheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(12),
                  child: ListTile(
                    leading: Icon(
                      Icons.collections_bookmark_rounded,
                      color: scheme.primary,
                    ),
                    title: Text(
                      a.name,
                      style: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    subtitle: Text(
                      a.keywords.isEmpty
                          ? L.t('albumNoKeywords')
                          : a.keywords.join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11),
                    ),
                    trailing: const Icon(Icons.chevron_right, size: 18),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => _AlbumEditPage(album: a),
                      ),
                    ),
                  ),
                );
              },
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          final a = await Navigator.of(context).push<Album>(
            MaterialPageRoute(builder: (_) => const _AlbumEditPage()),
          );
          if (a != null) {
            await CollectStore.instance.createAlbum(
              name: a.name,
              keywords: a.keywords,
            );
          }
        },
        icon: const Icon(Icons.add_rounded),
        label: Text(L.t('newAlbum')),
      ),
    );
  }
}

/// 新建 / 编辑专辑：名称 + 多个关键词。
class _AlbumEditPage extends StatefulWidget {
  const _AlbumEditPage({this.album});

  final Album? album;

  @override
  State<_AlbumEditPage> createState() => _AlbumEditPageState();
}

class _AlbumEditPageState extends State<_AlbumEditPage> {
  late final TextEditingController _name =
      TextEditingController(text: widget.album?.name ?? '');
  late final List<String> _keywords =
      List<String>.from(widget.album?.keywords ?? const []);
  final _kwCtrl = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    _kwCtrl.dispose();
    super.dispose();
  }

  void _addKeyword() {
    final v = _kwCtrl.text.trim();
    if (v.isEmpty) return;
    if (_keywords.contains(v)) {
      _kwCtrl.clear();
      return;
    }
    setState(() => _keywords.add(v));
    _kwCtrl.clear();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isNew = widget.album == null;

    return Scaffold(
      appBar: AppBar(
        title: Text(isNew ? L.t('newAlbum') : L.t('editAlbum')),
        actions: [
          TextButton(
            onPressed: () async {
              final name = _name.text.trim();
              if (name.isEmpty) return;
              if (isNew) {
                Navigator.pop(
                  context,
                  Album(
                    id: '',
                    name: name,
                    keywords: _keywords,
                    at: 0,
                  ),
                );
              } else {
                await CollectStore.instance.updateAlbum(
                  widget.album!.copyWith(
                    name: name,
                    keywords: _keywords,
                  ),
                );
                if (context.mounted) Navigator.pop(context);
              }
            },
            child: Text(L.t('save')),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _name,
            decoration: InputDecoration(
              labelText: L.t('albumName'),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 18),
          Text(
            L.t('albumKeywords'),
            style: const TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            L.t('albumKeywordsHint'),
            style: TextStyle(
              fontSize: 11,
              height: 1.5,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _kwCtrl,
                  onSubmitted: (_) => _addKeyword(),
                  decoration: InputDecoration(
                    hintText: L.t('albumKeywordHint'),
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _addKeyword,
                child: Text(L.t('add')),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final k in _keywords)
                Chip(
                  label: Text(k, style: const TextStyle(fontSize: 12)),
                  onDeleted: () => setState(() => _keywords.remove(k)),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 按关键词（作者/标签）搜作品的结果页。
class _KeywordResultsPage extends StatefulWidget {
  const _KeywordResultsPage({
    required this.kind,
    required this.keyword,
    required this.title,
  });

  final String kind;
  final String keyword;
  final String title;

  @override
  State<_KeywordResultsPage> createState() => _KeywordResultsPageState();
}

class _KeywordResultsPageState extends State<_KeywordResultsPage> {
  final _service = JmService.instance;
  final _items = <Comic>[];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final (list, _) = await _service.search(
        widget.keyword,
        searchType: widget.kind == 'author' ? 'author' : 'tag',
      );
      if (!mounted) return;
      setState(() {
        _items
          ..clear()
          ..addAll(list);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? EmptyView(
                  message: '${L.t('loadFailed')}\n$_error',
                  onRetry: _load,
                )
              : _items.isEmpty
                  ? EmptyView(message: L.t('empty'))
                  : LayoutBuilder(
                      builder: (context, box) {
                        const cols = 3;
                        const gap = 8.0;
                        final cardW =
                            (box.maxWidth - gap * (cols - 1) - 32) / cols;
                        return SingleChildScrollView(
                          padding: const EdgeInsets.all(16),
                          child: Wrap(
                            spacing: gap,
                            runSpacing: 10,
                            children: [
                              for (final c in _items)
                                SizedBox(
                                  width: cardW,
                                  child: ComicCard(
                                    title: c.name,
                                    subtitle: c.author,
                                    cover: _service.coverUrl(c),
                                    onTap: () => Navigator.of(context).push(
                                      MaterialPageRoute(
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
                    ),
    );
  }
}
