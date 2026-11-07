import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'cache_manager.dart';
import 'image_cache.dart';
import 'novel_cache.dart';
import 'video_cache.dart';

/// 单类资源占用。
class StorageSlice {
  final String key;
  final int bytes;

  /// 是否允许单独清理（配置除外）。
  final bool clearable;
  const StorageSlice({
    required this.key,
    required this.bytes,
    this.clearable = true,
  });
}

/// 存储总览：聚合图片 / 漫画章节 / 小说 / 视频 / 其它 的占用，
/// 供存储管理页绘制饼图与逐项清理。
class StorageManager {
  StorageManager._();
  static final StorageManager instance = StorageManager._();

  /// 采集各类占用。
  Future<List<StorageSlice>> collect() async {
    final img = await ImageCacheManager.instance.diskUsage();
    final chapters = await _chapterBytes();
    final novel = await NovelCacheManager.instance.usedBytes();
    final video = await VideoCacheManager.instance.usedBytes();
    final base = await getApplicationSupportDirectory();
    final config = await _dirBytes(Directory('${base.path}/config'));

    return [
      StorageSlice(key: 'storageImages', bytes: img),
      StorageSlice(key: 'storageChapters', bytes: chapters),
      StorageSlice(key: 'storageNovels', bytes: novel),
      StorageSlice(key: 'storageVideos', bytes: video),
      StorageSlice(
        key: 'storageConfig',
        bytes: config,
        clearable: false,
      ),
    ];
  }

  Future<int> totalBytes() async {
    final list = await collect();
    return list.fold<int>(0, (a, b) => a + b.bytes);
  }

  Future<int> _chapterBytes() async {
    // 漫画整章缓存由 CacheManager 记录在索引里，直接复用其统计
    try {
      final s = await CacheManager.instance.usageStats();
      return s.used;
    } catch (_) {
      return 0;
    }
  }

  Future<int> _dirBytes(Directory d) async {
    try {
      if (!await d.exists()) return 0;
      var sum = 0;
      await for (final e in d.list(recursive: true)) {
        if (e is File) sum += await e.length();
      }
      return sum;
    } catch (_) {
      return 0;
    }
  }

  /// 清空指定类别。
  Future<void> clear(String key) async {
    switch (key) {
      case 'storageImages':
        await ImageCacheManager.instance.clearDisk();
        break;
      case 'storageChapters':
        await CacheManager.instance.clearAll();
        break;
      case 'storageNovels':
        await NovelCacheManager.instance.clearAll();
        break;
      case 'storageVideos':
        await VideoCacheManager.instance.clearAll();
        break;
    }
  }

  /// 清空全部可清理类别。
  Future<void> clearAll() async {
    await clear('storageImages');
    await clear('storageChapters');
    await clear('storageNovels');
    await clear('storageVideos');
  }
}
