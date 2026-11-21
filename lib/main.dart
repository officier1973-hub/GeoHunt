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
import 'app_settings.dart';
import 'screens/home_screen.dart';
import 'screens/map_screen.dart';
import 'track_recorder.dart';

const supabaseUrl = 'https://qucrbwsudcwqetcullsp.supabase.co';
const supabaseAnonKey = 'sb_publishable_CVhiWocVbOe54-Bleexnpg_9meljsC8';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(url: supabaseUrl, anonKey: supabaseAnonKey);

  try {
    await AppSession.ensureSignedIn();
  } catch (e) {
    debugPrint('Ошибка анонимной авторизации: $e');
  }

  await AppSession.load();
  await AppSettings.load();
  await initializeService();

  if (AppSession.hasSession) {
    try {
      final res = await Supabase.instance.client
          .from('hunters')
          .select('id')
          .eq('id', AppSession.hunterId!)
          .maybeSingle();
      if (res == null) await AppSession.clear();
    } catch (_) {}
  }

  runApp(const GeoHuntApp());
}

Future<void> initializeService() async {
  final service = FlutterBackgroundService();

  const AndroidNotificationChannel channel = AndroidNotificationChannel(
    'geohunt_channel',
    'GeoHunt Tracking',
    description: 'Отслеживание вашей геопозиции для группы.',
    importance: Importance.low,
  );

  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
      FlutterLocalNotificationsPlugin();
  if (Platform.isAndroid) {
    await flutterLocalNotificationsPlugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
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

  StreamSubscription<Position>? posSub;
  bool isAppForeground = true;
  bool isTrackRecording = await TrackRecorder.isRecording();
  DateTime? lastDbUpdate;

  if (service is AndroidServiceInstance) {
    service.on('setAsForeground').listen((event) {
      service.setAsForegroundService();
    });
    service.on('setAsBackground').listen((event) {
      service.setAsBackgroundService();
    });
  }

  final prefs = await SharedPreferences.getInstance();
  await prefs.reload();

  final hunterId = prefs.getString('active_hunter_id');
  if (hunterId == null) {
    await service.stopSelf();
    return;
  }

  try {
    Supabase.instance.client;
  } catch (_) {
    await Supabase.initialize(url: supabaseUrl, anonKey: supabaseAnonKey);
  }

  Future<void> startOrRestartStream() async {
    await posSub?.cancel();
    await prefs.reload();

    final currentHunterId = prefs.getString('active_hunter_id');
    if (currentHunterId == null) {
      await service.stopSelf();
      return;
    }

    final dbInt = prefs.getInt('setting_db_interval') ?? 30;
    final interval = Duration(seconds: dbInt);

    final accStr = prefs.getString('setting_accuracy') ?? 'high';
    final acc = accStr == 'balanced'
        ? LocationAccuracy.medium
        : (accStr == 'low' ? LocationAccuracy.low : LocationAccuracy.high);

    posSub = Geolocator.getPositionStream(
      locationSettings: LocationSettings(
        accuracy: acc,
        distanceFilter: 5,
      ),
    ).listen((position) async {
      if (isAppForeground) return;

      // Запись локального трека идёт при каждом шаге 8+ м, независимо от интервала БД
      if (isTrackRecording) {
        await TrackRecorder.appendPoint(
          lat: position.latitude,
          lon: position.longitude,
          accuracy: position.accuracy,
        );
      }

      final activeHunterId = prefs.getString('active_hunter_id');
      if (activeHunterId == null) return;

      final now = DateTime.now();
      if (lastDbUpdate != null && now.difference(lastDbUpdate!) < interval) {
        return;
      }
      lastDbUpdate = now;

      try {
        await Supabase.instance.client.from('hunters').update({
          'lat': position.latitude,
          'lon': position.longitude,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        }).eq('id', activeHunterId);
      } catch (e) {
        debugPrint('BG location update error: $e');
      }
    });
  }

  service.on('appState').listen((event) {
    if (event != null && event['foreground'] is bool) {
      isAppForeground = event['foreground'] as bool;
    }
  });

  service.on('trackState').listen((event) {
    if (event != null && event['recording'] is bool) {
      isTrackRecording = event['recording'] as bool;
    }
  });

  service.on('updateSettings').listen((event) async {
    await startOrRestartStream();
  });

  service.on('stopService').listen((event) async {
    await posSub?.cancel();
    await service.stopSelf();
  });

  service.on('onTaskRemoved').listen((event) async {
    await posSub?.cancel();
    await service.stopSelf();
  });

  service.on('stopTracking').listen((event) async {
    await prefs.remove('active_hunter_id');
    await posSub?.cancel();
    await service.stopSelf();
    debugPrint('BG Service: Tracking stopped.');
  });

  await startOrRestartStream();
}

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
