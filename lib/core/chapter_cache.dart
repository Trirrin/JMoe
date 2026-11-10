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

/// 整章缓存的全局任务管理器。
///
/// 特性：
///  * **以整章为粒度**：一次缓存一整章的所有页
///  * **后台持续**：离开阅读页后任务继续跑，进度保留
///  * **统一进度**：`done/total` + 百分比，供蒙版与顶栏共用
///  * **可取消/可重试**
///  * **大章节不在内存里堆**：页数 ≥ [TempStore.spillPageCount] 的章节
///    一律把原图落到 [TempStore] 的临时目录，阅读时按需读盘解码，
///    内存只保留眼前几页（详见 [TempStore] 的删除策略）。
class ChapterCacheManager {
  ChapterCacheManager._() {
    // 告诉 TempStore「哪些目录正被后台任务写入」，避免清扫时误删。
    TempStore.instance.isBusy = (dir) => _tasks.values.any(
          (t) => t.tempDir == dir && t.isActive,
        );
  }
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
    // 并发 4：
    // 图像处理已经搬到后台 isolate（ImageWorker），主 isolate 只做
    // 网络 IO 和一次解码，所以并发可以比原来高一些 ——
    // 更多地并行下载能喂饱后台 worker，快速滑动时不至于等图。
    int concurrency = 4,
    bool skipIfCached = false,
    /// 是否把图片写入磁盘（true = 用户主动下载）。
    /// 阅读时「边看边缓存」只进内存，退出即释放。
    bool persistToDisk = false,
    /// 起始页（从 1 开始）。缓存顺序会从这一页向两侧扩散。
    int startPage = 1,
    /// 解码目标宽度（物理像素）。见 [ChapterCacheTask.decodeWidth]。
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
    // 大章节：不在内存里堆整章解码图，改为落临时目录按需读。
    // 阈值见 TempStore.spillPageCount（页数）——单页特别大的情况在写入时
    // 也会被 TempStore.maxSingleImageBytes 兜住。
    task.spill = bundle.length >= TempStore.spillPageCount;
    // 目录要异步取（path_provider），先挂一个 ready future，
    // 阅读页会等它就绪再建页面，避免先按「走网络」渲染一遍。
    if (task.spill) task.tempDirReady = _prepareTemp(task);
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

  /// 取（或创建）某章的临时目录，填进 task.tempDir。
  Future<void> _prepareTemp(ChapterCacheTask task) async {
    try {
      task.tempDir = await TempStore.instance.dirFor(
        task.source.id,
        task.bundle.chapterId,
      );
    } catch (_) {
      task.spill = false; // 取目录失败 → 退回内存模式
    }
    _notify();
  }

  Future<void> _run(ChapterCacheTask task, int concurrency) async {
    task.status = CacheStatus.running;
    _notify();

    final bundle = task.bundle;
    final sid = bundle.scrambleId;

    // 等临时目录就绪（大章节才有）
    if (task.tempDirReady != null) await task.tempDirReady;

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
            // ---- 大章节：原图直接落临时目录，不解码、不驻留内存 ----
            final tempDir = task.tempDir;
            if (task.spill && tempDir != null) {
              if (!TempStore.instance.has(tempDir, ref.index)) {
                // 注意：这里刻意不走 load() —— 那会把整章字节塞进内存 LRU，
                // 大章节几百 MB 直接 OOM。只读盘、没盘才下载且不缓存。
                var sb = await ImageCacheManager.instance.readDiskOnly(url);
                if (sb == null) {
                  sb = await fetcher(url);
                }
                if (sb != null) {
                  var sdata = sb;
                  if (sid != null &&
                      ImageScrambler.needScramble(
                        bundle.scrambleAid,
                        sid,
                        url,
                      )) {
                    // 必须还原后再落盘：落的是可直接显示的图。
                    //
                    // **在后台 isolate 完成**（解码 + 重排 + JPEG 编码），
                    // 主 isolate 不参与任何图像处理 → 滚动不卡。
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

              // 所有图像处理（打乱还原 + 编码）都在**后台常驻 isolate** 完成。
              //
              // 这是「缓存不卡阅读」的关键：主 isolate 只做网络 IO 和
              // 一次内存拷贝，不再解码/重绘/PNG 编码，滚动帧永远拿得到 CPU。
              //
              // 需要进内存的页（当前页附近）：
              //   后台还原+编码成 JPEG → 主 isolate 只解码这一张
              //   （解码是引擎原生实现，比 Canvas 重绘 + PNG 编码快得多）
              if (task.shouldDecodePage(i)) {
                Uint8List? jpg;
                if (needScramble) {
                  jpg = await ImageWorker.instance.unscrambleToJpeg(
                    bytes: data,
                    segments: seg,
                    maxWidth: task.decodeWidth,
                    // 内存用图质量略低一点，省解码时间
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
                // 远处的页：只保证已下载 + 已还原（写盘），不占内存。
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
      // 若本次是「边看边缓存」（未写盘），整章就绪后异步补写一次盘，
      // 这样读完的章节下次仍可离线观看，而不会像纯内存缓存那样丢失。
      // 落临时目录的章节跳过：数据已经在临时目录里了，再写一份纯属浪费。
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
      // 登记到「已缓存章节」索引：缓存管理页据此展示与清理，
      // 阅读页据此判断「进来就免加载」。
      // 同时记录该章图片 URL，删章时才能精确清理、不误伤别的章节。
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

  /// 纵向切段逆序还原，**直接返回还原后的 ui.Image**。
  ///
  /// 相比 [unscramble] 省掉了最后一步 `toByteData(png)` 重新编码 ——
  /// 对 800×5000 的图，PNG 压缩要在主 isolate 上跑上百毫秒，
  /// 缓存任务和滚动帧抢 CPU，这就是「边看边缓存时滚动卡顿」的主因。
  ///
  /// 而边看边缓存拿到字节后马上又要 `decode` 回 ui.Image，
  /// 等于「解码 → 重绘 → PNG 编码 → 再解码」，两轮全尺寸处理全白做。
  ///
  /// 调用方负责在使用后 `dispose()` 返回的图（除非已交给缓存持有）。
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
      // 不够分段，原图即可
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

  /// 纵向切段逆序还原（返回字节，用于写盘）。
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

  /// 「边看边缓存」模式下，只把当前页附近的页解码进内存。
  ///
  /// 为什么要限制范围：整章解码会留几十~上百张 ui.Image 在内存里，
  /// 而且解码本身要在主 isolate 上跑 —— 用户缓慢滚动时，
  /// 滚动帧与解码抢 CPU，表现就是「异常卡顿、几乎无法观看」。
  ///
  /// 只解码 [startPage] 前后 [decodeRadius] 页：读者当前看到的页
  /// 和即将看到的页都已在内存，滚动无等待；
  /// 其余页仍然下载并落盘（离线可用），只是不占内存。
  ///
  /// 从 4 提到 8：快速滑动时一屏能掠过好几页，
  /// 窗口太小会滑出预解码范围 → 每页都要临时解码 → 微微卡顿。
  static const int decodeRadius = 8;

  /// 提前解码的方向不对称：向后多备一些。
  ///
  /// 用户几乎总是往下读，所以「往后」多解 3 倍于「往前」，
  /// 用同样的内存换到更跟手的快速下滑体验。
  static const int decodeAhead = 4;

  /// 解码目标宽度（物理像素）。null = 按原图尺寸解码。
  ///
  /// 由阅读页传入屏幕物理宽度：漫画页常是 800×5000 的超长图，
  /// 全尺寸解码既慢又占内存，而实际只显示到屏幕宽度。
  int? decodeWidth;

  /// 单页解码图是否保留在内存（按页号判断）。
  bool shouldDecodePage(int index) {
    if (persistToDisk) return true; // 主动下载：全解码，读时零等待
    final d = index - startPage;
    // 往后（d>0）多留 decodeAhead 倍，往前少留
    final limit = d >= 0 ? decodeRadius * decodeAhead : decodeRadius;
    return d.abs() <= limit;
  }

  /// 大章节的临时目录（页数多 / 单页特别大时才创建）。
  ///
  /// 非空时整章原图落在 [TempStore]，内存里不留解码图。
  String? tempDir;

  /// 本章是否走「落临时目录」模式。
  bool spill = false;

  /// 临时目录准备完成的信号（大章节才有；阅读页据此决定等多久）。
  Future<void>? tempDirReady;

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