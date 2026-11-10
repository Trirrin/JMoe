import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

class PageSlice {
  final int start;
  final int end;
  final int index;

  const PageSlice({required this.start, required this.end, required this.index});
}

class TextPaginator {
  const TextPaginator();

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

    final tp = TextPainter(
      text: TextSpan(text: prepared, style: style),
      textAlign: align,
      textDirection: TextDirection.ltr,
      textHeightBehavior: const TextHeightBehavior(
        applyHeightToFirstAscent: false,
        applyHeightToLastDescent: false,
      ),
    )..layout(maxWidth: maxWidth);

    final lines = _extractLines(tp, prepared);
    final totalHeight = tp.height;
    tp.dispose();

    if (lines.isEmpty) {
      return [PageSlice(start: 0, end: prepared.length, index: 0)];
    }

    if (totalHeight <= maxHeight) {
      return [PageSlice(start: 0, end: prepared.length, index: 0)];
    }

    final result = <PageSlice>[];
    var pageStartLine = 0;
    var pageTop = lines.first.top;

    for (var i = 0; i < lines.length; i++) {
      final ln = lines[i];
      final bottom = ln.top + ln.height;
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
        result.add(PageSlice(
          start: ln.start,
          end: ln.end,
          index: result.length,
        ));
        pageStartLine = i + 1;
        pageTop = i + 1 < lines.length ? lines[i + 1].top : bottom;
      }
    }

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

  List<_LineInfo> _extractLines(TextPainter tp, String text) {
    final lines = <_LineInfo>[];
    final metrics = tp.computeLineMetrics();
    if (metrics.isEmpty) return lines;

    var charCursor = 0;
    for (var i = 0; i < metrics.length; i++) {
      final m = metrics[i];
      final bottomY = m.baseline - m.ascent + m.height;
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

List<String> splitParagraphs(String text) {
  return text
      .split(RegExp(r'\n{1,}'))
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();
}

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

const List<({String label, String? family})> kReaderFonts = [
  (label: 'fontDefault', family: null),
  (label: 'fontSerif', family: 'serif'),
  (label: 'fontMono', family: 'monospace'),
];

Color overlayFor(double brightness) {
  if (brightness >= 0) {
    return Colors.white.withValues(alpha: brightness.clamp(0.0, 0.6));
  }
  return Colors.black.withValues(alpha: (-brightness).clamp(0.0, 0.7));
}

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
