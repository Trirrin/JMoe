import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/app_theme.dart';
import '../core/l10n.dart';
import '../core/jm_service.dart';
import '../core/models.dart';
import '../widgets/common_widgets.dart';
import 'novel_pages.dart';
import 'unified_home_page.dart';
import 'unified_reader_page.dart';

class BookmarksPage extends StatefulWidget {
  const BookmarksPage({super.key});

  @override
  State<BookmarksPage> createState() => _BookmarksPageState();
}

class _BookmarksPageState extends State<BookmarksPage> {
  @override
  void initState() {
    super.initState();
    AppState.instance.addListener(_onChanged);
  }

  @override
  void dispose() {
    AppState.instance.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _open(Map<String, dynamic> bm) async {
    final kind = '${bm['kind'] ?? 'comic'}';
    final comicId = '${bm['comicId'] ?? ''}';
    final chapterId = '${bm['chapterId'] ?? ''}';
    final page = (bm['page'] as num?)?.toInt() ?? 0;
    final comic = Comic(
      id: comicId,
      name: '${bm['comicName'] ?? ''}',
      author: '',
      image: '${bm['cover'] ?? ''}',
      source: '${bm['source'] ?? 'jm'}',
    );

    if (kind == 'novel') {
      try {
        final detail =
            await JmService.instance.fetchNovelDetail(comicId);
        final chapters = JmService.chaptersFromDetail(detail);
        if (!mounted) return;
        if (chapters.isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(L.t('noChapter'))),
          );
          return;
        }
        var idx = chapters.indexWhere(
          (c) => '${c['id']}' == chapterId || '${c['cid']}' == chapterId,
        );
        if (idx < 0) idx = 0;
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => NovelReadPage(
              nid: comicId,
              chapters: chapters,
              index: idx,
              novelTitle: '${bm['comicName'] ?? ''}',
              cover: '${bm['cover'] ?? ''}',
            ),
          ),
        );
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$e')),
        );
      }
      return;
    }

    final source = SourceRegistry.current;
    try {
      final info = await source.detail(comic);
      final idx = info.chapters.indexWhere((c) => c.id == chapterId);
      if (!mounted) return;
      if (idx < 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(L.t('noChapter'))),
        );
        return;
      }
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => UnifiedReaderPage(
            source: source,
            comic: comic,
            chapters: info.chapters,
            initialIndex: idx,
            initialPage: page > 0
                ? page
                : (AppState.instance.lastReadFor(comicId)?.page ?? 1),
            albumName: comic.name,
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$e')),
      );
    }
  }

  Future<void> _editNote(Map<String, dynamic> bm) async {
    final ctrl = TextEditingController(text: '${bm['note'] ?? ''}');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(L.t('bookmarkNote')),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLines: 4,
          decoration: InputDecoration(
            hintText: L.t('bookmarkNoteHint'),
            border: const OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(L.t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(L.t('save')),
          ),
        ],
      ),
    );
    final text = ctrl.text;
    ctrl.dispose();
    if (ok != true) return;
    await AppState.instance.updateBookmarkNote(
      comicId: '${bm['comicId'] ?? ''}',
      chapterId: '${bm['chapterId'] ?? ''}',
      page: (bm['page'] as num?)?.toInt() ?? 0,
      note: text.trim(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final items = AppState.instance.chapterBookmarks;

    return Scaffold(
      appBar: AppBar(title: Text(L.t('bookmarks'))),
      body: items.isEmpty
          ? EmptyView(
              message: L.t('bookmarksEmpty'),
              icon: Icons.bookmark_border_rounded,
            )
          : ListView.separated(
              padding: const EdgeInsets.all(AppStyle.pagePadding),
              itemCount: items.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, i) {
                final bm = items[i];
                final isNovel = '${bm['kind']}' == 'novel';
                final page = (bm['page'] as num?)?.toInt() ?? 0;
                final note = '${bm['note'] ?? ''}';
                return Material(
                  color: scheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(10),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: () => _open(bm),
                    child: Padding(
                      padding: const EdgeInsets.all(10),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 40,
                            height: 54,
                            child: CoverImage(
                              url: '${bm['cover'] ?? ''}',
                              borderRadius: BorderRadius.circular(6),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '${bm['comicName'] ?? ''}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Row(
                                  children: [
                                    Icon(
                                      Icons.bookmark_rounded,
                                      size: 12,
                                      color: scheme.primary,
                                    ),
                                    const SizedBox(width: 4),
                                    Flexible(
                                      child: Text(
                                        [
                                          if (isNovel)
                                            L.t('novels')
                                          else
                                            L.t('searchComic'),
                                          '${bm['chapterName'] ?? ''}',
                                          if (page > 0)
                                            L.tp('bookmarkPageN', {'n': '$page'}),
                                        ].join(' · '),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 11.5,
                                          color: scheme.primary,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                if (note.isNotEmpty) ...[
                                  const SizedBox(height: 4),
                                  Text(
                                    note,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 11,
                                      height: 1.4,
                                      color: scheme.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                          Column(
                            children: [
                              IconButton(
                                visualDensity: VisualDensity.compact,
                                tooltip: L.t('bookmarkNote'),
                                icon: Icon(
                                  Icons.edit_note_rounded,
                                  size: 18,
                                  color: scheme.onSurfaceVariant,
                                ),
                                onPressed: () => _editNote(bm),
                              ),
                              IconButton(
                                visualDensity: VisualDensity.compact,
                                tooltip: L.t('delete'),
                                icon: Icon(
                                  Icons.bookmark_remove_outlined,
                                  size: 17,
                                  color: scheme.onSurfaceVariant,
                                ),
                                onPressed: () async {
                                  await AppState.instance.setChapterBookmark(
                                    comicId: '${bm['comicId'] ?? ''}',
                                    chapterId: '${bm['chapterId'] ?? ''}',
                                    comicName: '',
                                    chapterName: '',
                                    cover: '',
                                    source: '',
                                    on: false,
                                    page: page,
                                  );
                                },
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
    );
  }
}
