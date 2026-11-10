import 'package:flutter/material.dart';

import '../core/l10n.dart';

class ReadingCalendar extends StatefulWidget {
  const ReadingCalendar({
    super.key,
    required this.daily,
    this.initialMonth,
  });

  final Map<String, int> daily;

  final DateTime? initialMonth;

  @override
  State<ReadingCalendar> createState() => _ReadingCalendarState();
}

class _ReadingCalendarState extends State<ReadingCalendar> {
  late DateTime _month;

  DateTime? _selected;

  @override
  void initState() {
    super.initState();
    final n = widget.initialMonth ?? DateTime.now();
    _month = DateTime(n.year, n.month);
    if (n.year == _month.year && n.month == _month.month) {
      _selected = DateTime(n.year, n.month, n.day);
    }
  }

  static String _key(int y, int m, int d) =>
      '$y-${m.toString().padLeft(2, '0')}-${d.toString().padLeft(2, '0')}';

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
    final firstWeekday = DateTime(_month.year, _month.month, 1).weekday;
    final lead = firstWeekday % 7;

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
                onTap: () => setState(() => _selected = date),
              );
            },
          ),
          const SizedBox(height: 12),
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

  String _fmtDayDuration(int day, int sec) {
    if (sec <= 0) return '—';
    final mm = _month.month.toString().padLeft(2, '0');
    final dd = day.toString().padLeft(2, '0');
    final h = sec ~/ 3600;
    final m = (sec % 3600) ~/ 60;
    final buf = StringBuffer('$mm/$dd ');
    if (h > 0) buf.write('${h}h');
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
    final bg = active
        ? Color.lerp(
            scheme.primary.withValues(alpha: 0.22),
            scheme.primary,
            intensity,
          )!
        : Colors.transparent;
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
                ? Border.all(color: scheme.primary, width: 1.6)
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
