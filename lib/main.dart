import 'dart:async';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'app_session.dart';
import 'screens/home_screen.dart';
import 'screens/map_screen.dart';

const supabaseUrl = 'https://qucrbwsudcwqetcullsp.supabase.co';
const supabaseAnonKey = 'sb_publishable_CVhiWocVbOe54-Bleexnpg_9meljsC8';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(url: supabaseUrl, anonKey: supabaseAnonKey);

  // ✅ Анонимный вход (создает auth.uid() для RLS)
  final session = Supabase.instance.client.auth.currentSession;
  if (session == null) {
    try {
      await Supabase.instance.client.auth.signInAnonymously();
    } catch (e) {
      debugPrint('Ошибка анонимной авторизации: $e');
    }
  }

  await AppSession.load();
  await initializeService();

  if (AppSession.hasSession) {
    try {
      final res = await Supabase.instance.client
          .from('hunters')
          .select('id')
          .eq('id', AppSession.hunterId!)
          .maybeSingle();
      if (res == null) await AppSession.clear();
    } catch (_) {
      // Если произошла сетевая ошибка, оставляем сессию, пусть приложение откроется
    }
  }

  runApp(const GeoHuntApp());
}

// ===============================================================
// ✅ ФОНОВАЯ СЛУЖБА
// ===============================================================
Future<void> initializeService() async {
  final service = FlutterBackgroundService();

  const AndroidNotificationChannel channel = AndroidNotificationChannel(
    'geohunt_channel',
    'GeoHunt Tracking',
    description: 'Отслеживание вашей геопозиции для группы.',
    importance: Importance.low,
  );

  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();
  if (Platform.isAndroid) {
    await flutterLocalNotificationsPlugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);
  }

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStart,
      autoStart: false,
      isForegroundMode: true,
      notificationChannelId: 'geohunt_channel',
      initialNotificationTitle: 'GeoHunt',
      initialNotificationContent: 'Отслеживание локации...',
      foregroundServiceNotificationId: 888,
    ),
    iosConfiguration: IosConfiguration(
      autoStart: false,
      onForeground: onStart,
      onBackground: onIosBackground,
    ),
  );
}

@pragma('vm:entry-point')
Future<bool> onIosBackground(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  return true;
}

@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();

  if (service is AndroidServiceInstance) {
    service.on('setAsForeground').listen((event) {
      service.setAsForegroundService();
    });
    service.on('setAsBackground').listen((event) {
      service.setAsBackgroundService();
    });
  }

  // Остановка сервиса (кнопка Выйти или свайп)
  service.on('stopService').listen((event) {
    service.stopSelf();
  });

  // Остановка при свайпе приложения из недавних
  service.on('onTaskRemoved').listen((event) {
    service.stopSelf();
  });

  // Остановка отправки координат без остановки сервиса
  service.on('stopTracking').listen((event) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('active_hunter_id');
    debugPrint("BG Service: Tracking stopped.");
  });

  final prefs = await SharedPreferences.getInstance();
  final hunterId = prefs.getString('active_hunter_id');
  if (hunterId == null) return;

  try {
    Supabase.instance.client;
  } catch (_) {
    await Supabase.initialize(url: supabaseUrl, anonKey: supabaseAnonKey);
  }

  Geolocator.getPositionStream(
    locationSettings: const LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 5,
    ),
  ).listen((position) async {
    final currentHunterId = prefs.getString('active_hunter_id');
    if (currentHunterId == null) return;

    try {
      await Supabase.instance.client.from('hunters').update({
        'lat': position.latitude,
        'lon': position.longitude,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', currentHunterId);
    } catch (e) {
      debugPrint('BG location update error: $e');
    }
  });
}
// ===============================================================

class GeoHuntApp extends StatelessWidget {
  const GeoHuntApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GeoHunt',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2E4A2C),
          brightness: Brightness.dark,
        ),
      ),
      home: AppSession.hasSession ? const MapScreen() : const HomeScreen(),
    );
  }
}
