import 'package:flutter_test/flutter_test.dart';
import 'package:gzus_pro_mobile_web/app_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

void main() {
  test('应用范围 API 客户端保持单例且认证状态可观察', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final first = container.read(apiClientProvider);
    final second = container.read(apiClientProvider);
    expect(identical(first, second), isTrue);
    expect(container.read(authenticatedProvider), isFalse);

    container.read(authenticatedProvider.notifier).setAuthenticated(true);
    expect(container.read(authenticatedProvider), isTrue);
  });
}
