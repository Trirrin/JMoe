import 'package:flutter/material.dart';

class CloudUploadIcon extends StatelessWidget {
  const CloudUploadIcon({super.key, this.size = 24, this.color});

  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ??
        IconTheme.of(context).color ??
        Theme.of(context).colorScheme.onSurfaceVariant;
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _CloudUploadPainter(c)),
    );
  }
}

class _CloudUploadPainter extends CustomPainter {
  _CloudUploadPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final s = w / 24.0;

    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.7 * s
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final cloud = Path();
    cloud.moveTo(8.6 * s, 19.0 * s);
    cloud.lineTo(6.6 * s, 19.0 * s);
    cloud.cubicTo(
      4.0 * s,
      19.0 * s,
      2.2 * s,
      16.8 * s,
      2.2 * s,
      14.6 * s,
    );
    cloud.cubicTo(2.2 * s, 12.6 * s, 3.6 * s, 10.9 * s, 5.5 * s, 10.4 * s);
    cloud.cubicTo(6.2 * s, 6.6 * s, 9.4 * s, 4.0 * s, 13.0 * s, 4.0 * s);
    cloud.cubicTo(16.1 * s, 4.0 * s, 18.8 * s, 6.0 * s, 19.9 * s, 8.9 * s);
    cloud.cubicTo(22.2 * s, 9.4 * s, 24.0 * s, 11.4 * s, 24.0 * s, 13.9 * s);
    cloud.cubicTo(24.0 * s, 16.7 * s, 21.7 * s, 19.0 * s, 18.9 * s, 19.0 * s);
    cloud.lineTo(15.4 * s, 19.0 * s);
    canvas.drawPath(cloud, stroke);

    final arrow = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0 * s
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    canvas.drawLine(
      Offset(12.0 * s, 21.8 * s),
      Offset(12.0 * s, 7.6 * s),
      arrow,
    );
    final head = Path()
      ..moveTo(8.9 * s, 10.9 * s)
      ..lineTo(12.0 * s, 7.4 * s)
      ..lineTo(15.1 * s, 10.9 * s);
    canvas.drawPath(head, arrow);
  }

  @override
  bool shouldRepaint(_CloudUploadPainter old) => old.color != color;
}
