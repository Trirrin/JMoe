import 'dart:io';

import 'package:path_provider/path_provider.dart';

class AppLog {
  AppLog._();
  static final AppLog instance = AppLog._();

  static const int maxLines = 500;

  File? _file;
  final List<String> _buffer = [];

  Future<File> _ensure() async {
    if (_file != null) return _file!;
    final dir = await getApplicationSupportDirectory();
    final d = Directory('${dir.path}/logs');
    if (!await d.exists()) await d.create(recursive: true);
    _file = File('${d.path}/app.log');
    return _file!;
  }

  Future<void> log(String tag, Object? message, [Object? error]) async {
    final ts = DateTime.now().toIso8601String();
    final line = '[$ts] [$tag] $message'
        '${error == null ? '' : ' | $error'}';
    _buffer.add(line);
    if (_buffer.length > 200) _buffer.removeAt(0);

    try {
      final f = await _ensure();
      await f.writeAsString(
        '$line\n',
        mode: FileMode.append,
        flush: true,
      );
      await _trim(f);
    } catch (_) {}
  }

  Future<void> error(String tag, Object e, [StackTrace? st]) =>
      log(tag, e, st?.toString().split('\n').take(3).join(' / '));

  Future<void> _trim(File f) async {
    try {
      final lines = await f.readAsLines();
      if (lines.length <= maxLines) return;
      final keep = lines.sublist(lines.length - maxLines);
      await f.writeAsString('${keep.join('\n')}\n', flush: true);
    } catch (_) {}
  }

  Future<String> read() async {
    try {
      final f = await _ensure();
      if (!await f.exists()) return '';
      return await f.readAsString();
    } catch (_) {
      return '';
    }
  }

  Future<void> clear() async {
    try {
      final f = await _ensure();
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }
}
