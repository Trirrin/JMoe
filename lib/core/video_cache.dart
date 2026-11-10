import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

import 'net_throttle.dart';

class VideoCacheManager {
  VideoCacheManager._();
  static final VideoCacheManager instance = VideoCacheManager._();

  Dio? _dio;
  Dio get _http => _dio ??= Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 30),
          headers: {'User-Agent': 'okhttp/4.12.0'},
          followRedirects: true,
          maxRedirects: 5,
        ),
      );

  Directory? _root;

  Future<Directory> _dirFor(String key) async {
    if (_root == null) {
      final base = await getApplicationSupportDirectory();
      _root = Directory('${base.path}/video_cache');
      if (!await _root!.exists()) await _root!.create(recursive: true);
    }
    final d = Directory('${_root!.path}/${_hash(key)}');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  String _hash(String s) {
    var h = 2166136261;
    for (final c in s.codeUnits) {
      h ^= c;
      h = (h * 16777619) & 0xFFFFFFFF;
    }
    return h.toRadixString(16);
  }

  Future<String?> cachedPath(String src) async {
    try {
      final d = await _dirFor(src);
      final merged = File('${d.path}/merged.ts');
      if (await merged.exists() && await merged.length() > 0) {
        return merged.path;
      }
      final f = File('${d.path}/index.m3u8');
      if (await f.exists() && await f.length() > 0) return f.path;
    } catch (_) {}
    return null;
  }

  bool _downloading = false;
  bool get downloading => _downloading;

  Future<String?> fetchHls({
    required String url,
    required void Function(int doneBytes, int totalBytes) onProgress,
    bool Function()? isCancelled,
  }) async {
    if (_downloading) return null;
    _downloading = true;
    try {
      final dir = await _dirFor(url);
      final playlist = await _fetchPlaylist(url);
      if (playlist == null) return null;

      String finalPlaylistUrl = url;
      String playlistBody = playlist;
      if (_isMaster(playlistBody)) {
        final variant = _pickBestVariant(playlistBody, url);
        if (variant == null) return null;
        finalPlaylistUrl = variant;
        final sub = await _fetchPlaylist(variant);
        if (sub == null) return null;
        playlistBody = sub;
      }

      final segUrls = <String>[];
      for (final line in playlistBody.split('\n')) {
        final t = line.trim();
        if (t.isEmpty || t.startsWith('#')) continue;
        segUrls.add(_resolve(t, finalPlaylistUrl));
      }
      if (segUrls.isEmpty) return null;

      final total = segUrls.length;

      var doneBytes = 0;
      final segSizes = List<int>.filled(total, 0);
      for (var i = 0; i < total; i++) {
        final segFile = File('${dir.path}/seg_$i.ts');
        if (await segFile.exists()) {
          final len = await segFile.length();
          if (len > 0) {
            segSizes[i] = len;
            doneBytes += len;
          }
        }
      }

      for (var i = 0; i < total; i++) {
        if (isCancelled?.call() == true) return null;
        final segFile = File('${dir.path}/seg_$i.ts');
        if (segSizes[i] == 0) {
          final res = await _http.get<List<int>>(
            segUrls[i],
            options: Options(responseType: ResponseType.bytes),
          );
          final bytes = res.data;
          if (bytes == null || bytes.isEmpty) return null;
          await segFile.writeAsBytes(bytes, flush: true);
          await NetThrottle.instance.consume(bytes.length);
          segSizes[i] = bytes.length;
          doneBytes += bytes.length;
        }
        final avg = doneBytes / (i + 1);
        final estimatedTotal = (avg * total).round();
        onProgress(doneBytes, estimatedTotal > 0 ? estimatedTotal : doneBytes);
      }

      final buf = StringBuffer();
      for (final line in playlistBody.split('\n')) {
        final t = line.trim();
        if (t.isEmpty || t.startsWith('#')) {
          buf.writeln(line);
        } else {
          buf.writeln('__SEG__');
        }
      }
      var text = buf.toString();
      for (var i = 0; i < segUrls.length; i++) {
        text = text.replaceFirst('__SEG__', '${dir.path}/seg_$i.ts');
      }
      final index = File('${dir.path}/index.m3u8');
      await index.writeAsString(text, flush: true);

      try {
        final merged = File('${dir.path}/merged.ts');
        if (!await merged.exists() || await merged.length() == 0) {
          final sink = merged.openWrite();
          for (var i = 0; i < segUrls.length; i++) {
            final seg = File('${dir.path}/seg_$i.ts');
            if (await seg.exists()) {
              sink.add(await seg.readAsBytes());
            }
          }
          await sink.flush();
          await sink.close();
        }
        if (await merged.length() > 0) return merged.path;
      } catch (_) {}

      return index.path;
    } catch (_) {
      return null;
    } finally {
      _downloading = false;
    }
  }

  Future<String?> _fetchPlaylist(String url) async {
    try {
      final res = await _http.get<String>(
        url,
        options: Options(responseType: ResponseType.plain),
      );
      final body = res.data;
      if (body == null || !body.contains('#EXTM3U')) return null;
      return body;
    } catch (_) {
      return null;
    }
  }

  bool _isMaster(String body) =>
      body.contains('#EXT-X-STREAM-INF');

  String? _pickBestVariant(String body, String base) {
    final lines = body.split('\n');
    var bestBw = -1;
    String? best;
    for (var i = 0; i < lines.length; i++) {
      final l = lines[i].trim();
      if (!l.startsWith('#EXT-X-STREAM-INF')) continue;
      final m = RegExp(r'BANDWIDTH=(\d+)').firstMatch(l);
      final bw = int.tryParse(m?.group(1) ?? '') ?? 0;
      for (var j = i + 1; j < lines.length; j++) {
        final n = lines[j].trim();
        if (n.isEmpty || n.startsWith('#')) continue;
        if (bw > bestBw) {
          bestBw = bw;
          best = _resolve(n, base);
        }
        break;
      }
    }
    return best;
  }

  String _resolve(String path, String base) {
    if (path.startsWith('http')) return path;
    final u = Uri.parse(base);
    return u.resolve(path).toString();
  }

  Future<void> clearAll() async {
    try {
      if (_root != null && await _root!.exists()) {
        await _root!.delete(recursive: true);
      }
      _root = null;
    } catch (_) {}
  }

  Future<int> usedBytes() async {
    try {
      if (_root == null) {
        final base = await getApplicationSupportDirectory();
        _root = Directory('${base.path}/video_cache');
      }
      if (!await _root!.exists()) return 0;
      var sum = 0;
      await for (final e in _root!.list(recursive: true)) {
        if (e is File) sum += await e.length();
      }
      return sum;
    } catch (_) {
      return 0;
    }
  }
}
