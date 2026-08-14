import 'package:flutter_test/flutter_test.dart';
import 'package:gzus_pro_mobile_web/api_client.dart';
import 'package:gzus_pro_mobile_web/models/schedule_override.dart';

ScheduleCourse _course(
  String name,
  int weekday,
  int start, {
  int? end,
  String? weeks,
  String? kch,
}) {
  return ScheduleCourse(
    name: name,
    weekday: weekday,
    startSection: start,
    endSection: end ?? start,
    weeks: weeks,
    raw: kch == null ? const {} : {'kch': kch},
  );
}

ScheduleOverride _add({
  required ScheduleCourse course,
  String? weeks,
  String? note,
}) {
  return ScheduleOverride(
    id: 'add',
    weeks: weeks,
    hidden: false,
    course: course,
    note: note,
  );
}

ScheduleOverride _replace({
  required ScheduleCourse match,
  required ScheduleCourse course,
  String? id,
}) {
  return ScheduleOverride(
    id: id ?? 'replace',
    matchKey: 'kch:${match.raw['kch']}',
    matchWeekday: match.weekday,
    matchStartSection: match.startSection,
    hidden: false,
    course: course,
  );
}

ScheduleOverride _hide({
  required ScheduleCourse match,
  String? weeks,
}) {
  return ScheduleOverride(
    id: 'hide',
    matchKey: 'kch:${match.raw['kch']}',
    matchWeekday: match.weekday,
    matchStartSection: match.startSection,
    weeks: weeks,
    hidden: true,
  );
}

void main() {
  final math = _course('高等数学', 3, 3, end: 4, weeks: '1-16周', kch: 'MATH01');
  final english = _course('大学英语', 1, 1, end: 2, weeks: '1-16周', kch: 'ENG01');
  final items = [math, english];

  group('weekSpecContains 周次解析', () {
    test('区间', () {
      expect(weekSpecContains('1-8周', 3), isTrue);
      expect(weekSpecContains('1-8周', 9), isFalse);
    });
    test('单双周', () {
      expect(weekSpecContains('1-16周(单)', 3), isTrue);
      expect(weekSpecContains('1-16周(单)', 4), isFalse);
      expect(weekSpecContains('2-16周(双)', 4), isTrue);
      expect(weekSpecContains('2-16周(双)', 3), isFalse);
    });
    test('单个与逗号分隔', () {
      expect(weekSpecContains('3,5,7', 5), isTrue);
      expect(weekSpecContains('3,5,7', 6), isFalse);
      expect(weekSpecContains('8', 8), isTrue);
      expect(weekSpecContains('8', 9), isFalse);
    });
    test('中文括号与顿号归一化', () {
      expect(weekSpecContains('1-16周（单）', 5), isTrue);
      expect(weekSpecContains('3、6、9', 9), isTrue);
    });
    test('无数字段视为包含所有周', () {
      expect(weekSpecContains('周次待定', 20), isTrue);
      expect(weekSpecContains('第1周起', 20), isFalse);
    });
  });

  group('applyScheduleOverrides 叠加', () {
    test('无调课条目时原样返回', () {
      expect(applyScheduleOverrides(items, const []), items);
    });

    test('新增课程追加到末尾并标记本地', () {
      final added = _add(
        course: _course('毛概实践', 5, 7, end: 8, weeks: '8'),
      );
      final result = applyScheduleOverrides(items, [added]);
      expect(result.length, 3);
      expect(result.last.name, '毛概实践');
      expect(result.last.isLocal, isTrue);
      expect(result[0].isLocal, isFalse);
    });

    test('替换：kch 匹配的课程被替换并标记本地', () {
      final result = applyScheduleOverrides(items, [
        _replace(
          match: math,
          course: _course('高等数学', 5, 7, end: 8, weeks: '1-16周'),
        ),
      ]);
      expect(result.length, 2);
      final replaced = result.firstWhere((c) => c.name == '高等数学');
      expect(replaced.weekday, 5);
      expect(replaced.startSection, 7);
      expect(replaced.isLocal, isTrue);
      expect(result.any((c) => c == math), isFalse);
    });

    test('整学期停课：匹配课程被移除', () {
      final result = applyScheduleOverrides(items, [_hide(match: math)]);
      expect(result.length, 1);
      expect(result.first.name, '大学英语');
    });

    test('周次限定停课：条目保留（渲染层按周过滤）', () {
      final result = applyScheduleOverrides(items, [
        _hide(match: math, weeks: '8'),
      ]);
      expect(result.length, 2);
    });

    test('名字匹配（无 kch 时）', () {
      final noKch = _course('选修课', 2, 5);
      const override = ScheduleOverride(
        id: 'name',
        matchKey: 'name:选修课',
        hidden: true,
      );
      final result = applyScheduleOverrides([noKch], [override]);
      expect(result, isEmpty);
    });

    test('星期/节次限定：只命中匹配条目', () {
      final a = _course('同名课', 1, 3, kch: 'SAME');
      final b = _course('同名课', 2, 3, kch: 'SAME');
      const override = ScheduleOverride(
        id: 'limit',
        matchKey: 'kch:SAME',
        matchWeekday: 2,
        matchStartSection: 3,
        hidden: true,
      );
      final result = applyScheduleOverrides([a, b], [override]);
      expect(result, [a]);
    });

    test('多个匹配条目：首个 override 优先', () {
      final result = applyScheduleOverrides(items, [
        _hide(match: math),
        _replace(
          match: math,
          course: _course('高等数学', 5, 7, end: 8),
        ),
      ]);
      // 第一个是停课 → 整学期隐藏生效
      expect(result.length, 1);
      expect(result.first.name, '大学英语');
    });

    test('停课与替换顺序互换后行为不同', () {
      final result = applyScheduleOverrides(items, [
        _replace(
          match: math,
          course: _course('高等数学', 5, 7, end: 8),
        ),
        _hide(match: math),
      ]);
      // 第一个是替换 → 原课程已不存在，停课条目无匹配对象
      expect(result.length, 2);
      expect(result.first.name, '高等数学');
      expect(result.first.isLocal, isTrue);
    });
  });

  group('isHiddenByOverrides 周视图过滤', () {
    test('周次命中时隐藏', () {
      expect(
        isHiddenByOverrides(math, [_hide(match: math, weeks: '8')],
            currentWeek: 8),
        isTrue,
      );
      expect(
        isHiddenByOverrides(math, [_hide(match: math, weeks: '8')],
            currentWeek: 9),
        isFalse,
      );
    });

    test('weeks 为空：任何周都隐藏', () {
      expect(
        isHiddenByOverrides(math, [_hide(match: math)], currentWeek: 8),
        isTrue,
      );
    });

    test('全部视图（currentWeek=null）：周次限定不隐藏', () {
      expect(
        isHiddenByOverrides(math, [_hide(match: math, weeks: '8')]),
        isFalse,
      );
    });

    test('本地课程不参与隐藏匹配', () {
      final local = _course('高等数学', 3, 3).copyWith(isLocal: true);
      expect(isHiddenByOverrides(local, [_hide(match: math)], currentWeek: 8),
          isFalse);
    });
  });

  group('buildMoveToDayOverride 调到另一天', () {
    test('学校课程：生成替换条目，星期变更、其余不变', () {
      final override = buildMoveToDayOverride(
        course: math,
        targetWeekday: 5,
      );
      expect(override.isReplace, isTrue);
      expect(override.matchKey, 'kch:MATH01');
      expect(override.matchWeekday, 3);
      expect(override.matchStartSection, 3);
      expect(override.course?.weekday, 5);
      expect(override.course?.startSection, 3);
      expect(override.course?.endSection, 4);
      expect(override.course?.classroom, math.classroom);
      expect(override.course?.teacher, math.teacher);
      expect(override.course?.weeks, math.weeks);
      expect(override.note, contains('周三'));
      expect(override.note, contains('周五'));
      // 叠加后：原周三课程被替换为周五
      final result = applyScheduleOverrides(items, [override]);
      expect(result.length, 2);
      final moved = result.firstWhere((c) => c.name == '高等数学');
      expect(moved.weekday, 5);
      expect(moved.isLocal, isTrue);
    });

    test('本地课程：沿用原条目只改日期（不新增条目）', () {
      final localCourse = _course('高等数学', 3, 3, end: 4, kch: 'MATH01');
      final existing = buildMoveToDayOverride(
        course: localCourse,
        targetWeekday: 5,
      );
      expect(existing.id, isNotEmpty);
      // 再次调天：基于 existing 继续调整
      final movedAgain = buildMoveToDayOverride(
        course: existing.course!,
        targetWeekday: 2,
        existing: existing,
      );
      expect(movedAgain.id, existing.id);
      expect(movedAgain.course?.weekday, 2);
      expect(movedAgain.matchKey, existing.matchKey);
      expect(movedAgain.note, contains('周五'));
      expect(movedAgain.note, contains('周二'));
    });

    test('无 kch 时用课程名匹配', () {
      final noKch = _course('选修课', 2, 5);
      final override = buildMoveToDayOverride(
        course: noKch,
        targetWeekday: 4,
      );
      expect(override.matchKey, 'name:选修课');
      expect(override.course?.weekday, 4);
    });
  });

  group('序列化往返', () {
    test('toJson/fromJson 保留全部字段', () {
      final original = _replace(
        match: math,
        course: _course('高等数学', 5, 7, end: 8, weeks: '9-16周', kch: 'MATH01'),
      ).copyWith(note: '老师出差调课');
      final restored = ScheduleOverride.fromJson(original.toJson());
      expect(restored.id, original.id);
      expect(restored.matchKey, original.matchKey);
      expect(restored.matchWeekday, original.matchWeekday);
      expect(restored.matchStartSection, original.matchStartSection);
      expect(restored.hidden, original.hidden);
      expect(restored.course?.name, original.course?.name);
      expect(restored.course?.weekday, original.course?.weekday);
      expect(restored.course?.weeks, original.course?.weeks);
      expect(restored.note, original.note);
    });

    test('新增课程往返后仍为 isAdd', () {
      final added = _add(course: _course('毛概实践', 5, 7, end: 8, weeks: '8'));
      final restored = ScheduleOverride.fromJson(added.toJson());
      expect(restored.isAdd, isTrue);
      expect(restored.course?.weeks, '8');
    });
  });
}
