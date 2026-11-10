import 'package:flutter/services.dart';
import 'l10n.dart';

class ShareUtil {
  static const MethodChannel _ch = MethodChannel('jmoe/share');

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

  static Future<bool> shareText(String text, {String? subject}) async {
    try {
      final r = await _ch.invokeMethod<bool>('shareText', {
        'text': text,
        'subject': ?subject,
      });
      if (r == true) return true;
    } catch (_) {}
    try {
      await Clipboard.setData(ClipboardData(text: text));
      return true;
    } catch (_) {
      return false;
    }
  }
}
