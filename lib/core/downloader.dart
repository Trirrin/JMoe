import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../core/image_cache.dart';
import '../core/jm_protocol.dart';
import '../core/image_scrambler.dart';
import '../core/source.dart';
import 'l10n.dart';

/// 批量下载整章：并发抓取 + 还原 + 写入相册目录，带进度与取消。
class ChapterDownloader {
  static final Map<String, DownloadTask> _tasks = {};

  static DownloadTask? taskOf(String key) => _tasks[key];

  /// 所有下载任务（含已完成），供「我的下载」页展示。
  static List<DownloadTask> get allTasks => _tasks.values.toList();

  /// 正在下载的任务数。
  static int get activeCount => _tasks.values.where((t) => !t.done).length;

  /// 清空已完成的任务记录。
  static void clearFinished() {
    _tasks.removeWhere((_, t) => t.done);
  }

  /// 暂停任务。
  static void pause(String key) {
    _tasks[key]?.paused = true;
  }

  /// 继续任务。
  static void resume(String key) {
    _tasks[key]?.paused = false;
  }


  /// 从磁盘恢复已下载记录（App 启动时调用一次）。
  ///
  /// 扫描 `JMoe/<作品>/<章节>/meta.json`，重建 _tasks，
  /// 这样重启后「我的下载」仍能看到历史记录。
  static Future<void> restoreFromDisk() async {
    try {
      final base = await getExternalStorageDirectory() ??
          await getApplicationDocumentsDirectory();
      final root = Directory('${base.path}/JMoe');
      if (!await root.exists()) return;

      await for (final albumDir in root.list()) {
        if (albumDir is! Directory) continue;
        await for (final chDir in albumDir.list()) {
          if (chDir is! Directory) continue;
          final metaFile = File('${chDir.path}/meta.json');
          if (!await metaFile.exists()) continue;
          try {
            final m = jsonDecode(await metaFile.readAsString())
                as Map<String, dynamic>;
            final source = '${m['source'] ?? 'jm'}';
            final chapterId = '${m['chapterId'] ?? ''}';
            final total = (m['total'] as num?)?.toInt() ?? 0;
            if (chapterId.isEmpty) continue;

            final key = '$source:$chapterId';
            if (_tasks.containsKey(key)) continue;

            final t = DownloadTask(total: total)
              ..albumId = '${m['albumId'] ?? ''}'
              ..chapterId = chapterId
              ..albumName = '${m['albumName'] ?? ''}'
              ..chapterName = '${m['chapterName'] ?? ''}'
              ..coverUrl = m['coverPath'] != null
                  ? 'file://${m['coverPath']}'
                  : (m['coverUrl'] as String?)
              ..completed = total
              ..done = true
              ..savedPath = chDir.path;
            _tasks[key] = t;
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  static void cancel(String key) {
    _tasks[key]?.cancelled = true;
  }

  /// 开始下载（同名章节重复调用会直接返回已有任务）。
  static DownloadTask start({
    required ComicSource source,
    required String albumName,
    required ReadBundle bundle,
    required String albumId,
    /// 章节标题（用于离线展示）
    String chapterName = '',
    /// 封面地址（随下载一并保存，离线也能显示）
    String? coverUrl,
  }) {
    final key = '${source.id}:${bundle.chapterId}';
    final existing = _tasks[key];
    if (existing != null && !existing.done) return existing;

    final task = DownloadTask(total: bundle.length)
      ..albumId = albumId
      ..chapterId = bundle.chapterId
      ..albumName = albumName
      ..chapterName = chapterName.isNotEmpty
          ? chapterName
          : bundle.chapterName
      ..coverUrl = coverUrl;
    _tasks[key] = task;

    Future(() async {
      try {
        final base = await getExternalStorageDirectory() ??
            await getApplicationDocumentsDirectory();
        final safeAlbum = _sanitize(albumName);
        final safeChapter = _sanitize(
          bundle.chapterName.isEmpty ? bundle.chapterId : bundle.chapterName,
        );
        final dir = Directory('${base.path}/JMoe/$safeAlbum/$safeChapter');
        if (!dir.existsSync()) dir.createSync(recursive: true);

        // ---- 元信息：保证离线时仍有标题 / 封面 / 页数 ----
        try {
          // 封面随下载一并保存，离线也能显示
          String? coverPath;
          if (coverUrl != null && coverUrl.isNotEmpty) {
            final cb = await JmApi.instance.fetchBytes(coverUrl);
            if (cb != null && cb.isNotEmpty) {
              final cf = File('${dir.path}/cover.jpg');
              await cf.writeAsBytes(cb, flush: true);
              coverPath = cf.path;
            }
          }
          final meta = {
            'albumId': albumId,
            'albumName': albumName,
            'chapterId': bundle.chapterId,
            'chapterName': chapterName.isNotEmpty
                ? chapterName
                : bundle.chapterName,
            'source': source.id,
            'total': bundle.length,
            'coverPath': coverPath,
            'coverUrl': coverUrl,
            'downloadedAt': DateTime.now().millisecondsSinceEpoch,
          };
          await File('${dir.path}/meta.json')
              .writeAsString(jsonEncode(meta), flush: true);
        } catch (_) {}

        for (var i = 0; i < bundle.length; i++) {
          if (task.cancelled) break;
          // 暂停：等待恢复（可被取消打断）
          while (task.paused && !task.cancelled) {
            await Future<void>.delayed(const Duration(milliseconds: 200));
          }
          if (task.cancelled) break;
          final ref = bundle.pages[i];
          var url = ref.directUrl;
          if (url == null && ref.resolveUrl != null) {
            url = await source.resolvePageUrl(ref.resolveUrl!);
          }
          if (url == null) continue;

          final bytes = await ImageCacheManager.instance.load(
            url,
            fetcher: (u) => JmApi.instance.fetchBytes(u),
          );
          if (bytes == null || task.cancelled) continue;

          var out = bytes;
          final sid = bundle.scrambleId;
          if (sid != null && ImageScrambler.needScramble(albumId, sid, url)) {
            final key2 = ImageScrambler.pageKeyFromUrl(url, ref.index);
            final seg = ImageScrambler.segments(albumId, key2);
            out = await _unscramble(bytes, seg);
          }
          final file = File(
            '${dir.path}/${ref.index.toString().padLeft(3, '0')}.png',
          );
          await file.writeAsBytes(out);
          task.completed = i + 1;
        }
        task.done = true;
        task.savedPath = dir.path;
      } catch (e) {
        task.error = '$e';
        task.done = true;
      }
    });

    return task;
  }

  static String _sanitize(String s) =>
      s.replaceAll(RegExp(r'[\\/:*?"<>|\n\r\t]'), '_').trim();

  static Future<Uint8List> _unscramble(Uint8List bytes, int segments) async {
    if (segments <= 1) return bytes;
    final src = await ImageCacheManager.decode(bytes);
    if (src == null) return bytes;
    final w = src.width;
    final h = src.height;
    if (h < segments) {
      src.dispose();
      return bytes;
    }
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final rem = h % segments;
    final baseH = h ~/ segments;
    for (var i = 0; i < segments; i++) {
      var ch = baseH;
      var py = baseH * i;
      final y = h - baseH * (i + 1) - rem;
      if (i == 0) {
        ch += rem;
      } else {
        py += rem;
      }
      canvas.drawImageRect(
        src,
        Rect.fromLTWH(0, y.toDouble(), w.toDouble(), ch.toDouble()),
        Rect.fromLTWH(0, py.toDouble(), w.toDouble(), ch.toDouble()),
        Paint()..filterQuality = FilterQuality.medium,
      );
    }
    final pic = recorder.endRecording();
    final out = await pic.toImage(w, h);
    final data = await out.toByteData(format: ui.ImageByteFormat.png);
    src.dispose();
    out.dispose();
    pic.dispose();
    return data?.buffer.asUint8List() ?? bytes;
  }
}

class DownloadTask {
  final int total;
  int completed = 0;
  bool done = false;
  bool cancelled = false;

  /// 是否暂停（暂停时保留进度，可继续）
  bool paused = false;
  String? error;
  String? savedPath;

  /// 展示用元信息
  String albumName = '';
  String chapterName = '';
  String albumId = '';
  String chapterId = '';
  String? coverUrl;


  DownloadTask({required this.total});

  double get progress => total == 0 ? 0 : completed / total;
}

/// 下载进度弹层。
class DownloadProgressSheet extends StatefulWidget {
  final DownloadTask task;
  final String title;

  const DownloadProgressSheet({
    super.key,
    required this.task,
    required this.title,
  });

  @override
  State<DownloadProgressSheet> createState() => _DownloadProgressSheetState();
}

class _DownloadProgressSheetState extends State<DownloadProgressSheet> {
  @override
  Widget build(BuildContext context) {
    return StatefulBuilder(
      builder: (context, setSheetState) {
        // 轮询刷新（简单可靠）
        Future.delayed(const Duration(milliseconds: 400), () {
          if (mounted && !widget.task.done) setSheetState(() {});
        });
        final t = widget.task;
        return Padding(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 20,
            bottom: MediaQuery.of(context).padding.bottom + 20,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                t.done
                    ? (t.error != null ? L.t('downloadFailed') : L.t('downloadDone'))
                    : L.t('downloading'),
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                widget.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 16),
              LinearProgressIndicator(value: t.progress),
              const SizedBox(height: 8),
              Text(
                t.error != null
                    ? t.error!
                    : t.done
                        ? (t.savedPath ?? '')
                        : L.tp('pagesProgress', {'done': t.completed, 'total': t.total}),
                style: const TextStyle(fontSize: 11),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  if (!t.done)
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () {
                          t.cancelled = true;
                          Navigator.pop(context);
                        },
                        child: Text(L.t('cancel')),
                      ),
                    ),
                  if (!t.done) const SizedBox(width: 10),
                  if (t.done)
                    Expanded(
                      child: FilledButton(
                        onPressed: () => Navigator.pop(context),
                        child: Text(L.t('done')),
                      ),
                    ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 长按图片保存到相册。
Future<String?> saveImageToGallery(Uint8List bytes, String name) async {
  try {
    final base = await getExternalStorageDirectory() ??
        await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/JMoe/${L.t('saveDir')}');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final f = File('${dir.path}/$name.png');
    await f.writeAsBytes(bytes);
    HapticFeedback.mediumImpact();
    return f.path;
  } catch (_) {
    return null;
  }
}
