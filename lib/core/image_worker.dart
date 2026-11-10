import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as im;

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
        final strip = im.copyCrop(img, x: 0, y: y, width: w, height: ch);
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
