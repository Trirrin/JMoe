import 'dart:convert';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/widgets.dart';

/// 多语言：文案全部来自 `assets/i18n/{zh,zhHant,en}.json`，代码里不再硬编码。
///
/// 用法：
///   `L.t('catalog')`
///   `L.tp('worksCount', {'n': 12})`  → 把 `{n}` 替换为 12
///
/// 启动时调用 [load] 预加载所有语言表；未加载完成时自动回退到 key（不会崩）。
class L {
  L._();

  static const List<Locale> supported = [
    Locale('zh', 'Hans'),
    Locale('zh', 'Hant'),
    Locale('en'),
  ];

  /// 语言代码 → 资源文件
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

  /// 预加载全部语言表（幂等）。
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
        // 单个语言加载失败不影响其它语言
      }
    }
    _loaded = true;
  }

  /// 切换界面语言（zh-Hans / zh-Hant / en）。
  static void setLang(String lang) {
    final next = _normalize(lang);
    if (_lang == next) return;
    _lang = next;
    _notifier.value++;
  }

  /// 供 UI 监听语言变化。
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

  /// 取文案；缺失时回退到简中，再回退到 key 本身。
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

  /// 带占位符的文案：`{n}` / `{name}` …
  static String tp(String key, Map<String, Object?> args) {
    var s = t(key);
    args.forEach((k, v) {
      s = s.replaceAll('{$k}', '${v ?? ''}');
    });
    return s;
  }

  /// 是否包含某 key（调试/测试用）。
  static bool has(String key) => _tables[_lang]?.containsKey(key) ?? false;

  /// 全部语言表（测试用，外部只读）。
  static Map<String, Map<String, String>> get tables => _tables;
}
