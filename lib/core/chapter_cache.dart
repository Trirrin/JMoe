import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'image_cache.dart';
import 'image_worker.dart';
import 'cache_manager.dart';
import 'models.dart';
import 'image_scrambler.dart';
import 'jm_protocol.dart';
import 'source.dart';
import 'temp_store.dart';

class ChapterCacheManager {
  ChapterCacheManager._() {
    TempStore.instance.isBusy = (dir) => _tasks.values.any(
          (t) => t.tempDir == dir && t.isActive,
        );
  }
  static final ChapterCacheManager instance = ChapterCacheManager._();

  final Map<String, ChapterCacheTask> _tasks = {};

  final ValueNotifier<int> revision = ValueNotifier(0);

  static String keyOf(String sourceId, String chapterId) =>
      '$sourceId:$chapterId';

  ChapterCacheTask? task(String sourceId, String chapterId) =>
      _tasks[keyOf(sourceId, chapterId)];

  bool isComplete(String sourceId, String chapterId) {
    final t = task(sourceId, chapterId);
    return t != null && t.status == CacheStatus.completed;
  }

  ChapterCacheTask start({
    required ComicSource source,
    required Comic comic,
    required ReadBundle bundle,
    int concurrency = 4,
    bool skipIfCached = false,
    bool persistToDisk = false,
    int startPage = 1,
    int? decodeWidth,
  }) {
    final key = keyOf(source.id, bundle.chapterId);
    final existing = _tasks[key];
    if (existing != null && existing.isActive) return existing;
    if (existing != null && existing.status == CacheStatus.completed) {
      return existing;
    }

    final task = ChapterCacheTask(
      key: key,
      total: bundle.length,
      source: source,
      comic: comic,
      bundle: bundle,
    );
    task.decodeWidth = decodeWidth;
    task.spill = bundle.length >= TempStore.spillPageCount;
    if (task.spill) task.tempDirReady = _prepareTemp(task);
    if (skipIfCached) {
      task.status = CacheStatus.completed;
      task.done = task.total;
      task.readyCount = task.total;
      for (var i = 0; i < task.doneFlags.length; i++) {
        task.doneFlags[i] = true;
      }
      task.persistToDisk = persistToDisk;
    task.startPage = (startPage - 1).clamp(0, task.total - 1);
    _tasks[key] = task;
      _notify();
      return task;
    }
    _tasks[key] = task;
    unawaited(_run(task, concurrency));
    return task;
  }

  Future<void> _persistAfterComplete(ChapterCacheTask task) async {
    try {
      for (var i = 0; i < task.bundle.length; i++) {
        if (task.status == CacheStatus.cancelled) return;
        final ref = task.bundle.pages[i];
        var url = ref.directUrl;
        if (url == null && ref.resolveUrl != null) {
          url = await task.source.resolvePageUrl(ref.resolveUrl!);
        }
        if (url == null || url.isEmpty) continue;
        final mem = ImageCacheManager.instance.readSync(url);
        if (mem == null) continue;
        await ImageCacheManager.instance.persistBytes(url, mem);
      }
    } catch (_) {}
  }

  Future<void> _prepareTemp(ChapterCacheTask task) async {
    try {
      task.tempDir = await TempStore.instance.dirFor(
        task.source.id,
        task.bundle.chapterId,
      );
    } catch (_) {
      task.spill = false;
    }
    _notify();
  }

  Future<void> _run(ChapterCacheTask task, int concurrency) async {
    task.status = CacheStatus.running;
    _notify();

    final bundle = task.bundle;
    final sid = bundle.scrambleId;

    if (task.tempDirReady != null) await task.tempDirReady;

    final order = <int>[];
    {
      final n = bundle.length;
      final c = task.startPage.clamp(0, n - 1);
      order.add(c);
      for (var d = 1; d < n; d++) {
        final hi = c + d;
        final lo = c - d;
        if (hi < n) order.add(hi);
        if (lo >= 0) order.add(lo);
        if (order.length >= n) break;
      }
    }
    var cursor = 0;

    Future<void> worker() async {
      while (true) {
        if (task.status == CacheStatus.cancelled) return;
        if (cursor >= order.length) return;
        final i = order[cursor++];
        if (task.doneFlags[i]) {
          task.done++;
          _notify();
          continue;
        }

        final ref = bundle.pages[i];
        try {
          var url = ref.directUrl;
          if (url == null && ref.resolveUrl != null) {
            url = await task.source.resolvePageUrl(ref.resolveUrl!);
          }
          if (url != null && url.isNotEmpty) {
            if (ImageCacheManager.instance.getUiSync(url) != null) {
              task.doneFlags[i] = true;
              task.done++;
              _notify();
              continue;
            }
            Future<Uint8List?> fetcher(String u) => JmApi.instance.fetchBytes(
                  u,
                  referer:
                      task.source.id == 'ehentai' ? ref.resolveUrl : null,
                );
            final tempDir = task.tempDir;
            if (task.spill && tempDir != null) {
              if (!TempStore.instance.has(tempDir, ref.index)) {
                var sb = await ImageCacheManager.instance.readDiskOnly(url);
                sb ??= await fetcher(url);
                if (sb != null) {
                  var sdata = sb;
                  if (sid != null &&
                      ImageScrambler.needScramble(
                        bundle.scrambleAid,
                        sid,
                        url,
                      )) {
                    final pk = ImageScrambler.pageKeyFromUrl(url, ref.index);
                    final seg =
                        ImageScrambler.segments(bundle.scrambleAid, pk);
                    final jpg = await ImageWorker.instance.unscrambleToJpeg(
                      bytes: sb,
                      segments: seg,
                      maxWidth: task.decodeWidth,
                    );
                    if (jpg != null) sdata = jpg;
                  }
                  await TempStore.instance.put(
                    tempDir,
                    ref.index,
                    sdata,
                    sourceId: task.source.id,
                    chapterId: bundle.chapterId,
                  );
                }
              }
              task.doneFlags[i] = TempStore.instance.has(tempDir, ref.index);
              task.done++;
              task.readyCount = task.doneFlags.where((e) => e).length;
              _notify();
              continue;
            }

            final bytes = task.persistToDisk
                ? await ImageCacheManager.instance.loadForDownload(
                    url,
                    fetcher: fetcher,
                  )
                : await ImageCacheManager.instance.load(
                    url,
                    fetcher: fetcher,
                  );
            if (bytes != null) {
              var data = bytes;
              final needScramble = sid != null &&
                  ImageScrambler.needScramble(
                    bundle.scrambleAid,
                    sid,
                    url,
                  );
              int seg = 1;
              if (needScramble) {
                final pk = ImageScrambler.pageKeyFromUrl(url, ref.index);
                seg = ImageScrambler.segments(bundle.scrambleAid, pk);
              }

              if (task.shouldDecodePage(i)) {
                Uint8List? jpg;
                if (needScramble) {
                  jpg = await ImageWorker.instance.unscrambleToJpeg(
                    bytes: data,
                    segments: seg,
                    maxWidth: task.decodeWidth,
                    quality: 88,
                  );
                }
                final img = await ImageCacheManager.decodeScaled(
                  jpg ?? data,
                  targetWidth: task.decodeWidth,
                );
                if (img != null) ImageCacheManager.instance.putUi(url, img);
                task.doneFlags[i] = true;
              } else {
                if (needScramble) {
                  final jpg = await ImageWorker.instance.unscrambleToJpeg(
                    bytes: data,
                    segments: seg,
                    maxWidth: task.decodeWidth,
                  );
                  if (jpg != null) data = jpg;
                }
                if (data.length > TempStore.maxSingleImageBytes) {
                  task.tempDir ??= await TempStore.instance
                      .dirFor(task.source.id, bundle.chapterId);
                  await TempStore.instance.put(
                    task.tempDir!,
                    ref.index,
                    data,
                    sourceId: task.source.id,
                    chapterId: bundle.chapterId,
                  );
                }
                task.doneFlags[i] = true;
              }
            }
          }
        } catch (_) {}
        task.done++;
        task.readyCount = task.doneFlags.where((e) => e).length;
      if (!task.persistToDisk &&
          !task.spill &&
          task.readyCount >= task.total &&
          task.total > 0) {
        _persistAfterComplete(task);
      }
        _notify();
      }
    }

    try {
      await Future.wait(
        List.generate(concurrency.clamp(1, 8), (_) => worker()),
      );
      task.readyCount = task.doneFlags.where((e) => e).length;
      task.status = task.cancelledFlag
          ? CacheStatus.cancelled
          : CacheStatus.completed;
      if (task.status == CacheStatus.completed && task.readyCount > 0) {
        final urls = <String>[];
        for (final p in bundle.pages) {
          final u = p.directUrl ?? p.resolveUrl;
          if (u != null && u.isNotEmpty) urls.add(u);
        }
        unawaited(CacheManager.instance.markChapter(
          sourceId: task.source.id,
          comicId: task.comic.id,
          chapterId: bundle.chapterId,
          comicName: task.comic.name,
          chapterName: bundle.chapterName,
          cover: task.source.coverOf(task.comic),
          total: task.total,
          imageUrls: urls,
        ));
      }
    } catch (_) {
      task.status = CacheStatus.failed;
    }
    _notify();
  }

  void cancelTask(String sourceId, String chapterId) {
    final k = keyOf(sourceId, chapterId);
    _tasks[k]?.cancel();
    _tasks.remove(k);
    _notify();
  }

  void cancel(String sourceId, String chapterId) {
    final t = task(sourceId, chapterId);
    t?.cancel();
    _notify();
  }

  void _notify() => revision.value++;

  static Future<ui.Image?> unscrambleToImage(
    Uint8List bytes,
    int segments, {
    int? targetWidth,
  }) async {
    final src = await ImageCacheManager.decodeScaled(
      bytes,
      targetWidth: targetWidth,
    );
    if (src == null) return null;
    if (segments <= 1) return src;

    final w = src.width;
    final h = src.height;
    if (h < segments) {
      return src;
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
    final picture = recorder.endRecording();
    final out = await picture.toImage(w, h);
    src.dispose();
    picture.dispose();
    return out;
  }

  static Future<Uint8List> unscramble(Uint8List bytes, int segments) async {
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
    final picture = recorder.endRecording();
    final out = await picture.toImage(w, h);
    final data = await out.toByteData(format: ui.ImageByteFormat.png);
    src.dispose();
    out.dispose();
    picture.dispose();
    return data?.buffer.asUint8List() ?? bytes;
  }
}

enum CacheStatus { idle, running, completed, cancelled, failed }

class ChapterCacheTask {
  final String key;
  final int total;
  final ComicSource source;
  final Comic comic;
  final ReadBundle bundle;

  ChapterCacheTask({
    required this.key,
    required this.total,
    required this.source,
    required this.comic,
    required this.bundle,
  }) : doneFlags = List<bool>.filled(total, false);

  CacheStatus status = CacheStatus.idle;
  int done = 0;
  int readyCount = 0;
  bool cancelledFlag = false;
  final List<bool> doneFlags;

  bool persistToDisk = false;

  static const int decodeRadius = 8;

  static const int decodeAhead = 4;

  int? decodeWidth;

  bool shouldDecodePage(int index) {
    if (persistToDisk) return true;
    final d = index - startPage;
    final limit = d >= 0 ? decodeRadius * decodeAhead : decodeRadius;
    return d.abs() <= limit;
  }

  String? tempDir;

  bool spill = false;

  Future<void>? tempDirReady;

  int startPage = 0;

  bool get isActive =>
      status == CacheStatus.running || status == CacheStatus.idle;
  bool get isCompleted => status == CacheStatus.completed;

  double get progress => total == 0 ? 0 : (done / total).clamp(0.0, 1.0);

  int get readyOrDone => readyCount > 0 ? readyCount : done;

  void cancel() {
    cancelledFlag = true;
    status = CacheStatus.cancelled;
  }
}
