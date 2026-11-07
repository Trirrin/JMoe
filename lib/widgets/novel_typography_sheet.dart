import 'package:flutter/material.dart';

import '../core/l10n.dart';
import '../core/reader_settings.dart';

/// 小说排版设置面板。
///
/// 从 `novel_pages.dart` 抽出，只负责滑块与选项渲染。
class NovelTypographySheet extends StatelessWidget {
  const NovelTypographySheet({
    super.key,
    required this.settings,
    required this.theme,
    required this.onChanged,
    required this.onOpenPageMode,
  });

  final ReaderSettings settings;
  final ReaderTheme theme;

  /// 任一参数变化后回调（用于让阅读器重排）
  final VoidCallback onChanged;
  final VoidCallback onOpenPageMode;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              L.t('typography'),
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: theme.fg,
              ),
            ),
            const SizedBox(height: 14),
            // 翻页模式入口
            OutlinedButton.icon(
              onPressed: onOpenPageMode,
              icon: Icon(
                settings.pageMode == PageMode.scroll
                    ? Icons.swap_vert_rounded
                    : Icons.swap_horiz_rounded,
                size: 16,
              ),
              label: Text(
                '${L.t('pageMode')} · ${_modeLabel()}',
                style: const TextStyle(fontSize: 12.5),
              ),
            ),
            const SizedBox(height: 6),
            _slider(
              L.t('fontSize'),
              settings.fontSize,
              12,
              32,
              1,
              (v) => settings.update(() => settings.fontSize = v),
            ),
            _slider(
              L.t('lineHeight'),
              settings.lineHeight,
              1.2,
              2.6,
              1,
              (v) => settings.update(() => settings.lineHeight = v),
            ),
            _slider(
              L.t('letterSpacing'),
              settings.letterSpacing,
              0,
              3,
              1,
              (v) => settings.update(() => settings.letterSpacing = v),
            ),
            _slider(
              L.t('paragraphSpacing'),
              settings.paragraphSpacing,
              0,
              30,
              0,
              (v) => settings.update(() => settings.paragraphSpacing = v),
            ),
            _slider(
              L.t('marginH'),
              settings.marginH,
              8,
              40,
              0,
              (v) => settings.update(() => settings.marginH = v),
            ),
            _slider(
              L.t('marginV'),
              settings.marginV,
              8,
              40,
              0,
              (v) => settings.update(() => settings.marginV = v),
            ),
            _slider(
              L.t('indent'),
              settings.indent,
              0,
              3,
              1,
              (v) => settings.update(() => settings.indent = v),
            ),
            const SizedBox(height: 6),
            // 字重
            _chips(
              L.t('fontWeight'),
              ['常规', '中等', '粗体'],
              settings.weightIndex,
              (i) => settings.update(() => settings.weightIndex = i),
            ),
            const SizedBox(height: 10),
            // 字体
            _chips(
              L.t('fontFamily'),
              ['默认', '衬线'],
              settings.fontIndex,
              (i) => settings.update(() => settings.fontIndex = i),
            ),
            const SizedBox(height: 10),
            // 对齐
            _alignChips(),
          ],
        ),
      ),
    );
  }

  String _modeLabel() => switch (settings.pageMode) {
        PageMode.slide => L.t('modeSlide'),
        PageMode.cover => L.t('modeCover'),
        PageMode.none => L.t('modeNone'),
        PageMode.scroll => L.t('modeScroll'),
      };

  Widget _slider(
    String label,
    double value,
    double min,
    double max,
    int decimals,
    ValueChanged<double> onChanged,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(fontSize: 12.5, color: theme.fg),
                ),
              ),
              Text(
                value.toStringAsFixed(decimals),
                style: TextStyle(fontSize: 11.5, color: theme.subtle),
              ),
            ],
          ),
          Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            onChanged: (v) {
              onChanged(v);
            },
          ),
        ],
      ),
    );
  }

  Widget _chips(
    String label,
    List<String> options,
    int selected,
    ValueChanged<int> onPick,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(fontSize: 12.5, color: theme.fg)),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          children: List.generate(options.length, (i) {
            final on = i == selected;
            return ChoiceChip(
              label: Text(options[i], style: const TextStyle(fontSize: 11.5)),
              selected: on,
              onSelected: (_) => onPick(i),
            );
          }),
        ),
      ],
    );
  }

  Widget _alignChips() {
    final options = [
      (TextAlign.justify, '两端'),
      (TextAlign.left, '左'),
      (TextAlign.center, '中'),
      (TextAlign.right, '右'),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(L.t('alignment'),
            style: TextStyle(fontSize: 12.5, color: theme.fg)),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          children: options.map((o) {
            final on = settings.align == o.$1;
            return ChoiceChip(
              label: Text(o.$2, style: const TextStyle(fontSize: 11.5)),
              selected: on,
              onSelected: (_) => settings.update(() => settings.align = o.$1),
            );
          }).toList(),
        ),
      ],
    );
  }
}
