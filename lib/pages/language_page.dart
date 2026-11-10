import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/app_theme.dart';
import '../core/jm_protocol.dart';
import '../core/l10n.dart';
import '../widgets/common_widgets.dart';
import 'unified_home_page.dart';

class LanguagePage extends StatefulWidget {
  const LanguagePage({super.key});

  @override
  State<LanguagePage> createState() => _LanguagePageState();
}

class _LanguagePageState extends State<LanguagePage> {
  static List<(String, String, String)> get _uiOptions => [
    ('zh-Hans', L.t('langZhHans'), '简体中文'),
    ('zh-Hant', L.t('langZhHant'), '繁體中文'),
    ('en', 'English', 'English'),
  ];

  static List<(String, String, String)> get _contentOptions => [
    ('CN', L.t('langZhHans'), '简体中文'),
    ('TW', L.t('langZhHant'), '繁體中文'),
    ('JP', L.t('langJa'), '日本語'),
    ('EN', 'English', 'English'),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = AppState.instance;
    final scheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(title: Text(L.t('languageManage'))),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          SectionHeader(title: L.t('uiLanguage')),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
            child: Text(
              L.t('uiLanguageDesc'),
              style: TextStyle(
                fontSize: 11.5,
                height: 1.5,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          Container(
            margin: const EdgeInsets.symmetric(horizontal: AppStyle.pagePadding),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              children: _uiOptions.map((o) {
                final active = state.uiLang == o.$1;
                return ListTile(
                  title: Text(
                    o.$2,
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: active ? FontWeight.w700 : FontWeight.w400,
                      color: active ? scheme.primary : null,
                    ),
                  ),
                  subtitle: Text(
                    o.$3,
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  trailing: active
                      ? Icon(Icons.check_circle, size: 20, color: scheme.primary)
                      : null,
                  onTap: () async {
                    await state.setUiLang(o.$1);
                    if (mounted) setState(() {});
                  },
                );
              }).toList(),
            ),
          ),

          SectionHeader(title: L.t('contentLang')),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
            child: Text(
              L.t('contentLangDesc'),
              style: TextStyle(
                fontSize: 11.5,
                height: 1.5,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          Container(
            margin: const EdgeInsets.symmetric(horizontal: AppStyle.pagePadding),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              children: _contentOptions.map((o) {
                final active = state.lang == o.$1;
                return ListTile(
                  title: Text(
                    o.$2,
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: active ? FontWeight.w700 : FontWeight.w400,
                      color: active ? scheme.primary : null,
                    ),
                  ),
                  subtitle: Text(
                    o.$3,
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  trailing: active
                      ? Icon(Icons.check_circle, size: 20, color: scheme.primary)
                      : null,
                  onTap: () async {
                    await state.setLang(o.$1);
                    JmApi.instance.lang = o.$1;
                    UnifiedHomePageState.clearCache();
                    if (mounted) {
                      setState(() {});
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(L.t('contentLangChanged')),
                          duration: const Duration(seconds: 2),
                        ),
                      );
                    }
                  },
                );
              }).toList(),
            ),
          ),
          const SizedBox(height: 20),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppStyle.pagePadding),
            child: Text(
              L.t('langTip'),
              style: TextStyle(
                fontSize: 11,
                height: 1.6,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
