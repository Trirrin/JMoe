import 'package:flutter_test/flutter_test.dart';
import 'package:jmoe/core/jm_service.dart';

void main() {
  Map<String, dynamic> dailyPayload() => {
        'daily_id': 74,
        'three_days_coin': '30',
        'seven_days_coin': '500',
        'event_name': '11月-兔兔萬歲',
        'currentProgress': '0%',
        'record': [
          [
            for (var d = 1; d <= 7; d++)
              {'date': '$d'.padLeft(2, '0'), 'signed': d == 1, 'bonus': d == 1},
          ],
          [
            for (var d = 8; d <= 14; d++)
              {'date': '$d'.padLeft(2, '0'), 'signed': false, 'bonus': false},
          ],
          [
            for (var d = 15; d <= 21; d++)
              {'date': '$d'.padLeft(2, '0'), 'signed': false, 'bonus': false},
          ],
          [
            for (var d = 22; d <= 28; d++)
              {'date': '$d'.padLeft(2, '0'), 'signed': false, 'bonus': false},
          ],
          [
            {'date': '29', 'signed': false, 'bonus': false},
            {'date': '30', 'signed': false, 'bonus': true},
          ],
        ],
      };

  test('二维 record 被完整摊平为 30 天', () {
    final s = JmService.parseDaily(dailyPayload());
    expect(s.days.length, 30);
    expect(s.days.map((e) => e.date).toList(), [
      for (var d = 1; d <= 30; d++) '$d'.padLeft(2, '0'),
    ]);
  });

  test('日号连续、无缺号', () {
    final s = JmService.parseDaily(dailyPayload());
    for (var i = 0; i < s.days.length; i++) {
      expect(int.parse(s.days[i].date), i + 1);
    }
  });

  test('已签到天数只统计 signed=true', () {
    final s = JmService.parseDaily(dailyPayload());
    expect(s.days.where((e) => e.signed).length, 1);
    expect(s.signedCount, 1);
  });

  test('奖励日标记保留', () {
    final s = JmService.parseDaily(dailyPayload());
    final bonuses = s.days.where((e) => e.bonus).map((e) => e.date).toList();
    expect(bonuses, ['01', '30']);
  });

  test('平铺数组（服务端改格式）也能解析', () {
    final s = JmService.parseDaily({
      'record': [
        {'date': '01', 'signed': true, 'bonus': false},
        {'date': '02', 'signed': false, 'bonus': false},
      ],
    });
    expect(s.days.length, 2);
    expect(s.signedCount, 1);
  });

  test('日历列序号：周日排首列（周日→0，周一→1，周六→6）', () {
    int colOf(int weekday) => weekday % 7;
    expect(colOf(DateTime.sunday), 0);
    expect(colOf(DateTime.monday), 1);
    expect(colOf(DateTime.saturday), 6);
    expect(colOf(DateTime(2026, 11, 1).weekday), 0);
    expect(colOf(DateTime(2026, 11, 8).weekday), 0);
  });

  test('空/null 不会崩', () {
    expect(JmService.parseDaily(null).days, isEmpty);
    expect(JmService.parseDaily({'record': null}).days, isEmpty);
    expect(JmService.parseDaily({'record': []}).days, isEmpty);
  });
}
