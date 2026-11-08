import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'image_cache.dart';

/// 「大章节」临时目录。
///
/// 触发条件（任一条）：
///  * 章节页数多（≥ [spillPageCount] 页）
///  * 整章预估字节超内存预算
///  * 单张图特别大（解码后一张就几十 MB）
///
/// 这时**不再把整章解码图塞进内存**，而是把每页原图落到这里的临时目录，
/// 阅读时按需从磁盘读 → 解码 → 用完即可被内存 LRU 淘汰，
/// 内存只保留眼前这几页。
///
/// # 删除策略（确定性、可预期）
///
///  1. **章为单位**：一个 (source, chapterId) 对应一个目录，重进同一章直接复用。
///  2. **引用计数 + 空闲回收**：阅读器打开时 acquire，离开时 release；
///     release 后开始计空闲时间，超过 [idleTtl]（10 分钟）整目录删除。
///  3. **总量上限**：[maxTotalBytes]（384MB）。超限时按「最后访问时间」
///     从旧到新删整目录，直到回到上限以内；**正在阅读的那一章永不删**。
///  4. **启动清扫**：App 启动时清一次 —— 上次进程遗留的目录全部视为过期
///     （内存引用已丢失，复用没有收益），直接删掉。
///  5. **手动清理**：设置页「清理缓存」调 [clearAll]，全删。
///
/// 目录内部文件与图片缓存一样**加密落盘**（AES-256-CBC + 随机 IV），
/// 因此临时目录不会被系统图库或文件管理器直接读出内容。
class TempStore {
  TempStore._();
  static final TempStore instance = TempStore._();

  /// 页数达到这个阈值就转「落盘」模式（40 页以内的章节仍走纯内存）
  static const int spillPageCount = 40;

  /// 单张图超过这个字节数就单独落盘，不留在内存
  static const int maxSingleImageBytes = 6 * 1024 * 1024;

  /// 临时目录总量上限
  static const int maxTotalBytes = 384 * 1024 * 1024;

  /// 空闲多久后回收整目录。
  ///
  /// 取值权衡：太长会长期占盘；太短则「读完退出、立刻再打开」要重新下载。
  /// 30 分钟能覆盖绝大多数「同一章反复翻看」的场景，总量上限兜住极端情况。
  static const Duration idleTtl = Duration(minutes: 30);

  Directory? _root;

  /// dirPath → 持有者数量（阅读器）
  final Map<String, int> _refs = {};

  /// dirPath → 最后一次 release 的时间（null 表示仍被持有）
  final Map<String, DateTime?> _idleSince = {};

  /// dirPath → 最后访问时间（用于总量淘汰）
  final Map<String, DateTime> _touched = {};

  /// 外部注入的「该目录是否正被写入」判定。
  ///
  /// 后台整章缓存可能仍在往目录里写（用户已离开阅读页，引用计数归零），
  /// 这时若被清扫删掉，写盘就会静默失败、章节缺页。
  /// 由 [ChapterCacheManager] 在启动时挂上。
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

  /// 章节 → 目录名（可读 + 唯一）
  static String _slugOf(String sourceId, String chapterId) {
    final raw = '$sourceId' '_' '$chapterId';
    final safe = raw.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '-');
    // 太长时截断（chapterId 可能是很长的 EH 路径）
    return safe.length <= 80 ? safe : safe.substring(0, 80);
  }

  /// 加密键：必须跨会话稳定，否则重启后旧文件解不开。
  static String _cryptKey(String sourceId, String chapterId, int index) =>
      'jmoetmp://$sourceId/$chapterId#$index';

  /// 取（或创建）某章的临时目录。
  Future<String> dirFor(String sourceId, String chapterId) async {
    final root = await _ensureRoot();
    final d = Directory('${root.path}/${_slugOf(sourceId, chapterId)}');
    if (!d.existsSync()) d.createSync(recursive: true);
    return d.path;
  }

  File _fileOf(String dir, int index) =>
      File('$dir/${index.toString().padLeft(4, '0')}.jmt');

  /// 是否已有该页。
  bool has(String dir, int index) {
    try {
      return _fileOf(dir, index).existsSync();
    } catch (_) {
      return false;
    }
  }

  /// 写入一页（加密）。
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

  /// 读一页（解密）。不存在返回 null。
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

  /// 阅读器进入某章：引用计数 +1。
  void acquire(String dir) {
    _refs[dir] = (_refs[dir] ?? 0) + 1;
    _idleSince[dir] = null;
    _touched[dir] = DateTime.now();
  }

  /// 阅读器离开某章：引用计数 -1，归零则开始计空闲。
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

  /// 该目录是否仍被阅读器持有（持有中不参与淘汰）。
  bool isActive(String dir) => (_refs[dir] ?? 0) > 0;

  /// 删掉某章临时目录（用户主动删除该章下载/缓存时调用）。
  Future<void> remove(String dir) async {
    try {
      final d = Directory(dir);
      if (d.existsSync()) d.deleteSync(recursive: true);
    } catch (_) {}
    _refs.remove(dir);
    _idleSince.remove(dir);
    _touched.remove(dir);
  }

  /// 全局清扫：空闲超时 + 总量上限。
  ///
  /// 只删「整章目录」，绝不删单页 —— 否则章节会缺页。
  Future<void> sweep() async {
    try {
      final root = await _ensureRoot();
      final dirs = root.listSync().whereType<Directory>().toList();
      final now = DateTime.now();

      // 1) 空闲超时
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

      // 2) 总量上限：按最后访问时间从旧到新删
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
        if (_locked(e.$1.path)) continue; // 正在读 / 正在写的章不删
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

  /// 启动清扫：上个进程留下的临时目录全部删掉。
  ///
  /// 为什么全删？内存里的引用计数、idle 时间都随进程消失，
  /// 留着只会占空间；用户重进同一章时重新落盘一遍即可（有磁盘图片缓存
  /// 兜底，通常不用重新下载）。
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

  /// 全部删除（设置页「清理缓存」）。
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

  /// 当前临时目录总占用（字节）。
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

  /// 当前有临时目录的章节数（展示用）。
  Future<int> chapterCount() async {
    try {
      final root = await _ensureRoot();
      return root.listSync().whereType<Directory>().length;
    } catch (_) {
      return 0;
    }
  }

  /// 调试用：临时目录清单。
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

  /// 该章是否已有临时目录且里面有页（用于「进来就免加载」判断）。
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

  /// 元信息（供设置页文案用）。
  String describe() => jsonEncode({
        'maxMB': maxTotalBytes ~/ (1024 * 1024),
        'ttlMin': idleTtl.inMinutes,
        'spillPages': spillPageCount,
      });
}
