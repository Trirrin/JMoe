import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../core/app_theme.dart';
import '../core/downloader.dart';
import '../core/jmoe_archive.dart';
import '../core/l10n.dart';
import '../core/app_state.dart';
import '../core/jm_source.dart';
import '../core/models.dart';
import 'unified_reader_page.dart';

/// 下载列表的排序方式。
enum DownloadSort {
  /// 默认：按名称（作品名 → 章节名）
  name,

  /// 按下载时间（最新在前）
  time,
}

/// 我的下载：三个板块**始终显示**（下载中 / 暂停中 / 已完成），
/// 有任务时标题带数量 `下载中 (3)`，没有任务时不带括号。
///
/// 顶部有一行引导，告诉用户「点章节进去看离线」——
/// 之前没有任何提示，用户不知道点了会怎样。
class DownloadsPage extends StatefulWidget {
  const DownloadsPage({super.key});

  @override
  State<DownloadsPage> createState() => _DownloadsPageState();
}

class _DownloadsPageState extends State<DownloadsPage> {
  Timer? _ticker;

  /// 排序方式：
  ///  * [DownloadSort.name] 默认，按名称排序（作品与选集都按名称）
  ///  * [DownloadSort.time] 按下载时间排序（作品与选集都用下载时间）
  DownloadSort _sort = DownloadSort.name;

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

  /// 按当前排序规则整理列表。
  ///
  ///  * [DownloadSort.name]（默认）：作品按名称、作品内选集按**原名顺序**
  ///    （第一话 → 最后一话），符合「按名称排序」的直觉
  ///  * [DownloadSort.time]：作品与选集**都按下载时间**倒序
  List<DownloadTask> _sorted(List<DownloadTask> list) {
    final copy = List<DownloadTask>.from(list);
    switch (_sort) {
      case DownloadSort.name:
        copy.sort((a, b) {
          final c = a.albumName.compareTo(b.albumName);
          if (c != 0) return c;
          // 作品内保持默认顺序（章节名自然序，第一话在前）
          return _naturalCompare(a.chapterName, b.chapterName);
        });
      case DownloadSort.time:
        copy.sort((a, b) {
          // 先按作品的整体下载时间（取该作品最新的那次），
          // 再按集次的下载时间，保证「作品与选集都用下载时间」
          final at = a.finishedAt ?? a.startedAt;
          final bt = b.finishedAt ?? b.startedAt;
          final c = bt.compareTo(at);
          if (c != 0) return c;
          return _naturalCompare(a.chapterName, b.chapterName);
        });
    }
    return copy;
  }

  /// 自然序比较：让「第 2 话」排在「第 10 话」前面
  /// （纯字符串比较会把 10 排到 2 前面）。
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

    // 按当前排序规则整理（作品与选集都用同一套规则）
    // 进行中（含暂停）：暂停的任务也放这里，靠行内播放/暂停按钮区分
    final running = _sorted(
      tasks.where((t) => !t.done).toList(),
    );
    final done = _sorted(tasks.where((t) => t.done).toList());

    return Scaffold(
      appBar: AppBar(
        title: Text(L.t('myDownloads')),
        actions: [
          // 排序切换
          PopupMenuButton<DownloadSort>(
            initialValue: _sort,
            tooltip: L.t('sort'),
            icon: const Icon(Icons.sort_rounded),
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
              icon: const Icon(Icons.cleaning_services_outlined),
              onPressed: () => _onClear(theme),
            ),
        ],
      ),
      body: RefreshIndicator(
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
            // ---- 引导：点章节即可离线阅读 ----
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
            // ---- 两个板块：进行中（含暂停） / 已完成 ----
            //
            // 用户要求：不再单独分「暂停中」，暂停的与下载中的放在一起，
            // 靠每行右侧的播放/暂停按钮区分状态即可。
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
      ),
    );
  }

  /// 板块标题：有任务时 `下载中 (3)`，没有任务时只有 `下载中`。
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

  /// 清除任务：**先确认**，并让用户选择是否同时删文件。
  ///
  /// 之前是点一下立刻 clearFinished，既没有确认，也没有任何反馈，
  /// 还会被误认为「文件也删了」。现在：
  ///  * 「清除任务」= 只移除列表记录，磁盘文件保留
  ///  * 勾选「同时删除文件」才会真删
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

    // 收集要处理的已完成任务
    final doneList = ChapterDownloader.allTasks.where((t) => t.done).toList();
    if (alsoDeleteFiles) {
      for (final t in doneList) {
        await ChapterDownloader.deleteBy(t.sourceId, t.chapterId);
      }
    } else {
      // 只清记录：把 savedPath 留下来也没用（记录没了），所以直接清列表
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

  /// 选集行：**点击进入离线阅读**（行尾不再放 ✓ 图标 ——
  /// 选中/未选中已经有左侧状态图标与颜色区分，再加一个勾是重复信息）。
  Widget _buildChapterRow(ThemeData theme, DownloadTask t) {
    final scheme = theme.colorScheme;
    final pct = t.total <= 0 ? 0.0 : t.completed / t.total;
    final canOpen = t.done && t.savedPath != null;

    return InkWell(
      onTap: canOpen
          ? () async {
              // 复用在线阅读器（数据源换成磁盘目录），界面/手势/进度一致。
              // 需要构造一个最小 Comic/Chapter 以复用阅读器，
              // 并用归一化后的 id 读回上次进度。
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

  /// 长按 / 更多：打开目录、分享、删除。
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
              ListTile(
                leading: const Icon(Icons.vpn_key_rounded),
                title: Text(L.t('archivePassword')),
                subtitle: Text(
                  ChapterDownloader.archivePassword,
                  style: const TextStyle(fontSize: 11.5),
                ),
                trailing: IconButton(
                  icon: const Icon(Icons.copy_rounded, size: 16),
                  onPressed: () {
                    // 复制密码到剪贴板
                    ChapterDownloader.copyPassword();
                  },
                ),
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

  /// 把该章打包为 `.jmoe` 并分享。
  ///
  /// 用户要求：下载下来的是无加密包（明文图片目录），
  /// **只有分享**时才生成加密的 `.jmoe`，并且包里带上作品数据，
  /// 这样对方导入后能直接看到详情并阅读。
  Future<void> _shareAsArchive(DownloadTask t) async {
    final dirPath = t.savedPath;
    if (dirPath == null) return;
    // **先给反馈**：打包要逐页加密，大章节需要几秒。
    // 之前没有任何提示，用户以为卡死。
    _showPackingDialog();
    final name = (t.chapterName.isEmpty ? t.albumName : t.chapterName)
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final tmp = Directory('${Directory.systemTemp.path}/jmoe_share');
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

  /// 打包进度对话框（可取消说明：这里只做提示，不能中途取消，
  /// 因为中途取消会留下半个文件；但至少要告诉用户在做什么）。
  void _showPackingDialog() {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => PopScope(
        canPop: false,
        child: AlertDialog(
          content: Row(
            children: [
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 14),
              Expanded(child: Text(L.t('packingShare'))),
            ],
          ),
        ),
      ),
    );
  }

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
