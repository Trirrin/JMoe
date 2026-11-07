import 'dart:async';
import 'dart:math' as math;

/// 网络限速器（令牌桶）。
///
/// 单位：Mbps（兆比特/秒）。0 表示不限速。
/// 只用于图片/视频等大流量下载，API 小请求不过限速。
class NetThrottle {
  NetThrottle._();
  static final NetThrottle instance = NetThrottle._();

  /// 当前限速（Mbps）。0 = 不限速。
  int mbps = 10;

  /// 已消耗的令牌（字节）
  double _tokens = 0;
  DateTime _last = DateTime.now();

  /// 每秒可用的字节数
  double get _bps => mbps <= 0 ? 0 : (mbps * 1000 * 1000 / 8);

  /// 记录一次 [bytes] 字节的传输，必要时等待以维持速率。
  Future<void> consume(int bytes) async {
    if (mbps <= 0 || bytes <= 0) return;

    final now = DateTime.now();
    final elapsed = now.difference(_last).inMicroseconds / 1e6;
    _last = now;

    // 补充令牌（上限 1 秒的额度，避免长时间空闲后突发）
    _tokens = math.min(_bps, _tokens + _bps * elapsed);
    _tokens -= bytes;

    if (_tokens >= 0) return;

    // 欠了令牌：等它补齐
    final deficit = -_tokens;
    final waitSeconds = deficit / _bps;
    final waitMs = (waitSeconds * 1000).clamp(0, 30000).toInt();
    if (waitMs > 0) {
      await Future<void>.delayed(Duration(milliseconds: waitMs));
      // 等待结束后重置基准，避免累积误差导致后续卡顿
      _last = DateTime.now();
      _tokens = 0;
    }
  }
}
