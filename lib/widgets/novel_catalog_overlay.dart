import 'package:flutter/material.dart';

import '../core/l10n.dart';
import '../core/reader_settings.dart';

/// 小说目录覆盖层（章节列表 + 内文搜索）。
///
/// 从 `novel_pages.dart` 抽出，只负责列表渲染与交互回调。
class NovelCatalogOverlay extends StatelessWidget {
  const NovelCatalogOverlay({
    super.key,
    required this.theme,
    required this.chapters,
    required this.currentIndex,
    required this.onClose,
    required this.onPick,
    required this.searchQuery,
    required this.onSearchChanged,
    required this.searching,
    required this.hits,
    required this.onPickHit,
  });

  final ReaderTheme theme;
  final List<Map<String, dynamic>> chapters;
  final int currentIndex;
  final VoidCallback onClose;
  final ValueChanged<int> onPick;

  final String searchQuery;
  final ValueChanged<String> onSearchChanged;
  final bool searching;
  final List<
      ({
        int chapterIndex,
        int offset,
        String excerpt,
        String chapterTitle,
      })> hits;
  final void Function(int chapterIndex, int offset) onPickHit;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: theme.bg,
      child: SafeArea(
        child: Column(
          children: [
            _header(context),
            if (searchQuery.isNotEmpty) _searchHeader(),
            Expanded(
              child: searchQuery.isEmpty ? _chapterList() : _resultList(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _header(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      child: Row(
        children: [
          IconButton(
            icon: Icon(Icons.close_rounded, color: theme.fg),
            onPressed: onClose,
          ),
          Expanded(
            child: Text(
              L.t('catalog'),
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: theme.fg,
              ),
            ),
          ),
          Text(
            '${chapters.length} ${L.t('chaptersUnit')}',
            style: TextStyle(fontSize: 11, color: theme.subtle),
          ),
        ],
      ),
    );
  }

  Widget _searchHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
      child: Row(
        children: [
          if (searching) ...[
            const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 1.6),
            ),
            const SizedBox(width: 8),
          ],
          Text(
            L.tp('searchHits', {'n': '${hits.length}'}),
            style: TextStyle(fontSize: 11.5, color: theme.subtle),
          ),
        ],
      ),
    );
  }

  Widget _chapterList() {
    return ListView.builder(
      itemCount: chapters.length,
      itemBuilder: (context, i) {
        final active = i == currentIndex;
        return InkWell(
          onTap: () => onPick(i),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
            decoration: BoxDecoration(
              color: active
                  ? theme.fg.withValues(alpha: 0.06)
                  : Colors.transparent,
              border: Border(
                bottom: BorderSide(
                  color: theme.subtle.withValues(alpha: 0.15),
                ),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '${chapters[i]['title'] ?? ''}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                      color: active ? theme.fg : theme.fg.withValues(alpha: 0.85),
                    ),
                  ),
                ),
                if (active)
                  Icon(Icons.play_arrow_rounded, size: 16, color: theme.fg),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _resultList() {
    if (hits.isEmpty) {
      return Center(
        child: Text(
          searching ? L.t('searching') : L.t('noResults'),
          style: TextStyle(fontSize: 12.5, color: theme.subtle),
        ),
      );
    }
    return ListView.builder(
      itemCount: hits.length,
      itemBuilder: (context, i) {
        final h = hits[i];
        final title = (h.chapterIndex >= 0 && h.chapterIndex < chapters.length)
            ? '${chapters[h.chapterIndex]['title'] ?? ''}'
            : '';
        return InkWell(
          onTap: () => onPickHit(h.chapterIndex, h.offset),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: theme.subtle.withValues(alpha: 0.15),
                ),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: theme.subtle,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  h.excerpt,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.5,
                    color: theme.fg.withValues(alpha: 0.85),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
