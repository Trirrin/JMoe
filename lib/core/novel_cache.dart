import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pointycastle/api.dart' show KeyParameter, ParametersWithIV;
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/block/modes/cbc.dart';

/// 小说章节缓存：整章正文 **AES-256-CBC 加密落盘**，支持离线阅读与「先缓存再看」。
///
/// 文件格式与图片缓存一致：`MAGIC(4) | IV(16) | ciphertext`，
/// 因此用文本/图片查看器无法直接读取。
class NovelCacheManager {
  NovelCacheManager._();
  static final NovelCacheManager instance = NovelCacheManager._();

  Directory? _dir;

  static const String _secret = 'jmoe-novel-v1-7c2f91';
  static const List<int> _magic = [0x4A, 0x4E, 0x43, 0x01]; // JNC\x01
  static final math.Random _rnd = math.Random.secure();

  static Uint8List _keyFor(String seed) {
    final digest = sha256.convert(utf8.encode('$_secret|$seed')).bytes;
    return Uint8List.fromList(digest.sublist(0, 32));
  }

  static Uint8List _randomIv() {
    final iv = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      iv[i] = _rnd.nextInt(256);
    }
    return iv;
  }

  Future<Directory> _ensureDir() async {
    if (_dir != null) return _dir!;
    final base = await getApplicationSupportDirectory();
    final d = Directory('${base.path}/novel_cache');
    if (!await d.exists()) await d.create(recursive: true);
    _dir = d;
    return d;
  }

  String _key(String nid, String ncid) =>
      md5.convert(utf8.encode('$nid|$ncid')).toString();

  Future<File> _file(String nid, String ncid) async {
    final d = await _ensureDir();
    return File('${d.path}/${_key(nid, ncid)}.jnc');
  }

  /// 是否已缓存。
  Future<bool> has(String nid, String ncid) async {
    try {
      final f = await _file(nid, ncid);
      return await f.exists() && await f.length() > 20;
    } catch (_) {
      return false;
    }
  }

  /// 写入章节正文（加密）。
  Future<void> put(
    String nid,
    String ncid,
    String title,
    String text,
  ) async {
    try {
      final payload = jsonEncode({
        'title': title,
        'text': text,
        'at': DateTime.now().millisecondsSinceEpoch,
      });
      final enc = _encrypt(Uint8List.fromList(utf8.encode(payload)), '$nid|$ncid');
      final f = await _file(nid, ncid);
      await f.writeAsBytes(enc, flush: true);
    } catch (_) {}
  }

  /// 读取章节正文；未缓存或解密失败返回 null。
  Future<Map<String, dynamic>?> get(String nid, String ncid) async {
    try {
      final f = await _file(nid, ncid);
      if (!await f.exists()) return null;
      final raw = await f.readAsBytes();
      final plain = _decrypt(raw, '$nid|$ncid');
      if (plain == null) return null;
      final m = jsonDecode(utf8.decode(plain));
      if (m is Map) return Map<String, dynamic>.from(m);
    } catch (_) {}
    return null;
  }

  /// 删除某章缓存。
  Future<void> remove(String nid, String ncid) async {
    try {
      final f = await _file(nid, ncid);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  /// 清空全部小说缓存。
  Future<void> clearAll() async {
    try {
      final d = await _ensureDir();
      if (await d.exists()) await d.delete(recursive: true);
      _dir = null;
    } catch (_) {}
  }

  /// 占用字节数。
  Future<int> usedBytes() async {
    try {
      final d = await _ensureDir();
      if (!await d.exists()) return 0;
      var sum = 0;
      await for (final e in d.list(recursive: true)) {
        if (e is File) sum += await e.length();
      }
      return sum;
    } catch (_) {
      return 0;
    }
  }

  // ---------------- 加解密（AES-256-CBC/PKCS7） ----------------

  static Uint8List _encrypt(Uint8List plain, String seed) {
    final iv = _randomIv();
    final cipher = CBCBlockCipher(AESEngine())
      ..init(true, ParametersWithIV(KeyParameter(_keyFor(seed)), iv));
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

  static Uint8List? _decrypt(Uint8List raw, String seed) {
    try {
      if (raw.length < 4 + 16 + 16) return null;
      for (var i = 0; i < 4; i++) {
        if (raw[i] != _magic[i]) return null;
      }
      final iv = Uint8List.sublistView(raw, 4, 20);
      final body = Uint8List.sublistView(raw, 20);
      final cipher = CBCBlockCipher(AESEngine())
        ..init(false, ParametersWithIV(KeyParameter(_keyFor(seed)), iv));
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
}
