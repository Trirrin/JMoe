import 'package:flutter/material.dart';

import '../core/l10n.dart';
import '../core/reader_settings.dart';

class NovelThemeSheet extends StatelessWidget {
  const NovelThemeSheet({
    super.key,
    required this.settings,
    required this.theme,
    required this.onChanged,
  });

  final ReaderSettings settings;

  final ReaderTheme theme;

  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(18, 0, 18, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              L.t('theme'),
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: theme.fg,
              ),
            ),
            const SizedBox(height: 14),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              value: settings.followSystemTheme,
              onChanged: (v) {
                settings.update(() => settings.followSystemTheme = v);
                onChanged();
              },
              title: Text(
                L.t('followAppTheme'),
                style: TextStyle(fontSize: 13, color: theme.fg),
              ),
              subtitle: Text(
                L.t('followAppThemeDesc'),
                style: TextStyle(fontSize: 10.5, color: theme.subtle),
              ),
            ),
            const Divider(height: 24),
            Opacity(
              opacity: settings.followSystemTheme ? 0.4 : 1,
              child: IgnorePointer(
                ignoring: settings.followSystemTheme,
                child: Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: ReaderTheme.all.map((t) {
                    final on = settings.themeId == t.id;
                    return GestureDetector(
                      onTap: () {
                        settings.update(() {
                          settings.themeId = t.id;
                          settings.followSystemTheme = false;
                        });
                        onChanged();
                      },
                      child: Container(
                        width: 68,
                        height: 68,
                        decoration: BoxDecoration(
                          color: t.bg,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: on
                                ? theme.fg
                                : theme.subtle.withValues(alpha: 0.35),
                            width: on ? 2 : 1,
                          ),
                        ),
                        child: Stack(
                          children: [
                            Center(
                              child: Text(
                                'Aa',
                                style: TextStyle(
                                  fontSize: 17,
                                  fontWeight: FontWeight.w600,
                                  color: t.fg,
                                ),
                              ),
                            ),
                            if (on)
                              Positioned(
                                right: 4,
                                top: 4,
                                child: Icon(
                                  Icons.check_circle_rounded,
                                  size: 13,
                                  color: t.fg,
                                ),
                              ),
                          ],
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
