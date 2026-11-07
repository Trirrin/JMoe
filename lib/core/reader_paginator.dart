import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// 单页内容片段。
class PageSlice {
  final int start; // 全局字符偏移（含）
  final int end; // 全局字符偏移（不含）
  final int index;

  const PageSlice({required this.start, required this.end, required this.index});
}

/// 文本分页器：按给定宽度/高度与 TextStyle，把整章正文切成页。
///
/// 采用 TextPainter 的真实排版结果，用 `getPositionForOffset` 在「本页底部」
/// 反查应断在哪个字符，保证不出现半行或溢出。
class TextPaginator {
  const TextPaginator();

  /// 把 [text] 分页。
  ///
  /// [maxWidth] / [maxHeight] 为正文区可用尺寸（已扣掉内边距）。
  /// 把 [text] 分页（O(n)：全文仅 layout 一次）。
  ///
  /// 思路：
  ///   1. 用 TextPainter 对**整段文本** layout 一次；
  ///   2. 通过 getBoxesForSelection 拿到每一行的矩形（top/height）；
  ///   3. 按可用高度把连续的行分组成页；
  ///   4. 用行首/行尾字符偏移换算成页的 [start, end)。
  ///
  /// 这样与「逐页重新 layout」的结果一致，但只付出一次排版成本。
  List<PageSlice> paginate({
    required String text,
    required TextStyle style,
    required double maxWidth,
    required double maxHeight,
    required TextAlign align,
    double paragraphSpacing = 0,
    double indentEm = 0,
  }) {
    if (text.isEmpty || maxWidth <= 0 || maxHeight <= 0) return const [];

    final prepared = _prepare(text, indentEm);

    // 全文只 layout 一次
    final tp = TextPainter(
      text: TextSpan(text: prepared, style: style),
      textAlign: align,
      textDirection: TextDirection.ltr,
      textHeightBehavior: const TextHeightBehavior(
        applyHeightToFirstAscent: false,
        applyHeightToLastDescent: false,
      ),
    )..layout(maxWidth: maxWidth);

    // 提取每一行的字符区间与纵向位置
    final lines = _extractLines(tp, prepared);
    final totalHeight = tp.height;
    tp.dispose();

    if (lines.isEmpty) {
      return [PageSlice(start: 0, end: prepared.length, index: 0)];
    }

    // 若整体放得下，直接一页
    if (totalHeight <= maxHeight) {
      return [PageSlice(start: 0, end: prepared.length, index: 0)];
    }

    // 按高度分页
    final result = <PageSlice>[];
    var pageStartLine = 0;
    var pageTop = lines.first.top;

    for (var i = 0; i < lines.length; i++) {
      final ln = lines[i];
      final bottom = ln.top + ln.height;
      // 超出本页可用高度 → 在此行之前结束本页
      if (bottom - pageTop > maxHeight && i > pageStartLine) {
        final startChar = lines[pageStartLine].start;
        final endChar = lines[i - 1].end;
        result.add(PageSlice(
          start: startChar,
          end: endChar,
          index: result.length,
        ));
        pageStartLine = i;
        pageTop = ln.top;
      } else if (bottom - pageTop > maxHeight && i == pageStartLine) {
        // 单行就超高（极窄屏/超大字号）：至少放一行，避免死循环
        result.add(PageSlice(
          start: ln.start,
          end: ln.end,
          index: result.length,
        ));
        pageStartLine = i + 1;
        pageTop = i + 1 < lines.length ? lines[i + 1].top : bottom;
      }
    }

    // 收尾
    if (pageStartLine < lines.length) {
      final startChar = lines[pageStartLine].start;
      final endChar = lines.last.end;
      if (startChar < endChar) {
        result.add(PageSlice(
          start: startChar,
          end: endChar,
          index: result.length,
        ));
      }
    }

    if (result.isEmpty) {
      result.add(PageSlice(start: 0, end: prepared.length, index: 0));
    }
    return result;
  }

  /// 从已 layout 的 TextPainter 中提取「行」的字符区间与位置。
  List<_LineInfo> _extractLines(TextPainter tp, String text) {
    final lines = <_LineInfo>[];
    // 用 metrics 获取每行高度/基线，再按行边界求字符范围
    final metrics = tp.computeLineMetrics();
    if (metrics.isEmpty) return lines;

    var charCursor = 0;
    for (var i = 0; i < metrics.length; i++) {
      final m = metrics[i];
      // 该行底部所在的 y
      final bottomY = m.baseline - m.ascent + m.height;
      // 在该行底部中心取位置，得到本行结束字符
      final pos = tp.getPositionForOffset(
        Offset(m.width, bottomY - m.height / 2),
      );
      var end = pos.offset;
      if (end <= charCursor) end = charCursor + 1;
      if (end > text.length) end = text.length;

      lines.add(_LineInfo(
        start: charCursor,
        end: end,
        top: m.baseline - m.ascent,
        height: m.height,
      ));
      charCursor = end;
      if (charCursor >= text.length) break;
    }

    // 补齐可能的尾部
    if (lines.isNotEmpty && lines.last.end < text.length) {
      final last = lines.last;
      lines[lines.length - 1] = _LineInfo(
        start: last.start,
        end: text.length,
        top: last.top,
        height: last.height,
      );
    }
    return lines;
  }

  /// 首行缩进：在每个段落开头插入全角空格（U+3000 * indentEm）。
  /// 这样偏移就是「真实文本偏移」，后续高亮/书签可直接对应。
  String _prepare(String text, double indentEm) {
    if (indentEm <= 0) return text;
    final n = indentEm.round().clamp(0, 4);
    if (n == 0) return text;
    final pad = '\u3000' * n;
    final lines = text.split('\n');
    final out = StringBuffer();
    for (var i = 0; i < lines.length; i++) {
      final l = lines[i];
      if (l.trim().isNotEmpty) {
        out.write(pad);
        out.write(l);
      } else {
        out.write(l);
      }
      if (i != lines.length - 1) out.write('\n');
    }
    return out.toString();
  }
}

/// 测量文本高度（用于滚动模式预估总页数）。
double measureTextHeight({
  required String text,
  required TextStyle style,
  required double maxWidth,
  required TextAlign align,
}) {
  final tp = TextPainter(
    text: TextSpan(text: text, style: style),
    textAlign: align,
    textDirection: TextDirection.ltr,
  )..layout(maxWidth: math.max(1, maxWidth));
  final h = tp.height;
  tp.dispose();
  return h;
}

/// 把文本按段落切分为块，滚动模式用（便于实现段间距）。
List<String> splitParagraphs(String text) {
  return text
      .split(RegExp(r'\n{1,}'))
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();
}

/// 计算文本中某字符偏移处的近似纵向位置（用于书签跳转定位）。
double? offsetDyInText({
  required String text,
  required TextStyle style,
  required double maxWidth,
  required TextAlign align,
  required int offset,
}) {
  if (offset < 0 || offset > text.length) return null;
  final tp = TextPainter(
    text: TextSpan(text: text, style: style),
    textAlign: align,
    textDirection: TextDirection.ltr,
  )..layout(maxWidth: maxWidth);
  final boxes = tp.getBoxesForSelection(
    TextSelection(baseOffset: offset, extentOffset: math.min(offset + 1, text.length)),
  );
  double? dy;
  if (boxes.isNotEmpty) dy = boxes.first.top;
  tp.dispose();
  return dy;
}

/// 生成用于高亮的 TextSpan 树。
TextSpan buildHighlightedSpan({
  required String text,
  required TextStyle base,
  required List<({int start, int end, Color color, bool underline})> ranges,
}) {
  if (ranges.isEmpty) return TextSpan(text: text, style: base);
  final sorted = [...ranges]..sort((a, b) => a.start.compareTo(b.start));
  final children = <InlineSpan>[];
  var cur = 0;
  for (final r in sorted) {
    final s = r.start.clamp(0, text.length);
    final e = r.end.clamp(0, text.length);
    if (e <= s) continue;
    if (s > cur) {
      children.add(TextSpan(text: text.substring(cur, s), style: base));
    }
    children.add(TextSpan(
      text: text.substring(math.max(s, cur), e),
      style: base.copyWith(
        backgroundColor: r.color,
        decoration: r.underline ? TextDecoration.underline : null,
        decorationColor: r.underline ? base.color : null,
      ),
    ));
    cur = math.max(cur, e);
  }
  if (cur < text.length) {
    children.add(TextSpan(text: text.substring(cur), style: base));
  }
  return TextSpan(style: base, children: children);
}

/// 字体族常量（Flutter 内置逻辑字体）。
const List<({String label, String? family})> kReaderFonts = [
  (label: 'fontDefault', family: null),
  (label: 'fontSerif', family: 'serif'),
  (label: 'fontMono', family: 'monospace'),
];

/// 生成 UI 用的缩放比例（用于亮度遮罩）。
Color overlayFor(double brightness) {
  if (brightness >= 0) {
    return Colors.white.withValues(alpha: brightness.clamp(0.0, 0.6));
  }
  return Colors.black.withValues(alpha: (-brightness).clamp(0.0, 0.7));
}

/// 用于把 text 中 [start,end) 的选中文本转成 ui.Rect 列表的工具，供自定义选择菜单使用。
List<Rect> selectionRects({
  required TextPainter painter,
  required int start,
  required int end,
}) {
  final boxes =
      painter.getBoxesForSelection(TextSelection(baseOffset: start, extentOffset: end));
  return boxes
      .map((b) => Rect.fromLTRB(b.left, b.top, b.right, b.bottom))
      .toList();
}

/// 兼容不同 Flutter 版本的 Paragraph 生成（保留工具函数）。
ui.Paragraph buildParagraph(String text, TextStyle style, double width) {
  final pb = ui.ParagraphBuilder(ui.ParagraphStyle(
    textAlign: TextAlign.justify,
    fontSize: style.fontSize,
    height: style.height,
  ))
    ..pushStyle(ui.TextStyle(
      color: style.color,
      fontSize: style.fontSize,
      height: style.height,
      letterSpacing: style.letterSpacing,
      fontWeight: style.fontWeight,
      fontFamily: style.fontFamily,
    ))
    ..addText(text);
  final p = pb.build()..layout(ui.ParagraphConstraints(width: width));
  return p;
}

/// 单行的字符区间与纵向位置（分页用）。
class _LineInfo {
  final int start;
  final int end;
  final double top;
  final double height;
  const _LineInfo({
    required this.start,
    required this.end,
    required this.top,
    required this.height,
  });
}
