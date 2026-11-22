import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppSettings {
  static const _kAccuracy = 'setting_accuracy';
  static const _kDbInterval = 'setting_db_interval';
  static const _kShowDistanceRings = 'setting_show_distance_rings';
  static const _kRingDistances = 'setting_ring_distances';
  static const _kSkipOnboarding = 'setting_skip_onboarding';

  static const List<int> defaultRingDistances = [100, 200, 300];

  static LocationAccuracy gpsAccuracy = LocationAccuracy.high;
  static Duration dbInterval = const Duration(seconds: 30);
  static bool showDistanceRings = false;
  static List<int> ringDistancesMeters = List<int>.from(defaultRingDistances);
  static bool skipOnboarding = false;

  static String formatRingDistance(int meters) {
    if (meters >= 1000 && meters % 1000 == 0) {
      return '${meters ~/ 1000} км';
    }
    return '$meters м';
  }

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();

    final accStr = prefs.getString(_kAccuracy) ?? 'high';
    switch (accStr) {
      case 'high':
        gpsAccuracy = LocationAccuracy.high;
        break;
      case 'balanced':
        gpsAccuracy = LocationAccuracy.medium;
        break;
      case 'low':
        gpsAccuracy = LocationAccuracy.low;
        break;
      default:
        gpsAccuracy = LocationAccuracy.high;
    }

    final dbInt = prefs.getInt(_kDbInterval) ?? 30;
    dbInterval = Duration(seconds: dbInt);

    showDistanceRings = prefs.getBool(_kShowDistanceRings) ?? false;
    skipOnboarding = prefs.getBool(_kSkipOnboarding) ?? false;

    final rawRings = prefs.getStringList(_kRingDistances);
    if (rawRings != null && rawRings.isNotEmpty) {
      final parsed = rawRings
          .map(int.tryParse)
          .whereType<int>()
          .where((v) => v > 0)
          .toSet()
          .toList()
        ..sort();
      ringDistancesMeters =
          parsed.isNotEmpty ? parsed : List<int>.from(defaultRingDistances);
    } else {
      ringDistancesMeters = List<int>.from(defaultRingDistances);
    }
  }

  static Future<void> saveAccuracy(String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kAccuracy, value);
    await load();
  }

  static Future<void> saveDbInterval(int seconds) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kDbInterval, seconds);
    await load();
  }

  static Future<void> saveShowDistanceRings(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kShowDistanceRings, value);
    await load();
  }

  static Future<void> saveRingDistances(List<int> distances) async {
    final normalized = distances.where((v) => v > 0).toSet().toList()..sort();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _kRingDistances,
      normalized.map((e) => e.toString()).toList(),
    );
    await load();
  }

  static Future<void> saveSkipOnboarding(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kSkipOnboarding, value);
    await load();
  }
}
