import 'package:flutter/material.dart';

import '../core/l10n.dart';

/// 阅读日历：按月展示每天的阅读时长。
///
/// 参照签到日历的形态，但展示的是「阅读活跃度」：
///  * 有阅读的日子用圆形高亮（颜色深浅表示时长多少）
///  * 今天加描边圈
///  * 可左右切换月份
///  * 底部显示本月：累计时长 / 活跃天数 / 最长单日
class ReadingCalendar extends StatefulWidget {
  const ReadingCalendar({
    super.key,
    required this.daily,
    this.initialMonth,
  });

  /// 按天秒数，key 形如 `2026-11-09`
  final Map<String, int> daily;

  final DateTime? initialMonth;

  @override
  State<ReadingCalendar> createState() => _ReadingCalendarState();
}

class _ReadingCalendarState extends State<ReadingCalendar> {
  late DateTime _month;

  /// 当前选中的日期（点某个格子后，下方显示该日详情）
  DateTime? _selected;

  @override
  void initState() {
    super.initState();
    final n = widget.initialMonth ?? DateTime.now();
    _month = DateTime(n.year, n.month);
    // 默认选中今天（若在当月）
    if (n.year == _month.year && n.month == _month.month) {
      _selected = DateTime(n.year, n.month, n.day);
    }
  }

  static String _key(int y, int m, int d) =>
      '$y-${m.toString().padLeft(2, '0')}-${d.toString().padLeft(2, '0')}';

  /// 当月秒数
  int _secOf(int day) =>
      widget.daily[_key(_month.year, _month.month, day)] ?? 0;

  bool get _canGoNext {
    final now = DateTime.now();
    return _month.year < now.year ||
        (_month.year == now.year && _month.month < now.month);
  }

  void _shift(int delta) {
    setState(() {
      _month = DateTime(_month.year, _month.month + delta);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final now = DateTime.now();
    final daysInMonth = DateTime(_month.year, _month.month + 1, 0).day;
    // 当月 1 号是周几（Flutter: 周一=1 … 周日=7）
    final firstWeekday = DateTime(_month.year, _month.month, 1).weekday;
    // 周日为第一列 → 前面补的空白数
    final lead = firstWeekday % 7;

    // 本月统计
    var monthTotal = 0;
    var activeDays = 0;
    var bestDay = 0;
    var bestDayNum = 0;
    for (var d = 1; d <= daysInMonth; d++) {
      final s = _secOf(d);
      if (s > 0) {
        monthTotal += s;
        activeDays++;
        if (s > bestDay) {
          bestDay = s;
          bestDayNum = d;
        }
      }
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ---- 月份切换 ----
          Row(
            children: [
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.chevron_left_rounded, size: 20),
                onPressed: () => _shift(-1),
              ),
              Expanded(
                child: Center(
                  child: Text(
                    '${_month.year} / ${_month.month}',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: Icon(
                  Icons.chevron_right_rounded,
                  size: 20,
                  color: _canGoNext
                      ? null
                      : scheme.onSurface.withValues(alpha: 0.25),
                ),
                onPressed: _canGoNext ? () => _shift(1) : null,
              ),
            ],
          ),
          const SizedBox(height: 6),
          // ---- 星期表头（周日起） ----
          Row(
            children: [
              for (final w in const ['日', '一', '二', '三', '四', '五', '六'])
                Expanded(
                  child: Center(
                    child: Text(
                      w,
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          // ---- 日期网格 ----
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            padding: EdgeInsets.zero,
            gridDelegate:
                const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 7,
              mainAxisSpacing: 4,
              crossAxisSpacing: 4,
              childAspectRatio: 1,
            ),
            itemCount: lead + daysInMonth,
            itemBuilder: (context, i) {
              if (i < lead) return const SizedBox.shrink();
              final day = i - lead + 1;
              final sec = _secOf(day);
              final isToday = _month.year == now.year &&
                  _month.month == now.month &&
                  day == now.day;
              // 活跃度：以本月亮度最高的一天为满色
              final t = bestDay <= 0 ? 0.0 : (sec / bestDay).clamp(0.0, 1.0);
              final date = DateTime(_month.year, _month.month, day);
              final selected = _selected != null &&
                  _selected!.year == date.year &&
                  _selected!.month == date.month &&
                  _selected!.day == date.day;
              return _DayCell(
                day: day,
                seconds: sec,
                intensity: t,
                isToday: isToday,
                isSelected: selected,
                scheme: scheme,
                // 点选某日 → 下方显示该日数据
                onTap: () => setState(() => _selected = date),
              );
            },
          ),
          const SizedBox(height: 12),
          // ---- 选中日详情 ----
          //
          // 点某一天就显示那天的数据。默认选中今天，
          // 所以一进页面就能看到「今天读了多少」。
          if (_selected != null) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
              decoration: BoxDecoration(
                color: scheme.primary.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.event_available_rounded,
                    size: 15,
                    color: scheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${_selected!.month} 月 ${_selected!.day} 日',
                      style: const TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Text(
                    _fmtDur(widget.daily[
                            _key(_selected!.year, _selected!.month,
                                _selected!.day)] ??
                        0),
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: scheme.primary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
          ],
          // ---- 本月小结 ----
          Row(
            children: [
              _summary(
                scheme,
                L.t('calMonthTotal'),
                _fmtDur(monthTotal),
              ),
              const SizedBox(width: 10),
              _summary(
                scheme,
                L.t('calActiveDays'),
                '$activeDays',
              ),
            ],
          ),
          const SizedBox(height: 8),
          // ---- 放纵日：本月**看得最久的那一天** ----
          //
          // 保留原来的图标与「放纵日」这个名字（用户要求），
          // 只把数据换成「看的最久的一天」。
          // 格式：MM/dd + 时长（不足 1h 不显示 h）。
          Row(
            children: [
              Icon(
                Icons.self_improvement_rounded,
                size: 14,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Text(
                L.t('calLazyDays'),
                style: TextStyle(
                  fontSize: 11,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                bestDayNum == 0
                    ? '—'
                    : _fmtDayDuration(bestDayNum, bestDay),
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 把「几号 + 秒数」格式化成 `MM/dd 1h30m` 或 `MM/dd 45m`。
  String _fmtDayDuration(int day, int sec) {
    if (sec <= 0) return '—';
    final mm = _month.month.toString().padLeft(2, '0');
    final dd = day.toString().padLeft(2, '0');
    final h = sec ~/ 3600;
    final m = (sec % 3600) ~/ 60;
    final buf = StringBuffer('$mm/$dd ');
    if (h > 0) buf.write('${h}h');
    // 不足 1 小时不显示 h；分钟为 0 且有时长时显示 0m 以免空值
    if (m > 0 || h == 0) buf.write('${m}m');
    return buf.toString().trim();
  }

  Widget _summary(ColorScheme scheme, String label, String value) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  String _fmtDur(int sec) {
    if (sec <= 0) return '0';
    if (sec < 60) return '${sec}s';
    if (sec < 3600) return '${(sec / 60).round()}m';
    final h = sec / 3600;
    return h >= 10 ? '${h.round()}h' : '${h.toStringAsFixed(1)}h';
  }
}

/// 单个日期格子：圆形，颜色深浅 = 当天阅读时长。
class _DayCell extends StatelessWidget {
  const _DayCell({
    required this.day,
    required this.seconds,
    required this.intensity,
    required this.isToday,
    required this.isSelected,
    required this.scheme,
    this.onTap,
  });

  final int day;
  final int seconds;
  final double intensity;
  final bool isToday;
  final bool isSelected;
  final ColorScheme scheme;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final active = seconds > 0;
    // 有阅读：底色按活跃度加深；无阅读：透明
    final bg = active
        ? Color.lerp(
            scheme.primary.withValues(alpha: 0.22),
            scheme.primary,
            intensity,
          )!
        : Colors.transparent;
    // 深色底上用浅字，浅色底上用深字
    final fg = active && intensity > 0.55
        ? Colors.white
        : (active ? scheme.primary : scheme.onSurfaceVariant);

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Center(
        child: Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: bg,
            border: isToday
                // 今天：实线描边
                ? Border.all(color: scheme.primary, width: 1.6)
                // 选中（非今天）：虚线感用更粗的浅描边表达
                : isSelected
                    ? Border.all(
                        color: scheme.primary.withValues(alpha: 0.5),
                        width: 1.6,
                      )
                    : null,
          ),
          child: Center(
            child: Text(
              '$day',
              style: TextStyle(
                fontSize: 11,
                fontWeight: active || isToday || isSelected
                    ? FontWeight.w700
                    : FontWeight.w400,
                color: isToday && !active ? scheme.primary : fg,
              ),
            ),
          ),
        ),
      ),
    );
  }
}