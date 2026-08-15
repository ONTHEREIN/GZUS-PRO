import 'package:flutter_test/flutter_test.dart';
import 'package:gzus_pro_mobile_web/schedule_utils.dart';

void main() {
  group('academicPeriodOf 月份启发式', () {
    test('9月1日起进入新学年第1学期', () {
      expect(academicPeriodOf(DateTime(2026, 9, 1)), (2026, 1));
    });

    test('8月31日仍是上学年第2学期', () {
      expect(academicPeriodOf(DateTime(2026, 8, 31, 23, 59)), (2025, 2));
    });

    test('1月31日仍是秋季学期（第1学期）', () {
      expect(academicPeriodOf(DateTime(2027, 1, 31)), (2026, 1));
    });

    test('2月1日起为第2学期', () {
      expect(academicPeriodOf(DateTime(2027, 2, 1)), (2026, 2));
    });

    test('春季学期中段', () {
      expect(academicPeriodOf(DateTime(2027, 6, 15)), (2026, 2));
    });
  });

  group('defaultFirstWeekStart 开学日期推导', () {
    test('2026-09-01 是周二，其所在周周一为 2026-08-31', () {
      expect(defaultFirstWeekStart(2026, 1), DateTime(2026, 8, 31));
    });

    test('2027-03-01 本身是周一', () {
      expect(defaultFirstWeekStart(2026, 2), DateTime(2027, 3, 1));
    });
  });

  group('academicPeriodFromFirstWeeks 开学日期反推', () {
    final firstWeeks = {'2026-1': '2026-08-31', '2026-2': '2027-03-01'};

    test('开学日命中对应学期', () {
      expect(
        academicPeriodFromFirstWeeks(firstWeeks, DateTime(2026, 8, 31)),
        (2026, 1),
      );
      expect(
        academicPeriodFromFirstWeeks(firstWeeks, DateTime(2027, 3, 1)),
        (2026, 2),
      );
    });

    test('寒假仍落在上学期区间，直到新学期开学日', () {
      expect(
        academicPeriodFromFirstWeeks(firstWeeks, DateTime(2027, 2, 15)),
        (2026, 1),
      );
    });

    test('相邻学期区间重叠时取开学日期最新者', () {
      expect(
        academicPeriodFromFirstWeeks(firstWeeks, DateTime(2027, 3, 15)),
        (2026, 2),
      );
    });

    test('无命中返回 null', () {
      expect(
        academicPeriodFromFirstWeeks(
            {'2026-1': '2026-08-31'}, DateTime(2026, 8, 30)),
        isNull,
      );
      // 开学 30 周之后
      expect(
        academicPeriodFromFirstWeeks(
            {'2026-1': '2026-08-31'}, DateTime(2027, 4, 1)),
        isNull,
      );
      expect(academicPeriodFromFirstWeeks({}, DateTime(2026, 10, 1)), isNull);
    });

    test('非法条目忽略，合法条目仍可命中', () {
      final invalid = {
        'bad': '2026-08-31',
        '2026-1': 'not-a-date',
        '2026-3': '2026-09-01',
      };
      expect(
        academicPeriodFromFirstWeeks(invalid, DateTime(2026, 9, 10)),
        isNull,
      );
      final mixed = {'bad': 'x', '2026-1': '2026-08-31'};
      expect(
        academicPeriodFromFirstWeeks(mixed, DateTime(2026, 9, 10)),
        (2026, 1),
      );
    });
  });

  group('mondayOf 周一归位', () {
    test('周一本身保持不变', () {
      expect(mondayOf(DateTime(2026, 8, 31)), DateTime(2026, 8, 31));
    });

    test('周日归位到本周周一', () {
      expect(mondayOf(DateTime(2026, 9, 6)), DateTime(2026, 8, 31));
    });

    test('月首（9月1日周二）归位到上月末周一', () {
      expect(mondayOf(DateTime(2026, 9, 1)), DateTime(2026, 8, 31));
    });
  });
}
