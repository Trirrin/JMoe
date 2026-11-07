import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/app_theme.dart';
import '../core/eh_source.dart';
import '../core/jm_source.dart';
import '../core/models.dart';
import '../widgets/common_widgets.dart';
import 'unified_detail_page.dart';
import '../core/l10n.dart';

/// 阅读历史（本地持久化，JM / EH 通用）。
class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  @override
  Widget build(BuildContext context) {
    final state = AppState.instance;
    final theme = Theme.of(context);
    final list = state.history;
    return Scaffold(
      appBar: AppBar(
        title: Text(L.t('readHistory')),
        actions: [
          if (list.isNotEmpty)
            IconButton(
              tooltip: L.t('clear'),
              icon: const Icon(Icons.delete_outline),
              onPressed: () async {
                // 用户可关闭「删除前二次确认」
                if (!AppState.instance.confirmDelete) {
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
              },
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: list.isEmpty
          ? EmptyView(message: L.t('noHistory'), icon: Icons.history)
          : ListView.separated(
              padding: const EdgeInsets.all(AppStyle.pagePadding),
              cacheExtent: 900,
              itemCount: list.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, i) {
                final e = list[i];
                final time = DateTime.fromMillisecondsSinceEpoch(e.updatedAt);
                return Dismissible(
                  key: ValueKey('${e.comicId}_${e.chapterId}_$i'),
                  direction: DismissDirection.endToStart,
                  background: Container(
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.only(right: 20),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.errorContainer,
                      borderRadius: BorderRadius.circular(AppStyle.cardRadius),
                    ),
                    child: Icon(
                      Icons.delete_outline,
                      color: theme.colorScheme.onErrorContainer,
                    ),
                  ),
                  onDismissed: (_) async {
                    await state.removeHistory(e.comicId, e.chapterId);
                    setState(() {});
                  },
                  child: Card(
                    child: InkWell(
                      borderRadius: BorderRadius.circular(AppStyle.cardRadius),
                      onTap: () => _open(e),
                      child: Padding(
                        padding: const EdgeInsets.all(10),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 52,
                              height: 70,
                              child: CoverImage(
                                url: e.cover,
                                borderRadius: BorderRadius.circular(6),
                                memCacheWidth: 160,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    e.comicName,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                      fontSize: 13,
                                      height: 1.3,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    '${e.chapterName} · ${_fmt(time)}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 11,
                                      color:
                                          theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                  if (e.totalPage > 0) ...[
                                    const SizedBox(height: 4),
                                    Row(
                                      children: [
                                        Expanded(
                                          child: ClipRRect(
                                            borderRadius:
                                                BorderRadius.circular(2),
                                            child: LinearProgressIndicator(
                                              value: (e.page / e.totalPage)
                                                  .clamp(0.0, 1.0),
                                              minHeight: 3,
                                              backgroundColor: theme
                                                  .colorScheme
                                                  .surfaceContainerHighest,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 6),
                                        Text(
                                          '${e.page}/${e.totalPage}',
                                          style: TextStyle(
                                            fontSize: 10,
                                            fontWeight: FontWeight.w600,
                                            color: theme.colorScheme.primary,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            const SizedBox(width: 6),
                            Icon(
                              Icons.play_circle_outline,
                              size: 22,
                              color: theme.colorScheme.primary,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
    );
  }

  void _open(ReadHistoryEntry e) {
    final source = e.source == 'ehentai'
        ? EhSource.instance
        : JmSource.instance;
    final comic = Comic(
      id: e.comicId,
      name: e.comicName,
      image: e.cover,
      source: e.source,
    );
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => UnifiedDetailPage(source: source, comic: comic),
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
