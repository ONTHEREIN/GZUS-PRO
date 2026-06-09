// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:async';
import 'dart:html';

class LocationService {
  static Future<({double lat, double lon})?> getCoarseLocation() async {
    try {
      final pos = await _getCurrentPosition(window.navigator.geolocation);
      if (pos == null) return null;

      final coords = pos.coords;
      if (coords == null) return null;

      final lat = coords.latitude;
      final lon = coords.longitude;
      if (lat == null || lon == null) return null;

      return (lat: lat.toDouble(), lon: lon.toDouble());
    } catch (_) {
      return null;
    }
  }

  static Future<Geoposition?> _getCurrentPosition(Geolocation geo) async {
    try {
      return await geo.getCurrentPosition(
        enableHighAccuracy: false,
        timeout: const Duration(seconds: 10),
        maximumAge: const Duration(hours: 1),
      );
    } catch (_) {
      return null;
    }
  }
}
