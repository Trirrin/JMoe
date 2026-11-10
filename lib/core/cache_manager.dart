import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'image_cache.dart';
import 'temp_store.dart';

class CacheManager {
  CacheManager._();
  static final CacheManager instance = CacheManager._();

  SharedPreferences? _prefs;

  int maxSizeMb = 1024;

  int retentionDays = 30;

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
    try {
      total += await TempStore.instance.usedBytes();
    } catch (_) {}
    return total;
  }

  Future<({int used, int cap, double ratio})> usageStats() async {
    final used = await usedBytes();
    final cap = maxSizeMb > 0 ? maxSizeMb * 1024 * 1024 : 0;
    final ratio = cap > 0 ? (used / cap).clamp(0.0, 1.0) : 0.0;
    return (used: used, cap: cap, ratio: ratio);
  }

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
      unawaited(TempStore.instance.sweep());
    } catch (_) {}
  }

  Future<void> clearAll() async {
    await ImageCacheManager.instance.clearDisk();
    await TempStore.instance.clearAll();
    revision.value++;
  }

  Future<void> clearChapter(
    String sourceId,
    String chapterId, {
    List<String> imageUrls = const [],
  }) async {
    for (final url in imageUrls) {
      await ImageCacheManager.instance.evict(url);
    }
    try {
      final dir = await TempStore.instance.dirFor(sourceId, chapterId);
      await TempStore.instance.remove(dir);
    } catch (_) {}
    await unmarkChapter(sourceId, chapterId);
    revision.value++;
  }

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

  Future<void> markChapter({
    required String sourceId,
    required String comicId,
    required String chapterId,
    required String comicName,
    required String chapterName,
    String? cover,
    int total = 0,
    List<String> imageUrls = const [],
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
      'imageUrls': imageUrls,
      'at': DateTime.now().millisecondsSinceEpoch,
    });
    if (_index.length > 500) _index = _index.sublist(0, 500);
    await _saveIndex();
  }

  Future<void> unmarkChapter(String sourceId, String chapterId) async {
    _index.removeWhere((e) => e['key'] == '$sourceId:$chapterId');
    await _saveIndex();
  }

  Future<void> _saveIndex() async {
    await _prefs?.setString('cachedChapters', jsonEncode(_index));
    revision.value++;
  }

  Future<int> reconcileIndex() async {
    var removed = 0;
    final keep = <Map<String, dynamic>>[];
    for (final e in _index) {
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
      return d.listSync().isNotEmpty;
    } catch (_) {
      return false;
    }
  }
}
