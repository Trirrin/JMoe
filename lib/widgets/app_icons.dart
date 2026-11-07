import 'package:flutter/material.dart';

/// 自绘图标集。
///
/// 内置 Material 图标里 `movie_outlined` / `theaters` 的上边缘是梯形（斜边），
/// 视觉上像是画歪了。这里用 CustomPainter 重绘，保证上下边水平、比例端正。
class AppIcons {
  AppIcons._();

  /// 动漫/影片图标：圆角矩形 + 两侧胶片齿孔 + 中央播放三角。
  static Widget anime({
    double size = 22,
    Color? color,
  }) =>
      _AnimeIcon(size: size, color: color);

  /// 小说/书籍图标：规整的书页 + 书脊。
  static Widget novel({
    double size = 22,
    Color? color,
  }) =>
      _NovelIcon(size: size, color: color);
}

class _AnimeIcon extends StatelessWidget {
  final double size;
  final Color? color;
  const _AnimeIcon({required this.size, this.color});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _AnimePainter(color ?? IconTheme.of(context).color ?? Colors.black),
      ),
    );
  }
}

class _AnimePainter extends CustomPainter {
  final Color color;
  _AnimePainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = s * 0.085
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    // 外框：横向矩形，上下边完全水平
    final rect = RRect.fromRectAndRadius(
      Rect.fromLTWH(s * 0.06, s * 0.22, s * 0.88, s * 0.56),
      Radius.circular(s * 0.12),
    );
    canvas.drawRRect(rect, paint);

    // 左侧齿孔（三个小方块）
    final hole = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    final holeW = s * 0.085;
    final holeH = s * 0.075;
    for (var i = 0; i < 3; i++) {
      final y = s * 0.34 + i * s * 0.13;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(s * 0.15, y, holeW, holeH),
          Radius.circular(s * 0.02),
        ),
        hole,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(s * 0.765, y, holeW, holeH),
          Radius.circular(s * 0.02),
        ),
        hole,
      );
    }

    // 中央播放三角（正三角形）
    final cx = s * 0.5;
    final cy = s * 0.5;
    final r = s * 0.135;
    final tri = Path()
      ..moveTo(cx - r * 0.75, cy - r)
      ..lineTo(cx + r * 1.05, cy)
      ..lineTo(cx - r * 0.75, cy + r)
      ..close();
    canvas.drawPath(
      tri,
      Paint()
        ..color = color
        ..style = PaintingStyle.fill,
    );
  }

  @override
  bool shouldRepaint(covariant _AnimePainter old) => old.color != color;
}

class _NovelIcon extends StatelessWidget {
  final double size;
  final Color? color;
  const _NovelIcon({required this.size, this.color});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _NovelPainter(color ?? IconTheme.of(context).color ?? Colors.black),
      ),
    );
  }
}

class _NovelPainter extends CustomPainter {
  final Color color;
  _NovelPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = s * 0.085
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    // 书脊
    canvas.drawLine(
      Offset(s * 0.2, s * 0.14),
      Offset(s * 0.2, s * 0.86),
      paint,
    );

    // 封面：右侧圆角矩形
    final cover = RRect.fromRectAndRadius(
      Rect.fromLTWH(s * 0.2, s * 0.14, s * 0.64, s * 0.72),
      Radius.circular(s * 0.08),
    );
    canvas.drawRRect(cover, paint);

    // 两条文字线
    final line = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = s * 0.06
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      Offset(s * 0.34, s * 0.36),
      Offset(s * 0.7, s * 0.36),
      line,
    );
    canvas.drawLine(
      Offset(s * 0.34, s * 0.52),
      Offset(s * 0.6, s * 0.52),
      line,
    );
  }

  @override
  bool shouldRepaint(covariant _NovelPainter old) => old.color != color;
}
