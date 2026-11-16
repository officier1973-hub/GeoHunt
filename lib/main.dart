import 'dart:async';
import 'dart:io';
import 'dart:ui'; // ✅ Нужен для DartPluginRegistrant
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geolocator/geolocator.dart';
import 'package:maplibre/maplibre.dart'; // ✅ Импорт для MapLibre
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'app_session.dart';
import 'screens/home_screen.dart';
import 'screens/map_screen.dart';

const supabaseUrl = 'https://qucrbwsudcwqetcullsp.supabase.co';
const supabaseAnonKey = 'sb_publishable_CVhiWocVbOe54-Bleexnpg_9meljsC8';

final GlobalKey<RestartWidgetState> appRestartKey = GlobalKey<RestartWidgetState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // ✅ Принудительно используем TextureView для всех карт
  MapLibreMap.useHybridComposition = true;

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

// ... (RestartWidget и initializeService остаются без изменений) ...
