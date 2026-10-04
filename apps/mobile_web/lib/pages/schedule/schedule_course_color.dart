import 'package:flutter/material.dart';

Color scheduleCourseColor(String name) {
  const palette = [
    Color(0xFFFF9CCB),
    Color(0xFFFFE38B),
    Color(0xFFB9FF8A),
    Color(0xFF8EDDF3),
    Color(0xFFF3A6E7),
    Color(0xFFA9EFAF),
    Color(0xFFB8D7FF),
    Color(0xFFFFB9A8),
    Color(0xFFD7C5FF),
  ];
  var hash = 0;
  for (final unit in name.codeUnits) {
    hash = (hash + unit) % palette.length;
  }
  return palette[hash];
}
