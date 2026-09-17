import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'api_client.dart';

/// 日期调课的离线队列。写入本地后界面立即生效，联网时按顺序幂等上传。
class ScheduleAdjustmentSync {
  ScheduleAdjustmentSync._();

  static String _key(int year, int term) =>
      'schedule.adjustmentQueue.$year.$term';

  static Future<List<ScheduleAdjustmentRecord>> loadQueue(
      int year, int term) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key(year, term));
    if (raw == null || raw.isEmpty) return const [];
    final decoded = jsonDecode(raw);
    if (decoded is! List) throw const FormatException('课表调课离线队列格式无效');
    return [
      for (final item in decoded)
        if (item is Map)
          ScheduleAdjustmentRecord.fromJson(Map<String, dynamic>.from(item)),
    ];
  }

  static Future<void> enqueue(ScheduleAdjustmentRecord adjustment) async {
    final prefs = await SharedPreferences.getInstance();
    final queue = await loadQueue(adjustment.year, adjustment.term);
    final next = [
      for (final item in queue)
        if (item.clientId != adjustment.clientId) item,
      adjustment,
    ];
    await prefs.setString(
      _key(adjustment.year, adjustment.term),
      jsonEncode([for (final item in next) item.toJson()]),
    );
  }

  static Future<void> flush({
    required ApiClient api,
    required int year,
    required int term,
  }) async {
    final queue = await loadQueue(year, term);
    if (queue.isEmpty) return;
    final pending = <ScheduleAdjustmentRecord>[];
    for (final item in queue) {
      try {
        final synced = await api.createScheduleAdjustment(item);
        if (item.status == 'restored' && synced.isActive) {
          await api.restoreScheduleAdjustment(
            clientId: item.clientId,
            expectedRevision: synced.revision,
          );
        }
      } catch (_) {
        pending.add(item);
      }
    }
    final prefs = await SharedPreferences.getInstance();
    if (pending.isEmpty) {
      await prefs.remove(_key(year, term));
    } else {
      await prefs.setString(
        _key(year, term),
        jsonEncode([for (final item in pending) item.toJson()]),
      );
    }
  }
}
