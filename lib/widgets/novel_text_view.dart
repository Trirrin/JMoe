import 'package:flutter/material.dart';

import '../core/reader_paginator.dart';
import '../core/reader_settings.dart';
import '../core/reader_store.dart';

class NovelTextView extends StatelessWidget {
  const NovelTextView({
    super.key,
    required this.settings,
    required this.theme,
    required this.pageSource,
    required this.pages,
    required this.currentPage,
    required this.scrollController,
    required this.scrollRatio,
    required this.highlightRanges,
    required this.onTurn,
    required this.onTap,
    required this.onSelectionChanged,
    required this.onContextMenu,
    required this.onScrollNearBottom,
    required this.onScrollRatioChanged,
    required this.bookId,
    required this.chapterKey,
    required this.chapterTitle,
    required this.highlights,
  });

  final ReaderSettings settings;
  final ReaderTheme theme;

  final String pageSource;

  final List<PageSlice> pages;
  final int currentPage;

  final ScrollController scrollController;
  final double scrollRatio;

  final List<({int start, int end, Color color, bool underline})>
      highlightRanges;

  final ValueChanged<int> onTurn;
  final VoidCallback onTap;
  final ValueChanged<TextSelection> onSelectionChanged;
  final Widget Function(BuildContext, EditableTextState) onContextMenu;

  final void Function(double pixels, double maxExtent) onScrollNearBottom;
  final ValueChanged<double> onScrollRatioChanged;

  final String bookId;
  final String chapterKey;
  final String chapterTitle;
  final List<ReaderAnnotation> highlights;

  @override
  Widget build(BuildContext context) {
    return settings.pageMode == PageMode.scroll
        ? _buildScroll(context)
        : _buildPaged(context);
  }

  Widget _buildScroll(BuildContext context) {
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n.metrics.maxScrollExtent > 0) {
          final r = n.metrics.pixels / n.metrics.maxScrollExtent;
          if ((r - scrollRatio).abs() > 0.01) {
            onScrollRatioChanged(r.clamp(0.0, 1.0));
          }
          onScrollNearBottom(n.metrics.pixels, n.metrics.maxScrollExtent);
        }
        return false;
      },
      child: _TapDetector(
        onTap: onTap,
        child: SingleChildScrollView(
          controller: scrollController,
          physics: const AlwaysScrollableScrollPhysics(
            parent: BouncingScrollPhysics(),
          ),
          padding: _contentPadding(context),
          child: _text(context, pageSource, highlightRanges),
        ),
      ),
    );
  }

  Widget _buildPaged(BuildContext context) {
    if (pages.isEmpty) {
      return Center(
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: theme.subtle,
          ),
        ),
      );
    }
    final cur = pages[currentPage];
    final seg = pageSource.substring(
      cur.start.clamp(0, pageSource.length),
      cur.end.clamp(0, pageSource.length),
    );

    final body = Padding(
      padding: _contentPadding(context),
      child: _text(context, seg, highlightRanges),
    );

    return _TapDetector(
      onTapAt: (pos, width) {
        if (pos < width * 0.25) {
          onTurn(-1);
        } else if (pos > width * 0.75) {
          onTurn(1);
        } else {
          onTap();
        }
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragEnd: (d) {
          final v = d.primaryVelocity ?? 0;
          if (v < -180) {
            onTurn(1);
          } else if (v > 180) {
            onTurn(-1);
          }
        },
        child: body,
      ),
    );
  }

  EdgeInsets _contentPadding(BuildContext context) {
    return EdgeInsets.fromLTRB(
      settings.marginH,
      settings.marginV,
      settings.marginH,
      settings.marginV + (settings.showProgress ? 34 : 0),
    );
  }

  Widget _text(
    BuildContext context,
    String content,
    List<({int start, int end, Color color, bool underline})> ranges,
  ) {
    return SelectableText.rich(
      buildHighlightedSpan(
        text: content,
        base: settings.textStyleFor(theme),
        ranges: ranges,
      ),
      textAlign: settings.align,
      onSelectionChanged: (sel, _) => onSelectionChanged(sel),
      contextMenuBuilder: onContextMenu,
      selectionControls: materialTextSelectionControls,
    );
  }
}

class _TapDetector extends StatefulWidget {
  const _TapDetector({
    this.onTap,
    this.onTapAt,
    required this.child,
  });

  final VoidCallback? onTap;

  final void Function(double pos, double width)? onTapAt;

  final Widget child;

  @override
  State<_TapDetector> createState() => _TapDetectorState();
}

class _TapDetectorState extends State<_TapDetector> {
  Offset? _downAt;
  static const double _slop = 12;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (e) => _downAt = e.position,
          onPointerUp: (e) {
            final d = _downAt;
            _downAt = null;
            if (d == null) return;
            if ((e.position - d).distance > _slop) return;

            final at = widget.onTapAt;
            if (at != null) {
              final box = context.findRenderObject() as RenderBox?;
              final local = box?.globalToLocal(e.position).dx ?? 0;
              at(local, constraints.maxWidth);
            } else {
              widget.onTap?.call();
            }
          },
          onPointerCancel: (_) => _downAt = null,
          child: widget.child,
        );
      },
    );
  }
}
