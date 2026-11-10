import 'package:flutter/material.dart';

import '../core/l10n.dart';
import '../core/reader_settings.dart';

class NovelMenuOverlay extends StatefulWidget {
  const NovelMenuOverlay({
    super.key,
    required this.animation,
    required this.theme,
    required this.title,
    required this.chapterIndex,
    required this.chapterCount,
    required this.pageLabel,
    required this.onClose,
    required this.onBack,
    required this.onCatalog,
    required this.onSearch,
    required this.onTypography,
    required this.onTheme,
    required this.onBookmark,
    required this.onTts,
    required this.ttsOn,
    required this.onAutoScroll,
    required this.autoScrolling,
    required this.progress,
    required this.onProgressChanged,
  });

  final Animation<double> animation;
  final ReaderTheme theme;
  final String title;
  final int chapterIndex;
  final int chapterCount;
  final String pageLabel;
  final VoidCallback onClose;
  final VoidCallback onBack;
  final VoidCallback onCatalog;
  final VoidCallback onSearch;
  final VoidCallback onTypography;
  final VoidCallback onTheme;
  final VoidCallback onBookmark;
  final VoidCallback onTts;
  final bool ttsOn;

  final VoidCallback onAutoScroll;
  final bool autoScrolling;
  final double progress;
  final ValueChanged<double> onProgressChanged;

  @override
  State<NovelMenuOverlay> createState() => _NovelMenuOverlayState();
}

class _NovelMenuOverlayState extends State<NovelMenuOverlay> {
  double? _dragValue;

  double get progress => _dragValue ?? widget.progress;

  Animation<double> get animation => widget.animation;
  ReaderTheme get theme => widget.theme;
  String get title => widget.title;
  int get chapterIndex => widget.chapterIndex;
  int get chapterCount => widget.chapterCount;
  String get pageLabel => widget.pageLabel;
  VoidCallback get onClose => widget.onClose;
  VoidCallback get onBack => widget.onBack;
  VoidCallback get onCatalog => widget.onCatalog;
  VoidCallback get onSearch => widget.onSearch;
  VoidCallback get onTypography => widget.onTypography;
  VoidCallback get onTheme => widget.onTheme;
  VoidCallback get onBookmark => widget.onBookmark;
  VoidCallback get onTts => widget.onTts;
  bool get ttsOn => widget.ttsOn;
  VoidCallback get onAutoScroll => widget.onAutoScroll;
  bool get autoScrolling => widget.autoScrolling;
  ValueChanged<double> get onProgressChanged => widget.onProgressChanged;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onClose,
      child: Container(
        color: Colors.black.withValues(alpha: 0.25),
        child: Column(
          children: [
            _slideIn(
              from: -1,
              child: _topBar(context),
            ),
            const Spacer(),
            _slideIn(
              from: 1,
              child: _bottomPanel(context),
            ),
          ],
        ),
      ),
    );
  }

  Widget _slideIn({required double from, required Widget child}) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, c) {
        final t = Curves.easeOutCubic.transform(animation.value);
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, from * 60 * (1 - t)),
            child: c,
          ),
        );
      },
      child: child,
    );
  }

  Color get _panelColor {
    final isDark = theme.bg.computeLuminance() < 0.5;
    return isDark
        ? Color.alphaBlend(Colors.white.withValues(alpha: 0.08), theme.bg)
        : Color.alphaBlend(Colors.black.withValues(alpha: 0.04), theme.bg);
  }

  Color get _dividerColor => theme.subtle.withValues(alpha: 0.28);

  Widget _topBar(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: _panelColor,
        border: Border(bottom: BorderSide(color: _dividerColor)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.15),
            blurRadius: 12,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          IconButton(
            icon: Icon(Icons.arrow_back_rounded, color: theme.fg),
            onPressed: onBack,
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: theme.fg,
                  ),
                ),
                Text(
                  '${chapterIndex + 1}/$chapterCount  ·  $pageLabel',
                  style: TextStyle(fontSize: 10, color: theme.subtle),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _bottomPanel(BuildContext context) {
    final bottomInset = MediaQuery.of(context).padding.bottom;
    return Container(
      decoration: BoxDecoration(
        color: _panelColor,
        border: Border(top: BorderSide(color: _dividerColor)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.18),
            blurRadius: 14,
            offset: const Offset(0, -3),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 2,
              activeTrackColor: theme.fg,
              inactiveTrackColor: theme.subtle.withValues(alpha: 0.3),
              thumbColor: theme.fg,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 4, 10, 0),
              child: Slider(
                value: progress.clamp(0.0, 1.0),
                onChanged: (v) => setState(() => _dragValue = v),
                onChangeEnd: (v) {
                  setState(() => _dragValue = null);
                  onProgressChanged(v);
                },
              ),
            ),
          ),
          _toolbarRow(bottomInset),
        ],
      ),
    );
  }

  Widget _toolbarRow(double bottomInset) {
    return Padding(
      padding: EdgeInsets.fromLTRB(4, 2, 4, 6 + bottomInset),
      child: Row(
        children: [
          _btn(Icons.list_rounded, L.t('catalog'), onCatalog),
          _btn(Icons.search_rounded, L.t('searchInBook'), onSearch),
          _btn(Icons.text_fields_rounded, L.t('typography'), onTypography),
          _btn(Icons.palette_outlined, L.t('theme'), onTheme),
          _btn(
            autoScrolling
                ? Icons.pause_circle_outline
                : Icons.play_circle_outline,
            autoScrolling ? L.t('stopAutoScroll') : L.t('autoScroll'),
            onAutoScroll,
          ),
          _btn(
            ttsOn
                ? Icons.stop_circle_outlined
                : Icons.record_voice_over_outlined,
            ttsOn ? L.t('stopReading') : L.t('readAloud'),
            onTts,
          ),
        ],
      ),
    );
  }

  Widget _btn(IconData icon, String label, VoidCallback onTap) {
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 7),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 20, color: theme.fg),
              const SizedBox(height: 3),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 9, color: theme.subtle),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
