
import 'dart:async';

import 'package:flutter/services.dart';
import 'message_protocol_generated.dart';

class ReshubFlutter {

  late ReshubHostAction reshubHostAction;

  static const MethodChannel _channel =
      const MethodChannel('reshub_flutter');

  static Future<String> get platformVersion async {
    final String version = await _channel.invokeMethod('getPlatformVersion');
    return version;
  }

  ReshubFlutter() {
    reshubHostAction = ReshubHostAction();
  }

  static void initReshubCenter(
      String deviceId,
      String appVersion,
      bool isDebugPackage,
      Map<String, String> customParams,
      {
        String? customServerUrl = null,
      }) {
    print("ReshubFlutter initReshubCenter called in dart,customServerUrl = $customServerUrl");
    ReshubParams reshubParams = ReshubParams();
    reshubParams.deviceId = deviceId;
    reshubParams.appVersion = appVersion;
    reshubParams.isDebugPackage = isDebugPackage;
    reshubParams.customParams = customParams;
    if (customServerUrl != null) {
      reshubParams.customServerUrl = customServerUrl;
    }
    ReshubCenterHostAction().initReshubCenter(reshubParams);
  }

  static void initReshub(String appId, String appKey, String env) {
    print("ReshubFlutter initReshub called in dart");
    ReshubCenterHostAction().initReshub(appId, appKey, env);
  }

  Future<ResModel?> get(String resId) {
    return reshubHostAction.get(resId);
  }

  Future<ResModel?> getLatest(String resId) {
    return reshubHostAction.getLatest(resId);
  }

  Future<ResModel?> getFetchedResConfig(String resId) {
    return reshubHostAction.getFetchedResConfig(resId);
  }

  Future<LoadResult> load(String resId) {
    return reshubHostAction.load(resId);
  }

  Future<LoadResult> loadLatest(String resId) {
    return reshubHostAction.loadLatest(resId);
  }

  Future<LoadResult> loadLatestWithOption(String resId, bool forceRequestRemoteConfig) {
    return reshubHostAction.loadLatestWithOption(resId, forceRequestRemoteConfig);
  }

  Future<void> reportBusinessEvent(String eventName, int cost, int errCode, Map<String, String> extInfo, bool reportImmediately) {
    return reshubHostAction.reportBusinessEvent(eventName, cost, errCode, extInfo, reportImmediately);
  }

}
