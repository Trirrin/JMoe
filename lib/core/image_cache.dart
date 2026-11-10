import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pointycastle/api.dart' show KeyParameter, ParametersWithIV;
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/block/modes/cbc.dart';

import 'jm_protocol.dart';
import 'jm_service.dart';
import 'app_log.dart';
import 'net_throttle.dart';

class ImageCacheManager {
  ImageCacheManager._();
  static final ImageCacheManager instance = ImageCacheManager._();

  Directory? _dir;

  final Map<String, ui.Image> _uiCache = {};

  final Map<String, Uint8List> _bytesCache = {};

  final Map<String, Future<Uint8List?>> _inflight = {};

  final List<String> _lru = [];

  final Map<String, int> _bytesSize = {};

  final Map<String, int> _uiSize = {};

  final Set<String> _pinned = {};

  static const int _maxBytesTotal = 96 * 1024 * 1024;

  static const int _maxUiTotal = 128 * 1024 * 1024;

  static const int _maxUiImages = 200;
  static const int _maxBytes = 512;

  int _bytesTotal = 0;
  int _uiTotal = 0;

  int get memoryBytes => _bytesTotal + _uiTotal;

  static const int _maxConcurrent = 6;
  int _active = 0;
  final List<Future<void> Function()> _waiting = [];

  static const String _cacheSecret = 'jmoe-cache-v1-9f3a7c';

  static Uint8List _keyFor(String url) {
    final digest = sha256.convert(utf8.encode('$_cacheSecret|$url')).bytes;
    return Uint8List.fromList(digest.sublist(0, 32));
  }

  static final math.Random _rnd = math.Random.secure();

  static Uint8List _randomIv() {
    final iv = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      iv[i] = _rnd.nextInt(256);
    }
    return iv;
  }

  static const List<int> _magic = [0x4A, 0x4D, 0x43, 0x01];

  static Uint8List encryptBytes(Uint8List plain, String url) {
    final iv = _randomIv();
    final cipher = CBCBlockCipher(AESEngine())
      ..init(true, ParametersWithIV(KeyParameter(_keyFor(url)), iv));
    final padLen = 16 - (plain.length % 16);
    final padded = Uint8List(plain.length + padLen)
      ..setRange(0, plain.length, plain)
      ..fillRange(plain.length, plain.length + padLen, padLen);
    final out = Uint8List(padded.length);
    for (var off = 0; off < padded.length; off += 16) {
      cipher.processBlock(padded, off, out, off);
    }
    return Uint8List.fromList([..._magic, ...iv, ...out]);
  }

  static Uint8List? decryptBytes(Uint8List raw, String url) {
    try {
      if (raw.length < 4 + 16 + 16) return null;
      for (var i = 0; i < 4; i++) {
        if (raw[i] != _magic[i]) return null;
      }
      final iv = Uint8List.sublistView(raw, 4, 20);
      final body = Uint8List.sublistView(raw, 20);
      final cipher = CBCBlockCipher(AESEngine())
        ..init(false, ParametersWithIV(KeyParameter(_keyFor(url)), iv));
      final out = Uint8List(body.length);
      for (var off = 0; off < body.length; off += 16) {
        cipher.processBlock(body, off, out, off);
      }
      final pad = out.last;
      if (pad < 1 || pad > 16 || pad > out.length) return out;
      return Uint8List.sublistView(out, 0, out.length - pad);
    } catch (_) {
      return null;
    }
  }

  Future<Directory> _ensureDir() async {
    if (_dir != null) return _dir!;
    final base = await getApplicationCacheDirectory();
    final d = Directory('${base.path}/imgcache');
    if (!d.existsSync()) d.createSync(recursive: true);
    _dir = d;
    return d;
  }

  String _keyOf(String url) => md5.convert(utf8.encode(url)).toString();

  File? _fileFor(String url) {
    if (_dir == null) return null;
    return File('${_dir!.path}/${_keyOf(url)}.jmc');
  }

  Uint8List? readSync(String url) {
    final mem = _bytesCache[url];
    if (mem != null) {
      _touch(url);
      return mem;
    }
    return null;
  }

  Future<Uint8List?> readDiskOnly(String url) async {
    try {
      await _ensureDir();
      final f = _fileFor(url);
      if (f == null || !f.existsSync()) return null;
      final plain = decryptBytes(await f.readAsBytes(), url);
      if (plain == null || plain.isEmpty) return null;
      return plain;
    } catch (_) {
      return null;
    }
  }

  Future<Uint8List?> load(
    String url, {
    Future<Uint8List?> Function(String url)? fetcher,
    bool persist = false,
  }) async {
    final mem = _bytesCache[url];
    if (mem != null) {
      _touch(url);
      return mem;
    }
    final pending = _inflight[url];
    if (pending != null) return pending;

    final future = _loadQueued(url, fetcher, persist);
    _inflight[url] = future;
    try {
      return await future;
    } finally {
      _inflight.remove(url);
    }
  }

  Future<Uint8List?> _loadQueued(
    String url,
    Future<Uint8List?> Function(String url)? fetcher,
    bool persist,
  ) async {
    if (_active >= _maxConcurrent) {
      final completer = Completer<void>();
      _waiting.add(() async => completer.complete());
      await completer.future;
    }
    _active++;
    try {
      return await _loadInternal(url, fetcher, persist);
    } finally {
      _active--;
      if (_waiting.isNotEmpty) {
        final next = _waiting.removeAt(0);
        unawaited(next());
      }
    }
  }

  Future<Uint8List?> _loadInternal(
    String url,
    Future<Uint8List?> Function(String url)? fetcher,
    bool persist,
  ) async {
    final mem = _bytesCache[url];
    if (mem != null) {
      _touch(url);
      return mem;
    }
    await _ensureDir();
    final f = _fileFor(url);
    if (f != null && f.existsSync()) {
      try {
        final plain = decryptBytes(await f.readAsBytes(), url);
        if (plain != null && plain.isNotEmpty) {
          _putBytes(url, plain);
          return plain;
        }
      } catch (_) {}
    }
    final bytes = await fetcher?.call(url);
    if (bytes == null || bytes.isEmpty) return null;
    await NetThrottle.instance.consume(bytes.length);
    _putBytes(url, bytes);
    if (persist) {
      unawaited(
        Future(() async {
          try {
            final enc = encryptBytes(bytes, url);
            await f?.writeAsBytes(enc, flush: false);
          } catch (_) {}
        }),
      );
    }
    return bytes;
  }

  Future<void> persistBytes(String url, Uint8List bytes) async {
    try {
      await _ensureDir();
      final f = _fileFor(url);
      if (f == null) return;
      if (await f.exists() && await f.length() > 0) return;
      final enc = encryptBytes(bytes, url);
      await f.writeAsBytes(enc, flush: false);
    } catch (_) {}
  }

  Future<Uint8List?> loadForDownload(
    String url, {
    Future<Uint8List?> Function(String url)? fetcher,
  }) {
    return load(url, fetcher: fetcher, persist: true);
  }

  bool isCached(String url) =>
      _bytesCache.containsKey(url) ||
      (_fileFor(url)?.existsSync() ?? false);

  void _putBytes(String url, Uint8List b) {
    final old = _bytesSize[url];
    if (old != null) _bytesTotal -= old;
    _bytesCache[url] = b;
    _bytesSize[url] = b.length;
    _bytesTotal += b.length;
    _touch(url);
    _evictBytes();
  }

  void _evictBytes() {
    var guard = 0;
    while ((_bytesTotal > _maxBytesTotal || _bytesCache.length > _maxBytes) &&
        guard++ < 4096) {
      if (_lru.isEmpty) break;
      var evictIndex = -1;
      for (var i = 0; i < _lru.length; i++) {
        if (!_pinned.contains(_lru[i])) {
          evictIndex = i;
          break;
        }
      }
      if (evictIndex < 0) break;
      final oldest = _lru.removeAt(evictIndex);
      _bytesCache.remove(oldest);
      final sz = _bytesSize.remove(oldest);
      if (sz != null) _bytesTotal -= sz;
      if (_bytesTotal < 0) _bytesTotal = 0;
    }
  }

  void pin(String url) {
    if (url.isEmpty) return;
    _pinned.add(url);
    _touch(url);
  }

  void unpin(String url) {
    _pinned.remove(url);
  }

  void _touch(String url) {
    _lru.remove(url);
    _lru.add(url);
  }

  ui.Image? getUiSync(String url) => _uiCache[url];

  void putUi(String url, ui.Image img) {
    final old = _uiSize[url];
    if (old != null) _uiTotal -= old;
    _uiCache[url] = img;
    final sz = img.width * img.height * 4;
    _uiSize[url] = sz;
    _uiTotal += sz;
    _touchUi(url);
    var guard = 0;
    while ((_uiTotal > _maxUiTotal || _uiCache.length > _maxUiImages) &&
        guard++ < 4096) {
      if (_uiLru.isEmpty) break;
      final oldest = _uiLru.first;
      if (oldest == url) break;
      _uiLru.removeAt(0);
      final removed = _uiCache.remove(oldest);
      if (removed == null) continue;
      final s = _uiSize.remove(oldest);
      if (s != null) _uiTotal -= s;
    }
    if (_uiTotal < 0) _uiTotal = 0;
  }

  final List<String> _uiLru = [];

  void _touchUi(String url) {
    _uiLru.remove(url);
    _uiLru.add(url);
  }

  static Future<ui.Image?> decode(Uint8List bytes) async {
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      return frame.image;
    } catch (_) {
      return null;
    }
  }

  static Future<ui.Image?> decodeScaled(
    Uint8List bytes, {
    int? targetWidth,
  }) async {
    if (targetWidth == null || targetWidth <= 0) {
      return decode(bytes);
    }
    try {
      final codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: targetWidth,
      );
      final frame = await codec.getNextFrame();
      return frame.image;
    } catch (_) {
      return decode(bytes);
    }
  }

  Future<int> prefetchChapter({
    required List<({String key, String? directUrl, String? resolveUrl})> items,
    required Future<Uint8List?> Function(String url) fetch,
    required Future<String?> Function(String pageUrl) resolve,
    String? scrambleId,
    String albumId = '',
    int concurrency = 5,
    void Function(int done, int total)? onProgress,
  }) async {
    if (items.isEmpty) return 0;
    var done = 0;
    var cursor = 0;

    Future<void> worker() async {
      while (true) {
        final i = cursor++;
        if (i >= items.length) return;
        final it = items[i];
        try {
          if (!isCached(it.key) || getUiSync(it.key) == null) {
            var url = it.directUrl;
            if (url == null && it.resolveUrl != null) {
              url = await resolve(it.resolveUrl!);
            }
            if (url != null && url.isNotEmpty) {
              final bytes = await load(url, fetcher: fetch);
              if (bytes != null && getUiSync(url) == null) {
                var data = bytes;
                final img = await decode(data);
                if (img != null) putUi(url, img);
                data = bytes;
              }
            }
          }
        } catch (_) {}
        done++;
        onProgress?.call(done, items.length);
      }
    }

    await Future.wait(List.generate(concurrency.clamp(1, 8), (_) => worker()));
    return done;
  }

  Future<void> evict(String url) async {
    try {
      final old = _bytesSize.remove(url);
      if (old != null) _bytesTotal -= old;
      _bytesCache.remove(url);
      _lru.remove(url);
      final ui = _uiCache.remove(url);
      ui?.dispose();
      final uiOld = _uiSize.remove(url);
      if (uiOld != null) _uiTotal -= uiOld;
      _uiLru.remove(url);
      _pinned.remove(url);
      await _ensureDir();
      final f = _fileFor(url);
      if (f != null && await f.exists()) await f.delete();
    } catch (_) {}
  }

  Future<void> clearDisk() async {
    try {
      final d = await _ensureDir();
      if (d.existsSync()) {
        for (final f in d.listSync()) {
          try {
            f.deleteSync(recursive: true);
          } catch (_) {}
        }
      }
      _bytesCache.clear();
      _bytesSize.clear();
      _lru.clear();
      _bytesTotal = 0;
      for (final i in _uiCache.values) {
        i.dispose();
      }
      _uiCache.clear();
      _uiSize.clear();
      _uiLru.clear();
      _uiTotal = 0;
    } catch (_) {}
  }

  Future<int> diskUsage() async {
    try {
      final d = await _ensureDir();
      var total = 0;
      for (final f in d.listSync()) {
        if (f is File) total += f.lengthSync();
      }
      return total;
    } catch (_) {
      return 0;
    }
  }
}

class CachedCover extends StatefulWidget {
  final String? url;
  final BoxFit fit;
  final BorderRadius? borderRadius;
  final int? memCacheWidth;

  const CachedCover({
    super.key,
    required this.url,
    this.fit = BoxFit.cover,
    this.borderRadius,
    this.memCacheWidth,
  });

  @override
  State<CachedCover> createState() => _CachedCoverState();
}

class _CachedCoverState extends State<CachedCover> {
  Uint8List? _bytes;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant CachedCover old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) {
      if (old.url != null && old.url!.isNotEmpty) {
        ImageCacheManager.instance.unpin(old.url!);
      }
      _bytes = null;
      _failed = false;
      _load();
    }
  }

  void _load() {
    final url = widget.url;
    if (url == null || url.isEmpty) return;
    ImageCacheManager.instance.pin(url);
    final sync = ImageCacheManager.instance.readSync(url);
    if (sync != null) {
      _bytes = sync;
      return;
    }
    ImageCacheManager.instance.load(url, fetcher: _fetch).then((b) {
      if (!mounted) return;
      if (b == null) {
        unawaited(AppLog.instance.log('IMG', 'cover fetch failed: $url'));
      }
      setState(() {
        _bytes = b;
        _failed = b == null;
      });
    });
  }

  static Future<Uint8List?> _fetch(String url) async {
    final b = await JmApi.instance.fetchBytes(url);
    if (b != null) return b;
    for (final alt in JmService.instance.imageUrlCandidates(url)) {
      final r = await JmApi.instance.fetchBytes(alt);
      if (r != null) {
        print('[JMOE] cover mirror ok: $alt');
        return r;
      }
    }
    print('[JMOE] cover fetch FAILED (all mirrors): $url');
    return null;
  }

  @override
  void dispose() {
    final url = widget.url;
    if (url != null && url.isNotEmpty) {
      ImageCacheManager.instance.unpin(url);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget child;
    if (_bytes != null) {
      child = Image.memory(
        _bytes!,
        fit: widget.fit,
        width: double.infinity,
        height: double.infinity,
        gaplessPlayback: true,
        cacheWidth: widget.memCacheWidth,
        filterQuality: FilterQuality.low,
      );
    } else {
      child = Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              scheme.surfaceContainerHighest,
              scheme.surfaceContainerHigh,
            ],
          ),
        ),
        alignment: Alignment.center,
        child: Icon(
          _failed ? Icons.broken_image_outlined : Icons.image_outlined,
          color: scheme.onSurfaceVariant.withValues(alpha: 0.32),
          size: 22,
        ),
      );
    }
    if (widget.borderRadius != null) {
      child = ClipRRect(borderRadius: widget.borderRadius!, child: child);
    }
    return child;
  }
}
