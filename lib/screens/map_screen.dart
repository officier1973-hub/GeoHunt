import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:maplibre/maplibre.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:flutter_compass/flutter_compass.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import '../app_session.dart';
import '../main.dart';

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});
  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> with WidgetsBindingObserver {
  // ... (все переменные остаются без изменений) ...

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _posSub?.cancel();
    _compassSub?.cancel();
    _huntersSub?.cancel();
    _eventsSub?.cancel();
    _heartbeatTimer?.cancel();
    _freshnessTimer?.cancel();
    _cleanupTimer?.cancel();
    
    _audioPlayer.dispose();
    _sirenPlayer.dispose();
    
    MapLibreNetwork.urlTransform = null;
    
    super.dispose();
  }

  Future<void> _logout() async {
    // ... (диалог подтверждения) ...
    if (confirmed != true) return;

    FlutterBackgroundService().invoke("stopService");

    final hunterId = AppSession.hunterId;
    if (hunterId != null) {
      try {
        await Supabase.instance.client.from('hunters').delete().eq('id', hunterId);
      } catch (e) {
        debugPrint('Не удалось удалить охотника при выходе: $e');
      }
    }

    await AppSession.clear();
    
    // ✅ Принудительно очищаем кэш тайлов перед перезапуском
    try {
      await MapLibreNative.clearAmbientCache(); 
    } catch (e) {
      debugPrint('Ошибка очистки кэша: $e');
    }
    
    if (!mounted) return;
    
    // ✅ Перезапускаем приложение
    RestartWidget.restartApp(context);
  }

  // ... (остальной код без изменений) ...
}
