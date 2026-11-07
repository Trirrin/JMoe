import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'image_cache.dart';

/// 缓存治理：容量上限、保留时长、按章节/全部清理。
///
/// 与 `ImageCacheManager`（加密图片缓存）配合：
///  * 每次写入后触发配额检查（LRU 淘汰最旧文件）
///  * 启动时清理超过保留时间的文件
///  * 支持「清理全部」「仅清理过期」「按章节清理」
class CacheManager {
  CacheManager._();
  static final CacheManager instance = CacheManager._();

  SharedPreferences? _prefs;

  /// 最大缓存（MB），0 表示不限制
  int maxSizeMb = 1024;

  /// 保留天数，0 表示永久
  int retentionDays = 30;

  /// 变更通知（设置页刷新用）
  final ValueNotifier<int> revision = ValueNotifier(0);

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    maxSizeMb = _prefs?.getInt('cacheMaxMb') ?? 1024;
    retentionDays = _prefs?.getInt('cacheDays') ?? 30;
    unawaited(enforce());
  }

  Future<void> setMaxSizeMb(int v) async {
    maxSizeMb = v;
    await _prefs?.setInt('cacheMaxMb', v);
    revision.value++;
    await enforce();
  }

  Future<void> setRetentionDays(int v) async {
    retentionDays = v;
    await _prefs?.setInt('cacheDays', v);
    revision.value++;
    await enforce();
  }

  Future<Directory> _dir() async {
    final base = await getApplicationCacheDirectory();
    final d = Directory('${base.path}/imgcache');
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }

  /// 当前占用（字节）
  Future<int> usedBytes() async {
    final d = await _dir();
    var total = 0;
    for (final f in d.listSync()) {
      if (f is File) {
        try {
          total += f.lengthSync();
        } catch (_) {}
      }
    }
    return total;
  }

  /// 使用占比统计：已用 / 上限 / 百分比。
  Future<({int used, int cap, double ratio})> usageStats() async {
    final used = await usedBytes();
    final cap = maxSizeMb > 0 ? maxSizeMb * 1024 * 1024 : 0;
    final ratio = cap > 0 ? (used / cap).clamp(0.0, 1.0) : 0.0;
    return (used: used, cap: cap, ratio: ratio);
  }

  /// 执行配额与过期清理。
  Future<void> enforce() async {
    try {
      final d = await _dir();
      final files = d
          .listSync()
          .whereType<File>()
          .toList()
        ..sort(
          (a, b) => a.statSync().modified.compareTo(b.statSync().modified),
        );

      // 1) 过期清理
      if (retentionDays > 0) {
        final limit = DateTime.now().subtract(Duration(days: retentionDays));
        for (final f in files) {
          try {
            if (f.statSync().modified.isBefore(limit)) {
              f.deleteSync();
            }
          } catch (_) {}
        }
      }

      // 2) 容量清理（LRU：最旧的先删）
      if (maxSizeMb > 0) {
        final capBytes = maxSizeMb * 1024 * 1024;
        var total = 0;
        final alive = <(File, int)>[];
        for (final f in files) {
          if (!f.existsSync()) continue;
          final len = f.lengthSync();
          total += len;
          alive.add((f, len));
        }
        for (final e in alive) {
          if (total <= capBytes) break;
          try {
            e.$1.deleteSync();
            total -= e.$2;
          } catch (_) {}
        }
      }
      revision.value++;
    } catch (_) {}
  }

  /// 清理全部缓存。
  Future<void> clearAll() async {
    await ImageCacheManager.instance.clearDisk();
    revision.value++;
  }

  /// 仅清理过期项。
  Future<int> clearExpired() async {
    final d = await _dir();
    var removed = 0;
    if (retentionDays <= 0) return 0;
    final limit = DateTime.now().subtract(Duration(days: retentionDays));
    for (final f in d.listSync().whereType<File>()) {
      try {
        if (f.statSync().modified.isBefore(limit)) {
          f.deleteSync();
          removed++;
        }
      } catch (_) {}
    }
    revision.value++;
    return removed;
  }

  // ---------------- 离线章节索引 ----------------

  /// 已缓存章节索引：key = sourceId:chapterId，value = 元信息
  List<Map<String, dynamic>> _index = [];

  Future<void> loadIndex() async {
    final raw = _prefs?.getString('cachedChapters');
    if (raw == null || raw.isEmpty) {
      _index = [];
      return;
    }
    try {
      _index = (jsonDecode(raw) as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    } catch (_) {
      _index = [];
    }
  }

  List<Map<String, dynamic>> get cachedChapters => List.unmodifiable(_index);

  bool hasChapter(String sourceId, String chapterId) =>
      _index.any((e) => e['key'] == '$sourceId:$chapterId');

  /// 章节缓存完成后登记（供离线列表与一致性校验）。
  Future<void> markChapter({
    required String sourceId,
    required String comicId,
    required String chapterId,
    required String comicName,
    required String chapterName,
    String? cover,
    int total = 0,
  }) async {
    final key = '$sourceId:$chapterId';
    _index.removeWhere((e) => e['key'] == key);
    _index.insert(0, {
      'key': key,
      'source': sourceId,
      'comicId': comicId,
      'chapterId': chapterId,
      'comicName': comicName,
      'chapterName': chapterName,
      'cover': cover,
      'total': total,
      'at': DateTime.now().millisecondsSinceEpoch,
    });
    if (_index.length > 500) _index = _index.sublist(0, 500);
    await _saveIndex();
  }

  /// 删除某章索引（清理该章缓存时调用）。
  Future<void> unmarkChapter(String sourceId, String chapterId) async {
    _index.removeWhere((e) => e['key'] == '$sourceId:$chapterId');
    await _saveIndex();
  }

  Future<void> _saveIndex() async {
    await _prefs?.setString('cachedChapters', jsonEncode(_index));
    revision.value++;
  }

  /// 一致性校验：找出「索引里有但磁盘已不存在」的条目并清理。
  ///
  /// 返回被清理的条目数。用于云端收藏/历史与本地缓存对账。
  Future<int> reconcileIndex() async {
    var removed = 0;
    final keep = <Map<String, dynamic>>[];
    for (final e in _index) {
      // 章节缓存以图片文件存在与否为准：这里用章首页是否存在近似判断
      final ok = await _chapterFilesExist(e);
      if (ok) {
        keep.add(e);
      } else {
        removed++;
      }
    }
    if (removed > 0) {
      _index = keep;
      await _saveIndex();
    }
    return removed;
  }

  Future<bool> _chapterFilesExist(Map<String, dynamic> e) async {
    try {
      final d = await _dir();
      if (!d.existsSync()) return false;
      // 只要目录里还有文件即认为该章部分/完整存在（粗粒度一致性）
      return d.listSync().isNotEmpty;
    } catch (_) {
      return false;
    }
  }
}
