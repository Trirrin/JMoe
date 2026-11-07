import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'image_cache.dart';
import 'models.dart';
import 'image_scrambler.dart';
import 'jm_protocol.dart';
import 'source.dart';

/// 整章缓存的全局任务管理器。
///
/// 特性：
///  * **以整章为粒度**：一次缓存一整章的所有页
///  * **后台持续**：离开阅读页后任务继续跑，进度保留
///  * **统一进度**：`done/total` + 百分比，供蒙版与顶栏共用
///  * **可取消/可重试**
class ChapterCacheManager {
  ChapterCacheManager._();
  static final ChapterCacheManager instance = ChapterCacheManager._();

  /// 任务表：key = source.id:chapterId
  final Map<String, ChapterCacheTask> _tasks = {};

  /// 进度变化通知（阅读页/缓存面板监听）
  final ValueNotifier<int> revision = ValueNotifier(0);

  static String keyOf(String sourceId, String chapterId) =>
      '$sourceId:$chapterId';

  ChapterCacheTask? task(String sourceId, String chapterId) =>
      _tasks[keyOf(sourceId, chapterId)];

  bool isComplete(String sourceId, String chapterId) {
    final t = task(sourceId, chapterId);
    return t != null && t.status == CacheStatus.completed;
  }

  /// 启动（或复用）整章缓存任务。
  ChapterCacheTask start({
    required ComicSource source,
    required Comic comic,
    required ReadBundle bundle,
    int concurrency = 5,
    bool skipIfCached = false,
    /// 是否把图片写入磁盘（true = 用户主动下载）。
    /// 阅读时「边看边缓存」只进内存，退出即释放。
    bool persistToDisk = false,
    /// 起始页（从 1 开始）。缓存顺序会从这一页向两侧扩散。
    int startPage = 1,
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
    if (skipIfCached) {
      // 已完整缓存：直接标记完成，不重复下载
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

  /// 整章缓存完成后，把内存中的图片异步落盘一份（不阻塞阅读）。
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
        // 已在内存则直接从内存写盘；否则跳过（避免额外流量）
        final mem = ImageCacheManager.instance.readSync(url);
        if (mem == null) continue;
        await ImageCacheManager.instance.persistBytes(url, mem);
      }
    } catch (_) {}
  }

  Future<void> _run(ChapterCacheTask task, int concurrency) async {
    task.status = CacheStatus.running;
    _notify();

    final bundle = task.bundle;
    final sid = bundle.scrambleId;

    // 以 startPage 为中心向两侧扩散的取号序列：
    // start, start+1, start-1, start+2, start-2, ...
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
            // 已解码进内存则直接标记完成（避免重复下载）
            if (ImageCacheManager.instance.getUiSync(url) != null) {
              task.doneFlags[i] = true;
              task.done++;
              _notify();
              continue;
            }
            // 用户主动下载 → 写盘；边看边缓存 → 只进内存
            final fetcher = (String u) => JmApi.instance.fetchBytes(
                  u,
                  referer:
                      task.source.id == 'ehentai' ? ref.resolveUrl : null,
                );
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
              if (sid != null &&
                  ImageScrambler.needScramble(
                    bundle.scrambleAid,
                    sid,
                    url,
                  )) {
                final pk = ImageScrambler.pageKeyFromUrl(url, ref.index);
                final seg = ImageScrambler.segments(bundle.scrambleAid, pk);
                data = await unscramble(bytes, seg);
              }
              final img = await ImageCacheManager.decode(data);
              if (img != null) ImageCacheManager.instance.putUi(url, img);
              task.doneFlags[i] = true;
            }
          }
        } catch (_) {}
        task.done++;
        task.readyCount = task.doneFlags.where((e) => e).length;

      // 若本次是「边看边缓存」（未写盘），整章就绪后异步补写一次盘，
      // 这样读完的章节下次仍可离线观看，而不会像纯内存缓存那样丢失。
      if (!task.persistToDisk &&
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
    } catch (_) {
      task.status = CacheStatus.failed;
    }
    _notify();
  }

  /// 按 source/chapter 取消并移除任务。
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

  /// 纵向切段逆序还原。
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

  /// 是否写盘：true = 用户主动下载；false = 边看边缓存（仅内存）。
  bool persistToDisk = false;

  /// 优先加载的起始页（0-based）。
  int startPage = 0;

  bool get isActive =>
      status == CacheStatus.running || status == CacheStatus.idle;
  bool get isCompleted => status == CacheStatus.completed;

  double get progress => total == 0 ? 0 : (done / total).clamp(0.0, 1.0);

  /// 「已就绪 / 总数」用于 xx/xx 展示
  int get readyOrDone => readyCount > 0 ? readyCount : done;

  void cancel() {
    cancelledFlag = true;
    status = CacheStatus.cancelled;
  }
}
