import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'app_session.dart';
import 'screens/home_screen.dart';
import 'screens/map_screen.dart';

const supabaseUrl = 'https://qucrbwsudcwqetcullsp.supabase.co';
const supabaseAnonKey = 'sb_publishable_CVhiWocVbOe54-Bleexnpg_9meljsC8';

// ✅ Глобальный ключ для перезапуска приложения
final GlobalKey<RestartWidgetState> appRestartKey = GlobalKey<RestartWidgetState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(url: supabaseUrl, anonKey: supabaseAnonKey);
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
    } catch (_) {}
  }

  runApp(const GeoHuntApp());
}

// ✅ Виджет-обертка для перезапуска
class RestartWidget extends StatefulWidget {
  const RestartWidget({super.key, required this.child});
  final Widget child;

  static void restartApp(BuildContext context) {
    context.findAncestorStateOfType<RestartWidgetState>()?.restartApp();
  }

  @override
  State<RestartWidget> createState() => RestartWidgetState();
}

class RestartWidgetState extends State<RestartWidget> {
  Key _key = UniqueKey();

  void restartApp() {
    setState(() {
      _key = UniqueKey();
    });
  }

  @override
  Widget build(BuildContext context) {
    return KeyedSubtree(key: _key, child: widget.child);
  }
}

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

  service.on('stopService').listen((event) {
    service.stopSelf();
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
  ).listen((position) {
    Supabase.instance.client.from('hunters').update({
      'lat': position.latitude,
      'lon': position.longitude,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }).eq('id', hunterId).catchError((e) {
      print('BG location update error: $e');
    });
  });
}

class GeoHuntApp extends StatelessWidget {
  const GeoHuntApp({super.key});

  @override
  Widget build(BuildContext context) {
    return RestartWidget(
      key: appRestartKey,
      child: MaterialApp(
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
      ),
    );
  }
}
