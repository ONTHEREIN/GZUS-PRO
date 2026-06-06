import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class BuglyService {
  static const MethodChannel _channel = MethodChannel('cn.gzus.pro/bugly');
  
  static bool _isInitialized = false;
  static bool get isInitialized => _isInitialized;
  
  /// 初始化 Bugly
  static Future<void> init() async {
    if (_isInitialized) return;
    
    try {
      if (!kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS)) {
        await _channel.invokeMethod('init');
      }
      _isInitialized = true;
      debugPrint('Bugly initialized successfully');
    } catch (e) {
      debugPrint('Failed to initialize Bugly: $e');
    }
  }
  
  /// 设置用户标识
  static Future<void> setUserId(String userId) async {
    if (!_isInitialized) return;
    
    try {
      if (!kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS)) {
        await _channel.invokeMethod('setUserId', {'userId': userId});
      }
    } catch (e) {
      debugPrint('Failed to set user id: $e');
    }
  }
  
  /// 设置标签
  static Future<void> setTag(int tagId) async {
    if (!_isInitialized) return;
    
    try {
      if (!kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS)) {
        await _channel.invokeMethod('setTag', {'tagId': tagId});
      }
    } catch (e) {
      debugPrint('Failed to set tag: $e');
    }
  }
  
  /// 设置关键数据
  static Future<void> setUserData(String key, String value) async {
    if (!_isInitialized) return;
    
    try {
      if (!kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS)) {
        await _channel.invokeMethod('setUserData', {'key': key, 'value': value});
      }
    } catch (e) {
      debugPrint('Failed to set user data: $e');
    }
  }
  
  /// 上报自定义异常
  static Future<void> reportException(
    dynamic exception,
    StackTrace stackTrace, {
    String? reason,
  }) async {
    if (!_isInitialized) return;
    
    try {
      if (!kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS)) {
        await _channel.invokeMethod('reportException', {
          'exception': exception.toString(),
          'stackTrace': stackTrace.toString(),
          'reason': reason,
        });
      }
      debugPrint('Bugly reported exception: $exception');
    } catch (e) {
      debugPrint('Failed to report exception: $e');
    }
  }
  
  /// 测试崩溃
  static Future<void> testCrash() async {
    if (!_isInitialized) return;
    
    try {
      if (!kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS)) {
        await _channel.invokeMethod('testCrash');
      }
    } catch (e) {
      debugPrint('Failed to test crash: $e');
    }
  }
  
  /// 全局异常捕获
  static void setupErrorHandling() {
    // 捕获 Flutter 框架异常
    FlutterError.onError = (FlutterErrorDetails details) {
      FlutterError.presentError(details);
      if (_isInitialized) {
        reportException(details.exception, details.stack ?? StackTrace.empty);
      }
    };
    
    // 捕获 Dart 未捕获异常
    PlatformDispatcher.instance.onError = (error, stack) {
      if (_isInitialized) {
        reportException(error, stack);
      }
      return true;
    };
  }
}
