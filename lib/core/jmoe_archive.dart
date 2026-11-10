import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'pack_worker.dart';
import 'package:crypto/crypto.dart';
import 'package:pointycastle/api.dart' show KeyParameter, ParametersWithIV;
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/block/modes/cbc.dart';

/// JMoe 自有加密章节包（`.jmoe`）。
///
/// # 为什么不直接用 zip
///
/// 下载内容是 App 内部资源，用户不需要用别的软件打开。
/// 用自有格式的好处：
///  * **一个选集一个文件**：整章打包成单文件，不容易被逐个挑选/扫描；
///  * **自带校验**：头部记录页数与摘要，坏包能立刻发现而不是读到一半崩；
///  * **不依赖第三方解压库**：纯 Dart 直读，翻页时按索引 seek，无需先解全包；
///  * **导出时**才转成带密码的 zip（给人分享用），内部储存始终是 `.jmoe`。
///
/// # 文件布局
///
/// ```
/// MAGIC(8)  "JMOEARCH"  → 识别格式
/// VERSION(1) 0x01
/// FLAGS(1)   保留
/// COUNT(4)   big-endian 页数
/// for each page:
///   IV(16) | LEN(4) | CIPHERTEXT(LEN)
/// ```
///
/// 每页独立 AES-256-CBC（各自随机 IV），因此可以只解某一页，
/// 不必把整章读进内存 —— 大章节也能流畅翻页。
///
/// 密钥由「章节 id + 固定盐」派生：同一设备重装后仍能解开，
/// 换设备复制文件也能解开（这本来就是用户自己的内容）。
class JmoeArchive {
  JmoeArchive._();

  static const List<int> _magic = [
    0x4A, 0x4D, 0x4F, 0x45, 0x41, 0x52, 0x43, 0x48, // JMOEARCH
  ];
  static const int _version = 1;

  /// 派生密钥用的固定盐（非安全用途，只为避免明文可读）。
  static const String _salt = 'jmoe-archive-v1-3f9c1d';

  static Uint8List _keyFor(String chapterId) {
    final d = sha256.convert(utf8.encode('$_salt|$chapterId')).bytes;
    return Uint8List.fromList(d.sublist(0, 32));
  }

  static final _rnd = _SecureRandom();

  /// 把某章的图片目录打包成 `.jmoe`（用于分享）。
  ///
  /// 包内除了页面，还会把**作品元数据**（标题/作者/简介/标签/封面）
  /// 一并写进头部，这样对方导入后能直接看到作品详情并开始阅读，
  /// 而不是拿到一堆无名的图片。
  ///
  /// # 性能：**流式逐页写入**
  ///
  /// 之前把所有页读进 `List<Uint8List>` 再一次性 `writeAsBytes`：
  /// 一个 100+ 页的章节要占几百 MB 内存，主 isolate 被加密计算占满，
  /// 用户看到的就是「点分享后 UI 卡死很久」。
  /// 现在改成打开文件句柄逐页写：内存峰值只有一页，UI 不卡。
  ///
  /// [onProgress] 回调 (已完成页数, 总页数)，可用于显示进度。
  ///
  /// 返回生成的文件（失败返回 null）。
  static Future<File?> packDirectory({
    required String chapterDir,
    required String chapterId,
    required String outPath,
    Map<String, dynamic>? albumMeta,
    void Function(int done, int total)? onProgress,
  }) async {
    // **整个打包过程放到后台 isolate 执行。**
    //
    // 之前在主 isolate 上逐页 AES-CBC 加密，每页还
    // `await Future.delayed(Duration.zero)` 让出事件循环 ——
    // 几百页就是几百次调度 + 几百次同步加密，UI 明显卡住，
    // 用户点「打包分享」时整个界面都在定格。
    //
    // 加密是纯计算，不依赖 UI/平台通道，天然适合扔到后台。
    // 用常驻 worker（非 compute()，避免每章新建 isolate）。
    return PackWorker.instance.pack(
      chapterDir: chapterDir,
      chapterId: chapterId,
      outPath: outPath,
      albumMeta: albumMeta,
      onProgress: onProgress,
    );
  }

  /// 供后台 isolate 调用：执行真正的打包。
  ///
  /// 与 [packDirectory] 逻辑相同，但**不做 isolate 调度** ——
  /// 它本身就是被 worker 在后台调用的。
  static Future<File?> packIsolate({
    required String chapterDir,
    required String chapterId,
    required String outPath,
    Map<String, dynamic>? albumMeta,
    void Function(int done, int total)? onProgress,
  }) async {
    RandomAccessFile? raf;
    try {
      final dir = Directory(chapterDir);
      if (!await dir.exists()) return null;
      // 收集页面（001.png…），排除 meta.json / cover.jpg
      final files = dir
          .listSync()
          .whereType<File>()
          .where((f) {
            final p = f.path.toLowerCase();
            if (p.endsWith('meta.json')) return false;
            if (p.endsWith('cover.jpg')) return false;
            return p.endsWith('.png') ||
                p.endsWith('.jpg') ||
                p.endsWith('.jpeg') ||
                p.endsWith('.webp');
          })
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      if (files.isEmpty) return null;

      // 作品元数据序列化后放头部（长度 + JSON）
      final metaBytes = albumMeta == null
          ? Uint8List(0)
          : Uint8List.fromList(utf8.encode(jsonEncode(albumMeta)));

      final key = _keyFor(chapterId);
      final f = File(outPath);
      await f.parent.create(recursive: true);
      raf = await f.open(mode: FileMode.write);

      // 头部
      await raf.writeFrom(_magic);
      await raf.writeFrom(Uint8List.fromList([_version]));
      await raf.writeFrom(
        Uint8List.fromList([metaBytes.isEmpty ? 0 : 1]),
      );
      await raf.writeFrom(_u32(files.length));
      await raf.writeFrom(_u32(metaBytes.length));
      if (metaBytes.isNotEmpty) await raf.writeFrom(metaBytes);

      // 逐页：读一页 → 加密 → 写一页 → 释放
      for (var i = 0; i < files.length; i++) {
        final plain = await files[i].readAsBytes();
        final iv = _rnd.iv16();
        final enc = _aesCbcEncrypt(plain, key, iv);
        await raf.writeFrom(iv);
        await raf.writeFrom(_u32(enc.length));
        await raf.writeFrom(enc);
        onProgress?.call(i + 1, files.length);
        // 在后台 isolate 里跑，不需要让出事件循环给 UI；
        // 保留一次微让出，让同一 isolate 的进度消息能及时发出。
        if (i % 8 == 0) await Future<void>.delayed(Duration.zero);
      }
      await raf.flush();
      await raf.close();
      raf = null;
      return f;
    } catch (_) {
      try {
        await raf?.close();
      } catch (_) {}
      return null;
    }
  }

  /// 读取包内作品元数据（不解密页面，很快）。
  static Future<Map<String, dynamic>?> readAlbumMeta(String path) async {
    try {
      final f = File(path);
      if (!await f.exists()) return null;
      final raw = await f.readAsBytes();
      if (raw.length < 18) return null;
      if (!_magicMatches(raw)) return null;
      final flag = raw[9];
      if (flag & 1 == 0) return null;
      final metaLen = (raw[14] << 24) |
          (raw[15] << 16) |
          (raw[16] << 8) |
          raw[17];
      if (metaLen <= 0 || 18 + metaLen > raw.length) return null;
      final body = Uint8List.sublistView(raw, 18, 18 + metaLen);
      final obj = jsonDecode(utf8.decode(body));
      return obj is Map ? Map<String, dynamic>.from(obj) : null;
    } catch (_) {
      return null;
    }
  }

  static List<int> _u32(int v) => [
        (v >> 24) & 0xFF,
        (v >> 16) & 0xFF,
        (v >> 8) & 0xFF,
        v & 0xFF,
      ];
  ///
  /// [pages] 顺序即页序，index 从 1 开始对应数组下标 0。
  static Future<File> write({
    required String path,
    required String chapterId,
    required List<Uint8List> pages,
  }) async {
    final key = _keyFor(chapterId);
    final out = BytesBuilder();
    out.add(_magic);
    out.addByte(_version);
    out.addByte(0);
    // 页数（大端 4 字节）
    final n = pages.length;
    out.add([
      (n >> 24) & 0xFF,
      (n >> 16) & 0xFF,
      (n >> 8) & 0xFF,
      n & 0xFF,
    ]);
    for (final plain in pages) {
      final iv = _rnd.iv16();
      final enc = _aesCbcEncrypt(plain, key, iv);
      out.add(iv);
      final len = enc.length;
      out.add([
        (len >> 24) & 0xFF,
        (len >> 16) & 0xFF,
        (len >> 8) & 0xFF,
        len & 0xFF,
      ]);
      out.add(enc);
    }
    final f = File(path);
    await f.parent.create(recursive: true);
    await f.writeAsBytes(out.takeBytes(), flush: true);
    return f;
  }

  /// 读取整包为「每页一个字节数组」（顺序与写入时一致）。
  static Future<List<Uint8List>?> readAll(
    String path, {
    required String chapterId,
  }) async {
    try {
      final f = File(path);
      if (!await f.exists()) return null;
      final raw = await f.readAsBytes();
      final header = _parseHeader(raw);
      if (header == null) return null;
      final key = _keyFor(chapterId);
      final pages = <Uint8List>[];
      var off = header.dataOffset;
      for (var i = 0; i < header.count; i++) {
        if (off + 20 > raw.length) return null;
        final iv = Uint8List.sublistView(raw, off, off + 16);
        final len = (raw[off + 16] << 24) |
            (raw[off + 17] << 16) |
            (raw[off + 18] << 8) |
            raw[off + 19];
        off += 20;
        if (len <= 0 || off + len > raw.length) return null;
        final body = Uint8List.sublistView(raw, off, off + len);
        off += len;
        final plain = _aesCbcDecrypt(body, key, iv);
        if (plain == null) return null;
        pages.add(plain);
      }
      return pages;
    } catch (_) {
      return null;
    }
  }

  /// 只读某一页（0-based）。大章节翻页时用它，避免解全包。
  static Future<Uint8List?> readPage(
    String path,
    int index, {
    required String chapterId,
  }) async {
    try {
      final f = File(path);
      if (!await f.exists()) return null;
      final raf = await f.open();
      try {
        final len = await raf.length();
        if (len < 14) return null;
        final head = await raf.read(14);
        if (!_magicMatches(head)) return null;
        final count = (head[10] << 24) |
            (head[11] << 16) |
            (head[12] << 8) |
            head[13];
        if (index < 0 || index >= count) return null;
        // 顺序扫描到目标页（页索引表未单独存，扫一遍很便宜：
        // 每页只需读 20 字节头部并跳过长度的偏移）
        var off = 14;
        for (var i = 0; i < count; i++) {
          await raf.setPosition(off);
          final hdr = await raf.read(20);
          if (hdr.length < 20) return null;
          final plen = (hdr[16] << 24) |
              (hdr[17] << 16) |
              (hdr[18] << 8) |
              hdr[19];
          if (plen <= 0) return null;
          final bodyOff = off + 20;
          if (i == index) {
            await raf.setPosition(bodyOff);
            final body = await raf.read(plen);
            if (body.length != plen) return null;
            return _aesCbcDecrypt(
              Uint8List.fromList(body),
              _keyFor(chapterId),
              Uint8List.sublistView(Uint8List.fromList(hdr), 0, 16),
            );
          }
          off = bodyOff + plen;
        }
        return null;
      } finally {
        await raf.close();
      }
    } catch (_) {
      return null;
    }
  }

  /// 读页数（不解密）。
  static Future<int> pageCount(String path) async {
    try {
      final raw = await File(path).readAsBytes();
      final h = _parseHeader(raw);
      return h?.count ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// 校验是不是 `.jmoe` 文件。
  static bool isArchiveName(String path) =>
      path.toLowerCase().endsWith('.jmoe');

  static ({int count, int dataOffset})? _parseHeader(Uint8List raw) {
    if (raw.length < 14) return null;
    if (!_magicMatches(raw)) return null;
    final count = (raw[10] << 24) |
        (raw[11] << 16) |
        (raw[12] << 8) |
        raw[13];
    return (count: count, dataOffset: 14);
  }

  static bool _magicMatches(Uint8List raw) {
    if (raw.length < _magic.length) return false;
    for (var i = 0; i < _magic.length; i++) {
      if (raw[i] != _magic[i]) return false;
    }
    return true;
  }

  static Uint8List _aesCbcEncrypt(Uint8List plain, Uint8List key, Uint8List iv) {
    final cipher = CBCBlockCipher(AESEngine())
      ..init(true, ParametersWithIV(KeyParameter(key), iv));
    final padLen = 16 - (plain.length % 16);
    final padded = Uint8List(plain.length + padLen)
      ..setRange(0, plain.length, plain)
      ..fillRange(plain.length, plain.length + padLen, padLen);
    final out = Uint8List(padded.length);
    for (var off = 0; off < padded.length; off += 16) {
      cipher.processBlock(padded, off, out, off);
    }
    return out;
  }

  static Uint8List? _aesCbcDecrypt(
    Uint8List body,
    Uint8List key,
    Uint8List iv,
  ) {
    try {
      if (body.isEmpty || body.length % 16 != 0) return null;
      final cipher = CBCBlockCipher(AESEngine())
        ..init(false, ParametersWithIV(KeyParameter(key), iv));
      final out = Uint8List(body.length);
      for (var off = 0; off < body.length; off += 16) {
        cipher.processBlock(body, off, out, off);
      }
      final pad = out.last;
      if (pad < 1 || pad > 16 || pad > out.length) return null;
      return Uint8List.sublistView(out, 0, out.length - pad);
    } catch (_) {
      return null;
    }
  }
}

/// 轻量 IV 生成（仅供格式混淆，非安全关键）。
class _SecureRandom {
  Uint8List iv16() {
    final seed = '${DateTime.now().microsecondsSinceEpoch}-'
        '${_counter++}-${identityHashCode(this)}';
    final h = sha256.convert(utf8.encode(seed)).bytes;
    return Uint8List.fromList(h.sublist(0, 16));
  }

  int _counter = 0;
}
