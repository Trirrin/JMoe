import 'dart:async';
import 'dart:math' as math;

class NetThrottle {
  NetThrottle._();
  static final NetThrottle instance = NetThrottle._();

  int mbps = 10;

  double _tokens = 0;
  DateTime _last = DateTime.now();

  double get _bps => mbps <= 0 ? 0 : (mbps * 1000 * 1000 / 8);

  Future<void> consume(int bytes) async {
    if (mbps <= 0 || bytes <= 0) return;

    final now = DateTime.now();
    final elapsed = now.difference(_last).inMicroseconds / 1e6;
    _last = now;

    _tokens = math.min(_bps, _tokens + _bps * elapsed);
    _tokens -= bytes;

    if (_tokens >= 0) return;

    final deficit = -_tokens;
    final waitSeconds = deficit / _bps;
    final waitMs = (waitSeconds * 1000).clamp(0, 30000).toInt();
    if (waitMs > 0) {
      await Future<void>.delayed(Duration(milliseconds: waitMs));
      _last = DateTime.now();
      _tokens = 0;
    }
  }
}
