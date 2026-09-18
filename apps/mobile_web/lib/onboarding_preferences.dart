/// 首次引导和课表本地偏好的账号作用域键。
///
/// [namespace] 通常是学号；在身份尚未解析完成的测试或临时会话中，
/// 由 ApiClient 提供的 namespace 仍能保证当前会话之间不会共用无作用域的旧键。
String onboardingPreferenceKey(String namespace, String name) =>
    'onboarding.$namespace.$name';

String schedulePreferenceKey(String namespace, String name) =>
    'schedule.$namespace.$name';

String scheduleAcademicPreferenceKey(
  String namespace,
  int year,
  int term,
  String name,
) =>
    'schedule.$namespace.$year.$term.$name';

int onboardingStepFromStoredValue(int? value) {
  final step = value ?? 1;
  return step.clamp(1, 4).toInt();
}
