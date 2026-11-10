import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'app_state.dart';
import 'downloader.dart';

class FavoritesBackup {
  FavoritesBackup._();

  static Future<String> appSubDir(String name) async {
    final base = await getExternalStorageDirectory() ??
        await getApplicationDocumentsDirectory();
    final d = Directory('${base.path}/JMoe/$name');
    if (!d.existsSync()) d.createSync(recursive: true);
    return d.path;
  }

  static Future<bool> openFolder(String path) =>
      ChapterDownloader.openFolder(path);

  static Future<({bool ok, int count, String? error})> importFromPickedFile(
    String path,
  ) async {
    try {
      final f = File(path);
      if (!await f.exists()) {
        return (ok: false, count: 0, error: 'file not found');
      }
      final raw = await f.readAsString();
      final obj = jsonDecode(raw);
      final list = obj is Map ? obj['favorites'] : obj;
      if (list is! List) {
        return (ok: false, count: 0, error: 'invalid format');
      }
      final existing =
          AppState.instance.localFavorites.map((e) => '${e['id']}').toSet();
      var added = 0;
      for (final item in list) {
        if (item is! Map) continue;
        final m = Map<String, dynamic>.from(item);
        final id = '${m['id'] ?? ''}';
        if (id.isEmpty || existing.contains(id)) continue;
        await AppState.instance.setLocalFavorite(m, true);
        existing.add(id);
        added++;
      }
      return (ok: true, count: added, error: null);
    } catch (e) {
      return (ok: false, count: 0, error: '$e');
    }
  }

  static Future<({bool ok, int count, String? error})> importFromFile() async {
    final f = await _latestFile();
    if (f == null) return (ok: false, count: 0, error: 'no file');
    return importFromPickedFile(f.path);
  }

  static Future<String?> exportToPickedFile() async {
    try {
      final dir = await _dir();
      final defaultName = 'jmoe-favorites-'
          '${DateTime.now().millisecondsSinceEpoch}.json';
      final body = _buildJson();
      final fallback = File('${dir.path}/$defaultName');
      await fallback.writeAsString(body, flush: true);
      return fallback.path;
    } catch (_) {
      return null;
    }
  }

  static String _buildJson() => const JsonEncoder.withIndent('  ').convert({
        'app': 'JMoe',
        'kind': 'favorites',
        'version': 1,
        'exportedAt': DateTime.now().toIso8601String(),
        'count': AppState.instance.localFavorites.length,
        'favorites': AppState.instance.localFavorites,
      });

  static Future<String?> exportToFile() async {
    try {
      final dir = await _dir();
      final f = File(
        '${dir.path}/jmoe-favorites-'
        '${DateTime.now().millisecondsSinceEpoch}.json',
      );
      await f.writeAsString(_buildJson(), flush: true);
      return f.path;
    } catch (_) {
      return null;
    }
  }

  static Future<File?> _latestFile() async {
    try {
      final dir = await _dir();
      final files = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.contains('jmoe-favorites-'))
          .toList()
        ..sort(
          (a, b) => b.statSync().modified.compareTo(a.statSync().modified),
        );
      return files.isEmpty ? null : files.first;
    } catch (_) {
      return null;
    }
  }

  static Future<Directory> _dir() async {
    final base = await getExternalStorageDirectory() ??
        await getApplicationDocumentsDirectory();
    final d = Directory('${base.path}/JMoe/backup');
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }
}
