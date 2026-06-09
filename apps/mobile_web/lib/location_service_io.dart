import 'dart:async';

import 'package:flutter/services.dart';

class LocationService {
  static const _channel = MethodChannel('cn.gzus.pro/location');

  static Future<({double lat, double lon})?> getCoarseLocation() async {
    try {
      final result = await _channel
          .invokeMethod<Map<dynamic, dynamic>>('getCoarseLocation');
      if (result == null) return null;
      final lat = result['lat'];
      final lon = result['lon'];
      if (lat is double && lon is double) {
        return (lat: lat, lon: lon);
      }
      if (lat is int && lon is int) {
        return (lat: lat.toDouble(), lon: lon.toDouble());
      }
      return null;
    } on MissingPluginException {
      return null;
    } catch (_) {
      return null;
    }
  }
}
