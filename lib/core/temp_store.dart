import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'image_cache.dart';

class TempStore {
  TempStore._();
  static final TempStore instance = TempStore._();

  static const int spillPageCount = 40;

  static const int maxSingleImageBytes = 6 * 1024 * 1024;

  static const int maxTotalBytes = 384 * 1024 * 1024;

  static const Duration idleTtl = Duration(minutes: 30);

  Directory? _root;

  final Map<String, int> _refs = {};

  final Map<String, DateTime?> _idleSince = {};

  final Map<String, DateTime> _touched = {};

  bool Function(String dir)? isBusy;

  bool _locked(String dir) => isActive(dir) || (isBusy?.call(dir) ?? false);

  Future<Directory> _ensureRoot() async {
    if (_root != null) return _root!;
    final base = await getApplicationCacheDirectory();
    final d = Directory('${base.path}/jmoetmp');
    if (!d.existsSync()) d.createSync(recursive: true);
    _root = d;
    return d;
  }

  static String _slugOf(String sourceId, String chapterId) {
    final raw = '$sourceId' '_' '$chapterId';
    final safe = raw.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '-');
    return safe.length <= 80 ? safe : safe.substring(0, 80);
  }

  static String _cryptKey(String sourceId, String chapterId, int index) =>
      'jmoetmp://$sourceId/$chapterId#$index';

  Future<String> dirFor(String sourceId, String chapterId) async {
    final root = await _ensureRoot();
    final d = Directory('${root.path}/${_slugOf(sourceId, chapterId)}');
    if (!d.existsSync()) d.createSync(recursive: true);
    return d.path;
  }

  File _fileOf(String dir, int index) =>
      File('$dir/${index.toString().padLeft(4, '0')}.jmt');

  bool has(String dir, int index) {
    try {
      return _fileOf(dir, index).existsSync();
    } catch (_) {
      return false;
    }
  }

  Future<void> put(
    String dir,
    int index,
    Uint8List bytes, {
    required String sourceId,
    required String chapterId,
  }) async {
    try {
      final f = _fileOf(dir, index);
      final enc = ImageCacheManager.encryptBytes(
        bytes,
        _cryptKey(sourceId, chapterId, index),
      );
      await f.writeAsBytes(enc, flush: false);
      _touched[dir] = DateTime.now();
    } catch (_) {}
  }

  Future<Uint8List?> get(
    String dir,
    int index, {
    required String sourceId,
    required String chapterId,
  }) async {
    try {
      final f = _fileOf(dir, index);
      if (!f.existsSync()) return null;
      _touched[dir] = DateTime.now();
      final raw = await f.readAsBytes();
      return ImageCacheManager.decryptBytes(
        raw,
        _cryptKey(sourceId, chapterId, index),
      );
    } catch (_) {
      return null;
    }
  }

  void acquire(String dir) {
    _refs[dir] = (_refs[dir] ?? 0) + 1;
    _idleSince[dir] = null;
    _touched[dir] = DateTime.now();
  }

  void release(String dir) {
    final n = (_refs[dir] ?? 0) - 1;
    if (n <= 0) {
      _refs.remove(dir);
      _idleSince[dir] = DateTime.now();
    } else {
      _refs[dir] = n;
    }
    _touched[dir] = DateTime.now();
  }

  bool isActive(String dir) => (_refs[dir] ?? 0) > 0;

  Future<void> remove(String dir) async {
    try {
      final d = Directory(dir);
      if (d.existsSync()) d.deleteSync(recursive: true);
    } catch (_) {}
    _refs.remove(dir);
    _idleSince.remove(dir);
    _touched.remove(dir);
  }

  Future<void> sweep() async {
    try {
      final root = await _ensureRoot();
      final dirs = root.listSync().whereType<Directory>().toList();
      final now = DateTime.now();

      final alive = <Directory>[];
      for (final d in dirs) {
        final idle = _idleSince[d.path];
        if (!_locked(d.path) && idle != null) {
          if (now.difference(idle) > idleTtl) {
            await remove(d.path);
            continue;
          }
        }
        alive.add(d);
      }

      int sizeOf(Directory d) {
        var t = 0;
        try {
          for (final f in d.listSync()) {
            if (f is File) t += f.lengthSync();
          }
        } catch (_) {}
        return t;
      }

      final stats = alive
          .map((d) => (d, sizeOf(d), _touched[d.path] ?? d.statSync().modified))
          .toList()
        ..sort((a, b) => a.$3.compareTo(b.$3));

      var total = stats.fold<int>(0, (s, e) => s + e.$2);
      for (final e in stats) {
        if (total <= maxTotalBytes) break;
        if (_locked(e.$1.path)) continue;
        try {
          e.$1.deleteSync(recursive: true);
          total -= e.$2;
          _refs.remove(e.$1.path);
          _idleSince.remove(e.$1.path);
          _touched.remove(e.$1.path);
        } catch (_) {}
      }
    } catch (_) {}
  }

  Future<void> sweepOnStartup() async {
    try {
      final root = await _ensureRoot();
      for (final d in root.listSync().whereType<Directory>()) {
        try {
          d.deleteSync(recursive: true);
        } catch (_) {}
      }
      _refs.clear();
      _idleSince.clear();
      _touched.clear();
    } catch (_) {}
  }

  Future<void> clearAll() async {
    try {
      final root = await _ensureRoot();
      for (final d in root.listSync()) {
        try {
          d.deleteSync(recursive: true);
        } catch (_) {}
      }
    } catch (_) {}
    _refs.clear();
    _idleSince.clear();
    _touched.clear();
  }

  Future<int> usedBytes() async {
    try {
      final root = await _ensureRoot();
      var total = 0;
      for (final d in root.listSync().whereType<Directory>()) {
        for (final f in d.listSync()) {
          if (f is File) total += f.lengthSync();
        }
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  Future<int> chapterCount() async {
    try {
      final root = await _ensureRoot();
      return root.listSync().whereType<Directory>().length;
    } catch (_) {
      return 0;
    }
  }

  Future<List<Map<String, Object>>> listing() async {
    final out = <Map<String, Object>>[];
    try {
      final root = await _ensureRoot();
      for (final d in root.listSync().whereType<Directory>()) {
        var size = 0;
        var files = 0;
        for (final f in d.listSync()) {
          if (f is File) {
            size += f.lengthSync();
            files++;
          }
        }
        out.add({
          'dir': d.path,
          'bytes': size,
          'files': files,
          'active': isActive(d.path),
        });
      }
    } catch (_) {}
    out.sort((a, b) => (b['bytes'] as int).compareTo(a['bytes'] as int));
    return out;
  }

  Future<bool> hasChapter(String sourceId, String chapterId) async {
    try {
      final root = await _ensureRoot();
      final d = Directory('${root.path}/${_slugOf(sourceId, chapterId)}');
      if (!d.existsSync()) return false;
      return d.listSync().whereType<File>().any(
            (f) => f.path.endsWith('.jmt'),
          );
    } catch (_) {
      return false;
    }
  }

  String describe() => jsonEncode({
        'maxMB': maxTotalBytes ~/ (1024 * 1024),
        'ttlMin': idleTtl.inMinutes,
        'spillPages': spillPageCount,
      });
}
