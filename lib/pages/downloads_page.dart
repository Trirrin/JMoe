import 'dart:async';

import 'package:flutter/material.dart';

import '../core/app_theme.dart';
import '../core/downloader.dart';
import '../core/l10n.dart';

/// 我的下载：实时显示每个章节的下载进度、状态与操作。
class DownloadsPage extends StatefulWidget {
  const DownloadsPage({super.key});

  @override
  State<DownloadsPage> createState() => _DownloadsPageState();
}

class _DownloadsPageState extends State<DownloadsPage> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    // 400ms 刷新一次进度（简单可靠，且开销可忽略）
    _ticker = Timer.periodic(const Duration(milliseconds: 400), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tasks = ChapterDownloader.allTasks
      ..sort((a, b) {
        // 未完成的优先，其次按完成时间倒序
        if (a.done != b.done) return a.done ? 1 : -1;
        return 0;
      });
    final active = tasks.where((t) => !t.done).length;

    return Scaffold(
      appBar: AppBar(
        title: Text(L.t('myDownloads')),
        actions: [
          if (tasks.any((t) => t.done))
            IconButton(
              tooltip: L.t('clear'),
              icon: const Icon(Icons.cleaning_services_outlined),
              onPressed: () {
                ChapterDownloader.clearFinished();
                setState(() {});
              },
            ),
        ],
      ),
      body: tasks.isEmpty
          ? _buildEmpty(theme)
          : Column(
              children: [
                if (active > 0)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    color: scheme.primaryContainer.withValues(alpha: 0.5),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: scheme.primary,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          L.tp('downloadingN', {'n': active}),
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: scheme.onPrimaryContainer,
                          ),
                        ),
                      ],
                    ),
                  ),
                Expanded(
                  child: ListView.separated(
                    padding: const EdgeInsets.all(AppStyle.pagePadding),
                    itemCount: tasks.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, i) => _buildTask(theme, tasks[i]),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _buildEmpty(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.download_outlined,
            size: 54,
            color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
          ),
          const SizedBox(height: 12),
          Text(
            L.t('noDownloadTasks'),
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              height: 1.6,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTask(ThemeData theme, DownloadTask t) {
    final scheme = theme.colorScheme;
    final pct = t.total <= 0 ? 0.0 : t.completed / t.total;
    final cover = t.coverUrl;

    return Card(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 封面
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                width: 46,
                height: 62,
                child: cover == null || cover.isEmpty
                    ? Container(color: scheme.surfaceContainerHighest)
                    : Image.network(
                        cover,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => Container(
                          color: scheme.surfaceContainerHighest,
                        ),
                      ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    t.albumName.isEmpty ? L.t('downloads') : t.albumName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    t.chapterName.isEmpty ? '-' : t.chapterName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 6),
                  // 进度条
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: t.done ? 1.0 : pct,
                      minHeight: 4,
                      backgroundColor: scheme.surfaceContainerHighest,
                      valueColor: AlwaysStoppedAnimation(
                        t.error != null ? scheme.error : scheme.primary,
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Text(
                        t.error != null
                            ? L.tp('downloadFailedWith', {'e': t.error!})
                            : t.paused
                                ? L.t('paused')
                                : '${t.completed}/${t.total}'
                                    '  ·  ${(pct * 100).toStringAsFixed(0)}%',
                        style: TextStyle(
                          fontSize: 10.5,
                          color: t.error != null
                              ? scheme.error
                              : t.paused
                                  ? scheme.primary
                                  : scheme.onSurfaceVariant,
                        ),
                      ),
                      const Spacer(),
                      if (!t.done)
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // 暂停 / 继续
                            TextButton(
                              onPressed: () {
                                final key =
                                    '${t.albumId}:${t.chapterId}';
                                if (t.paused) {
                                  ChapterDownloader.resume(key);
                                } else {
                                  ChapterDownloader.pause(key);
                                }
                                setState(() {});
                              },
                              style: TextButton.styleFrom(
                                minimumSize: const Size(0, 28),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 6),
                              ),
                              child: Icon(
                                t.paused
                                    ? Icons.play_arrow_rounded
                                    : Icons.pause_rounded,
                                size: 16,
                              ),
                            ),
                            // 取消
                            TextButton(
                              onPressed: () {
                                ChapterDownloader.cancel(
                                  '${t.albumId}:${t.chapterId}',
                                );
                                setState(() {});
                              },
                              style: TextButton.styleFrom(
                                minimumSize: const Size(0, 28),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 6),
                              ),
                              child: Text(
                                L.t('cancel'),
                                style: const TextStyle(fontSize: 11),
                              ),
                            ),
                          ],
                        )
                      else if (t.savedPath != null)
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.check_circle_rounded,
                                size: 13, color: scheme.primary),
                            const SizedBox(width: 3),
                            Text(
                              L.t('downloadDone'),
                              style: TextStyle(
                                fontSize: 10.5,
                                color: scheme.primary,
                              ),
                            ),
                          ],
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
