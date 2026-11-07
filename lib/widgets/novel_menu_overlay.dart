import 'package:flutter/material.dart';

import '../core/l10n.dart';
import '../core/reader_settings.dart';

/// 小说阅读器的菜单覆盖层（顶栏 + 底部工具栏）。
///
/// 从原 `novel_pages.dart`（2000+ 行）中抽出，职责单一：
/// 只负责渲染菜单与控制动画，不处理业务逻辑。
class NovelMenuOverlay extends StatelessWidget {
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
  final double progress;
  final ValueChanged<double> onProgressChanged;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onClose,
      child: Container(
        color: Colors.black.withValues(alpha: 0.25),
        child: AnimatedBuilder(
          animation: animation,
          builder: (context, child) {
            final t = Curves.easeOutCubic.transform(animation.value);
            return Opacity(
              opacity: t,
              child: Transform.translate(
                offset: Offset(0, 24 * (1 - t)),
                child: child,
              ),
            );
          },
          child: SafeArea(
            child: Column(
              children: [
                _topBar(context),
                const Spacer(),
                _progressBar(context),
                _toolbar(context),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _topBar(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: theme.bg.withValues(alpha: 0.96),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 10,
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

  Widget _progressBar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: SliderTheme(
        data: SliderTheme.of(context).copyWith(
          trackHeight: 2,
          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
          overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
        ),
        child: Slider(
          value: progress.clamp(0.0, 1.0),
          onChanged: onProgressChanged,
        ),
      ),
    );
  }

  Widget _toolbar(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: theme.bg.withValues(alpha: 0.96),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 10,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: Row(
        children: [
          _btn(Icons.list_rounded, L.t('catalog'), onCatalog),
          _btn(Icons.search_rounded, L.t('searchInBook'), onSearch),
          _btn(Icons.text_fields_rounded, L.t('typography'), onTypography),
          _btn(Icons.palette_outlined, L.t('theme'), onTheme),
          _btn(Icons.bookmark_add_outlined, L.t('addBookmark'), onBookmark),
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
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            children: [
              Icon(icon, size: 21, color: theme.fg),
              const SizedBox(height: 4),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 9.5, color: theme.subtle),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
