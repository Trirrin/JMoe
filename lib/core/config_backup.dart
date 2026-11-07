import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'reader_settings.dart';

/// 配置备份与恢复：
/// 把「设置 / 阅读偏好 / 收藏 / 历史 / 书签 / 批注」打包成 JSON，
/// 可导出到文件、也可从文件导入（不含登录凭据）。
class ConfigBackup {
  ConfigBackup._();
  static final ConfigBackup instance = ConfigBackup._();

  /// 版本号，便于将来兼容旧备份。
  static const int formatVersion = 1;

  /// 允许导出的 key（白名单，避免把 jwt 等凭据带出去）。
  static const List<String> _exportKeys = [
    'themeMode',
    'oled',
    'seedColor',
    'readerMode',
    'showPageProgress',
    'enableVolumeKeys',
    'imageShunt',
    'imgHost',
    'lang',
    'uiLang',
    'search_history',
    'localFavorites',
    'history',
    'reader_settings_v2',
    'cache_max_size_mb',
    'cache_retention_days',
  ];

  /// 打包为 JSON 字符串。
  Future<String> export() async {
    final sp = await SharedPreferences.getInstance();
    final data = <String, dynamic>{};
    for (final k in _exportKeys) {
      final v = sp.get(k);
      if (v != null) data[k] = v;
    }
    // 书签 / 批注使用前缀存储，需按前缀扫描
    for (final k in sp.getKeys()) {
      if (k.startsWith('reader_bookmarks_') ||
          k.startsWith('reader_annotations_') ||
          k.startsWith('reader_progress_')) {
        final v = sp.get(k);
        if (v != null) data[k] = v;
      }
    }
    return const JsonEncoder.withIndent('  ').convert({
      'app': 'JMoe',
      'version': formatVersion,
      'exportedAt': DateTime.now().toIso8601String(),
      'data': data,
    });
  }

  /// 导出到应用文档目录，返回文件路径。
  Future<String?> exportToFile() async {
    try {
      final json = await export();
      final dir = await getApplicationDocumentsDirectory();
      final f = File(
        '${dir.path}/jmoe-backup-'
        '${DateTime.now().millisecondsSinceEpoch}.json',
      );
      await f.writeAsString(json, flush: true);
      return f.path;
    } catch (_) {
      return null;
    }
  }

  /// 从 JSON 字符串导入。
  ///
  /// [merge] 为 true 时只覆盖备份中存在的键，否则等同 merge（
  /// 键级覆盖，不删除其它本地数据，更安全）。
  Future<({bool ok, int count, String? error})> import(
    String json, {
    bool merge = true,
  }) async {
    try {
      final obj = jsonDecode(json);
      if (obj is! Map) {
        return (ok: false, count: 0, error: 'invalid format');
      }
      final data = obj['data'];
      if (data is! Map) {
        return (ok: false, count: 0, error: 'missing data');
      }
      final sp = await SharedPreferences.getInstance();
      var n = 0;
      for (final e in data.entries) {
        final k = '${e.key}';
        final v = e.value;
        if (v is String) {
          await sp.setString(k, v);
        } else if (v is bool) {
          await sp.setBool(k, v);
        } else if (v is int) {
          await sp.setInt(k, v);
        } else if (v is double) {
          await sp.setDouble(k, v);
        } else if (v is List) {
          await sp.setStringList(k, v.map((x) => '$x').toList());
        }
        n++;
      }
      // 阅读偏好需要重新载入内存
      await ReaderSettings.instance.load();
      return (ok: true, count: n, error: null);
    } catch (e) {
      return (ok: false, count: 0, error: '$e');
    }
  }
}
