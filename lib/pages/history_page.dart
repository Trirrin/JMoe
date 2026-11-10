import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/app_theme.dart';
import '../core/eh_source.dart';
import '../core/jm_source.dart';
import '../core/models.dart';
import '../widgets/common_widgets.dart';
import '../widgets/detail_route.dart';
import 'anime_player_page.dart';
import 'novel_detail_page.dart';
import 'unified_detail_page.dart';
import '../core/l10n.dart';

class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  HistorySort _sort = HistorySort.recent;

  final Set<String> _expanded = {};

  @override
  Widget build(BuildContext context) {
    final state = AppState.instance;
    final theme = Theme.of(context);
    final groups = state.groupedHistory(sort: _sort);

    return Scaffold(
      appBar: AppBar(
        title: Text(L.t('readHistory')),
        actions: [
          PopupMenuButton<HistorySort>(
            initialValue: _sort,
            tooltip: L.t('sort'),
            icon: const Icon(Icons.sort_rounded),
            onSelected: (v) {
              if (v == _sort) return;
              setState(() => _sort = v);
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: HistorySort.recent,
                child: Text(L.t('historySortRecent')),
              ),
              PopupMenuItem(
                value: HistorySort.progress,
                child: Text(L.t('historySortProgress')),
              ),
            ],
          ),
          if (groups.isNotEmpty)
            IconButton(
              tooltip: L.t('clear'),
              icon: const Icon(Icons.delete_outline),
              onPressed: () => _clearAll(state),
            ),
          const SizedBox(width: 4),
        ],
      ),
      body: groups.isEmpty
          ? EmptyView(message: L.t('noHistory'), icon: Icons.history)
          : ListView.separated(
              cacheExtent: 900, padding: const EdgeInsets.all(AppStyle.pagePadding),
              itemCount: groups.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, i) => _buildGroupCard(theme, groups[i]),
            ),
    );
  }

  Future<void> _clearAll(AppState state) async {
    if (!state.confirmDelete) {
      await state.clearHistory();
      setState(() {});
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(L.t('clearHistory')),
        content: Text(L.t('clearHistoryConfirm')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: Text(L.t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: Text(L.t('clear')),
          ),
        ],
      ),
    );
    if (ok == true) {
      await state.clearHistory();
      if (mounted) setState(() {});
    }
  }

  (IconData, String) _kindOf(String kind) => switch (kind) {
        'novel' => (Icons.menu_book_rounded, L.t('novels')),
        'video' => (Icons.movie_rounded, L.t('anime')),
        _ => (Icons.auto_stories_rounded, L.t('searchComic')),
      };

  Widget _buildGroupCard(ThemeData theme, HistoryGroup g) {
    final scheme = theme.colorScheme;
    final expanded = _expanded.contains(g.comicId);
    final (kindIcon, kindLabel) = _kindOf(g.kind);
    final latest = g.latest;
    final hasSub = g.chapters.length > 1;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          InkWell(
            onTap: () => _open(g),
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Row(
                children: [
                  SizedBox(
                    width: 52,
                    height: 70,
                    child: Hero(
                      tag: 'history_cover_${g.source}_${g.comicId}',
                      flightShuttleBuilder: (ctx, anim, dir, from, to) {
                        return ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: CoverImage(
                            url: g.cover,
                            memCacheWidth: 160,
                          ),
                        );
                      },
                      child: CoverImage(
                        url: g.cover,
                        borderRadius: BorderRadius.circular(6),
                        memCacheWidth: 160,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          g.comicName,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                            height: 1.3,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Icon(kindIcon, size: 12, color: scheme.primary),
                            const SizedBox(width: 3),
                            Text(
                              kindLabel,
                              style: TextStyle(
                                fontSize: 10.5,
                                color: scheme.primary,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Flexible(
                              child: Text(
                                latest == null
                                    ? ''
                                    : '${latest.chapterName} · '
                                        '${_fmt(DateTime.fromMillisecondsSinceEpoch(latest.updatedAt))}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 10.5,
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 5),
                        Row(
                          children: [
                            Expanded(
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(2),
                                child: LinearProgressIndicator(
                                  value: g.overallRatio,
                                  minHeight: 3,
                                  backgroundColor:
                                      scheme.surfaceContainerHighest,
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              '${(g.overallRatio * 100).toStringAsFixed(0)}%',
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                                color: scheme.primary,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  if (hasSub)
                    IconButton(
                      tooltip: expanded ? L.t('collapse') : L.t('expand'),
                      icon: Icon(
                        expanded
                            ? Icons.keyboard_arrow_up_rounded
                            : Icons.keyboard_arrow_down_rounded,
                        size: 20,
                      ),
                      onPressed: () => setState(() {
                        if (expanded) {
                          _expanded.remove(g.comicId);
                        } else {
                          _expanded.add(g.comicId);
                        }
                      }),
                    )
                  else
                    const SizedBox(width: 8),
                ],
              ),
            ),
          ),
          if (expanded) ...[
            Divider(
              height: 1,
              color: scheme.outlineVariant.withValues(alpha: 0.4),
            ),
            ...g.chapters.map((e) => _buildChapterRow(theme, g, e)),
          ],
        ],
      ),
    );
  }

  Widget _buildChapterRow(
    ThemeData theme,
    HistoryGroup g,
    ReadHistoryEntry e,
  ) {
    final scheme = theme.colorScheme;
    return InkWell(
      onTap: () => _open(g, chapter: e),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
        child: Row(
          children: [
            Expanded(
              child: Text(
                e.chapterName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12),
              ),
            ),
            SizedBox(
              width: 70,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: e.ratio,
                  minHeight: 3,
                  backgroundColor: scheme.surfaceContainerHighest,
                ),
              ),
            ),
            const SizedBox(width: 6),
            Text(
              e.totalPage > 0 ? '${e.page}/${e.totalPage}' : '—',
              style: TextStyle(
                fontSize: 10,
                color: scheme.onSurfaceVariant,
              ),
            ),
            IconButton(
              tooltip: L.t('delete'),
              icon: Icon(
                Icons.close_rounded,
                size: 16,
                color: scheme.onSurfaceVariant,
              ),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
              onPressed: () async {
                await AppState.instance.removeHistory(
                  e.comicId,
                  e.chapterId,
                );
                if (mounted) setState(() {});
              },
            ),
          ],
        ),
      ),
    );
  }

  void _open(HistoryGroup g, {ReadHistoryEntry? chapter}) {
    final tag = 'history_cover_${g.source}_${g.comicId}';
    if (g.kind == 'novel') {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => NovelDetailPage(
            nid: g.comicId,
            title: g.comicName,
            cover: g.cover,
          ),
        ),
      );
      return;
    }
    if (g.kind == 'video') {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => AnimePlayerPage(id: g.comicId, title: g.comicName),
        ),
      );
      return;
    }
    final source =
        g.source == 'ehentai' ? EhSource.instance : JmSource.instance;
    final comic = Comic(
      id: g.comicId,
      name: g.comicName,
      image: g.cover,
      source: g.source,
    );
    Navigator.of(context).push(
      detailRoute(
        builder: (_) => UnifiedDetailPage(
          source: source,
          comic: comic,
          coverTag: tag,
        ),
      ),
    );
  }

  String _fmt(DateTime t) {
    final now = DateTime.now();
    final diff = now.difference(t);
    if (diff.inMinutes < 1) return L.t('justNow');
    if (diff.inHours < 1) return L.tp('minutesAgoShort', {'n': diff.inMinutes});
    if (diff.inDays < 1) return L.tp('hoursAgoShort', {'n': diff.inHours});
    if (diff.inDays < 30) return L.tp('daysAgoShort', {'n': diff.inDays});
    return '${t.year}-${t.month.toString().padLeft(2, '0')}-'
        '${t.day.toString().padLeft(2, '0')}';
  }
}
