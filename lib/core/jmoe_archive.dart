import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'pack_worker.dart';
import 'package:crypto/crypto.dart';
import 'package:pointycastle/api.dart' show KeyParameter, ParametersWithIV;
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/block/modes/cbc.dart';

class JmoeArchive {
  JmoeArchive._();

  static const List<int> _magic = [
    0x4A, 0x4D, 0x4F, 0x45, 0x41, 0x52, 0x43, 0x48,
  ];
  static const int _version = 1;

  static const String _salt = 'jmoe-archive-v1-3f9c1d';

  static Uint8List _keyFor(String chapterId) {
    final d = sha256.convert(utf8.encode('$_salt|$chapterId')).bytes;
    return Uint8List.fromList(d.sublist(0, 32));
  }

  static final _rnd = _SecureRandom();

  static Future<File?> packDirectory({
    required String chapterDir,
    required String chapterId,
    required String outPath,
    Map<String, dynamic>? albumMeta,
    void Function(int done, int total)? onProgress,
  }) async {
    return PackWorker.instance.pack(
      chapterDir: chapterDir,
      chapterId: chapterId,
      outPath: outPath,
      albumMeta: albumMeta,
      onProgress: onProgress,
    );
  }

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

      final metaBytes = albumMeta == null
          ? Uint8List(0)
          : Uint8List.fromList(utf8.encode(jsonEncode(albumMeta)));

      final key = _keyFor(chapterId);
      final f = File(outPath);
      await f.parent.create(recursive: true);
      raf = await f.open(mode: FileMode.write);

      await raf.writeFrom(_magic);
      await raf.writeFrom(Uint8List.fromList([_version]));
      await raf.writeFrom(
        Uint8List.fromList([metaBytes.isEmpty ? 0 : 1]),
      );
      await raf.writeFrom(_u32(files.length));
      await raf.writeFrom(_u32(metaBytes.length));
      if (metaBytes.isNotEmpty) await raf.writeFrom(metaBytes);

      for (var i = 0; i < files.length; i++) {
        final plain = await files[i].readAsBytes();
        final iv = _rnd.iv16();
        final enc = _aesCbcEncrypt(plain, key, iv);
        await raf.writeFrom(iv);
        await raf.writeFrom(_u32(enc.length));
        await raf.writeFrom(enc);
        onProgress?.call(i + 1, files.length);
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

  static Future<int> pageCount(String path) async {
    try {
      final raw = await File(path).readAsBytes();
      final h = _parseHeader(raw);
      return h?.count ?? 0;
    } catch (_) {
      return 0;
    }
  }

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

class _SecureRandom {
  Uint8List iv16() {
    final seed = '${DateTime.now().microsecondsSinceEpoch}-'
        '${_counter++}-${identityHashCode(this)}';
    final h = sha256.convert(utf8.encode(seed)).bytes;
    return Uint8List.fromList(h.sublist(0, 16));
  }

  int _counter = 0;
}
