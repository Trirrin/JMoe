import 'dart:convert';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/widgets.dart';

class L {
  L._();

  static const List<Locale> supported = [
    Locale('zh', 'Hans'),
    Locale('zh', 'Hant'),
    Locale('en'),
  ];

  static const Map<String, String> _files = {
    'zh': 'assets/i18n/zh.json',
    'zhHant': 'assets/i18n/zhHant.json',
    'en': 'assets/i18n/en.json',
  };

  static final Map<String, Map<String, String>> _tables = {};

  static String _lang = 'zh';
  static bool _loaded = false;

  static String get lang => _lang;
  static bool get isHant => _lang == 'zhHant';
  static bool get isEn => _lang == 'en';
  static bool get loaded => _loaded;

  static Future<void> load() async {
    if (_loaded) return;
    for (final entry in _files.entries) {
      try {
        final raw = await rootBundle.loadString(entry.value);
        final map = jsonDecode(raw);
        if (map is Map) {
          _tables[entry.key] = map.map(
            (k, v) => MapEntry('$k', '$v'),
          );
        }
      } catch (_) {
      }
    }
    _loaded = true;
  }

  static void setLang(String lang) {
    final next = _normalize(lang);
    if (_lang == next) return;
    _lang = next;
    _notifier.value++;
  }

  static final ValueNotifier<int> _notifier = ValueNotifier<int>(0);
  static ValueListenable<int> get listenable => _notifier;

  static String _normalize(String lang) {
    switch (lang) {
      case 'zh-Hant':
      case 'zhHant':
      case 'zh-TW':
      case 'zh-HK':
        return 'zhHant';
      case 'en':
      case 'en-US':
      case 'en-GB':
        return 'en';
      default:
        return 'zh';
    }
  }

  static String t(String key) {
    final cur = _tables[_lang];
    final v = cur?[key];
    if (v != null && v.isNotEmpty) return v;
    final fb = _tables['zh']?[key];
    if (fb != null && fb.isNotEmpty) return fb;
    final en = _tables['en']?[key];
    if (en != null && en.isNotEmpty) return en;
    return key;
  }

  static String tp(String key, Map<String, Object?> args) {
    var s = t(key);
    args.forEach((k, v) {
      s = s.replaceAll('{$k}', '${v ?? ''}');
    });
    return s;
  }

  static bool has(String key) => _tables[_lang]?.containsKey(key) ?? false;

  static Map<String, Map<String, String>> get tables => _tables;
}
