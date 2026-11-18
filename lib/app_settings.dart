import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppSettings {
  static const _kAccuracy = 'setting_accuracy';
  static const _kDbInterval = 'setting_db_interval';

  static LocationAccuracy gpsAccuracy = LocationAccuracy.high;
  static Duration dbInterval = const Duration(seconds: 30);

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
}
