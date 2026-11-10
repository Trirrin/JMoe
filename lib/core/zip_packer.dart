import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path_provider/path_provider.dart';

/// 下载内容的**本地打包器**：把图片目录收拢成一个**无加密 zip**。
///
/// # 为什么本地用 zip、分享用 .jmoe
///
///  * **本地存储**：用标准 zip（不加密）。用户可以自己用任何解压工具
///    打开、取出图片，符合"下载下来的文件应该能用"的预期。
///  * **分享**：用 `.jmoe`（AES 加密 + 自带元数据），对方导入 App
///    后能直接看到详情并阅读。
///
/// # 为什么放后台 isolate
///
/// 一章节几百页，zip 压缩是纯 CPU 计算。放主 isolate 会让
/// 「打包时整个界面卡住」。这里用常驻 worker（非 `compute()`，
/// 避免每次新建 isolate）。
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

  /// 把目录打成 zip（不含 meta.json / cover.jpg，只要图片）。
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

  /// 同步实现（在 worker isolate 里跑）。
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

    // **不压缩**（store 模式）：漫画图已是压缩格式（jpg/webp），
    // 再 deflate 一遍几乎压不下去，只是白耗 CPU 和时间。
    // store 模式打包接近纯 IO 速度，几百页也能很快完成。
    final archive = Archive();
    for (var i = 0; i < files.length; i++) {
      final f = files[i];
      final bytes = f.readAsBytesSync();
      // 用文件名（001.jpg）作为包内路径，解压后就是干净的顺序图
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

/// 把 zip 内的图片读出来（供阅读器按页读取）。
class ZipReader {
  /// 把 zip 里的图片解到应用缓存目录，返回该目录路径。
  ///
  /// # 为什么不直接从 zip 逐页读
  ///
  /// 从 zip 读单页需要每次重新解析整个中央目录（几十~几百条目），
  /// 翻页会有明显延迟。首次打开时一次性解到缓存目录，
  /// 之后就是普通文件读取，翻页和看本地目录一样快。
  ///
  /// 解出的目录以「zip 文件名 + 修改时间」为 key，重复打开直接复用。
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

  /// 读出该 zip 内所有图片条目，按文件名排序。
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

  /// 读取某一条目的字节。
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
