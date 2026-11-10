import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../core/image_cache.dart';
import '../core/jm_protocol.dart';
import '../core/image_scrambler.dart';
import '../core/source.dart';
import '../core/models.dart';
import '../core/jm_source.dart';
import 'zip_packer.dart';
import 'l10n.dart';

class ChapterDownloader {
  static final Map<String, DownloadTask> _tasks = {};

  static DownloadTask? taskOf(String key) => _tasks[key];

  static List<DownloadTask> get allTasks => _tasks.values.toList();

  static int get activeCount => _tasks.values.where((t) => !t.done).length;

  static void clearFinished() {
    _tasks.removeWhere((_, t) => t.done);
  }

  static void pause(String key) {
    _tasks[key]?.paused = true;
  }

  static void resume(String key) {
    final t = _tasks[key];
    if (t == null) return;
    t.paused = false;
    if (!t.done && t.savedPath != null) {
      unawaited(_restartRestored(t));
    }
  }

  static Future<void> _restartRestored(DownloadTask t) async {
    if (t._restarting) return;
    t._restarting = true;
    try {
      final dir = Directory(t.savedPath!);
      final have = <int>{};
      if (await dir.exists()) {
        await for (final f in dir.list()) {
          if (f is! File) continue;
          final stem = f.path.split(Platform.pathSeparator).last.split('.').first;
          final n = int.tryParse(stem);
          if (n != null) have.add(n);
        }
      }
      final comic = Comic(
        id: t.albumId,
        name: t.albumName,
        author: '',
        image: t.coverUrl ?? '',
        source: t.sourceId,
      );
      final chapter = Chapter(
        id: t.chapterId,
        name: t.chapterName,
        sort: 1,
      );
      final source = JmSource.instance;
      final bundle = await source.read(comic, chapter);
      if (bundle.length == 0) {
        t.error = 'no images';
        t.done = true;
        return;
      }
      start(
        source: source,
        albumName: t.albumName,
        bundle: bundle,
        albumId: t.albumId,
        chapterName: t.chapterName,
        coverUrl: t.coverUrl,
      );
      t.completed = have.length;
    } catch (e) {
      t.error = '$e';
    } finally {
      t._restarting = false;
    }
  }

  static Future<void> restoreFromDisk() async {
    try {
      final base = await getExternalStorageDirectory() ??
          await getApplicationDocumentsDirectory();
      final root = Directory('${base.path}/JMoe');
      if (!await root.exists()) return;

      await for (final albumDir in root.list()) {
        if (albumDir is! Directory) continue;
        final albumName = albumDir.path.split(Platform.pathSeparator).last;
        if (albumName == 'backup' ||
            albumName == 'imported' ||
            albumName == 'bg') {
          continue;
        }
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

            var onDisk = 0;
            await for (final f in chDir.list()) {
              if (f is! File) continue;
              final name = f.path.split(Platform.pathSeparator).last;
              final stem = name.split('.').first;
              if (int.tryParse(stem) != null) onDisk++;
            }
            if (total > 0 && onDisk > total) onDisk = total;
            final finished = total > 0 && onDisk >= total;

            final t = DownloadTask(total: total)
              ..sourceId = source
              ..albumId = '${m['albumId'] ?? ''}'
              ..chapterId = chapterId
              ..albumName = '${m['albumName'] ?? ''}'
              ..chapterName = '${m['chapterName'] ?? ''}'
              ..coverUrl = m['coverPath'] != null
                  ? 'file://${m['coverPath']}'
                  : (m['coverUrl'] as String?)
              ..completed = onDisk
              ..paused = !finished
              ..done = finished
              ..finishedAt = finished
                  ? (m['downloadedAt'] as num?)?.toInt()
                  : null
              ..savedPath = chDir.path;
            _tasks[key] = t;
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  static Future<void> deleteTask(String key) async {
    final t = _tasks.remove(key);
    if (t?.savedPath == null) return;
    try {
      final d = Directory(t!.savedPath!);
      if (await d.exists()) await d.delete(recursive: true);
    } catch (_) {}
  }

  static Future<({
    String dir,
    String chapterName,
    List<String> files,
  })?> localPages(String sourceId, String chapterId) async {
    final t = _tasks['$sourceId:$chapterId'];
    final path = t?.savedPath;
    if (path == null) return null;
    try {
      final lower = path.toLowerCase();
      if (lower.endsWith('.zip') || lower.endsWith('.jmoe')) {
        final f = File(path);
        if (!await f.exists()) return null;
        return (
          dir: path,
          chapterName: t!.chapterName,
          files: const <String>[],
        );
      }
      final d = Directory(path);
      if (!await d.exists()) return null;
      final files = <String>[];
      for (final e in d.listSync()) {
        if (e is! File) continue;
        final p = e.path.toLowerCase();
        if (p.endsWith('cover.jpg') || p.endsWith('meta.json')) continue;
        if (p.endsWith('.png') ||
            p.endsWith('.jpg') ||
            p.endsWith('.jpeg') ||
            p.endsWith('.webp')) {
          files.add(e.path);
        }
      }
      files.sort();
      if (files.isEmpty) return null;
      return (
        dir: path,
        chapterName: t!.chapterName,
        files: files,
      );
    } catch (_) {
      return null;
    }
  }

  static bool isPacked(String sourceId, String chapterId) {
    final p = _tasks['$sourceId:$chapterId']?.savedPath;
    return p != null && p.toLowerCase().endsWith('.jmoe');
  }

  static Future<void> deleteBy(String sourceId, String chapterId) =>
      deleteTask('$sourceId:$chapterId');

  static void cancel(String key) {
    _tasks[key]?.cancelled = true;
  }

  static DownloadTask start({
    required ComicSource source,
    required String albumName,
    required ReadBundle bundle,
    required String albumId,
    String chapterName = '',
    String? coverUrl,
    Map<String, dynamic>? albumExtra,
  }) {
    final key = '${source.id}:${bundle.chapterId}';
    final existing = _tasks[key];
    if (existing != null && !existing.done) return existing;

    final task = DownloadTask(total: bundle.length)
      ..sourceId = source.id
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
        final albumDir = Directory('${base.path}/JMoe/$safeAlbum');
        final dir = Directory('${albumDir.path}/$safeChapter');
        if (!dir.existsSync()) dir.createSync(recursive: true);

        try {
          final albumMeta = File('${albumDir.path}/album.json');
          if (!albumMeta.existsSync()) {
            String? albumCover;
            if (coverUrl != null && coverUrl.isNotEmpty) {
              final cb = await JmApi.instance.fetchBytes(coverUrl);
              if (cb != null && cb.isNotEmpty) {
                final cf = File('${albumDir.path}/cover.jpg');
                await cf.writeAsBytes(cb, flush: true);
                albumCover = 'cover.jpg';
              }
            }
            await albumMeta.writeAsString(
              jsonEncode({
                'albumId': albumId,
                'albumName': albumName,
                'source': source.id,
                'coverFile': albumCover,
                'coverUrl': coverUrl,
                if (albumExtra != null) ...albumExtra,
                'createdAt': DateTime.now().millisecondsSinceEpoch,
              }),
              flush: true,
            );
          }
        } catch (_) {}

        try {
          final meta = {
            'albumId': albumId,
            'albumName': albumName,
            'chapterId': bundle.chapterId,
            'chapterName': chapterName.isNotEmpty
                ? chapterName
                : bundle.chapterName,
            'source': source.id,
            'total': bundle.length,
            'coverUrl': coverUrl,
            'downloadedAt': DateTime.now().millisecondsSinceEpoch,
          };
          await File('${dir.path}/meta.json')
              .writeAsString(jsonEncode(meta), flush: true);
        } catch (_) {}

        final existing = <int>{};
        try {
          for (final f in dir.listSync()) {
            if (f is! File) continue;
            final name = f.uri.pathSegments.last;
            final base = name.split('.').first;
            final n = int.tryParse(base);
            if (n != null) existing.add(n);
          }
        } catch (_) {}
        if (existing.isNotEmpty) task.completed = existing.length;

        final workers = task.concurrency.clamp(1, 6);
        var cursor = 0;

        Future<void> worker() async {
          while (true) {
            if (task.cancelled) return;
            while (task.paused && !task.cancelled) {
              await Future<void>.delayed(const Duration(milliseconds: 200));
            }
            if (task.cancelled) return;
            final i = cursor++;
            if (i >= bundle.length) return;

            final ref = bundle.pages[i];
            if (existing.contains(ref.index)) continue;

            var url = ref.directUrl;
            if (url == null && ref.resolveUrl != null) {
              url = await source.resolvePageUrl(ref.resolveUrl!);
            }
            if (url == null) continue;

            Uint8List? bytes;
            for (var attempt = 0; attempt < 3; attempt++) {
              if (task.cancelled) return;
              bytes = await ImageCacheManager.instance.load(
                url,
                fetcher: (u) => JmApi.instance.fetchBytes(u),
              );
              if (bytes != null) break;
              await Future<void>.delayed(
                Duration(milliseconds: 300 * (1 << attempt)),
              );
            }
            if (bytes == null) {
              task.failed++;
              continue;
            }

            var out = bytes;
            final sid = bundle.scrambleId;
            if (sid != null &&
                ImageScrambler.needScramble(albumId, sid, url)) {
              final key2 = ImageScrambler.pageKeyFromUrl(url, ref.index);
              final seg = ImageScrambler.segments(albumId, key2);
              out = await _unscramble(bytes, seg);
            }
            final file = File(
              '${dir.path}/${ref.index.toString().padLeft(3, '0')}.png',
            );
            await file.writeAsBytes(out);
            task.completed++;
          }
        }

        await Future.wait(List.generate(workers, (_) => worker()));
        if (task.failed > 0) {
          task.error = '${task.failed} pages failed';
        }
        task.done = task.failed == 0;
        if (task.done) task.finishedAt = DateTime.now().millisecondsSinceEpoch;
        task.savedPath = dir.path;
        final cf = File('${albumDir.path}/cover.jpg');
        if (cf.existsSync()) task.coverPath = cf.path;

        if (task.done) {
          await packCompleted(task, dir, albumDir);
        }
      } catch (e) {
        task.error = '$e';
        task.done = true;
      }
    });

    return task;
  }

  static Future<void> packCompleted(
    DownloadTask task,
    Directory chapterDir,
    Directory albumDir,
  ) async {
    try {
      final name = _sanitize(
        task.chapterName.isEmpty ? task.albumName : task.chapterName,
      );
      if (name.isEmpty) return;
      final outPath = '${albumDir.path}/$name.zip';

      final packed = await ZipPacker.instance.pack(
        dirPath: chapterDir.path,
        outPath: outPath,
      );
      if (packed == null) return;

      try {
        if (chapterDir.existsSync()) chapterDir.deleteSync(recursive: true);
      } catch (_) {}
      task.savedPath = packed.path;
      task.packedPath = packed.path;
    } catch (_) {
    }
  }

  static String _sanitize(String s) =>
      s.replaceAll(RegExp(r'[\\/:*?"<>|\n\r\t]'), '_').trim();

  static Future<bool> openFolder(String dirPath) async {
    try {
      final ok = await _launch(dirPath, mime: 'resource/folder');
      if (ok) return true;
      final parent = File(dirPath).parent.path;
      return await _launch(parent, mime: 'resource/folder');
    } catch (_) {
      return false;
    }
  }

  static Future<bool> _launch(String path, {String? mime}) async {
    try {
      final uri = Uri.file(path);
      await _channel.invokeMethod('openPath', {
        'path': uri.toFilePath(),
        if (mime != null) 'mime': mime,
      });
      return true;
    } catch (_) {
      return false;
    }
  }

  static const _channel = MethodChannel('jmoe/reader');

  static Future<bool> shareFile(String path) async {
    try {
      final f = File(path);
      if (!await f.exists()) return false;
      await _channel.invokeMethod('shareFiles', {
        'paths': [path],
      });
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> shareFiles(String dirPath) async {
    try {
      final d = Directory(dirPath);
      if (!await d.exists()) return false;
      final files = d
          .listSync()
          .whereType<File>()
          .map((f) => f.path)
          .where((p) => !p.endsWith('meta.json'))
          .toList();
      if (files.isEmpty) return false;
      await _channel.invokeMethod('shareFiles', {'paths': files});
      return true;
    } catch (_) {
      return false;
    }
  }

  static int sizeOfDir(String dirPath) {
    try {
      final d = Directory(dirPath);
      if (!d.existsSync()) return 0;
      var total = 0;
      for (final f in d.listSync()) {
        if (f is File) total += f.lengthSync();
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  static int totalDownloadBytes() {
    var total = 0;
    for (final t in _tasks.values) {
      final p = t.savedPath;
      if (p != null) total += sizeOfDir(p);
    }
    return total;
  }

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

  bool paused = false;
  String? error;
  String? savedPath;

  String? packedPath;

  String albumName = '';
  String chapterName = '';
  String albumId = '';

  String sourceId = 'jm';
  String chapterId = '';
  String? coverUrl;

  String? coverPath;

  int concurrency = 3;

  int failed = 0;

  final int startedAt = DateTime.now().millisecondsSinceEpoch;

  int? finishedAt;

  bool _restarting = false;

  DownloadTask({required this.total});

  double get progress => total == 0 ? 0 : completed / total;

  bool get partiallyFailed => failed > 0;
}

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
