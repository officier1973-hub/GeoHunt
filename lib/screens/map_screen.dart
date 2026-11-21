import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../app_session.dart';
import '../app_settings.dart';
import 'home_screen.dart';
import 'settings_screen.dart';

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});
  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> with WidgetsBindingObserver {
  MapLibreMapController? _mapCtrl;
  StreamSubscription<geo.Position>? _posSub;
  StreamSubscription<CompassEvent>? _compassSub;

  StreamSubscription<List<Map<String, dynamic>>>? _huntersSub;
  List<Map<String, dynamic>> _otherHunters = [];

  bool _mySosActive = false;
  bool _sosDialogOpen = false;
  final Map<String, bool> _otherHuntersSosState = {};
  final AudioPlayer _sirenPlayer = AudioPlayer();

  StreamSubscription<List<Map<String, dynamic>>>? _eventsSub;
  List<Map<String, dynamic>> _events = [];
  final Set<String> _seenEventIds = {};
  bool _initialEventsLoaded = false;

  LatLng? _myPos;
  double? _myBearing;
  double? _compassHeading;
  double? _gpsHeading;
  double _mapBearing = 0.0;

  bool _locating = false;
  bool _firstFix = true;
  bool _pendingCenter = false;

  LatLng? _lastCenter;
  double? _lastZoom;

  int _currentStyleIndex = 0;
  bool _isOfflineMode = false;
  bool _isSwitchingStyle = false;

  DateTime? _lastBearingUpdate;
  static const _bearingUpdateInterval = Duration(milliseconds: 250);

  DateTime? _lastDbUpdate;

  bool _myLayersSyncInProgress = false;
  bool _myLayersSyncPending = false;
  bool _myLayersPendingUpdateRings = false;

  static const _staleThreshold = Duration(hours: 1);
  static const _heartbeatInterval = Duration(minutes: 15);

  Timer? _heartbeatTimer;
  Timer? _freshnessTimer;

  static const double _labelsMinZoom = 12;

  final AudioPlayer _audioPlayer = AudioPlayer();

  static const String _satelliteTileUrl =
      'https://tiles.maps.eox.at/wmts/1.0.0/s2cloudless-2025_3857/default/g/{z}/{y}/{x}.jpg';
  static const String _baseStyleUrl =
      'https://tiles.openfreemap.org/styles/positron';

  final List<String> _styleNames = ['Улицы', 'Спутник', 'Гибрид'];

  String _roleLabel(String? role) {
    switch (role) {
      case 'shooter':
        return 'стрелок';
      case 'driver':
        return 'загонщик';
      case 'ranger':
        return 'егерь';
      case 'none':
        return '';
      default:
        return '';
    }
  }

  Color _safeParseHexColor(String? raw,
      {Color fallback = const Color(0xFF1976D2)}) {
    if (raw == null) return fallback;
    final cleaned = raw.replaceAll('#', '').trim();
    if (cleaned.length != 6 && cleaned.length != 8) return fallback;
    final parsed = int.tryParse(cleaned, radix: 16);
    if (parsed == null) return fallback;
    return Color(cleaned.length == 6 ? (0xFF000000 | parsed) : parsed);
  }

  DateTime? _parseUpdatedAt(dynamic raw) {
    if (raw == null) return null;
    final s = raw.toString().trim();
    if (s.isEmpty) return null;
    final hasTz = s.endsWith('Z') ||
        RegExp(r'[+\-]\d{2}:?\d{2}$').hasMatch(s) ||
        RegExp(r'[+\-]\d{2}$')
            .hasMatch(s.substring(s.length > 3 ? s.length - 3 : 0));
    final normalized = hasTz ? s : '${s}Z';
    final dt = DateTime.tryParse(normalized);
    return dt?.toUtc();
  }

  String _formatAge(Duration age) {
    if (age.inDays >= 1) return '${age.inDays} дн';
    if (age.inHours >= 1) {
      final m = age.inMinutes % 60;
      return m > 0 ? '${age.inHours} ч $m м' : '${age.inHours} ч';
    }
    if (age.inMinutes >= 1) return '${age.inMinutes} мин';
    return 'меньше минуты';
  }

  String _formatRingDistance(int meters) {
    if (meters >= 1000 && meters % 1000 == 0) {
      return '${meters ~/ 1000} км';
    }
    return '$meters м';
  }

  double _bearingDiffDeg(double a, double b) {
    return ((a - b + 540.0) % 360.0 - 180.0).abs();
  }

  List<double> _destinationPoint(
      LatLng center, double distanceMeters, double bearingRad) {
    const double earthRadius = 6371000.0;
    final lat1 = center.latitude * math.pi / 180.0;
    final lon1 = center.longitude * math.pi / 180.0;
    final angularDist = distanceMeters / earthRadius;

    final sinLat1 = math.sin(lat1);
    final cosLat1 = math.cos(lat1);
    final sinDist = math.sin(angularDist);
    final cosDist = math.cos(angularDist);

    final lat2 = math.asin(
      sinLat1 * cosDist + cosLat1 * sinDist * math.cos(bearingRad),
    );
    final lon2 = lon1 +
        math.atan2(
          math.sin(bearingRad) * sinDist * cosLat1,
          cosDist - sinLat1 * math.sin(lat2),
        );

    return [lon2 * 180.0 / math.pi, lat2 * 180.0 / math.pi];
  }

  Future<Uint8List> _createMapIcon({
    required IconData icon,
    required Color backgroundColor,
  }) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    const size = 64.0;
    const radius = size / 2 - 3;
    const center = Offset(size / 2, size / 2);

    final paintFill = Paint()..color = backgroundColor;
    canvas.drawCircle(center, radius, paintFill);

    final paintBorder = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0;
    canvas.drawCircle(center, radius, paintBorder);

    final textPainter = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(icon.codePoint),
        style: TextStyle(
          fontSize: 38,
          fontFamily: icon.fontFamily,
          package: icon.fontPackage,
          color: Colors.white,
        ),
      ),
      textDirection: TextDirection.ltr,
    );
    textPainter.layout();
    textPainter.paint(
      canvas,
      Offset((size - textPainter.width) / 2, (size - textPainter.height) / 2),
    );

    final picture = recorder.endRecording();
    final image = await picture.toImage(size.toInt(), size.toInt());
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _initTrackingService();

    _audioPlayer.setAudioContext(AudioContext(
      android: AudioContextAndroid(
        isSpeakerphoneOn: true,
        stayAwake: true,
        contentType: AndroidContentType.sonification,
        usageType: AndroidUsageType.alarm,
        audioFocus: AndroidAudioFocus.gainTransient,
      ),
    ));

    _sirenPlayer.setReleaseMode(ReleaseMode.loop);
    _sirenPlayer.setAudioContext(AudioContext(
      android: AudioContextAndroid(
        isSpeakerphoneOn: true,
        stayAwake: true,
        contentType: AndroidContentType.sonification,
        usageType: AndroidUsageType.alarm,
        audioFocus: AndroidAudioFocus.gainTransient,
      ),
    ));

    AppSettings.load().then((_) {
      if (mounted) setState(() {});
      _startLocation();
      _startCompass();
      _syncMyLocationLayers(updateRings: true);
    });

    _subscribeToGroupHunters();
    _subscribeToEvents();
    _startHeartbeat();
    _startFreshnessTimer();
  }

  Future<void> _initTrackingService() async {
    if (!kIsWeb && Platform.isAndroid) {
      try {
        await FlutterLocalNotificationsPlugin()
            .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin>()
            ?.requestNotificationsPermission();
      } catch (e) {
        debugPrint('Ошибка запроса разрешения на уведомления: $e');
      }
    }

    final service = FlutterBackgroundService();
    final running = await service.isRunning();
    if (!running) {
      await service.startService();
    } else {
      service.invoke('updateSettings');
    }
    service.invoke('appState', {'foreground': true});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _posSub?.cancel();
    _compassSub?.cancel();
    _huntersSub?.cancel();
    _eventsSub?.cancel();
    _heartbeatTimer?.cancel();
    _freshnessTimer?.cancel();

    _audioPlayer.dispose();
    _sirenPlayer.stop();
    _sirenPlayer.dispose();

    super.dispose();
  }

  void _showLegend() {
    const myColor = Color(0xFF2E7D32);
    final now = DateTime.now().toUtc();

    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) {
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(ctx).size.height * 0.7,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                  child: Row(
                    children: [
                      const Icon(Icons.people, size: 20),
                      const SizedBox(width: 8),
                      Text(
                        'Группа ${AppSession.groupCode ?? ""}',
                        style: const TextStyle(
                            fontSize: 18, fontWeight: FontWeight.bold),
                      ),
                      const Spacer(),
                      Text(
                        '${_otherHunters.length + 1} чел.',
                        style: const TextStyle(color: Colors.white60),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      ListTile(
                        leading: const CircleAvatar(
                          radius: 12,
                          backgroundColor: myColor,
                          child: Icon(Icons.my_location,
                              size: 14, color: Colors.white),
                        ),
                        title: Text(
                          '${AppSession.hunterName ?? ""} (вы)',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        subtitle: const Text('ваша позиция'),
                      ),
                      ..._otherHunters.map((h) {
                        final color =
                            _safeParseHexColor(h['color']?.toString());
                        final dt = _parseUpdatedAt(h['updated_at']);
                        final age = dt != null ? now.difference(dt) : null;

                        return ListTile(
                          leading: CircleAvatar(
                            radius: 12,
                            backgroundColor: color,
                          ),
                          title: Text((h['name'] ?? '').toString()),
                          subtitle: Text(
                              age != null ? _formatAge(age) : 'нет данных'),
                          trailing: h['sos'] == true
                              ? const Icon(Icons.warning_rounded,
                                  color: Colors.red)
                              : null,
                        );
                      }),
                      if (_otherHunters.isEmpty)
                        const Padding(
                          padding: EdgeInsets.all(32),
                          child: Text(
                            'В группе пока только вы.\nПередайте код другим охотникам.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.white60),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _toggleOfflineMode(bool value) async {
    setState(() => _isOfflineMode = value);
    if (!kIsWeb && Platform.isAndroid) {
      try {
        await setOffline(value);
      } catch (e) {
        debugPrint('setOffline error: $e');
      }
    }
    if (!mounted) return;
    if (_isOfflineMode) {
      _toast('Офлайн-режим: карта использует только кэш.');
    } else {
      _toast('Онлайн-режим карты.');
    }
  }

  Future<void> _toggleDistanceRings(bool value) async {
    await AppSettings.saveShowDistanceRings(value);
    if (mounted) setState(() {});
    await _syncMyLocationLayers(updateRings: true);
  }

  Future<void> _cycleStyle() async {
    if (_isSwitchingStyle) return;

    setState(() => _isSwitchingStyle = true);
    _rememberCamera();

    final nextIndex = (_currentStyleIndex + 1) % _styleNames.length;
    setState(() => _currentStyleIndex = nextIndex);

    await _updateStyleLayers();

    await Future.delayed(const Duration(milliseconds: 500));
    if (mounted) setState(() => _isSwitchingStyle = false);
  }

  Future<void> _updateStyleLayers() async {
    final ctrl = _mapCtrl;
    if (ctrl == null) return;

    try {
      try { await ctrl.removeLayer('satellite_layer'); } catch (_) {}
      try { await ctrl.removeSource('satellite_source'); } catch (_) {}
      try { await ctrl.removeLayer('roads_layer'); } catch (_) {}
      try { await ctrl.removeLayer('labels_layer'); } catch (_) {}

      if (_currentStyleIndex > 0) {
        await ctrl.addSource(
          'satellite_source',
          RasterSourceProperties(
            tiles: [_satelliteTileUrl],
            tileSize: 256,
            minzoom: 0,
            maxzoom: 14,
            attribution:
                '<a href="https://cloudless.eox.at">EOxCloudless</a> by EOX IT Services GmbH',
          ),
        );
        await ctrl.addRasterLayer(
          'satellite_source',
          'satellite_layer',
          RasterLayerProperties(),
        );
      }

      if (_currentStyleIndex == 2) {
        await ctrl.addLineLayer(
          'openmaptiles',
          'roads_layer',
          LineLayerProperties(
            lineColor: '#FFFFFF',
            lineWidth: 1.5,
            lineOpacity: 0.8,
          ),
          sourceLayer: 'transportation',
        );

        await ctrl.addSymbolLayer(
          'openmaptiles',
          'labels_layer',
          SymbolLayerProperties(
            textField: '{name}',
            textSize: 13,
            textColor: '#FFFFFF',
            textHaloColor: '#000000',
            textHaloWidth: 1.8,
            textFont: ['Noto Sans Regular'],
            textAllowOverlap: false,
          ),
          sourceLayer: 'place',
        );
      }

      await _updateOthersLayer();
      await _updateEventsLayer();
      await _syncMyLocationLayers(updateRings: true);
    } catch (e) {
      debugPrint('Error updating style layers: $e');
    }
  }

  Future<void> _syncMyLocationLayers({bool updateRings = false}) async {
    if (_mapCtrl == null) return;
    if (_myLayersSyncInProgress) {
      _myLayersSyncPending = true;
      if (updateRings) _myLayersPendingUpdateRings = true;
      return;
    }
    _myLayersSyncInProgress = true;

    try {
      if (updateRings) {
        await _updateDistanceRingsLayerInternal();
      }
      await _updateUserLocationLayerInternal();
    } finally {
      _myLayersSyncInProgress = false;
      if (_myLayersSyncPending) {
        final needRings = _myLayersPendingUpdateRings;
        _myLayersSyncPending = false;
        _myLayersPendingUpdateRings = false;
        _syncMyLocationLayers(updateRings: needRings);
      }
    }
  }

  Future<void> _updateDistanceRingsLayerInternal() async {
    final ctrl = _mapCtrl;
    if (ctrl == null) return;

    try {
      try { await ctrl.removeLayer('distance_rings_labels_layer'); } catch (_) {}
      try { await ctrl.removeLayer('distance_rings_layer'); } catch (_) {}
      try { await ctrl.removeLayer('distance_rings_casing_layer'); } catch (_) {}
      try { await ctrl.removeSource('distance_rings_labels_source'); } catch (_) {}
      try { await ctrl.removeSource('distance_rings_source'); } catch (_) {}

      final pos = _myPos;
      if (!AppSettings.showDistanceRings ||
          pos == null ||
          AppSettings.ringDistancesMeters.isEmpty) {
        return;
      }

      const int segments = 64;
      final ringFeatures = <Map<String, dynamic>>[];
      final labelFeatures = <Map<String, dynamic>>[];

      for (final meters in AppSettings.ringDistancesMeters) {
        final coords = <List<double>>[];
        for (int i = 0; i < segments; i++) {
          final theta = (2.0 * math.pi * i) / segments;
          coords.add(_destinationPoint(pos, meters.toDouble(), theta));
        }
        if (coords.isNotEmpty) {
          coords.add(List<double>.from(coords.first));
        }

        ringFeatures.add({
          'type': 'Feature',
          'geometry': {
            'type': 'LineString',
            'coordinates': coords,
          },
          'properties': {'meters': meters},
        });

        final northPoint = _destinationPoint(pos, meters.toDouble(), 0.0);
        labelFeatures.add({
          'type': 'Feature',
          'geometry': {
            'type': 'Point',
            'coordinates': northPoint,
          },
          'properties': {'label': _formatRingDistance(meters)},
        });
      }

      await ctrl.addGeoJsonSource('distance_rings_source', {
        'type': 'FeatureCollection',
        'features': ringFeatures,
      });

      await ctrl.addGeoJsonSource('distance_rings_labels_source', {
        'type': 'FeatureCollection',
        'features': labelFeatures,
      });

      await ctrl.addLineLayer(
        'distance_rings_source',
        'distance_rings_casing_layer',
        LineLayerProperties(
          lineColor: '#000000',
          lineWidth: 3.0,
          lineOpacity: 0.35,
        ),
      );

      await ctrl.addLineLayer(
        'distance_rings_source',
        'distance_rings_layer',
        LineLayerProperties(
          lineColor: '#29B6F6',
          lineWidth: 1.5,
          lineOpacity: 0.9,
        ),
      );

      await ctrl.addSymbolLayer(
        'distance_rings_labels_source',
        'distance_rings_labels_layer',
        SymbolLayerProperties(
          textField: ['get', 'label'],
          textSize: 11,
          textColor: '#E1F5FE',
          textHaloColor: '#000000',
          textHaloWidth: 1.8,
          textFont: ['Noto Sans Regular'],
          textAllowOverlap: false,
          textOffset: [0, -0.7],
        ),
        minzoom: _labelsMinZoom,
      );
    } catch (e) {
      debugPrint('Ошибка обновления слоя кругов расстояния: $e');
    }
  }

  Future<void> _updateUserLocationLayerInternal() async {
    final ctrl = _mapCtrl;
    final pos = _myPos;
    if (ctrl == null || pos == null) return;

    try {
      try { await ctrl.removeLayer('user_location_layer'); } catch (_) {}
      try { await ctrl.removeSource('user_location_source'); } catch (_) {}

      final bearing = _myBearing ?? 0.0;
      final geoJsonData = {
        'type': 'Feature',
        'geometry': {
          'type': 'Point',
          'coordinates': [pos.longitude, pos.latitude],
        },
        'properties': {'bearing': bearing},
      };

      await ctrl.addGeoJsonSource('user_location_source', geoJsonData);
      await ctrl.addSymbolLayer(
        'user_location_source',
        'user_location_layer',
        SymbolLayerProperties(
          iconImage: 'user_arrow',
          iconSize: 2.5,
          iconRotate: ['get', 'bearing'],
          iconRotationAlignment: 'map',
          iconAnchor: 'center',
          iconAllowOverlap: true,
          iconIgnorePlacement: true,
        ),
      );
    } catch (e) {
      debugPrint('Ошибка обновления слоя пользователя: $e');
    }
  }

  void _subscribeToEvents() {
    final groupId = AppSession.groupId;
    if (groupId == null) return;

    _eventsSub?.cancel();
    _eventsSub = Supabase.instance.client
        .from('events')
        .stream(primaryKey: ['id'])
        .eq('group_id', groupId)
        .order('created_at', ascending: false)
        .listen((rows) {
      if (!mounted) return;

      if (!_initialEventsLoaded) {
        for (final row in rows) {
          _seenEventIds.add(row['id'] as String);
        }
        _initialEventsLoaded = true;
      } else {
        for (final row in rows) {
          final id = row['id'] as String;
          if (!_seenEventIds.contains(id)) {
            _seenEventIds.add(id);
            final authorId = row['hunter_id'];
            if (authorId != AppSession.hunterId) {
              _playEventSound(row['type'] as String);
            }
          }
        }
      }

      setState(() => _events = rows);
      _updateEventsLayer();
    }, onError: (e) => debugPrint('Ошибка подписки на события: $e'));
  }

  Future<void> _playEventSound(String type) async {
    try {
      if (type == 'spotted') {
        await _audioPlayer.play(AssetSource('sounds/sound_spotted.mp3'));
      } else if (type == 'wounded') {
        await _audioPlayer.play(AssetSource('sounds/sound_wounded.mp3'));
      } else if (type == 'harvested') {
        await _audioPlayer.play(AssetSource('
