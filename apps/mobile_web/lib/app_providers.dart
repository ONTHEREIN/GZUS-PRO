import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'api_client.dart';

/// 应用级 API 客户端：会话、缓存和认证状态只在一个受控实例中保存。
final apiClientProvider = Provider<ApiClient>((ref) {
  final client = ApiClient();
  ref.onDispose(client.dispose);
  return client;
});

/// 根壳可观察的认证状态，逐步替代页面间可变字段传递。
final authenticatedProvider = NotifierProvider<AuthenticatedNotifier, bool>(
  AuthenticatedNotifier.new,
);

class AuthenticatedNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void setAuthenticated(bool value) {
    state = value;
  }
}

/// 个人资料页的数据源；失效后由页面显式刷新，避免页面私有 Future 状态分散。
final studentInfoProvider =
    FutureProvider.family<StudentInfo, ApiClient>((ref, client) async {
  final response = await client.me(forceRefresh: false);
  return response.data;
});

/// 学分页的数据源；缓存和网络协议仍由 ApiClient 统一处理。
final creditsProvider =
    FutureProvider.family<List<CreditItem>, ApiClient>((ref, client) async {
  final response = await client.credits(forceRefresh: false);
  return response.data;
});

/// 通知详情查询的不可变参数，确保不同 API 会话不会共享详情状态。
class NoticeDetailRequest {
  const NoticeDetailRequest({required this.client, required this.url});

  final ApiClient client;
  final String url;

  @override
  bool operator ==(Object other) =>
      other is NoticeDetailRequest &&
      identical(client, other.client) &&
      url == other.url;

  @override
  int get hashCode => Object.hash(identityHashCode(client), url);
}

final noticesProvider =
    FutureProvider.family<List<NoticeItem>, ApiClient>((ref, client) async {
  final response = await client.notices(forceRefresh: false);
  return response.data;
});

final noticeDetailProvider =
    FutureProvider.family<NoticeDetail, NoticeDetailRequest>(
  (ref, request) async {
    final response = await request.client.fetchNoticeDetail(request.url);
    return response.data;
  },
);

final ehallApplicationsProvider =
    FutureProvider.family<List<EhallApplicationItem>, ApiClient>((ref, client) {
  return client.ehallApplications(forceRefresh: false).timeout(
        const Duration(seconds: 12),
      );
});

/// 考勤数据的不可变查询参数；按 API 会话与学期隔离缓存。
class AttendanceRequest {
  const AttendanceRequest({
    required this.client,
    required this.year,
    required this.term,
    required this.forceRefresh,
  });

  final ApiClient client;
  final int year;
  final int term;
  final bool forceRefresh;

  @override
  bool operator ==(Object other) =>
      other is AttendanceRequest &&
      identical(client, other.client) &&
      year == other.year &&
      term == other.term &&
      forceRefresh == other.forceRefresh;

  @override
  int get hashCode =>
      Object.hash(identityHashCode(client), year, term, forceRefresh);
}

final attendanceProvider =
    FutureProvider.family<DataResult<AttendanceResponse>, AttendanceRequest>(
  (ref, request) async {
    return request.client.attendance(
      year: request.year,
      term: request.term,
      forceRefresh: request.forceRefresh,
    );
  },
);

final ehallAffairsProvider =
    FutureProvider.family<List<EhallAffairItem>, ApiClient>((ref, client) {
  return client.ehallAffairs(forceRefresh: false);
});

final ehallProgressProvider =
    FutureProvider.family<EhallProgressOverview, ApiClient>((ref, client) {
  return client.ehallProgressOverview(forceRefresh: false);
});
