import 'dart:convert';

import 'package:crypto/crypto.dart';

/// JM 图片「打乱」还原。
///
/// 官方实现（`scramble_image` + `get_num`）：
///   ```js
///   const altKey = image.match(/\/([^/]+)\.webp/)?.[1] ?? String(page);
///   var num = get_num(btoa(aid), btoa(altKey));
///   ```
/// **注意**：分片数依赖的 `page` 参数取的是 **URL 文件名**（如 `00001`），
/// 不是整数页序号；用整数会导致每页分片数算错、拼接错乱。
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

  /// 从图片地址提取官方使用的 page 键。
  ///
  /// 官方正则只匹配 `.webp`；这里扩展为「路径最后一段的文件名（去扩展名）」，
  /// 对 `.webp` 结果与官方完全一致，同时对 `.jpg/.png` 也能取到正确文件名，
  /// 比官方的回退（直接用整数页号）更稳。
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

  /// 计算纵向切分段数。
  ///
  /// [pageKey] 必须是 [pageKeyFromUrl] 的结果（URL 文件名）。
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

  /// 是否需要还原：新作品才切图，GIF 不切。
  static bool needScramble(String albumId, String scrambleId, String url) {
    if (url.toLowerCase().contains('.gif')) return false;
    final aid = int.tryParse(albumId) ?? 0;
    final sid = int.tryParse(scrambleId) ?? 0;
    if (sid <= 0) return false;
    return aid >= sid;
  }
}
