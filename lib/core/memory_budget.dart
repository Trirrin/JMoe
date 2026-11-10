import 'dart:io';

import 'package:flutter/foundation.dart';

class MemoryBudget {
  MemoryBudget._();

  static int? _cachedPageLimit;

  static int get maxPages {

    final cached = _cachedPageLimit;
    if (cached != null) return cached;

    final limit = _compute();
    _cachedPageLimit = limit;
    return limit;
  }

  static int _compute() {

    final totalMb = _totalMemoryMb();

    if (totalMb <= 0) return 24;

    if (totalMb >= 12000) return 80;
    if (totalMb >= 8000) return 64;
    if (totalMb >= 6000) return 48;
    if (totalMb >= 4000) return 36;
    if (totalMb >= 3000) return 24;
    return 16;
  }

  static int _totalMemoryMb() {
    try {
      if (Platform.isAndroid || Platform.isLinux) {
        final f = File('/proc/meminfo');
        if (f.existsSync()) {
          for (final line in f.readAsLinesSync()) {
            if (line.startsWith('MemTotal:')) {
              final kb = int.tryParse(
                    RegExp(r'\d+').firstMatch(line)?.group(0) ?? '',
                  ) ??
                  0;
              return kb ~/ 1024;
            }
          }
        }
      }
    } catch (_) {}
    return 0;
  }

  static int get reserveMb => 64;

  static String describe() {
    final mb = _totalMemoryMb();
    return '${mb}MB RAM / ${maxPages} pages';
  }

  @visibleForTesting
  static void resetForTest() {
    _cachedPageLimit = null;
  }
}
