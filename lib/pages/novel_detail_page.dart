import 'dart:async';
import 'package:flutter/material.dart';
import '../core/app_state.dart';
import '../core/jm_service.dart';
import '../core/l10n.dart';
import '../core/reader_store.dart';
import 'novel_read_page.dart';
import '../widgets/app_toast.dart';
import '../widgets/common_widgets.dart';

class NovelDetailPage extends StatefulWidget {
  final String nid;
  final String title;
  final String? cover;

  const NovelDetailPage({
    super.key,
    required this.nid,
    required this.title,
    this.cover,
  });

  @override
  State<NovelDetailPage> createState() => _NovelDetailPageState();
}

class _NovelDetailPageState extends State<NovelDetailPage> {
  final _service = JmService.instance;
  final _store = ReaderStore.instance;
  Map<String, dynamic>? _detail;
  List<Map<String, dynamic>> _chapters = [];
  bool _descExpanded = false;
  int _resumeIndex = 0;
  bool _resumeLoaded = false;

  bool _novelFav = false;

  @override
  void initState() {
    super.initState();
    _novelFav = AppState.instance.isLocalFavorite(widget.nid);
    _load();
  }

  Future<void> _toggleNovelFav() async {
    final target = !_novelFav;
    setState(() => _novelFav = target);
    await AppState.instance.setLocalFavorite(
      {
        'id': widget.nid,
        'name': _displayTitle,
        'author': '${_detail?['author'] ?? ''}',
        'cover': _coverUrl ?? '',
        'source': 'jm',
        'type': 'novel',
      },
      target,
    );
    if (!mounted) return;
    AppToast.show(
      context,
      target ? L.t('favorited') : L.t('unfavorited'),
      icon: target ? Icons.favorite_rounded : Icons.favorite_border_rounded,
      accent: target ? const Color(0xFFFF6B81) : null,
    );
  }

  Future<void> _load() async {
    final d = await _service.fetchNovelDetail(widget.nid);
    final chapters = JmService.chaptersFromDetail(d);
    await _store.loadBook(widget.nid);
    final p = _store.progress(widget.nid);
    var resume = 0;
    if (p != null && p.chapterIndex >= 0 && p.chapterIndex < chapters.length) {
      resume = p.chapterIndex;
    }
    if (!mounted) return;
    setState(() {
      _detail = d;
      _chapters = chapters;
      _resumeIndex = resume;
      _resumeLoaded = p != null;
    });
  }

  (String, String) _splitTitle(String raw) {
    final parts = raw.split('|');
    if (parts.length >= 2) {
      return (parts[0].trim(), parts.sublist(1).join('|').trim());
    }
    return (raw.trim(), '');
  }

  String get _displayTitle =>
      _splitTitle('${_detail?['name'] ?? widget.title}').$1;

  String? get _coverUrl {
    final img = '${_detail?['images'] ?? ''}';
    if (img.isNotEmpty) {
      if (img.startsWith('http')) return img;
      final host = _service.imgHost ?? 'https://cdn-msp.jmapiproxy3.cc';
      return '$host$img';
    }
    return widget.cover;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final desc = '${_detail?['description'] ?? ''}';
    final tags = (_detail?['tags'] as List?)
            ?.whereType<Object>()
            .map((e) => '$e')
            .toList() ??
        const <String>[];
    final author = '${_detail?['author'] ?? ''}';
    final views = '${_detail?['total_views'] ?? ''}';

    return Scaffold(
      appBar: AppBar(
        title: Text(_displayTitle, maxLines: 1),
        actions: [
          IconButton(
            tooltip: L.t('favorite'),
            icon: Icon(
              _novelFav ? Icons.favorite : Icons.favorite_border,
              color: _novelFav ? theme.colorScheme.error : null,
            ),
            onPressed: _toggleNovelFav,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 32),
        children: [
          SizedBox(
            height: 139,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Hero(
                  tag: 'novel_${widget.nid}',
                  flightShuttleBuilder: (ctx, anim, dir, from, to) {
                    return ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: CoverImage(url: _coverUrl),
                    );
                  },
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: SizedBox(
                      width: 104,
                      height: 139,
                      child: _coverUrl == null
                          ? Container(
                              color: theme.colorScheme.surfaceContainerHighest,
                              child: const Icon(
                                Icons.menu_book_rounded,
                                size: 32,
                              ),
                            )
                          : CoverImage(url: _coverUrl),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.start,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _displayTitle,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                              height: 1.3,
                            ),
                          ),
                          if (author.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Row(
                              children: [
                                Icon(
                                  Icons.person_outline_rounded,
                                  size: 12,
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                                const SizedBox(width: 3),
                                Expanded(
                                  child: Text(
                                    author,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 11,
                                      color:
                                          theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                          if (views.isNotEmpty) ...[
                            const SizedBox(height: 2),
                            Row(
                              children: [
                                Icon(
                                  Icons.visibility_outlined,
                                  size: 12,
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                                const SizedBox(width: 3),
                                Text(
                                  views,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color:
                                        theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                      const Spacer(),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: _chapters.isEmpty
                              ? null
                              : () => _open(_resumeIndex),
                          icon: const Icon(Icons.play_arrow_rounded, size: 17),
                          label: Text(
                            _resumeLoaded && _resumeIndex > 0
                                ? L.t('continueReading')
                                : L.t('startReading'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          style: FilledButton.styleFrom(
                            minimumSize: const Size(0, 34),
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            textStyle: const TextStyle(fontSize: 12.5),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (_detail == null) ...[
            const SizedBox(height: 14),
            const Row(
              children: [
                ShimmerBox(width: 56, height: 22, radius: 11),
                SizedBox(width: 6),
                ShimmerBox(width: 72, height: 22, radius: 11),
              ],
            ),
            const SizedBox(height: 16),
            const ShimmerBox(height: 13, radius: 4),
            const SizedBox(height: 7),
            const ShimmerBox(height: 13, radius: 4),
            const SizedBox(height: 7),
            ShimmerBox(
              height: 13,
              radius: 4,
              width: MediaQuery.of(context).size.width * 0.62,
            ),
          ] else ...[
            if (tags.isNotEmpty) ...[
              const SizedBox(height: 14),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: tags
                    .map(
                      (t) => Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 9,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          t,
                          style: const TextStyle(fontSize: 11),
                        ),
                      ),
                    )
                    .toList(),
              ),
            ],
            if (desc.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(
                desc,
                maxLines: _descExpanded ? null : 4,
                overflow: _descExpanded ? null : TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.7,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.85),
                ),
              ),
              if (desc.length > 90)
                GestureDetector(
                  onTap: () =>
                      setState(() => _descExpanded = !_descExpanded),
                  child: Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      _descExpanded ? L.t('collapse') : L.t('expandAll'),
                      style: TextStyle(
                        fontSize: 12,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ),
                ),
            ],
          ],
                const SizedBox(height: 18),
                Row(
                  children: [
                    Text(
                      L.t('chapters'),
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '${_chapters.length}',
                      style: TextStyle(
                        fontSize: 12,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (_detail == null)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  ),
                ...List.generate(_chapters.length, (i) {
                  final c = _chapters[i];
                  final active = i == _resumeIndex && _resumeLoaded;
                  return Card(
                    margin: const EdgeInsets.only(bottom: 6),
                    elevation: 0,
                    color: active
                        ? theme.colorScheme.primaryContainer.withValues(alpha: 0.5)
                        : theme.colorScheme.surfaceContainerHighest
                            .withValues(alpha: 0.5),
                    child: ListTile(
                      dense: true,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      title: Text(
                        '${c['title'] ?? ''}',
                        style: const TextStyle(fontSize: 13),
                      ),
                      subtitle: null,
                      trailing:
                          const Icon(Icons.chevron_right_rounded, size: 18),
                      onTap: () => _open(i),
                    ),
                  );
                }),
                if (_chapters.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Center(
                      child: Text(
                        L.t('empty'),
                        style: TextStyle(
                          fontSize: 13,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
    );
  }

  void _open(int index) {
    final p = ReaderStore.instance.progress(widget.nid);
    final ratio = (p != null && p.chapterIndex == index) ? p.ratio : null;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => NovelReadPage(
          nid: widget.nid,
          chapters: _chapters,
          index: index,
          initialRatio: ratio,
          novelTitle: _displayTitle,
          cover: _coverUrl,
        ),
      ),
    );
  }
}
