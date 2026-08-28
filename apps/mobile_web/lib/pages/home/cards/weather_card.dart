import 'package:flutter/material.dart';

import '../../../api_client.dart';
import '../../../responsive/spacing.dart';
import '../../home/cards/home_card_shell.dart';

/// 今日天气卡片：大/中/小三种信息密度。
class WeatherLargeCard extends StatelessWidget {
  const WeatherLargeCard({this.weather, super.key});

  final WeatherData? weather;

  @override
  Widget build(BuildContext context) {
    return _WeatherCard(weather: weather, showForecast: true);
  }
}

class WeatherMediumCard extends StatelessWidget {
  const WeatherMediumCard({this.weather, super.key});

  final WeatherData? weather;

  @override
  Widget build(BuildContext context) {
    return _WeatherCard(weather: weather, showForecast: false);
  }
}

class WeatherSmallCard extends StatelessWidget {
  const WeatherSmallCard({this.weather, super.key});

  final WeatherData? weather;

  @override
  Widget build(BuildContext context) {
    final w = weather;
    if (w == null) {
      return const HomeCardShell(
        title: '天气',
        icon: Icons.wb_sunny,
        density: HomeCardDensity.small,
        badge: '--',
        child: Center(child: Text('加载失败')),
      );
    }
    return HomeCardShell(
      title: '天气',
      icon: Icons.wb_sunny,
      density: HomeCardDensity.small,
      badge: '${w.temperature.round()}°',
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${w.temperature.round()}°',
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
          ),
          Text(
            w.weather,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}

class _WeatherCard extends StatelessWidget {
  const _WeatherCard({required this.weather, required this.showForecast});

  final WeatherData? weather;
  final bool showForecast;

  @override
  Widget build(BuildContext context) {
    final w = weather;
    if (w == null) {
      return const HomeCardShell(
        title: '今日天气',
        icon: Icons.wb_sunny,
        density: HomeCardDensity.medium,
        badge: '--',
        child: Center(child: Text('天气数据加载失败')),
      );
    }

    final forecast = w.forecast.skip(1).take(3).toList();

    return HomeCardShell(
      title: '今日天气',
      icon: Icons.wb_sunny,
      density: showForecast ? HomeCardDensity.large : HomeCardDensity.medium,
      badge: w.location,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(_weatherIcon(w.weather),
                  size: 40, color: _weatherColor(w.weather, context)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${w.temperature.round()}°',
                        style: const TextStyle(
                            fontSize: 36, fontWeight: FontWeight.w200)),
                    Text(
                      '${w.weather}  ${w.tempMin != null ? w.tempMin!.round() : '--'}°~${w.tempMax != null ? w.tempMax!.round() : '--'}°',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 13,
                          color:
                              Theme.of(context).colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: GzusSpacing.m),
          Row(
            children: [
              Expanded(
                child: _WeatherMeta(
                  icon: Icons.water_drop,
                  text: '湿度 ${w.humidity}%',
                ),
              ),
              const SizedBox(width: GzusSpacing.s),
              Expanded(
                child: _WeatherMeta(
                  icon: Icons.air,
                  text: '${w.windDirection} ${w.windPower}',
                ),
              ),
            ],
          ),
          if (showForecast && forecast.isNotEmpty) ...[
            const Divider(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                for (final f in forecast)
                  Column(
                    children: [
                      Text(f.week,
                          style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant)),
                      const SizedBox(height: GzusSpacing.xs),
                      Icon(_weatherIcon(f.weatherDay),
                          size: 20,
                          color:
                              Theme.of(context).colorScheme.onSurfaceVariant),
                      const SizedBox(height: GzusSpacing.xs),
                      Text('${f.tempMax.round()}°',
                          style: const TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w700)),
                    ],
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _WeatherMeta extends StatelessWidget {
  const _WeatherMeta({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 16),
        const SizedBox(width: 4),
        Expanded(
          child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
      ],
    );
  }
}

IconData _weatherIcon(String? weatherText) {
  final w = weatherText ?? '';
  if (w.contains('雨')) return Icons.water_drop;
  if (w.contains('雪')) return Icons.ac_unit;
  if (w.contains('云') || w.contains('阴')) return Icons.wb_cloudy;
  return Icons.wb_sunny;
}

Color _weatherColor(String? weatherText, BuildContext context) {
  final w = weatherText ?? '';
  if (w.contains('雨')) return Colors.blue;
  if (w.contains('雪')) return Colors.lightBlue;
  if (w.contains('云') || w.contains('阴')) return Colors.grey;
  return Theme.of(context).colorScheme.primary;
}
