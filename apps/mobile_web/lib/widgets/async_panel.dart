import 'dart:async';

import 'package:flutter/material.dart';

import '../api_client.dart';
import 'empty_state.dart';

String _refreshFailureReason(Object error) {
  if (error is ApiException) {
    final message = error.message.trim();
    final prefix = switch (error.statusCode) {
      401 => '登录状态失效',
      429 => '请求过于频繁',
      502 => '学校系统请求异常',
      503 => '服务暂时不可用',
      504 => '上游服务响应超时',
      _ => null,
    };
    if (prefix == null || message.startsWith(prefix)) return message;
    return '$prefix：$message';
  }
  if (error is TimeoutException) {
    return '客户端等待接口响应超时（已自动重试），请检查网络后重试';
  }
  if (error is FormatException) {
    return '服务器返回的数据格式异常，请稍后重试';
  }
  return '发生未预期错误（${error.runtimeType}），请稍后重试';
}

/// 下拉刷新失败时统一显示具体原因；保留原页面数据，不中断后续操作。
void showRefreshFailure(BuildContext context, Object error) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
        SnackBar(content: Text('刷新失败：${_refreshFailureReason(error)}')));
}

/// 异步面板：支持 stale-while-revalidate。
///
/// future 更换时若已有旧数据，继续展示旧数据（不闪加载动画），新数据就绪后
/// 平滑替换；静默刷新失败时保留旧数据。首次加载（无旧数据）仍显示加载动画。
class AsyncPanel<T> extends StatefulWidget {
  const AsyncPanel({
    super.key,
    required this.future,
    required this.builder,
    this.initialData,
    this.emptyMessage = '暂无数据',
    this.onSessionExpired,
  });

  final Future<T> future;
  final Widget Function(T data) builder;
  final T? initialData;
  final String emptyMessage;
  final VoidCallback? onSessionExpired;

  @override
  State<AsyncPanel<T>> createState() => _AsyncPanelState<T>();
}

class _AsyncPanelState<T> extends State<AsyncPanel<T>> {
  T? _lastData;

  @override
  void initState() {
    super.initState();
    _lastData = widget.initialData;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<T>(
      future: widget.future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          if (_lastData != null) {
            // 静默刷新中：展示旧数据，不闪加载动画
            return _buildData(_lastData as T);
          }
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          if (_lastData != null) {
            // 静默刷新失败：保留旧数据
            return _buildData(_lastData as T);
          }
          final error = snapshot.error;
          // 不再在 401 时触发 onSessionExpired，_withFallback 已处理 relogin
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.error_outline,
                      size: 48, color: Theme.of(context).colorScheme.error),
                  const SizedBox(height: 12),
                  Text(
                    error is ApiException ? error.message : error.toString(),
                    textAlign: TextAlign.center,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                ],
              ),
            ),
          );
        }
        final data = snapshot.data;
        _lastData = data;
        return _buildData(data as T);
      },
    );
  }

  Widget _buildData(T data) {
    if (data is List && data.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          SizedBox(
            height: MediaQuery.sizeOf(context).height * 0.45,
            child: EmptyState(message: widget.emptyMessage),
          ),
        ],
      );
    }
    return widget.builder(data);
  }
}

class PageRefresh extends StatelessWidget {
  const PageRefresh({super.key, required this.onRefresh, required this.child});

  final Future<void> Function() onRefresh;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      notificationPredicate: (notification) =>
          notification.metrics.axis == Axis.vertical,
      onRefresh: () async {
        try {
          await onRefresh();
        } catch (error) {
          if (context.mounted) showRefreshFailure(context, error);
        }
      },
      child: child,
    );
  }
}
