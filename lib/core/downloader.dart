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
  ///
  /// 两种情况：
  ///  * 任务还在内存里（只是被暂停）→ 清 paused 标志，循环自己接着跑
  ///  * 任务是从磁盘恢复的（进程被杀过）→ 没有活的下载循环，
  ///    必须重新登记一次下载，让它从**已有页之后**继续
  static void resume(String key) {
    final t = _tasks[key];
    if (t == null) return;
    t.paused = false;
    // 没有 savedPath 说明从未开始过；有但 completed < total 且没有
    // 活跃循环 —— 用 _restartRestored 重新驱动。
    if (!t.done && t.savedPath != null) {
      unawaited(_restartRestored(t));
    }
  }

  /// 重新驱动一个「从磁盘恢复」的未完成任务。
  ///
  /// 会重新向源请求章节图片地址（页码可能过期），
  /// 然后从磁盘上已有的编号之后开始下载，实现断点续传。
  static Future<void> _restartRestored(DownloadTask t) async {
    if (t._restarting) return;
    t._restarting = true;
    try {
      // 已有页数（用于跳过）
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
      // 需要重新拿到 bundle（页面地址）
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
      // 复用原有下载流程：start 会扫描磁盘跳过已有页
      start(
        source: source,
        albumName: t.albumName,
        bundle: bundle,
        albumId: t.albumId,
        chapterName: t.chapterName,
        coverUrl: t.coverUrl,
      );
      // 把恢复任务的进度对齐到已有页
      t.completed = have.length;
    } catch (e) {
      t.error = '$e';
    } finally {
      t._restarting = false;
    }
  }


  /// 从磁盘恢复已下载记录（App 启动时调用一次）。
  ///
  /// 扫描 `JMoe/<作品>/<章节>/meta.json`，重建 _tasks。
  ///
  /// **关键：未完成的任务也要恢复**（用户要求「杀掉后台还能断点续传」）。
  ///
  /// 之前这里无条件把任务标成 `done = true, completed = total`，
  /// 于是下到一半被系统杀掉后，重启就再也看不到这个任务，
  /// 也无法继续 —— 磁盘上缺的页永远补不回来。
  ///
  /// 现在按「磁盘上实际存在的页数」判断：
  ///  * 页数 = total → 已完成
  ///  * 页数 < total → 未完成，恢复成可继续的任务（保留 savedPath）
  static Future<void> restoreFromDisk() async {
    try {
      final base = await getExternalStorageDirectory() ??
          await getApplicationDocumentsDirectory();
      final root = Directory('${base.path}/JMoe');
      if (!await root.exists()) return;

      await for (final albumDir in root.list()) {
        if (albumDir is! Directory) continue;
        // 跳过非作品目录（如 backup / imported / bg）
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

            // 统计磁盘上实际已下载的页（001.png 这类数字命名文件）
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
              // 未下完 → 保持 paused，让用户手动「继续」，
              // 避免一启动就并发下载一堆任务把网速占满。
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

  /// 删除一个已完成任务：移除记录 + 删除磁盘目录。
  static Future<void> deleteTask(String key) async {
    final t = _tasks.remove(key);
    if (t?.savedPath == null) return;
    try {
      final d = Directory(t!.savedPath!);
      if (await d.exists()) await d.delete(recursive: true);
    } catch (_) {}
  }

  /// 读取某章已下载到本地的页面文件（按 001/002… 顺序）。
  ///
  /// 供阅读器的**离线模式**复用同一套 UI：把本地文件当作页面地址，
  /// 阅读器无需区分「在线 / 离线」两套实现。
  static Future<({
    String dir,
    String chapterName,
    List<String> files,
  })?> localPages(String sourceId, String chapterId) async {
    final t = _tasks['$sourceId:$chapterId'];
    final path = t?.savedPath;
    if (path == null) return null;
    try {
      // 已打包成 zip / .jmoe 单文件 → 返回包路径，files 为空。
      // 阅读时由阅读器从包内按页读取（见 ZipReader）。
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

  /// 某个下载任务是否已经打包成 `.jmoe` 单文件。
  static bool isPacked(String sourceId, String chapterId) {
    final p = _tasks['$sourceId:$chapterId']?.savedPath;
    return p != null && p.toLowerCase().endsWith('.jmoe');
  }

  /// 按数据源 + 章节 id 删除（与 _tasks 的 key 格式一致）。
  static Future<void> deleteBy(String sourceId, String chapterId) =>
      deleteTask('$sourceId:$chapterId');

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
    /// 作品级附加数据（作者 / 简介 / 标签等），写进 album.json。
    /// 多个选集共用同一份，第二次下载不会覆盖。
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
        // 目录结构：JMoe/<作品>/album.json（**作品级，所有选集共用一份**）
        //           JMoe/<作品>/<选集>/001.png …（明文图片 + meta.json）
        final albumDir = Directory('${base.path}/JMoe/$safeAlbum');
        final dir = Directory('${albumDir.path}/$safeChapter');
        if (!dir.existsSync()) dir.createSync(recursive: true);

        // ---- 作品级元信息（多选集共用，只写一次）----
        //
        // 用户明确要求：「下载多个选集就共用一个数据文件」。
        // album.json 里放作品本身的字段（标题/作者/简介/标签/封面），
        // 这样导入后能直接展示详情，而不只是「一堆图片」。
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

        // ---- 选集级元信息 ----
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

        // ---- 断点续传：跳过已存在的页 ----
        // 之前每次「继续」都从第 1 页重下，白费流量。
        // 现在先扫盘，已有的页直接跳过并计入进度。
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

        // 并发下载：单线程时大章节很慢，并发太高又会被图源限速，3 是折中。
        final workers = task.concurrency.clamp(1, 6);
        var cursor = 0;

        Future<void> worker() async {
          while (true) {
            if (task.cancelled) return;
            // 暂停：等待恢复（可被取消打断）
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

            // 单页最多重试 3 次（网络抖动很常见）
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
        // 有页失败则不算完全成功：保留记录以便「继续」重试剩余页
        if (task.failed > 0) {
          task.error = '${task.failed} pages failed';
        }
        task.done = task.failed == 0;
        if (task.done) task.finishedAt = DateTime.now().millisecondsSinceEpoch;
        task.savedPath = dir.path;
        // 封面现在存在**作品级目录**（所有选集共用一张）
        final cf = File('${albumDir.path}/cover.jpg');
        if (cf.existsSync()) task.coverPath = cf.path;

        // **下载完成后自动打包成 .jmoe 单文件**（用户要求：
        // 「下载后应该是个压缩包，而不是一个目录」）。
        //
        // 下载过程仍用目录，因为逐页写入 + 断点续传需要散文件；
        // 全部页就绪后再收拢成一个包并删掉目录 —— 用户看到的就是
        // 一个 .jmoe 文件，而不是一堆散图。
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

  /// 把已完成的下载目录打包成 **无加密 zip**，然后删除目录。
  ///
  /// 用户要求：「在本地存储用 zip 无加密压缩包，分享用 .jmoe」。
  ///
  ///  * 下载过程仍用目录（逐页写入 + 断点续传需要散文件）
  ///  * 全部页就绪后收拢成一个 zip，删掉目录 → 用户看到的是一个
  ///    标准压缩包，可以用任何解压工具打开取出图片
  ///  * 点「分享」时才另外生成 `.jmoe`（加密 + 带元数据）
  ///
  /// 打包在后台 isolate 执行，不卡 UI。
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

      // 打包成功 → 删掉散图目录，并把路径换成 zip
      try {
        if (chapterDir.existsSync()) chapterDir.deleteSync(recursive: true);
      } catch (_) {}
      task.savedPath = packed.path;
      task.packedPath = packed.path;
    } catch (_) {
      // 打包失败就保留目录（内容仍然可读，只是没合成单文件）
    }
  }

  static String _sanitize(String s) =>
      s.replaceAll(RegExp(r'[\\/:*?"<>|\n\r\t]'), '_').trim();

  // ---------------- 离线文件的外围操作 ----------------

  /// 用系统文件管理器打开某章目录。
  static Future<bool> openFolder(String dirPath) async {
    try {
      final ok = await _launch(dirPath, mime: 'resource/folder');
      if (ok) return true;
      // 某些 ROM 不支持文件夹 URI，退化为打开其父目录
      final parent = File(dirPath).parent.path;
      return await _launch(parent, mime: 'resource/folder');
    } catch (_) {
      return false;
    }
  }

  static Future<bool> _launch(String path, {String? mime}) async {
    try {
      final uri = Uri.file(path);
      // 走 MethodChannel 让原生侧起 Intent（flutter 侧直接用 url_launcher
      // 打开 folder:// 在多数 ROM 上无效）
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

  /// 分享**单个文件**（如打包好的 .jmoe）。
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

  /// 分享某章目录下的图片文件（走系统分享面板）。
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

  /// 某章已下载占用的字节数（含压缩包）。
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

  /// 所有下载内容的总占用（字节），供存储管理展示。
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

  /// 是否暂停（暂停时保留进度，可继续）
  bool paused = false;
  String? error;
  String? savedPath;

  /// 打包后的 `.jmoe` 文件路径（下载完成后自动生成）。
  ///
  /// 非空表示这一章已经收拢成单文件、散图目录已删除。
  /// 阅读时由 `localPages` 从这个包直接读。
  String? packedPath;

  /// 展示用元信息
  String albumName = '';
  String chapterName = '';
  String albumId = '';

  /// 数据源 id（jm / ehentai），用于还原任务 key
  String sourceId = 'jm';
  String chapterId = '';
  String? coverUrl;

  /// 本地封面文件路径（下载时一并保存，离线也能显示）
  String? coverPath;

  /// 并发下载条数（1~6，默认 3）。太高会被图源限速，太低慢。
  int concurrency = 3;

  /// 失败页数（有值说明这一章没下全，可「继续」补齐）
  int failed = 0;

  /// 任务创建时间（用于「按下载时间」排序）
  final int startedAt = DateTime.now().millisecondsSinceEpoch;

  /// 完成时间（未完成时为 null）
  int? finishedAt;

  /// 是否正在执行「从磁盘恢复后重启下载」（防重入）
  bool _restarting = false;

  DownloadTask({required this.total});

  double get progress => total == 0 ? 0 : completed / total;

  /// 是否「下完了但缺页」
  bool get partiallyFailed => failed > 0;
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