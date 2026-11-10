import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path_provider/path_provider.dart';

class ZipPacker {
  ZipPacker._();
  static final ZipPacker instance = ZipPacker._();

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
    required String dirPath,
    required String outPath,
    void Function(int done, int total)? onProgress,
  }) async {
    try {
      final port = await _ensureStarted();
      final id = ++_seq;
      final c = Completer<File?>();
      _pending[id] = c;
      _progress[id] = onProgress;
      port.send({'id': id, 'dirPath': dirPath, 'outPath': outPath});
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
        final f = _run(
          msg['dirPath'] as String,
          msg['outPath'] as String,
          (done, total) =>
              reply.send({'id': id, 'done': done, 'total': total}),
        );
        reply.send({'id': id, 'ok': f != null, 'path': f?.path});
      } catch (_) {
        reply.send({'id': id, 'ok': false, 'path': null});
      }
    });
  }

  static File? _run(
    String dirPath,
    String outPath,
    void Function(int, int) onProgress,
  ) {
    final dir = Directory(dirPath);
    if (!dir.existsSync()) return null;

    final files = <File>[];
    for (final e in dir.listSync()) {
      if (e is! File) continue;
      final p = e.path.toLowerCase();
      if (p.endsWith('meta.json') || p.endsWith('cover.jpg')) continue;
      if (p.endsWith('.png') ||
          p.endsWith('.jpg') ||
          p.endsWith('.jpeg') ||
          p.endsWith('.webp')) {
        files.add(e);
      }
    }
    if (files.isEmpty) return null;
    files.sort((a, b) => a.path.compareTo(b.path));

    final archive = Archive();
    for (var i = 0; i < files.length; i++) {
      final f = files[i];
      final bytes = f.readAsBytesSync();
      archive.addFile(ArchiveFile(f.uri.pathSegments.last, bytes.length, bytes));
      onProgress(i + 1, files.length);
    }

    final out = File(outPath);
    out.parent.createSync(recursive: true);
    final encoded = ZipEncoder().encode(archive);
    out.writeAsBytesSync(encoded, flush: true);
    return out;
  }
}

class ZipReader {
  static Future<String?> extractToCache(String zipPath) async {
    try {
      final f = File(zipPath);
      if (!await f.exists()) return null;
      final stat = await f.stat();
      final base = await getTemporaryDirectory();
      final key =
          '${_safeName(f.uri.pathSegments.last)}_${stat.modified.millisecondsSinceEpoch}';
      final dir = Directory('${base.path}/jmoe_unzip/$key');

      if (await dir.exists()) {
        final has = dir.listSync().whereType<File>().any(
              (e) => _isImage(e.path),
            );
        if (has) return dir.path;
      }

      await dir.create(recursive: true);
      final bytes = await f.readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);
      var n = 0;
      for (final entry in archive.files) {
        if (!entry.isFile) continue;
        if (!_isImage(entry.name)) continue;
        final out = File('${dir.path}/${entry.name.split('/').last}');
        await out.writeAsBytes(entry.content, flush: false);
        n++;
      }
      return n > 0 ? dir.path : null;
    } catch (_) {
      return null;
    }
  }

  static bool _isImage(String p) {
    final n = p.toLowerCase();
    return n.endsWith('.png') ||
        n.endsWith('.jpg') ||
        n.endsWith('.jpeg') ||
        n.endsWith('.webp');
  }

  static String _safeName(String s) =>
      s.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');

  static List<String> listPages(String zipPath) {
    final bytes = File(zipPath).readAsBytesSync();
    final archive = ZipDecoder().decodeBytes(bytes);
    final names = <String>[];
    for (final f in archive.files) {
      if (!f.isFile) continue;
      if (_isImage(f.name)) names.add(f.name);
    }
    names.sort();
    return names;
  }

  static Uint8List? readEntry(String zipPath, String name) {
    final bytes = File(zipPath).readAsBytesSync();
    final archive = ZipDecoder().decodeBytes(bytes);
    for (final f in archive.files) {
      if (f.isFile && f.name == name) {
        return Uint8List.fromList(f.content);
      }
    }
    return null;
  }}
