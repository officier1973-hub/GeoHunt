import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppSettings {
  static const _kAccuracy = 'setting_accuracy';
  static const _kDbInterval = 'setting_db_interval';
  static const _kCompassEnabled = 'setting_compass_enabled';

  static LocationAccuracy gpsAccuracy = LocationAccuracy.high;
  static Duration dbInterval = const Duration(seconds: 30);
  static bool compassEnabled = true;

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();

    final accStr = prefs.getString(_kAccuracy) ?? 'high';
    switch (accStr) {
      case 'high': gpsAccuracy = LocationAccuracy.high; break;
      case 'balanced': gpsAccuracy = LocationAccuracy.medium; break;
      case 'low': gpsAccuracy = LocationAccuracy.low; break;
      default: gpsAccuracy = LocationAccuracy.high;
    }

    final dbInt = prefs.getInt(_kDbInterval) ?? 30;
    dbInterval = Duration(seconds: dbInt);

    compassEnabled = prefs.getBool(_kCompassEnabled) ?? true;
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

  static Future<void> saveCompass(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kCompassEnabled, enabled);
    await load();
  }
}
