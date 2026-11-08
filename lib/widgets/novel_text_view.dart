import 'package:flutter/material.dart';

import '../core/reader_paginator.dart';
import '../core/reader_settings.dart';
import '../core/reader_store.dart';

/// 小说正文渲染与交互层。
///
/// 从 `novel_pages.dart`（原 2100+ 行）抽出的**正文展示**职责：
/// - 分页模式：单页 SelectableText + 左右滑动翻页
/// - 滚动模式：整章连续滚动 + 到底自动续读
/// - 文本选择菜单、高亮批注
///
/// 不持有加载/缓存/统计逻辑，全部通过回调交给页面。
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

  /// 全文（可能含多章合并内容）
  final String pageSource;

  /// 分页结果
  final List<PageSlice> pages;
  final int currentPage;

  final ScrollController scrollController;
  final double scrollRatio;

  /// 当前页范围内的批注/高亮
  final List<({int start, int end, Color color, bool underline})>
      highlightRanges;

  final ValueChanged<int> onTurn;
  final VoidCallback onTap;
  final ValueChanged<TextSelection> onSelectionChanged;
  final Widget Function(BuildContext, EditableTextState) onContextMenu;

  /// 滚动接近底部（自动续读）
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

  // ---------------- 滚动模式 ----------------

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

  // ---------------- 分页模式 ----------------

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

    // 分页模式的手势：
    // - 横向滑动 → 翻页
    // - 点左侧 1/4 → 上一页
    // - 点右侧 1/4 → 下一页
    // - 点中间 → 呼出菜单
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

  /// 统一的内容内边距：顶部含状态栏，底部含进度栏高度。
  EdgeInsets _contentPadding(BuildContext context) {
    // 状态栏由外层 SafeArea 处理，这里只留正常边距
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


/// 只把「真正的点击」识别为 tap，并上报点击位置。
///
/// 直接用 Listener.onPointerUp 会在滑动结束时也触发，
/// 导致一滑动就弹出菜单。这里记录按下与抬起的位移，
/// 超过阈值视为拖动，不触发点击。
class _TapDetector extends StatefulWidget {
  const _TapDetector({
    this.onTap,
    this.onTapAt,
    required this.child,
  });

  /// 简单点击回调（不需要位置时用）
  final VoidCallback? onTap;

  /// 带位置的点击回调：pos = 局部 x 坐标，width = 控件宽度
  final void Function(double pos, double width)? onTapAt;

  final Widget child;

  @override
  State<_TapDetector> createState() => _TapDetectorState();
}

class _TapDetectorState extends State<_TapDetector> {
  Offset? _downAt;
  static const double _slop = 12; // 允许的手指抖动

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
            if ((e.position - d).distance > _slop) return; // 拖动，不算点击

            final at = widget.onTapAt;
            if (at != null) {
              // 用全局坐标减去控件左上角，得到局部 x
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
