import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

import 'net_throttle.dart';

/// 视频（HLS）预缓存：把 m3u8 索引与全部分片下载到本地，
/// 播放时改用本地索引，避免卡顿且可离线观看。
///
/// 仅处理 `#EXT-X-*` 播放列表（含嵌套子播放列表），不处理 DASH。
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
    // 稳定短标识（不用 crypto 以减依赖）：FNV-1a
    var h = 2166136261;
    for (final c in s.codeUnits) {
      h ^= c;
      h = (h * 16777619) & 0xFFFFFFFF;
    }
    return h.toRadixString(16);
  }

  /// 本地已缓存的播放地址；不存在返回 null。
  ///
  /// 优先返回合并后的单一 TS 文件（兼容性最好）。
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

  /// 下载 HLS 全量分片。
  ///
  /// [onProgress] 回调 0..1；[isCancelled] 返回 true 时中止。
  /// 返回本地 m3u8 路径，失败返回 null。
  Future<String?> fetchHls({
    required String url,
    /// (已完成字节, 总字节)
    required void Function(int doneBytes, int totalBytes) onProgress,
    bool Function()? isCancelled,
  }) async {
    if (_downloading) return null;
    _downloading = true;
    try {
      final dir = await _dirFor(url);
      final playlist = await _fetchPlaylist(url);
      if (playlist == null) return null;

      // 若是 master playlist（含子播放列表），选带宽最高的一条
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

      // 分片清单
      final segUrls = <String>[];
      for (final line in playlistBody.split('\n')) {
        final t = line.trim();
        if (t.isEmpty || t.startsWith('#')) continue;
        segUrls.add(_resolve(t, finalPlaylistUrl));
      }
      if (segUrls.isEmpty) return null;

      final total = segUrls.length;

      // 先总览一遍已存在的分片大小，作为进度起点
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

      // 总字节数未知（HLS 不提供），用「已下载字节」做单调推进，
      // 分片全部下完后归一到 100%。为让进度平滑，按已下片段数估计总量。
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
          // 网络限速
          await NetThrottle.instance.consume(bytes.length);
          segSizes[i] = bytes.length;
          doneBytes += bytes.length;
        }
        // 用「已下字节」和「按平均片大小预估的总字节」计算真实百分比
        final avg = doneBytes / (i + 1);
        final estimatedTotal = (avg * total).round();
        onProgress(doneBytes, estimatedTotal > 0 ? estimatedTotal : doneBytes);
      }

      // 写本地索引：分片指向本地文件（video_player 支持 file:// 绝对路径分片）
      final buf = StringBuffer();
      for (final line in playlistBody.split('\n')) {
        final t = line.trim();
        if (t.isEmpty || t.startsWith('#')) {
          // 加密/密钥行原样保留（若有）
          buf.writeln(line);
        } else {
          // 占位，下面按序替换
          buf.writeln('__SEG__');
        }
      }
      var text = buf.toString();
      for (var i = 0; i < segUrls.length; i++) {
        text = text.replaceFirst('__SEG__', '${dir.path}/seg_$i.ts');
      }
      final index = File('${dir.path}/index.m3u8');
      await index.writeAsString(text, flush: true);

      // 合并为单一 TS：按分片顺序二进制拼接
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
      // 下一行非注释即子列表地址
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

  /// 清空全部视频缓存。
  Future<void> clearAll() async {
    try {
      if (_root != null && await _root!.exists()) {
        await _root!.delete(recursive: true);
      }
      _root = null;
    } catch (_) {}
  }

  /// 缓存占用字节数。
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
