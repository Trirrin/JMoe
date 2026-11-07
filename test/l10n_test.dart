import 'package:flutter_test/flutter_test.dart';
import 'package:jmoe/core/l10n.dart';

void main() {
  // 文案来自 assets/i18n/*.json，需要绑定与资源加载
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await L.load();
  });

  test('三套语言表完整且正确', () {
    final keys = [
      'cancel',
      'tabDiscover',
      'tabSearch',
      'cacheManage',
      'uiLanguage',
      'searchComic',
      'startReading',
      'noAnime',
      'clearAllCache',
    ];
    final seen = <String, Map<String, String>>{};
    for (final lang in ['zh-Hans', 'zh-Hant', 'en']) {
      L.setLang(lang);
      final m = <String, String>{};
      for (final k in keys) {
        m[k] = L.t(k);
        expect(L.t(k), isNot(k), reason: '$lang 缺失 key: $k');
      }
      seen[lang] = Map.of(m); // 深拷贝，避免引用变化
    }
    expect(seen['zh-Hans']!['tabDiscover'], '发现');
    expect(seen['zh-Hant']!['tabDiscover'], '發現');
    expect(seen['en']!['tabDiscover'], 'Discover');
    for (final v in seen['en']!.values) {
      expect(
        RegExp(r'[\u4e00-\u9fff]').hasMatch(v),
        false,
        reason: '英文表混入中文: $v',
      );
    }
    final zhVals = seen['zh-Hans']!.values.toSet();
    expect(zhVals.length, greaterThan(keys.length ~/ 2));
  });

  test('占位符替换', () {
    L.setLang('zh-Hans');
    expect(L.tp('daysN', {'n': 7}), contains('7'));
  });

  test('三套语言键集合一致', () {
    final zh = L.tables['zh']?.keys.toSet() ?? {};
    final hant = L.tables['zhHant']?.keys.toSet() ?? {};
    final en = L.tables['en']?.keys.toSet() ?? {};
    expect(zh.isNotEmpty, true, reason: 'zh 表未加载');
    expect(hant.difference(zh), isEmpty, reason: '繁中多出键');
    expect(zh.difference(hant), isEmpty, reason: '繁中缺少键');
    expect(en.difference(zh), isEmpty, reason: '英文多出键');
    expect(zh.difference(en), isEmpty, reason: '英文缺少键');
  });
}
