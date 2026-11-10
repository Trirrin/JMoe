import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'reader_settings.dart';

class ConfigBackup {
  ConfigBackup._();
  static final ConfigBackup instance = ConfigBackup._();

  static const int formatVersion = 1;

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

  Future<String> export() async {
    final sp = await SharedPreferences.getInstance();
    final data = <String, dynamic>{};
    for (final k in _exportKeys) {
      final v = sp.get(k);
      if (v != null) data[k] = v;
    }
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
      await ReaderSettings.instance.load();
      return (ok: true, count: n, error: null);
    } catch (e) {
      return (ok: false, count: 0, error: '$e');
    }
  }
}
