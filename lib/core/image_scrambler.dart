import 'dart:convert';

import 'package:crypto/crypto.dart';

class ImageScrambler {
  ImageScrambler._();

  static int _table(int key) {
    switch (key) {
      case 0:
        return 2;
      case 1:
        return 4;
      case 2:
        return 6;
      case 3:
        return 8;
      case 4:
        return 10;
      case 5:
        return 12;
      case 6:
        return 14;
      case 7:
        return 16;
      case 8:
        return 18;
      case 9:
        return 20;
      default:
        return 10;
    }
  }

  static String pageKeyFromUrl(String url, int page) {
    try {
      final path = Uri.parse(url).path;
      final seg = path.split('/').last;
      final dot = seg.lastIndexOf('.');
      final stem = dot > 0 ? seg.substring(0, dot) : seg;
      if (stem.isNotEmpty) return stem;
    } catch (_) {}
    return page.toString();
  }

  static int segments(String albumId, String pageKey) {
    final aid = int.tryParse(albumId) ?? 0;
    final digest = md5.convert(utf8.encode('${albumId.trim()}$pageKey')).toString();
    var code = digest.codeUnitAt(digest.length - 1);
    if (aid >= 268850 && aid <= 421925) {
      code = code % 10;
    } else if (aid >= 421926) {
      code = code % 8;
    }
    return _table(code);
  }

  static bool needScramble(String albumId, String scrambleId, String url) {
    if (url.toLowerCase().contains('.gif')) return false;
    final aid = int.tryParse(albumId) ?? 0;
    final sid = int.tryParse(scrambleId) ?? 0;
    if (sid <= 0) return false;
    return aid >= sid;
  }
}
