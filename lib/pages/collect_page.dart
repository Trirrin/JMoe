import 'package:flutter/material.dart';

import '../core/collect_store.dart';
import '../core/jm_service.dart';
import '../core/l10n.dart';
import '../core/models.dart';
import '../widgets/common_widgets.dart';
import 'unified_detail_page.dart';
import 'unified_home_page.dart';

class CollectPage extends StatefulWidget {
  const CollectPage({super.key, this.initialTab = 0});

  final int initialTab;

  @override
  State<CollectPage> createState() => _CollectPageState();
}

class _CollectPageState extends State<CollectPage> {
  @override
  void initState() {
    super.initState();
    CollectStore.instance.addListener(_onChanged);
  }

  @override
  void dispose() {
    CollectStore.instance.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(L.t('following')),
      ),
      body: const _FollowingTab(),
    );
  }
}

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
