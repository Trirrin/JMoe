import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'jmoe_archive.dart';

class PackWorker {
  PackWorker._();
  static final PackWorker instance = PackWorker._();

  Isolate? _isolate;
  SendPort? _toWorker;
  ReceivePort? _fromWorker;

  int _seq = 0;

  final Map<int, Completer<File?>> _pending = {};
  final Map<int, void Function(int, int)?> _progress = {};

  Timer? _idleTimer;

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
      if (msg is! Map) return;
      final id = msg['id'] as int?;
      if (id == null) return;

      if (msg.containsKey('done')) {
        _progress[id]?.call(msg['done'] as int, msg['total'] as int);
        return;
      }

      final c = _pending.remove(id);
      _progress.remove(id);
      if (c == null) return;
      final ok = msg['ok'] == true;
      final path = msg['path'] as String?;
      c.complete(ok && path != null ? File(path) : null);
    });

    _isolate = await Isolate.spawn(_workerMain, rp.sendPort);
    _scheduleIdleStop();
    return ready.future;
  }

  void _scheduleIdleStop() {
    _idleTimer?.cancel();
    _idleTimer = Timer(const Duration(seconds: 30), () {
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

  Future<File?> pack({
    required String chapterDir,
    required String chapterId,
    required String outPath,
    Map<String, dynamic>? albumMeta,
    void Function(int done, int total)? onProgress,
  }) async {
    try {
      final port = await _ensureStarted();
      final id = ++_seq;
      final c = Completer<File?>();
      _pending[id] = c;
      _progress[id] = onProgress;
      port.send({
        'id': id,
        'chapterDir': chapterDir,
        'chapterId': chapterId,
        'outPath': outPath,
        'albumMeta': albumMeta,
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
    rp.listen((dynamic msg) async {
      if (msg is! Map) return;
      final id = msg['id'] as int;
      try {
        final file = await JmoeArchive.packIsolate(
          chapterDir: msg['chapterDir'] as String,
          chapterId: msg['chapterId'] as String,
          outPath: msg['outPath'] as String,
          albumMeta: (msg['albumMeta'] as Map?)?.cast<String, dynamic>(),
          onProgress: (done, total) {
            reply.send({'id': id, 'done': done, 'total': total});
          },
        );
        reply.send({'id': id, 'ok': file != null, 'path': file?.path});
      } catch (_) {
        reply.send({'id': id, 'ok': false, 'path': null});
      }
    });
  }
}
