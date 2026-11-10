import 'dart:async';

import 'package:flutter/material.dart';

class MarqueeText extends StatefulWidget {
  final String text;
  final TextStyle? style;
  final int maxLines;

  final double velocity;

  final Duration pause;

  const MarqueeText(
    this.text, {
    super.key,
    this.style,
    this.maxLines = 1,
    this.velocity = 20,
    this.pause = const Duration(milliseconds: 700),
  });

  @override
  State<MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<MarqueeText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  Timer? _timer;
  double _overflowPx = 0;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this)
      ..addListener(() => setState(() {}))
      ..addStatusListener(_onStatus);
  }

  @override
  void didUpdateWidget(covariant MarqueeText old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text || old.style != widget.style) {
      _restart();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  void _restart() {
    _timer?.cancel();
    _ctrl.stop();
    _ctrl.value = 0;
    _schedule();
  }

  void _schedule() {
    if (_overflowPx <= 0.5) return;
    final ms = (_overflowPx / widget.velocity * 1000).clamp(1500, 15000).toInt();
    _ctrl.duration = Duration(milliseconds: ms);
    _timer?.cancel();
    _timer = Timer(widget.pause, () {
      if (mounted && _overflowPx > 0.5) _ctrl.forward(from: 0);
    });
  }

  void _onStatus(AnimationStatus s) {
    if (!mounted || _overflowPx <= 0.5) return;
    if (s == AnimationStatus.completed) {
      _timer?.cancel();
      _timer = Timer(widget.pause, () {
        if (mounted && _overflowPx > 0.5) _ctrl.reverse(from: 1);
      });
    } else if (s == AnimationStatus.dismissed) {
      _timer?.cancel();
      _timer = Timer(widget.pause, () {
        if (mounted && _overflowPx > 0.5) _ctrl.forward(from: 0);
      });
    }
  }

  double _measure(String text) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: widget.style),
      maxLines: widget.maxLines,
      textDirection: TextDirection.ltr,
    )..layout();
    return tp.width;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final avail = constraints.maxWidth;
        final full = _measure(widget.text);
        final overflow = (full - avail).clamp(0.0, double.infinity);

        if ((overflow - _overflowPx).abs() > 0.5) {
          _overflowPx = overflow;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              _ctrl.stop();
              _ctrl.value = 0;
              _schedule();
            }
          });
        }

        final offset = _overflowPx > 0.5
            ? -Curves.easeInOut.transform(_ctrl.value) * _overflowPx
            : 0.0;

        return ClipRect(
          child: Transform.translate(
            offset: Offset(offset, 0),
            child: Text(
              widget.text,
              maxLines: widget.maxLines,
              softWrap: false,
              overflow: TextOverflow.visible,
              style: widget.style,
            ),
          ),
        );
      },
    );
  }
}
