import 'package:flutter/services.dart';
import 'l10n.dart';

/// 系统分享。
///
/// Flutter 无内置分享，这里通过平台通道调用 Android 原生 `ACTION_SEND`。
/// 由 MainActivity 侧（share 通道）实现；若通道不可用则退回剪贴板。
class ShareUtil {
  static const MethodChannel _ch = MethodChannel('jmoe/share');

  /// 分享作品文本。
  ///
  /// 文本格式（自定义语法，便于识别与解析）：
  /// ```
  /// 【JMoe】作品分享
  /// 《名称》 - 作者
  /// JM123456
  /// ```
  /// EH 源直接输出 gid（无前缀、无井号）。
  static Future<bool> shareComic({
    required String sourceId,
    required String serial,
    required String name,
    String author = '',
    String? cover,
  }) async {
    final tag = sourceId == 'jm' ? 'JM$serial' : serial;
    final buf = StringBuffer()
      ..writeln(L.t('shareTitle'))
      ..writeln('《$name》${author.isNotEmpty ? ' - $author' : ''}')
      ..write(tag);
    return shareText(buf.toString(), subject: name);
  }

  /// 分享任意文本。
  static Future<bool> shareText(String text, {String? subject}) async {
    try {
      final r = await _ch.invokeMethod<bool>('shareText', {
        'text': text,
        if (subject != null) 'subject': subject,
      });
      if (r == true) return true;
    } catch (_) {}
    // 兜底：复制到剪贴板
    try {
      await Clipboard.setData(ClipboardData(text: text));
      return true;
    } catch (_) {
      return false;
    }
  }
}
