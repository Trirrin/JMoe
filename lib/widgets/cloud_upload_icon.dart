import 'package:flutter/material.dart';

/// 「上传到云端」图标：**云 + 向上箭头**，单色描边风格。
///
/// 参考常见云上传图标：一条连续的云轮廓（左下单开口）+ 竖直箭头从开口处
/// 向上穿出。全部用 `Path` 自绘，保证任意尺寸都清晰、颜色只取当前
/// `IconTheme` 的色（黑白随主题走，不写死蓝色）。
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
    // 全部按 24×24 设计，再等比缩放到实际尺寸
    final s = w / 24.0;

    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.7 * s
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    // ---- 云：底边中间留口，让箭头穿出 ----
    // 用「左半圆 + 两个顶部鼓包 + 右半圆」拼，比例对称、不会歪
    final cloud = Path();
    cloud.moveTo(8.6 * s, 19.0 * s);
    // 左下 → 左侧
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
    // 左上鼓包
    cloud.cubicTo(6.2 * s, 6.6 * s, 9.4 * s, 4.0 * s, 13.0 * s, 4.0 * s);
    cloud.cubicTo(16.1 * s, 4.0 * s, 18.8 * s, 6.0 * s, 19.9 * s, 8.9 * s);
    // 右侧鼓包 → 右下
    cloud.cubicTo(22.2 * s, 9.4 * s, 24.0 * s, 11.4 * s, 24.0 * s, 13.9 * s);
    cloud.cubicTo(24.0 * s, 16.7 * s, 21.7 * s, 19.0 * s, 18.9 * s, 19.0 * s);
    cloud.lineTo(15.4 * s, 19.0 * s);
    canvas.drawPath(cloud, stroke);

    // ---- 箭头：竖直、居中(x=12)，**比之前更大** ----
    final arrow = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0 * s
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    // 竖杆：从云下方一直顶到接近上沿
    canvas.drawLine(
      Offset(12.0 * s, 21.8 * s),
      Offset(12.0 * s, 7.6 * s),
      arrow,
    );
    // 箭头两撇：左右对称、张角适中（之前 8.6/15.4 与杆顶不匹配显得歪）
    final head = Path()
      ..moveTo(8.9 * s, 10.9 * s)
      ..lineTo(12.0 * s, 7.4 * s)
      ..lineTo(15.1 * s, 10.9 * s);
    canvas.drawPath(head, arrow);
  }

  @override
  bool shouldRepaint(_CloudUploadPainter old) => old.color != color;
}
