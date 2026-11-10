import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as im;

/// 后台图像处理 worker（**常驻 isolate**）。
///
/// # 为什么需要它
///
/// 缓存漫画页时每页要做「打乱还原 + 编码写盘」。原实现用 `ui.Image`
/// 在主 isolate 上做：解码 → Canvas 重绘 → PNG 编码 —— 三步全占主线程，
/// 滚动帧抢不到 CPU，表现就是「边看边缓存时卡」。
///
/// 关键洞察：打乱还原本质是**纯像素搬运**（若干横向条带按逆序重排），
/// 不需要 `ui.Image`，用 `image` 包在任意 isolate 里都能做；编码同理。
/// 所以整件事可以完全搬离主 isolate。
///
/// # 为什么不用 compute()
///
/// `compute()` 每次调用都**新建并销毁一个 isolate**。一章节几百页就是
/// 几百次 isolate 生命周期加内存拷贝，开销比省下的还多 ——
/// 实测反而让整个 App 变卡。这里改成**一个常驻 worker 排队处理**，
/// 空闲 20 秒后才自动退出。
class ImageWorker {
  ImageWorker._();
  static final ImageWorker instance = ImageWorker._();

  Isolate? _isolate;
  SendPort? _toWorker;
  ReceivePort? _fromWorker;

  int _seq = 0;
  final Map<int, Completer<Uint8List?>> _pending = {};
  Timer? _idleTimer;

  bool get isRunning => _isolate != null;

  Future<SendPort> _ensureStarted() async {
    final existing = _toWorker;
    if (existing != null) return existing;

    final ready = Completer<SendPort>();
    final rp = ReceivePort();
    _fromWorker = rp;

    rp.listen((dynamic msg) {
      if (msg is SendPort) {
        _toWorker = msg;
        if (!ready.isCompleted) ready.complete(msg);
        return;
      }
      if (msg is Map) {
        final id = msg['id'] as int?;
        if (id == null) return;
        final c = _pending.remove(id);
        if (c == null) return;
        final data = msg['data'];
        c.complete(data is Uint8List ? data : null);
      }
    });

    _isolate = await Isolate.spawn(_workerMain, rp.sendPort);
    _scheduleIdleStop();
    return ready.future;
  }

  void _scheduleIdleStop() {
    _idleTimer?.cancel();
    _idleTimer = Timer(const Duration(seconds: 20), () {
      if (_pending.isNotEmpty) {
        _scheduleIdleStop();
        return;
      }
      _stop();
    });
  }

  void _stop() {
    _idleTimer?.cancel();
    _idleTimer = null;
    _fromWorker?.close();
    _fromWorker = null;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _toWorker = null;
  }

  /// 后台还原打乱图并编码为 JPEG；失败返回 null（调用方回退原图）。
  ///
  /// [maxWidth] 非空时先缩到该宽度 —— 像素搬运量和内存按平方级下降。
  Future<Uint8List?> unscrambleToJpeg({
    required Uint8List bytes,
    required int segments,
    int? maxWidth,
    int quality = 92,
  }) async {
    try {
      final port = await _ensureStarted();
      final id = ++_seq;
      final c = Completer<Uint8List?>();
      _pending[id] = c;
      port.send({
        'id': id,
        'bytes': bytes,
        'segments': segments,
        'maxWidth': maxWidth,
        'quality': quality,
      });
      _scheduleIdleStop();
      return await c.future;
    } catch (_) {
      return null;
    }
  }

  static void _workerMain(SendPort reply) {
    final rp = ReceivePort();
    reply.send(rp.sendPort);
    rp.listen((dynamic msg) {
      if (msg is! Map) return;
      final id = msg['id'] as int;
      try {
        final out = _process(
          msg['bytes'] as Uint8List,
          msg['segments'] as int,
          msg['maxWidth'] as int?,
          msg['quality'] as int? ?? 92,
        );
        reply.send({'id': id, 'data': out});
      } catch (_) {
        reply.send({'id': id, 'data': null});
      }
    });
  }

  /// 纯像素处理：解码 → 可选缩放 → 条带逆序重排 → 编码 JPEG。
  static Uint8List? _process(
    Uint8List bytes,
    int segments,
    int? maxWidth,
    int quality,
  ) {
    var img = im.decodeImage(bytes);
    if (img == null) return null;

    if (maxWidth != null && maxWidth > 0 && img.width > maxWidth) {
      img = im.copyResize(img, width: maxWidth);
    }

    final w = img.width;
    final h = img.height;

    if (segments > 1 && h >= segments) {
      // 原图从上到下切成 segments 段，显示时需逆序拼回。
      // 用 drawImage 整块搬运（比逐像素快得多）。
      final dst = im.Image(width: w, height: h, numChannels: 3);
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
        if (ch <= 0) continue;
        // 裁剪源条带
        final strip = im.copyCrop(img, x: 0, y: y, width: w, height: ch);
        // 整块贴到目标位置（不要 clear，否则会擦掉已拼好的其他段）
        im.compositeImage(
          dst,
          strip,
          dstX: 0,
          dstY: py,
        );
      }
      return Uint8List.fromList(im.encodeJpg(dst, quality: quality));
    }

    return Uint8List.fromList(im.encodeJpg(img, quality: quality));
  }
}
