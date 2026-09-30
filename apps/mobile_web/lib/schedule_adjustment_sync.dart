import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'api_client.dart';

class ScheduleAdjustmentConflict implements Exception {
  const ScheduleAdjustmentConflict(this.pending, this.cause);

  final ScheduleAdjustmentRecord pending;
  final ApiException cause;

  @override
  String toString() => cause.message;
}

/// 日期调课的离线队列。写入本地后界面立即生效，联网时按顺序幂等上传。
class ScheduleAdjustmentSync {
  ScheduleAdjustmentSync._();

  static String _key(String namespace, int year, int term) =>
      'schedule.$namespace.adjustmentQueue.$year.$term';

  static String _snapshotKey(String namespace, int year, int term) =>
      'schedule.$namespace.adjustmentSnapshot.$year.$term';

  static Future<List<ScheduleAdjustmentRecord>> loadSnapshot(
      String namespace, int year, int term) async {
    final prefs = await SharedPreferences.getInstance();
    return _readQueue(prefs, _snapshotKey(namespace, year, term));
  }

  static Future<void> saveSnapshot(String namespace, int year, int term,
      List<ScheduleAdjustmentRecord> records) async {
    final prefs = await SharedPreferences.getInstance();
    await _saveQueue(prefs, _snapshotKey(namespace, year, term), records);
  }

  /// 读取当前账号的云端记录并叠加尚未同步的本机修改。
  static Future<List<ScheduleAdjustmentRecord>> loadCurrent({
    required ApiClient api,
    required int year,
    required int term,
  }) async {
    final namespace = api.namespace;
    final remote = await api.fetchScheduleAdjustments(year: year, term: term);
    _requireSameAccount(api, namespace);
    final pending = await loadQueue(namespace, year, term);
    _requireSameAccount(api, namespace);
    return mergePendingScheduleAdjustments(remote, pending);
  }

  static Future<void> _saveSyncedRecord(String namespace, int year, int term,
      ScheduleAdjustmentRecord record) async {
    final prefs = await SharedPreferences.getInstance();
    final key = _snapshotKey(namespace, year, term);
    final current = _readQueue(prefs, key);
    await _saveQueue(
        prefs, key, mergePendingScheduleAdjustments(current, [record]));
  }

  static Future<bool> hasLegacyQueue(int year, int term) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.containsKey('schedule.adjustmentQueue.$year.$term');
  }

  /// 旧版没有账号归属，只有用户确认属于当前账号后才可导入。
  static Future<void> importLegacyQueue(
      String namespace, int year, int term) async {
    final prefs = await SharedPreferences.getInstance();
    final legacyKey = 'schedule.adjustmentQueue.$year.$term';
    if (!prefs.containsKey(legacyKey)) return;
    final legacy = _readQueue(prefs, legacyKey);
    final key = _key(namespace, year, term);
    final current = _readQueue(prefs, key);
    final byId = {for (final item in current) item.clientId: item};
    for (final item in legacy) {
      final existing = byId[item.clientId];
      if (existing != null &&
          jsonEncode(existing.toJson()) != jsonEncode(item.toJson())) {
        throw StateError('当前账号存在同编号的不同调课记录，无法导入');
      }
    }
    await _saveQueue(prefs, key, [
      ...current,
      for (final item in legacy)
        if (!byId.containsKey(item.clientId)) item,
    ]);
    if (!await prefs.remove(legacyKey)) throw StateError('旧版调课队列清理失败');
  }

  static Future<List<ScheduleAdjustmentRecord>> loadQueue(
      String namespace, int year, int term) async {
    final prefs = await SharedPreferences.getInstance();
    return _readQueue(prefs, _key(namespace, year, term));
  }

  static List<ScheduleAdjustmentRecord> _readQueue(
      SharedPreferences prefs, String key) {
    final raw = prefs.getString(key);
    if (raw == null || raw.isEmpty) return const [];
    final decoded = jsonDecode(raw);
    if (decoded is! List) throw const FormatException('课表调课离线队列格式无效');
    return decoded.map((item) {
      if (item is! Map) throw const FormatException('课表调课离线记录格式无效');
      return ScheduleAdjustmentRecord.fromJson(Map<String, dynamic>.from(item));
    }).toList();
  }

  static Future<void> enqueue(
      String namespace, ScheduleAdjustmentRecord adjustment) async {
    final prefs = await SharedPreferences.getInstance();
    final key = _key(namespace, adjustment.year, adjustment.term);
    final queue = _readQueue(prefs, key);
    final next = [
      for (final item in queue)
        if (item.clientId != adjustment.clientId) item,
      adjustment,
    ];
    await _saveQueue(prefs, key, next);
  }

  static Future<void> flush({
    required ApiClient api,
    required int year,
    required int term,
  }) async {
    final namespace = api.namespace;
    while (true) {
      _requireSameAccount(api, namespace);
      final queue = await loadQueue(namespace, year, term);
      if (queue.isEmpty) return;
      for (final item in queue) {
        _requireSameAccount(api, namespace);
        final synced = await api.createScheduleAdjustment(item);
        _requireSameAccount(api, namespace);
        ScheduleAdjustmentRecord confirmed = synced;
        if (item.status == 'restored' && synced.isActive) {
          try {
            confirmed = await api.restoreScheduleAdjustment(
              clientId: item.clientId,
              expectedRevision: item.revision - 1,
            );
          } on ApiException catch (error) {
            if (error.statusCode == 409) {
              throw ScheduleAdjustmentConflict(item, error);
            }
            rethrow;
          }
        }
        await _saveSyncedRecord(namespace, year, term, confirmed);
        // 只确认本次成功上传的版本，保留网络等待期间新增或撤回的记录。
        await _acknowledge(namespace, year, term, item);
      }
    }
  }

  static void _requireSameAccount(ApiClient api, String namespace) {
    if (api.namespace != namespace) throw StateError('账号已切换，请重新同步调课');
  }

  static Future<void> discardPending(
          String namespace, ScheduleAdjustmentRecord pending) =>
      _acknowledge(namespace, pending.year, pending.term, pending);

  static Future<void> _acknowledge(String namespace, int year, int term,
      ScheduleAdjustmentRecord uploaded) async {
    final prefs = await SharedPreferences.getInstance();
    final key = _key(namespace, year, term);
    final uploadedJson = jsonEncode(uploaded.toJson());
    final remaining = _readQueue(prefs, key)
        .where((item) => jsonEncode(item.toJson()) != uploadedJson)
        .toList();
    await _saveQueue(prefs, key, remaining);
  }

  static Future<void> _saveQueue(SharedPreferences prefs, String key,
      List<ScheduleAdjustmentRecord> queue) async {
    final bool saved;
    if (queue.isEmpty) {
      saved = await prefs.remove(key);
    } else {
      saved = await prefs.setString(
        key,
        jsonEncode([for (final item in queue) item.toJson()]),
      );
    }
    if (!saved) throw StateError('课表调课离线队列保存失败');
  }
}

/// 用本账号尚未同步的修改覆盖云端快照，保留调课发生的顺序。
List<ScheduleAdjustmentRecord> mergePendingScheduleAdjustments(
  List<ScheduleAdjustmentRecord> remote,
  List<ScheduleAdjustmentRecord> pending,
) {
  final byId = {for (final item in pending) item.clientId: item};
  final remoteIds = remote.map((item) => item.clientId).toSet();
  return [
    for (final item in remote) byId[item.clientId] ?? item,
    for (final item in pending)
      if (!remoteIds.contains(item.clientId)) item,
  ];
}
