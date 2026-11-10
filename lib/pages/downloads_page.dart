import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../core/app_theme.dart';
import '../core/downloader.dart';
import '../core/jmoe_archive.dart';
import '../core/l10n.dart';
import '../core/app_state.dart';
import '../core/jm_source.dart';
import '../core/models.dart';
import 'unified_reader_page.dart';

enum DownloadSort {
  name,

  time,
}

class DownloadsPage extends StatefulWidget {
  const DownloadsPage({super.key, this.embedded = false});

  final bool embedded;

  @override
  State<DownloadsPage> createState() => DownloadsPageState();
}

class DownloadsPageState extends State<DownloadsPage> {
  Timer? _ticker;

  DownloadSort _sort = DownloadSort.name;

  DownloadSort get sortMode => _sort;

  bool get hasCompleted =>
      ChapterDownloader.allTasks.any((t) => t.done);

  void setSort(DownloadSort v) {
    if (v == _sort) return;
    setState(() => _sort = v);
  }

  void clearCompleted() => _onClear(Theme.of(context));

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(milliseconds: 400), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  List<DownloadTask> _sorted(List<DownloadTask> list) {
    final copy = List<DownloadTask>.from(list);
    switch (_sort) {
      case DownloadSort.name:
        copy.sort((a, b) {
          final c = a.albumName.compareTo(b.albumName);
          if (c != 0) return c;
          return _naturalCompare(a.chapterName, b.chapterName);
        });
      case DownloadSort.time:
        copy.sort((a, b) {
          final at = a.finishedAt ?? a.startedAt;
          final bt = b.finishedAt ?? b.startedAt;
          final c = bt.compareTo(at);
          if (c != 0) return c;
          return _naturalCompare(a.chapterName, b.chapterName);
        });
    }
    return copy;
  }

  static int _naturalCompare(String a, String b) {
    final ra = RegExp(r'\d+').allMatches(a).map((m) => m.group(0)!).toList();
    final rb = RegExp(r'\d+').allMatches(b).map((m) => m.group(0)!).toList();
    for (var i = 0; i < ra.length && i < rb.length; i++) {
      final na = int.tryParse(ra[i]);
      final nb = int.tryParse(rb[i]);
      if (na != null && nb != null && na != nb) return na.compareTo(nb);
    }
    return a.compareTo(b);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tasks = ChapterDownloader.allTasks;

    final running = _sorted(
      tasks.where((t) => !t.done).toList(),
    );
    final done = _sorted(tasks.where((t) => t.done).toList());

    final toolbar = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        PopupMenuButton<DownloadSort>(
          initialValue: _sort,
          tooltip: L.t('sort'),
          icon: const Icon(Icons.sort_rounded, size: 20),
          onSelected: (v) {
            if (v == _sort) return;
            setState(() => _sort = v);
          },
          itemBuilder: (_) => [
            PopupMenuItem(
              value: DownloadSort.name,
              child: Text(L.t('sortByName')),
            ),
            PopupMenuItem(
              value: DownloadSort.time,
              child: Text(L.t('sortByDownloadTime')),
            ),
          ],
        ),
        if (done.isNotEmpty)
          IconButton(
            tooltip: L.t('clear'),
            icon: const Icon(Icons.cleaning_services_outlined, size: 20),
            onPressed: () => _onClear(theme),
          ),
      ],
    );

    final bodyContent = RefreshIndicator(
        onRefresh: () async {
          await ChapterDownloader.restoreFromDisk();
          if (mounted) setState(() {});
        },
        edgeOffset: MediaQuery.of(context).padding.top,
        child: ListView(
          physics: const BouncingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics(),
          ),
          padding: const EdgeInsets.fromLTRB(
            AppStyle.pagePadding,
            AppStyle.pagePadding,
            AppStyle.pagePadding,
            32,
          ),
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: scheme.primaryContainer.withValues(alpha: 0.45),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.lightbulb_outline_rounded,
                    size: 16,
                    color: scheme.onPrimaryContainer,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      L.t('downloadsTapHint'),
                      style: TextStyle(
                        fontSize: 11.5,
                        height: 1.4,
                        color: scheme.onPrimaryContainer,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            _sectionHeader(theme, L.t('downloadsRunning'), running.length,
                Icons.downloading_rounded, scheme.primary),
            if (running.isEmpty)
              _emptyRow(theme, L.t('downloadsRunningEmpty'))
            else
              ..._buildGroups(theme, running),
            _sectionHeader(theme, L.t('downloadsDone'), done.length,
                Icons.check_circle_outline_rounded, scheme.primary),
            if (done.isEmpty)
              _emptyRow(theme, L.t('downloadsDoneEmpty'))
            else
              ..._buildGroups(theme, done),
          ],
        ),
    );

    if (widget.embedded) {
      return bodyContent;
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(L.t('myDownloads')),
        actions: [toolbar],
      ),
      body: bodyContent,
    );
  }

  Widget _sectionHeader(
    ThemeData theme,
    String title,
    int count,
    IconData icon,
    Color color,
  ) {
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 14, 4, 8),
      child: Row(
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Text(
            count > 0 ? '$title ($count)' : title,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
              color: scheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }

  Widget _emptyRow(ThemeData theme, String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 2, 8, 6),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11.5,
          color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.75),
        ),
      ),
    );
  }

  List<Widget> _buildGroups(ThemeData theme, List<DownloadTask> list) {
    final groups = <String, List<DownloadTask>>{};
    for (final t in list) {
      final key = '${t.sourceId}:${t.albumId}';
      groups.putIfAbsent(key, () => []).add(t);
    }
    for (final g in groups.values) {
      g.sort((a, b) => a.chapterName.compareTo(b.chapterName));
    }
    return groups.values.map((g) => _buildGroup(theme, g)).toList();
  }

  Future<void> _onClear(ThemeData theme) async {
    var alsoDeleteFiles = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setD) => AlertDialog(
          title: Text(L.t('clearTasks')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                L.t('clearTasksDesc'),
                style: const TextStyle(fontSize: 13, height: 1.5),
              ),
              const SizedBox(height: 8),
              CheckboxListTile(
                value: alsoDeleteFiles,
                onChanged: (v) => setD(() => alsoDeleteFiles = v ?? false),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                dense: true,
                title: Text(
                  L.t('clearTasksAlsoFiles'),
                  style: const TextStyle(fontSize: 12.5),
                ),
                subtitle: Text(
                  L.t('clearTasksAlsoFilesDesc'),
                  style: const TextStyle(fontSize: 11),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: Text(L.t('cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: Text(L.t('confirm')),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;

    final doneList = ChapterDownloader.allTasks.where((t) => t.done).toList();
    if (alsoDeleteFiles) {
      for (final t in doneList) {
        await ChapterDownloader.deleteBy(t.sourceId, t.chapterId);
      }
    } else {
      ChapterDownloader.clearFinished();
    }
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          alsoDeleteFiles ? L.t('clearTasksDoneWithFiles') : L.t('clearTasksDone'),
        ),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Widget _buildGroup(ThemeData theme, List<DownloadTask> list) {
    final scheme = theme.colorScheme;
    final first = list.first;

    return Card(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 10, 10, 6),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: SizedBox(
                    width: 42,
                    height: 56,
                    child: first.coverPath != null
                        ? Image.file(
                            File(first.coverPath!),
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => Container(
                              color: scheme.surfaceContainerHighest,
                            ),
                          )
                        : (first.coverUrl == null ||
                                first.coverUrl!.isEmpty
                            ? Container(
                                color: scheme.surfaceContainerHighest,
                              )
                            : Image.network(
                                first.coverUrl!,
                                fit: BoxFit.cover,
                                errorBuilder: (_, _, _) => Container(
                                  color: scheme.surfaceContainerHighest,
                                ),
                              )),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        first.albumName.isEmpty
                            ? L.t('downloads')
                            : first.albumName,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w700,
                          height: 1.3,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        L.tp('offlineChaptersN', {'n': '${list.length}'}),
                        style: TextStyle(
                          fontSize: 10.5,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Divider(
            height: 1,
            color: scheme.outlineVariant.withValues(alpha: 0.4),
          ),
          ...list.map((t) => _buildChapterRow(theme, t)),
        ],
      ),
    );
  }

  Widget _buildChapterRow(ThemeData theme, DownloadTask t) {
    final scheme = theme.colorScheme;
    final pct = t.total <= 0 ? 0.0 : t.completed / t.total;
    final canOpen = t.done && t.savedPath != null;

    return InkWell(
      onTap: canOpen
          ? () async {
              final comic = Comic(
                id: t.albumId,
                name: t.albumName,
                author: '',
                image: '',
                source: t.sourceId,
              );
              final chapter = Chapter(
                id: t.chapterId,
                name: t.chapterName,
                sort: 1,
              );
              final last = AppState.instance.lastReadFor(t.albumId);
              final startPage =
                  (last != null && last.chapterId == t.chapterId)
                      ? last.page
                      : 1;
              await Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => UnifiedReaderPage(
                    source: JmSource.instance,
                    comic: comic,
                    chapters: [chapter],
                    initialIndex: 0,
                    initialPage: startPage,
                    albumName: t.albumName,
                    localDir: t.savedPath,
                  ),
                ),
              );
            }
          : null,
      onLongPress: () => _showActions(theme, t),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
        child: Row(
          children: [
            Icon(
              canOpen
                  ? Icons.check_circle_rounded
                  : (t.paused
                      ? Icons.pause_circle_outline_rounded
                      : Icons.downloading_rounded),
              size: 15,
              color: canOpen
                  ? scheme.primary
                  : (t.paused ? scheme.tertiary : scheme.onSurfaceVariant),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    t.chapterName.isEmpty ? '-' : t.chapterName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12.5),
                  ),
                  if (!t.done) ...[
                    const SizedBox(height: 4),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: LinearProgressIndicator(
                        value: t.paused ? null : pct,
                        minHeight: 3,
                        backgroundColor: scheme.surfaceContainerHighest,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 6),
            if (!t.done)
              Text(
                t.paused ? L.t('paused') : '${(pct * 100).toStringAsFixed(0)}%',
                style: TextStyle(
                  fontSize: 10,
                  color: t.paused ? scheme.tertiary : scheme.onSurfaceVariant,
                ),
              ),
            if (!t.done)
              IconButton(
                tooltip: t.paused ? L.t('resume') : L.t('pause'),
                icon: Icon(
                  t.paused ? Icons.play_arrow_rounded : Icons.pause_rounded,
                  size: 18,
                ),
                padding: EdgeInsets.zero,
                constraints:
                    const BoxConstraints(minWidth: 30, minHeight: 30),
                onPressed: () {
                  final key = '${t.sourceId}:${t.chapterId}';
                  if (t.paused) {
                    ChapterDownloader.resume(key);
                  } else {
                    ChapterDownloader.pause(key);
                  }
                  setState(() {});
                },
              ),
            IconButton(
              tooltip: L.t('more'),
              icon: const Icon(Icons.more_vert_rounded, size: 18),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
              onPressed: () => _showActions(theme, t),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showActions(ThemeData theme, DownloadTask t) async {
    final scheme = theme.colorScheme;
    final canOpen = t.done && t.savedPath != null;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                t.chapterName.isEmpty ? t.albumName : t.chapterName,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            if (canOpen) ...[
              ListTile(
                leading: const Icon(Icons.folder_open_rounded),
                title: Text(L.t('openFolder')),
                onTap: () async {
                  Navigator.pop(ctx);
                  await ChapterDownloader.openFolder(t.savedPath!);
                },
              ),
              ListTile(
                leading: const Icon(Icons.share_rounded),
                title: Text(L.t('shareAsArchive')),
                subtitle: Text(
                  L.t('shareAsArchiveDesc'),
                  style: const TextStyle(fontSize: 11),
                ),
                onTap: () async {
                  Navigator.pop(ctx);
                  await _shareAsArchive(t);
                },
              ),
            ],
            ListTile(
              leading: Icon(Icons.delete_outline_rounded, color: scheme.error),
              title: Text(
                L.t('delete'),
                style: TextStyle(color: scheme.error),
              ),
              onTap: () async {
                Navigator.pop(ctx);
                await _confirmDelete(t);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _shareAsArchive(DownloadTask t) async {
    final dirPath = t.savedPath;
    if (dirPath == null) return;
    _showPackingDialog();
    final name = (t.chapterName.isEmpty ? t.albumName : t.chapterName)
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    Directory? tmp;
    try {
      final base = await getTemporaryDirectory();
      tmp = Directory('${base.path}/jmoe_share');
    } catch (_) {
      tmp = Directory('${Directory.systemTemp.path}/jmoe_share');
    }
    if (!tmp.existsSync()) tmp.createSync(recursive: true);
    final outPath = '${tmp.path}/$name.jmoe';
    final albumDir = File(dirPath).parent.path;
    final albumMeta = <String, dynamic>{
      'title': t.albumName,
      'chapterName': t.chapterName,
      'albumId': t.albumId,
      'chapterId': t.chapterId,
      'sourceId': t.sourceId,
      if (t.coverUrl != null) 'coverUrl': t.coverUrl,
    };
    try {
      final albumFile = File('$albumDir/album.json');
      if (albumFile.existsSync()) {
        final m = jsonDecode(albumFile.readAsStringSync());
        if (m is Map) albumMeta.addAll(Map<String, dynamic>.from(m));
      }
    } catch (_) {}
    final packed = await JmoeArchive.packDirectory(
      chapterDir: dirPath,
      chapterId: t.chapterId,
      outPath: outPath,
      albumMeta: albumMeta,
      onProgress: (done, total) {
        _packDone.value = done;
        _packTotal.value = total;
      },
    );
    _dismissPackingDialog();
    if (!mounted) return;
    if (packed == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(L.t('shareFailed'))),
      );
      return;
    }
    await ChapterDownloader.shareFile(packed.path);
  }

  void _showPackingDialog() {
    _packDone.value = 0;
    _packTotal.value = 0;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => PopScope(
        canPop: false,
        child: AlertDialog(
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const SizedBox(
                width: 26,
                height: 26,
                child: CircularProgressIndicator(strokeWidth: 2.4),
              ),
              const SizedBox(height: 16),
              Text(
                L.t('packingShare'),
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 14),
              ),
              const SizedBox(height: 8),
              ValueListenableBuilder<int>(
                valueListenable: _packTotal,
                builder: (context, total, _) => total <= 0
                    ? const SizedBox.shrink()
                    : ValueListenableBuilder<int>(
                        valueListenable: _packDone,
                        builder: (context, done, _) => Text(
                          '$done / $total',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
                          ),
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  final _packDone = ValueNotifier<int>(0);
  final _packTotal = ValueNotifier<int>(0);

  void _dismissPackingDialog() {
    if (!mounted) return;
    final nav = Navigator.of(context, rootNavigator: true);
    if (nav.canPop()) nav.pop();
  }

  Future<void> _confirmDelete(DownloadTask t) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(L.t('delete')),
        content: Text(
          L.tp('deleteDownloadConfirm', {
            'name': t.chapterName.isEmpty ? t.albumName : t.chapterName,
          }),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: Text(L.t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: Text(L.t('delete')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ChapterDownloader.deleteBy(t.sourceId, t.chapterId);
    if (!mounted) return;
    setState(() {});
  }
}
