import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 板块类型。
enum StatType { comic, novel, video }

/// 单个板块的统计。
class TypeStats {
  int seconds = 0;
  int chapters = 0;
  int pages = 0;

  /// 读过的不重复作品 id
  final Set<String> works = {};

  /// 按天累计秒数
  final Map<String, int> daily = {};

  int get todaySeconds => daily[_dayKey(DateTime.now())] ?? 0;

  int get streakDays {
    if (daily.isEmpty) return 0;
    var streak = 0;
    var cursor = DateTime.now();
    while (true) {
      final k = _dayKey(cursor);
      final v = daily[k] ?? 0;
      if (v > 0) {
        streak++;
        cursor = cursor.subtract(const Duration(days: 1));
      } else {
        break;
      }
      if (streak > 3650) break;
    }
    return streak;
  }

  List<({String day, int seconds})> get last7Days {
    final out = <({String day, int seconds})>[];
    for (var i = 6; i >= 0; i--) {
      final d = DateTime.now().subtract(Duration(days: i));
      out.add((day: _dayKey(d), seconds: daily[_dayKey(d)] ?? 0));
    }
    return out;
  }

  Map<String, dynamic> toJson() => {
        'seconds': seconds,
        'chapters': chapters,
        'pages': pages,
        'works': works.toList(),
        'daily': daily,
      };

  void fromJson(Map<String, dynamic> m) {
    seconds = (m['seconds'] as num?)?.toInt() ?? 0;
    chapters = (m['chapters'] as num?)?.toInt() ?? 0;
    pages = (m['pages'] as num?)?.toInt() ?? 0;
    works.clear();
    final w = m['works'];
    if (w is List) works.addAll(w.map((e) => '$e'));
    daily.clear();
    final d = m['daily'];
    if (d is Map) {
      d.forEach((k, v) {
        final n = (v as num?)?.toInt() ?? 0;
        if (n > 0) daily['$k'] = n;
      });
    }
  }

  void clear() {
    seconds = 0;
    chapters = 0;
    pages = 0;
    works.clear();
    daily.clear();
  }
}

String _dayKey(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

/// 全局统计：三个板块互不混淆。
class ReadingStats {
  ReadingStats._();
  static final ReadingStats instance = ReadingStats._();

  static const _key = 'reading_stats_v2';

  /// 三个板块独立数据
  final Map<StatType, TypeStats> byType = {
    StatType.comic: TypeStats(),
    StatType.novel: TypeStats(),
    StatType.video: TypeStats(),
  };

  // ---- 全局缓存统计（与板块无关）----
  int cacheHits = 0;
  int cacheMisses = 0;
  int bytesSaved = 0;

  bool _inited = false;

  TypeStats of(StatType t) => byType[t]!;

  // ---- 汇总（概览用）----
  int get totalSeconds =>
      byType.values.fold<int>(0, (a, b) => a + b.seconds);
  int get totalChapters =>
      byType.values.fold<int>(0, (a, b) => a + b.chapters);
  int get totalPages => byType.values.fold<int>(0, (a, b) => a + b.pages);
  int get totalWorks =>
      byType.values.fold<int>(0, (a, b) => a + b.works.length);
  int get todaySeconds =>
      byType.values.fold<int>(0, (a, b) => a + b.todaySeconds);

  /// 三个板块合并后的「按天秒数」，供日历使用。
  ///
  /// 日历要按天显示阅读活跃度，而 `daily` 存在各板块内部，
  /// 所以这里做一次聚合（同一天多板块相加）。
  Map<String, int> get mergedDaily {
    final out = <String, int>{};
    for (final t in byType.values) {
      t.daily.forEach((k, v) {
        out[k] = (out[k] ?? 0) + v;
      });
    }
    return out;
  }

  /// 汇总的 7 日曲线（三板块相加）
  List<({String day, int seconds})> get last7Days {
    final out = <({String day, int seconds})>[];
    for (var i = 6; i >= 0; i--) {
      final d = DateTime.now().subtract(Duration(days: i));
      final k = _dayKey(d);
      var sum = 0;
      for (final t in byType.values) {
        sum += t.daily[k] ?? 0;
      }
      out.add((day: k, seconds: sum));
    }
    return out;
  }

  int get streakDays {
    // 任一板块当天有阅读即算连续
    final days = <String>{};
    for (final t in byType.values) {
      t.daily.forEach((k, v) {
        if (v > 0) days.add(k);
      });
    }
    if (days.isEmpty) return 0;
    var streak = 0;
    var cursor = DateTime.now();
    while (true) {
      if (days.contains(_dayKey(cursor))) {
        streak++;
        cursor = cursor.subtract(const Duration(days: 1));
      } else {
        break;
      }
      if (streak > 3650) break;
    }
    return streak;
  }

  // ---- 记录 ----

  /// 累计某板块的阅读时长。
  Future<void> addSeconds(StatType type, int sec) async {
    if (sec <= 0) return;
    final t = of(type);
    t.seconds += sec;
    final k = _dayKey(DateTime.now());
    t.daily[k] = (t.daily[k] ?? 0) + sec;
    await save();
  }

  /// 记录一次阅读（章节 / 篇章 / 视频）。
  Future<void> recordChapter({
    required StatType type,
    required String workId,
    int pages = 0,
  }) async {
    final t = of(type);
    t.chapters++;
    t.pages += pages;
    t.works.add(workId);
    await save();
  }

  Future<void> recordCache({required bool hit, int savedBytes = 0}) async {
    if (hit) {
      cacheHits++;
      bytesSaved += savedBytes;
    } else {
      cacheMisses++;
    }
    await save();
  }

  // ---- 持久化 ----

  Future<void> load() async {
    if (_inited) return;
    _inited = true;
    try {
      final sp = await SharedPreferences.getInstance();
      final raw = sp.getString(_key);
      if (raw == null || raw.isEmpty) return;
      final m = jsonDecode(raw) as Map<String, dynamic>;

      cacheHits = (m['cacheHits'] as num?)?.toInt() ?? 0;
      cacheMisses = (m['cacheMisses'] as num?)?.toInt() ?? 0;
      bytesSaved = (m['bytesSaved'] as num?)?.toInt() ?? 0;

      final types = m['types'];
      if (types is Map) {
        for (final e in byType.entries) {
          final v = types[e.key.name];
          if (v is Map) {
            e.value.fromJson(Map<String, dynamic>.from(v));
          }
        }
      }
    } catch (_) {}
  }

  Future<void> save() async {
    try {
      final sp = await SharedPreferences.getInstance();
      // 每板块只保留最近 400 天
      for (final t in byType.values) {
        if (t.daily.length > 400) {
          final keys = t.daily.keys.toList()..sort();
          for (final k in keys.take(t.daily.length - 400)) {
            t.daily.remove(k);
          }
        }
      }
      await sp.setString(
        _key,
        jsonEncode({
          'cacheHits': cacheHits,
          'cacheMisses': cacheMisses,
          'bytesSaved': bytesSaved,
          'types': {
            for (final e in byType.entries) e.key.name: e.value.toJson(),
          },
        }),
      );
    } catch (_) {}
  }

  Future<void> clear() async {
    for (final t in byType.values) {
      t.clear();
    }
    cacheHits = 0;
    cacheMisses = 0;
    bytesSaved = 0;
    await save();
  }
}
