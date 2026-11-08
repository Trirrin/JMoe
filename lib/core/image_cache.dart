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

/// 统一的图片缓存：**加密磁盘存储** + 内存 LRU + 并发去重 + 整章预缓存。
///
/// 磁盘上不保存任何明文图片：写入前用 AES-256-CBC 加密，
/// 文件头写入随机 IV，因此用系统图片查看器 / 其他 App 无法直接打开阅读。
/// 内存缓存仅在进程内存在，退出即释放。
class ImageCacheManager {
  ImageCacheManager._();
  static final ImageCacheManager instance = ImageCacheManager._();

  Directory? _dir;

  /// 内存缓存（解码后的 ui.Image，阅读器直接用，避免重复解码）
  final Map<String, ui.Image> _uiCache = {};

  /// 内存缓存（明文原始字节，供 Image.memory 使用）
  final Map<String, Uint8List> _bytesCache = {};

  /// 进行中的请求（去重，避免同一 URL 并发重复下载）
  final Map<String, Future<Uint8List?>> _inflight = {};

  /// LRU 顺序（_bytesCache）
  final List<String> _lru = [];

  /// 每张图在内存中占的字节数（用于按字节预算淘汰）
  final Map<String, int> _bytesSize = {};

  /// 解码图占用的估算字节（width * height * 4）
  final Map<String, int> _uiSize = {};

  /// 「正在显示」的图片（如详情页封面）：淘汰时跳过，避免闪白
  final Set<String> _pinned = {};

  // ---- 内存预算 ----
  //
  // 早期按「条数」限制（512 条字节 + 200 条解码图），但一张 3000×4000 的
  // 大图解码后就是 ~48MB，200 条理论上是 GB 级 —— 手机直接 OOM。
  // 因此全部改成**按字节**限额，超限即按 LRU 淘汰。

  /// 原始字节缓存上限（默认 96MB）
  static const int _maxBytesTotal = 96 * 1024 * 1024;

  /// 解码图缓存上限（默认 128MB）
  static const int _maxUiTotal = 128 * 1024 * 1024;

  /// 条数上限仍保留一道，避免「大量极小图」把 Map 撑爆
  static const int _maxUiImages = 200;
  static const int _maxBytes = 512;

  int _bytesTotal = 0;
  int _uiTotal = 0;

  /// 当前内存占用（原始字节 + 解码图估算），供设置页/日志展示。
  int get memoryBytes => _bytesTotal + _uiTotal;

  /// 封面/图片加载并发上限：超出排队，避免滚动时抢占 I/O 导致卡顿。
  static const int _maxConcurrent = 6;
  int _active = 0;
  final List<Future<void> Function()> _waiting = [];

  // ---------------- 加密参数 ----------------

  /// 缓存加密密钥：由固定口令 + url 派生，保证不同图片用不同密钥。
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

  /// 加密：`MAGIC(4) | IV(16) | ciphertext`
  static const List<int> _magic = [0x4A, 0x4D, 0x43, 0x01]; // JMC\x01

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

  // ---------------- 磁盘 ----------------

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

  /// **仅查内存**（不做任何磁盘 I/O 与解密）。
  ///
  /// 滚动列表中若在此同步读盘+解密，会阻塞 UI 线程导致掉帧，
  /// 因此磁盘命中一律交给 [load] 异步完成。
  Uint8List? readSync(String url) {
    final mem = _bytesCache[url];
    if (mem != null) {
      _touch(url);
      return mem;
    }
    return null;
  }

  /// **仅读磁盘**：解密后返回，但**不写入内存缓存**。
  ///
  /// 给「大章节落临时目录」用：那时我们只想要字节去写临时文件，
  /// 不希望它被塞进内存 LRU（整章几百 MB 会直接把内存挤爆）。
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

  /// 异步获取：内存 → 磁盘(解密) → 网络(并加密落盘)。
  Future<Uint8List?> load(
    String url, {
    Future<Uint8List?> Function(String url)? fetcher,
    // 默认只进内存（临时缓存）：阅读时路过的图片不写盘，
    // 避免缓存体积失控。需要长期保存的「下载」显式传 true。
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

  /// 受并发上限约束的实际加载。
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
    // 内存优先：已解码的字节直接返回，避免重复解密磁盘导致闪白
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
    // 网络限速：按实际字节数消耗令牌（大图才明显）
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

  /// 把已在内存中的字节写盘（用于「读完整章后补写」）。
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

  /// 下载专用：强制持久化到磁盘。
  ///
  /// 与 [load] 的区别：只有这里写盘，用于「用户主动下载」的场景。
  Future<Uint8List?> loadForDownload(
    String url, {
    Future<Uint8List?> Function(String url)? fetcher,
  }) {
    return load(url, fetcher: fetcher, persist: true);
  }

  /// 预判是否已缓存（不触发网络）。
  bool isCached(String url) =>
      _bytesCache.containsKey(url) ||
      (_fileFor(url)?.existsSync() ?? false);

  void _putBytes(String url, Uint8List b) {
    // 覆盖旧值时先扣掉旧尺寸，否则预算会越算越大
    final old = _bytesSize[url];
    if (old != null) _bytesTotal -= old;
    _bytesCache[url] = b;
    _bytesSize[url] = b.length;
    _bytesTotal += b.length;
    _touch(url);
    _evictBytes();
  }

  /// 按字节预算淘汰（同时保留条数上限作为兜底）。
  ///
  /// 跳过 pinned（正在显示的图），避免详情页封面被挤出后闪白。
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
      if (evictIndex < 0) break; // 全是 pinned，放弃本次淘汰
      final oldest = _lru.removeAt(evictIndex);
      _bytesCache.remove(oldest);
      final sz = _bytesSize.remove(oldest);
      if (sz != null) _bytesTotal -= sz;
      if (_bytesTotal < 0) _bytesTotal = 0;
    }
  }

  /// 标记为「正在显示」，淘汰时优先保留。
  void pin(String url) {
    if (url.isEmpty) return;
    _pinned.add(url);
    _touch(url);
  }

  /// 取消保留。
  void unpin(String url) {
    _pinned.remove(url);
  }

  void _touch(String url) {
    _lru.remove(url);
    _lru.add(url);
  }

  // ---------------- 解码后的 ui.Image ----------------

  ui.Image? getUiSync(String url) => _uiCache[url];

  void putUi(String url, ui.Image img) {
    final old = _uiSize[url];
    if (old != null) _uiTotal -= old;
    _uiCache[url] = img;
    final sz = img.width * img.height * 4;
    _uiSize[url] = sz;
    _uiTotal += sz;
    _touchUi(url);
    // 按字节预算淘汰，再兜一道条数上限
    var guard = 0;
    while ((_uiTotal > _maxUiTotal || _uiCache.length > _maxUiImages) &&
        guard++ < 4096) {
      if (_uiLru.isEmpty) break;
      final oldest = _uiLru.first;
      if (oldest == url) break; // 刚放进去的别立刻删
      _uiLru.removeAt(0);
      // 不 dispose 被淘汰对象：阅读器可能仍持有该 ui.Image，
      // dispose 后会导致 RawImage 渲染成灰色。交由 GC 回收。
      final removed = _uiCache.remove(oldest);
      if (removed == null) continue;
      final s = _uiSize.remove(oldest);
      if (s != null) _uiTotal -= s;
    }
    if (_uiTotal < 0) _uiTotal = 0;
  }

  /// 解码图 LRU 顺序
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

  /// 整章预缓存：并发抓取 + 还原 + 解码进内存，读时零等待。
  ///
  /// [items] 每项为 (缓存键, 直接地址, 需解析的页面地址)。
  /// 返回已就绪数量。
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

  /// 精确删除单张图片（内存 + 磁盘）。
  ///
  /// 用于「只删某一章缓存」：不能整目录清光，否则删一本会连带清掉全部。
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

/// 基于统一加密缓存的封面组件。
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
    // 正在显示：标记保留，避免被 LRU 淘汰导致闪白
    ImageCacheManager.instance.pin(url);
    final sync = ImageCacheManager.instance.readSync(url);
    if (sync != null) {
      _bytes = sync;
      return;
    }
    ImageCacheManager.instance.load(url, fetcher: _fetch).then((b) {
      if (!mounted) return;
      if (b == null) {
        // 记一条日志：封面全灰时至少要能看出「是取图失败还是解码失败」
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
    // 取图失败：服务端可能下发了一个死掉的 CDN 域名。
    // 依次换成像 cdns 再试 —— 这是「封面全灰」的自愈路径。
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
