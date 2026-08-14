import 'package:flutter/foundation.dart';

/// 测试后门开关：为 true 时隐藏「生活缴费（ecard）」相关入口。
/// 从 main.dart 拆出，供 models/nav_config.dart 与 models/home_config.dart 复用。
@visibleForTesting
bool debugHideEcardForTests = false;

bool get hideEcardOnCurrentPlatform => debugHideEcardForTests;
