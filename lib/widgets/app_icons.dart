import 'dart:math' as math;

import 'package:flutter/material.dart';

class AppIcons {
  AppIcons._();

  static Widget anime({
    double size = 22,
    Color? color,
  }) =>
      _AnimeIcon(size: size, color: color);

  static Widget novel({
    double size = 22,
    Color? color,
  }) =>
      _NovelIcon(size: size, color: color);

  static Widget weeklyStars({
    double size = 22,
    Color? color,
  }) =>
      _WeeklyStarsIcon(size: size, color: color);
}

class _WeeklyStarsIcon extends StatelessWidget {
  final double size;
  final Color? color;
  const _WeeklyStarsIcon({required this.size, this.color});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _WeeklyStarsPainter(
          color ?? IconTheme.of(context).color ?? Colors.black,
        ),
      ),
    );
  }
}

class _WeeklyStarsPainter extends CustomPainter {
  final Color color;
  _WeeklyStarsPainter(this.color);

  void _star(Canvas canvas, Offset c, double r, Paint p) {
    final path = Path();
    for (var i = 0; i < 10; i++) {
      final rr = i.isEven ? r : r * 0.44;
      final ang = -1.5707963267948966 + i * 0.6283185307179586;
      final x = c.dx + rr * math.cos(ang);
      final y = c.dy + rr * math.sin(ang);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    path.close();
    canvas.drawPath(path, p);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    final fill = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    _star(canvas, Offset(s * 0.34, s * 0.36), s * 0.30, fill);
    _star(canvas, Offset(s * 0.74, s * 0.62), s * 0.21, fill);
    _star(canvas, Offset(s * 0.80, s * 0.22), s * 0.13, fill);
  }

  @override
  bool shouldRepaint(covariant _WeeklyStarsPainter old) =>
      old.color != color;
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

    final rect = RRect.fromRectAndRadius(
      Rect.fromLTWH(s * 0.06, s * 0.22, s * 0.88, s * 0.56),
      Radius.circular(s * 0.12),
    );
    canvas.drawRRect(rect, paint);

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
      ..strokeWidth = s * 0.075
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final top = s * 0.18;
    final bottom = s * 0.82;
    final midX = s * 0.5;

    final leftPage = Path()
      ..moveTo(midX, top)
      ..lineTo(s * 0.22, top)
      ..quadraticBezierTo(s * 0.14, top, s * 0.14, top + s * 0.09)
      ..lineTo(s * 0.14, bottom - s * 0.09)
      ..quadraticBezierTo(
        s * 0.14,
        bottom,
        s * 0.22,
        bottom,
      )
      ..lineTo(midX, bottom);
    canvas.drawPath(leftPage, paint);

    final rightPage = Path()
      ..moveTo(midX, top)
      ..lineTo(s * 0.78, top)
      ..quadraticBezierTo(s * 0.86, top, s * 0.86, top + s * 0.09)
      ..lineTo(s * 0.86, bottom - s * 0.09)
      ..quadraticBezierTo(
        s * 0.86,
        bottom,
        s * 0.78,
        bottom,
      )
      ..lineTo(midX, bottom);
    canvas.drawPath(rightPage, paint);

    canvas.drawLine(
      Offset(midX, top),
      Offset(midX, bottom),
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = s * 0.075,
    );

    final text = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = s * 0.055
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      Offset(s * 0.24, s * 0.40),
      Offset(s * 0.42, s * 0.40),
      text,
    );
    canvas.drawLine(
      Offset(s * 0.58, s * 0.40),
      Offset(s * 0.76, s * 0.40),
      text,
    );
    canvas.drawLine(
      Offset(s * 0.24, s * 0.56),
      Offset(s * 0.40, s * 0.56),
      text,
    );
    canvas.drawLine(
      Offset(s * 0.60, s * 0.56),
      Offset(s * 0.76, s * 0.56),
      text,
    );
  }

  @override
  bool shouldRepaint(covariant _NovelPainter old) => old.color != color;
}
