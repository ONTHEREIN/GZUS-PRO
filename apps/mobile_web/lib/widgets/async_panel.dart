import 'package:flutter/material.dart';

import '../api_client.dart';
import 'empty_state.dart';

class AsyncPanel<T> extends StatelessWidget {
  const AsyncPanel({
    super.key,
    required this.future,
    required this.builder,
    this.emptyMessage = '暂无数据',
    this.onSessionExpired,
  });

  final Future<T> future;
  final Widget Function(T data) builder;
  final String emptyMessage;
  final VoidCallback? onSessionExpired;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<T>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
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
        if (data is List && data.isEmpty) {
          return ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              SizedBox(
                height: MediaQuery.sizeOf(context).height * 0.45,
                child: EmptyState(message: emptyMessage),
              ),
            ],
          );
        }
        return builder(data as T);
      },
    );
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
      onRefresh: onRefresh,
      child: child,
    );
  }
}
