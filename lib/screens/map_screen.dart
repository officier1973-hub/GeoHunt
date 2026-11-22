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
import '../track_exporter.dart';
import '../track_recorder.dart';
import 'home_screen.dart';
import 'settings_screen.dart';
import 'tracks_history_screen.dart';

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
  double? _myAccuracy;
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
  static const _bearingUpdateInterval = Duration(milliseconds: 100);

  DateTime? _lastDbUpdate;

  bool _userLayerReady = false;
  bool _ringsLayersReady = false;
  bool _trackLayersReady = false;
  bool _myLayersSyncInProgress = false;
  bool _myLayersSyncPending = false;
  bool _myLayersPendingUpdateRings = false;
  bool _myLayersPendingUpdateTrack = false;

  // Активная запись трека
  bool _isRecordingTrack = false;
  DateTime? _trackStartedAt;
  List<TrackPoint> _activeTrackPoints = [];
  double _activeTrackDistance = 0.0;
  Timer? _trackUiTimer;

  static const _staleThreshold = Duration(hours: 1);
  static const _heartbeatInterval = Duration(minutes: 15);

  Timer? _heartbeatTimer;
  Timer? _freshnessTimer;

  static const double _labelsMinZoom = 12;

  final AudioPlayer _audioPlayer = AudioPlayer();

  static const String _satelliteTileUrl =
      'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}';
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

  String _formatRingDistance(int meters) => AppSettings.formatRingDistance(meters);

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

    AppSettings.load().then((_) async {
      await _restoreActiveTrack();
      if (mounted) setState(() {});
      _startLocation();
      _startCompass();
      _syncMyLocationLayers(updateRings: true, updateTrack: true);
    });

    TrackRecorder.syncPendingTracks();

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

  Future<void> _restoreActiveTrack() async {
    final state = await TrackRecorder.loadActiveState();
    if (!mounted) return;
    setState(() {
      _isRecordingTrack = state.isRecording;
      _trackStartedAt = state.startedAt;
      _activeTrackPoints = state.points;
      _activeTrackDistance = state.distanceMeters;
    });
    FlutterBackgroundService()
        .invoke('trackState', {'recording': state.isRecording});
    _syncTrackTimer();
    await _syncMyLocationLayers(updateTrack: true);
  }

  void _syncTrackTimer() {
    _trackUiTimer?.cancel();
    if (_isRecordingTrack) {
      _trackUiTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted && _isRecordingTrack) {
          setState(() {});
        }
      });
    }
  }

  Future<void> _startTrackRecording() async {
    final pos = _myPos;
    final state = await TrackRecorder.startNewTrack(
      initialLat: pos?.latitude,
      initialLon: pos?.longitude,
      initialAccuracy: _myAccuracy,
    );
    if (!mounted) return;
    setState(() {
      _isRecordingTrack = true;
      _trackStartedAt = state.startedAt;
      _activeTrackPoints = state.points;
      _activeTrackDistance = state.distanceMeters;
    });
    FlutterBackgroundService().invoke('trackState', {'recording': true});
    _syncTrackTimer();
    await _syncMyLocationLayers(updateTrack: true);
    _toast('Запись трека началась');
  }

  Future<void> _showStopTrackDialog() async {
    final defaultTitle = TrackRecorder.defaultTrackTitle(
      _trackStartedAt ?? DateTime.now().toUtc(),
    );
    final titleCtrl = TextEditingController(text: defaultTitle);

    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Завершить запись трека?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Пройдено: ${TrackRecorder.formatDistance(_activeTrackDistance)} · Точек: ${_activeTrackPoints.length}',
              style: const TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: titleCtrl,
              maxLength: 60,
              decoration: const InputDecoration(
                labelText: 'Название трека',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('discard'),
            child: const Text('Сбросить', style: TextStyle(color: Colors.redAccent)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('continue'),
            child: const Text('Продолжить'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop('save'),
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );

    final enteredTitle = titleCtrl.text.trim();
    titleCtrl.dispose();

    if (action == null || action == 'continue') return;

    if (action == 'discard') {
      await TrackRecorder.discardActiveTrack();
      if (!mounted) return;
      setState(() {
        _isRecordingTrack = false;
        _trackStartedAt = null;
        _activeTrackPoints = [];
        _activeTrackDistance = 0.0;
      });
      FlutterBackgroundService().invoke('trackState', {'recording': false});
      _syncTrackTimer();
      await _syncMyLocationLayers(updateTrack: true);
      _toast('Запись трека сброшена');
      return;
    }

    if (action == 'save') {
      final uploaded = await TrackRecorder.finishAndSaveTrack(title: enteredTitle);
      if (!mounted) return;
      setState(() {
        _isRecordingTrack = false;
        _trackStartedAt = null;
        _activeTrackPoints = [];
        _activeTrackDistance = 0.0;
      });
      FlutterBackgroundService().invoke('trackState', {'recording': false});
      _syncTrackTimer();
      await _syncMyLocationLayers(updateTrack: true);
      if (uploaded) {
        _toast('Трек сохранён в облако');
      } else {
        _toast('Нет сети: трек сохранён локально и отправится позже');
      }
    }
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
    _trackUiTimer?.cancel();

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

  Future<void> _exportGroupEvents() async {
    if (_events.isEmpty) {
      _toast('Событий в группе пока нет');
      return;
    }
    final exportEvents = _events.map(ExportEvent.fromMap).toList();
    await TrackExporter.showEventsExportSheet(
      context,
      events: exportEvents,
      groupCode: AppSession.groupCode,
    );
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
      try { await ctrl.removeLayer('waterway_layer'); } catch (_) {}
      try { await ctrl.removeLayer('roads_layer'); } catch (_) {}
      try { await ctrl.removeLayer('roads_casing_layer'); } catch (_) {}
      try { await ctrl.removeLayer('labels_layer'); } catch (_) {}

      if (_currentStyleIndex > 0) {
        await ctrl.addSource(
          'satellite_source',
          RasterSourceProperties(
            tiles: [_satelliteTileUrl],
            tileSize: 256,
            minzoom: 0,
            maxzoom: 17,
            attribution:
                'Tiles &copy; Esri &mdash; Source: Esri, Maxar, Earthstar Geographics',
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
          'waterway_layer',
          LineLayerProperties(
            lineColor: '#4FC3F7',
            lineWidth: 1.2,
            lineOpacity: 0.65,
          ),
          sourceLayer: 'waterway',
        );

        await ctrl.addLineLayer(
          'openmaptiles',
          'roads_casing_layer',
          LineLayerProperties(
            lineColor: '#000000',
            lineWidth: 3.0,
            lineOpacity: 0.45,
            lineCap: 'round',
            lineJoin: 'round',
          ),
          sourceLayer: 'transportation',
        );

        await ctrl.addLineLayer(
          'openmaptiles',
          'roads_layer',
          LineLayerProperties(
            lineColor: '#FFFDE7',
            lineWidth: 1.4,
            lineOpacity: 0.88,
            lineCap: 'round',
            lineJoin: 'round',
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
            textHaloWidth: 2.0,
            textFont: ['Noto Sans Regular'],
            textAllowOverlap: false,
          ),
          sourceLayer: 'place',
        );
      }

      _userLayerReady = false;
      _ringsLayersReady = false;
      _trackLayersReady = false;
      await _updateOthersLayer();
      await _updateEventsLayer();
      await _syncMyLocationLayers(updateRings: true, updateTrack: true);
    } catch (e) {
      debugPrint('Error updating style layers: $e');
    }
  }

  Future<void> _syncMyLocationLayers({
    bool updateRings = false,
    bool updateTrack = false,
  }) async {
    if (_mapCtrl == null) return;
    if (_myLayersSyncInProgress) {
      _myLayersSyncPending = true;
      if (updateRings) _myLayersPendingUpdateRings = true;
      if (updateTrack) _myLayersPendingUpdateTrack = true;
      return;
    }
    _myLayersSyncInProgress = true;

    try {
      if (updateRings) {
        await _updateDistanceRingsLayerInternal();
      }
      if (updateTrack) {
        await _updateActiveTrackLayerInternal();
      }
      await _updateUserLocationLayerInternal();
    } finally {
      _myLayersSyncInProgress = false;
      if (_myLayersSyncPending) {
        final needRings = _myLayersPendingUpdateRings;
        final needTrack = _myLayersPendingUpdateTrack;
        _myLayersSyncPending = false;
        _myLayersPendingUpdateRings = false;
        _myLayersPendingUpdateTrack = false;
        _syncMyLocationLayers(updateRings: needRings, updateTrack: needTrack);
      }
    }
  }

  Future<void> _updateActiveTrackLayerInternal() async {
    final ctrl = _mapCtrl;
    if (ctrl == null) return;

    try {
      if (!_isRecordingTrack || _activeTrackPoints.length < 2) {
        _trackLayersReady = false;
        try { await ctrl.removeLayer('active_track_layer'); } catch (_) {}
        try { await ctrl.removeLayer('active_track_casing_layer'); } catch (_) {}
        try { await ctrl.removeSource('active_track_source'); } catch (_) {}
        return;
      }

      final coords =
          _activeTrackPoints.map((p) => [p.lon, p.lat]).toList();
      final geoJson = {
        'type': 'Feature',
        'geometry': {
          'type': 'LineString',
          'coordinates': coords,
        },
        'properties': {},
      };

      if (_trackLayersReady) {
        try {
          await ctrl.setGeoJsonSource('active_track_source', geoJson);
          return;
        } catch (_) {
          _trackLayersReady = false;
        }
      }

      try { await ctrl.removeLayer('active_track_layer'); } catch (_) {}
      try { await ctrl.removeLayer('active_track_casing_layer'); } catch (_) {}
      try { await ctrl.removeSource('active_track_source'); } catch (_) {}

      await ctrl.addGeoJsonSource('active_track_source', geoJson);

      await ctrl.addLineLayer(
        'active_track_source',
        'active_track_casing_layer',
        LineLayerProperties(
          lineColor: '#000000',
          lineWidth: 5.5,
          lineOpacity: 0.65,
          lineCap: 'round',
          lineJoin: 'round',
        ),
        belowLayerId: _userLayerReady ? 'user_location_layer' : null,
      );

      await ctrl.addLineLayer(
        'active_track_source',
        'active_track_layer',
        LineLayerProperties(
          lineColor: '#FFB300',
          lineWidth: 3.5,
          lineOpacity: 0.95,
          lineCap: 'round',
          lineJoin: 'round',
        ),
        belowLayerId: _userLayerReady ? 'user_location_layer' : null,
      );

      _trackLayersReady = true;
    } catch (e) {
      debugPrint('Ошибка обновления слоя активного трека: $e');
    }
  }

  Future<void> _updateDistanceRingsLayerInternal() async {
    final ctrl = _mapCtrl;
    if (ctrl == null) return;

    try {
      final pos = _myPos;
      if (!AppSettings.showDistanceRings ||
          pos == null ||
          AppSettings.ringDistancesMeters.isEmpty) {
        _ringsLayersReady = false;
        try { await ctrl.removeLayer('distance_rings_labels_layer'); } catch (_) {}
        try { await ctrl.removeLayer('distance_rings_layer'); } catch (_) {}
        try { await ctrl.removeLayer('distance_rings_casing_layer'); } catch (_) {}
        try { await ctrl.removeSource('distance_rings_labels_source'); } catch (_) {}
        try { await ctrl.removeSource('distance_rings_source'); } catch (_) {}
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

      final ringsGeoJson = {
        'type': 'FeatureCollection',
        'features': ringFeatures,
      };
      final labelsGeoJson = {
        'type': 'FeatureCollection',
        'features': labelFeatures,
      };

      if (_ringsLayersReady) {
        try {
          await ctrl.setGeoJsonSource('distance_rings_source', ringsGeoJson);
          await ctrl.setGeoJsonSource(
              'distance_rings_labels_source', labelsGeoJson);
          return;
        } catch (_) {
          _ringsLayersReady = false;
        }
      }

      try { await ctrl.removeLayer('distance_rings_labels_layer'); } catch (_) {}
      try { await ctrl.removeLayer('distance_rings_layer'); } catch (_) {}
      try { await ctrl.removeLayer('distance_rings_casing_layer'); } catch (_) {}
      try { await ctrl.removeSource('distance_rings_labels_source'); } catch (_) {}
      try { await ctrl.removeSource('distance_rings_source'); } catch (_) {}

      await ctrl.addGeoJsonSource('distance_rings_source', ringsGeoJson);
      await ctrl.addGeoJsonSource(
          'distance_rings_labels_source', labelsGeoJson);

      await ctrl.addLineLayer(
        'distance_rings_source',
        'distance_rings_casing_layer',
        LineLayerProperties(
          lineColor: '#000000',
          lineWidth: 3.0,
          lineOpacity: 0.35,
        ),
        belowLayerId: _userLayerReady ? 'user_location_layer' : null,
      );

      await ctrl.addLineLayer(
        'distance_rings_source',
        'distance_rings_layer',
        LineLayerProperties(
          lineColor: '#29B6F6',
          lineWidth: 1.5,
          lineOpacity: 0.9,
        ),
        belowLayerId: _userLayerReady ? 'user_location_layer' : null,
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
        belowLayerId: _userLayerReady ? 'user_location_layer' : null,
      );

      _ringsLayersReady = true;
    } catch (e) {
      debugPrint('Ошибка обновления слоя кругов расстояния: $e');
    }
  }

  Future<void> _updateUserLocationLayerInternal() async {
    final ctrl = _mapCtrl;
    final pos = _myPos;
    if (ctrl == null || pos == null) return;

    try {
      final bearing = _myBearing ?? 0.0;
      final geoJsonData = {
        'type': 'Feature',
        'geometry': {
          'type': 'Point',
          'coordinates': [pos.longitude, pos.latitude],
        },
        'properties': {'bearing': bearing},
      };

      if (_userLayerReady) {
        try {
          await ctrl.setGeoJsonSource('user_location_source', geoJsonData);
          return;
        } catch (_) {
          _userLayerReady = false;
        }
      }

      try { await ctrl.removeLayer('user_location_layer'); } catch (_) {}
      try { await ctrl.removeSource('user_location_source'); } catch (_) {}

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
      _userLayerReady = true;
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
        await _audioPlayer.play(AssetSource('sounds/sound_harvested.mp3'));
      }
    } catch (e) {
      debugPrint('Ошибка воспроизведения звука: $e');
    }
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer =
        Timer.periodic(_heartbeatInterval, (_) => _sendHeartbeat());
  }

  Future<void> _sendHeartbeat() async {
    final hunterId = AppSession.hunterId;
    if (hunterId == null) return;
    try {
      await Supabase.instance.client.from('hunters').update({
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', hunterId);
    } catch (e) {
      debugPrint('Heartbeat error: $e');
    }
  }

  void _startFreshnessTimer() {
    _freshnessTimer?.cancel();
    _freshnessTimer = Timer.periodic(const Duration(seconds: 60), (_) {
      if (mounted) _updateOthersLayer();
    });
  }

  void _startCompass() {
    _compassSub?.cancel();
    _compassSub = FlutterCompass.events?.listen((CompassEvent event) {
      final h = event.heading;
      if (h != null && h >= 0) {
        _compassHeading = h;
        _applyBearing();
      }
    });
  }

  void _applyBearing() {
    final bearing = _compassHeading ?? _gpsHeading;
    if (bearing == null) return;
    final now = DateTime.now();
    if (_lastBearingUpdate != null &&
        now.difference(_lastBearingUpdate!) < _bearingUpdateInterval) {
      return;
    }
    if (_myBearing != null && _bearingDiffDeg(bearing, _myBearing!) < 1.5) {
      return;
    }
    _lastBearingUpdate = now;
    _myBearing = bearing;
    _syncMyLocationLayers(updateRings: false, updateTrack: false);
  }

  void _subscribeToGroupHunters() {
    final groupId = AppSession.groupId;
    final myId = AppSession.hunterId;
    if (groupId == null || myId == null) return;

    _huntersSub?.cancel();
    _huntersSub = Supabase.instance.client
        .from('hunters')
        .stream(primaryKey: ['id'])
        .eq('group_id', groupId)
        .listen((rows) {
      for (final row in rows) {
        final id = row['id'] as String;
        final isSos = row['sos'] == true;

        if (id == myId) {
          _mySosActive = isSos;
        } else {
          if (isSos && _otherHuntersSosState[id] != true) {
            _triggerIncomingSos(row['name'] as String? ?? 'Охотник');
          }
          _otherHuntersSosState[id] = isSos;
        }
      }

      final others = rows
          .where((r) => r['id'] != myId)
          .where((r) => r['lat'] != null && r['lon'] != null)
          .toList();
      if (!mounted) return;
      setState(() => _otherHunters = others);
      _updateOthersLayer();
    }, onError: (e) => debugPrint('Ошибка подписки на охотников: $e'));
  }

  Future<void> _triggerIncomingSos(String name) async {
    try {
      await _sirenPlayer.stop();
      await _sirenPlayer.play(AssetSource('sounds/sos_siren.mp3'));
    } catch (e) {
      debugPrint('Ошибка сирены: $e');
    }

    if (!mounted) return;
    if (_sosDialogOpen) {
      _toast('SOS от $name!');
      return;
    }

    _sosDialogOpen = true;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: const Color(0xFFB71C1C),
          title: const Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: Colors.white, size: 32),
              SizedBox(width: 8),
              Text('SOS!',
                  style: TextStyle(
                      color: Colors.white, fontWeight: FontWeight.bold)),
            ],
          ),
          content: Text(
            'Охотник "$name" просит о помощи!\n\nПосмотрите на карту, его точка выделена красным.',
            style: const TextStyle(color: Colors.white, fontSize: 16),
          ),
          actions: [
            FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: Colors.white, foregroundColor: Colors.red),
              onPressed: () {
                _sirenPlayer.stop();
                Navigator.of(ctx).pop();
              },
              child: const Text('Понятно'),
            ),
          ],
        );
      },
    );
    _sosDialogOpen = false;
    await _sirenPlayer.stop();
  }

  Future<void> _toggleMySos() async {
    final hunterId = AppSession.hunterId;
    if (hunterId == null) return;

    if (!_mySosActive) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Отправить сигнал SOS?'),
          content: const Text(
              'Все участники группы услышат громкую сирену и увидят вашу точку красным. Используйте только в экстренной ситуации.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Отмена')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('SOS!'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }

    try {
      final newState = !_mySosActive;
      await Supabase.instance.client.from('hunters').update({
        'sos': newState,
        'sos_at': newState ? DateTime.now().toUtc().toIso8601String() : null,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', hunterId);

      setState(() => _mySosActive = newState);
      if (newState) _toast('Сигнал SOS отправлен!');
    } catch (e) {
      _toast('Ошибка отправки SOS: $e');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final service = FlutterBackgroundService();
    if (state == AppLifecycleState.resumed) {
      service.invoke('appState', {'foreground': true});
      _rememberCamera();
      AppSettings.load().then((_) async {
        await _restoreActiveTrack();
        if (mounted) setState(() {});
        _startLocation();
        _startCompass();
        _syncMyLocationLayers(updateRings: true, updateTrack: true);
      });
      TrackRecorder.syncPendingTracks();
      if (mounted) {
        setState(() {});
        _updateOthersLayer();
        _updateEventsLayer();
        _sendHeartbeat();
      }
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      service.invoke('appState', {'foreground': false});
    }
  }

  void _rememberCamera() {
    final cam = _mapCtrl?.cameraPosition;
    if (cam != null) {
      _lastCenter = cam.target;
      _lastZoom = cam.zoom;
    }
  }

  void _onCameraMove(CameraPosition position) {
    final b = position.bearing;
    if ((b - _mapBearing).abs() > 0.2 && mounted) {
      setState(() => _mapBearing = b);
    }
  }

  void _onCameraMoveEnd() {
    _rememberCamera();
    final cam = _mapCtrl?.cameraPosition;
    if (cam != null &&
        (cam.bearing - _mapBearing).abs() > 0.05 &&
        mounted) {
      setState(() => _mapBearing = cam.bearing);
    }
  }

  Future<void> _logout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Выйти из группы?'),
        content: Text(
          _isRecordingTrack
              ? 'Сейчас идёт запись трека — при выходе она будет остановлена и сброшена. Выйти из группы?'
              : 'Вы покинете группу на этом устройстве. Чтобы вернуться, снова введите код.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Отмена')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Выйти')),
        ],
      ),
    );
    if (confirmed != true) return;

    if (_isRecordingTrack) {
      await TrackRecorder.discardActiveTrack();
    }

    final hunterId = AppSession.hunterId;
    await AppSession.clear();
    FlutterBackgroundService().invoke('stopService');

    if (hunterId != null) {
      try {
        await Supabase.instance.client
            .from('hunters')
            .delete()
            .eq('id', hunterId);
      } catch (e) {
        debugPrint('Не удалось удалить охотника при выходе: $e');
      }
    }

    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const HomeScreen()),
      (_) => false,
    );
  }

  Future<void> _centerOnMe() async {
    final pos = _myPos;
    final ctrl = _mapCtrl;
    if (pos == null || ctrl == null) {
      _pendingCenter = true;
      await _startLocation();
      return;
    }
    await ctrl.animateCamera(
      CameraUpdate.newLatLngZoom(pos, 15),
      duration: const Duration(milliseconds: 500),
    );
    _lastCenter = pos;
    _lastZoom = 15;
  }

  Future<void> _startLocation() async {
    final ok = await _ensurePermission();
    if (!ok) {
      _toast('Нет разрешения на геолокацию');
      return;
    }
    if (mounted) setState(() => _locating = true);
    _posSub?.cancel();

    _posSub = geo.Geolocator.getPositionStream(
      locationSettings: geo.LocationSettings(
        accuracy: AppSettings.gpsAccuracy,
        distanceFilter: 5,
      ),
    ).listen(_onPosition);

    try {
      final cur = await geo.Geolocator.getCurrentPosition(
        locationSettings:
            geo.LocationSettings(accuracy: AppSettings.gpsAccuracy),
      );
      _onPosition(cur);
    } catch (_) {}
  }

  Future<bool> _ensurePermission() async {
    if (!await geo.Geolocator.isLocationServiceEnabled()) return false;
    var perm = await geo.Geolocator.checkPermission();
    if (perm == geo.LocationPermission.denied) {
      perm = await geo.Geolocator.requestPermission();
    }
    return perm == geo.LocationPermission.whileInUse ||
        perm == geo.LocationPermission.always;
  }

  Future<void> _onPosition(geo.Position pos) async {
    if (!mounted) return;
    final newPos = LatLng(pos.latitude, pos.longitude);
    _myAccuracy = pos.accuracy;
    _gpsHeading = pos.heading;
    _myBearing = _compassHeading ?? _gpsHeading ?? _myBearing;

    bool trackUpdated = false;
    if (_isRecordingTrack) {
      final added = await TrackRecorder.appendPoint(
        lat: pos.latitude,
        lon: pos.longitude,
        accuracy: pos.accuracy,
      );
      if (added != null && mounted) {
        if (_activeTrackPoints.isNotEmpty) {
          final prev = _activeTrackPoints.last;
          _activeTrackDistance += geo.Geolocator.distanceBetween(
            prev.lat,
            prev.lon,
            added.lat,
            added.lon,
          );
        }
        _activeTrackPoints = [..._activeTrackPoints, added];
        trackUpdated = true;
      }
    }

    if (!mounted) return;
    setState(() {
      _myPos = newPos;
      _locating = false;
    });

    await _syncMyLocationLayers(
      updateRings: AppSettings.showDistanceRings,
      updateTrack: trackUpdated,
    );
    await _updateMyPositionInDb(newPos);

    if (_firstFix && _mapCtrl != null) {
      _firstFix = false;
      await _mapCtrl!.animateCamera(
        CameraUpdate.newLatLngZoom(newPos, 15),
        duration: const Duration(milliseconds: 500),
      );
      _lastCenter = newPos;
      _lastZoom = 15;
      _pendingCenter = false;
      return;
    }

    if (_pendingCenter && _mapCtrl != null) {
      _pendingCenter = false;
      await _mapCtrl!.animateCamera(
        CameraUpdate.newLatLngZoom(newPos, 15),
        duration: const Duration(milliseconds: 500),
      );
      _lastCenter = newPos;
      _lastZoom = 15;
    }
  }

  Future<void> _updateMyPositionInDb(LatLng pos) async {
    final hunterId = AppSession.hunterId;
    if (hunterId == null) return;

    final now = DateTime.now();
    if (_lastDbUpdate != null &&
        now.difference(_lastDbUpdate!) < AppSettings.dbInterval) {
      return;
    }
    _lastDbUpdate = now;

    try {
      await Supabase.instance.client.from('hunters').update({
        'lat': pos.latitude,
        'lon': pos.longitude,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', hunterId);
    } catch (e) {
      debugPrint('Не удалось обновить позицию в БД: $e');
    }
  }

  void _onMapCreated(MapLibreMapController ctrl) => _mapCtrl = ctrl;

  Future<void> _onStyleLoaded() async {
    final ctrl = _mapCtrl;
    if (ctrl == null) return;

    _userLayerReady = false;
    _ringsLayersReady = false;
    _trackLayersReady = false;
    _myLayersSyncInProgress = false;
    _myLayersSyncPending = false;
    _myLayersPendingUpdateRings = false;
    _myLayersPendingUpdateTrack = false;
    _lastBearingUpdate = null;

    try {
      final arrowBytes = await rootBundle.load('assets/icons/arrow.png');
      await ctrl.addImage('user_arrow', arrowBytes.buffer.asUint8List());

      final spottedBytes = await _createMapIcon(
          icon: Icons.remove_red_eye,
          backgroundColor: const Color(0xFFFFC107));
      await ctrl.addImage('event_spotted', spottedBytes);

      final woundedBytes = await _createMapIcon(
          icon: Icons.water_drop, backgroundColor: const Color(0xFFE64A19));
      await ctrl.addImage('event_wounded', woundedBytes);

      final harvestedBytes = await _createMapIcon(
          icon: Icons.track_changes, backgroundColor: const Color(0xFF388E3C));
      await ctrl.addImage('event_harvested', harvestedBytes);
    } catch (e) {
      debugPrint('Не удалось загрузить/сгенерировать иконки: $e');
    }

    await _updateStyleLayers();
  }

  Future<void> _updateOthersLayer() async {
    final ctrl = _mapCtrl;
    if (ctrl == null) return;

    try {
      try { await ctrl.removeLayer('others_labels_layer'); } catch (_) {}
      try { await ctrl.removeLayer('others_layer'); } catch (_) {}
      try { await ctrl.removeSource('others_source'); } catch (_) {}

      if (_otherHunters.isEmpty) return;
      final now = DateTime.now().toUtc();

      final features = _otherHunters.map((h) {
        final name = (h['name'] ?? '').toString();
        final isSos = h['sos'] == true;
        final dt = _parseUpdatedAt(h['updated_at']);
        final age = dt != null ? now.difference(dt) : null;
        final isStale = age != null && age > _staleThreshold;

        String color;
        double radius;
        double strokeWidth;

        if (isSos) {
          color = '#FF0000';
          radius = 18.0;
          strokeWidth = 5.0;
        } else if (isStale) {
          color = '#9E9E9E';
          radius = 12.0;
          strokeWidth = 3.0;
        } else {
          color = (h['color'] ?? '#1976D2').toString();
          radius = 12.0;
          strokeWidth = 3.0;
        }

        String label = name;
        if (isSos) {
          label = 'SOS! $name';
        } else if (age != null && age > const Duration(minutes: 5)) {
          label = '$name · ${_formatAge(age)}';
        }

        return {
          'type': 'Feature',
          'geometry': {
            'type': 'Point',
            'coordinates': [h['lon'], h['lat']],
          },
          'properties': {
            'name': name,
            'color': color,
            'label': label,
            'radius': radius,
            'strokeWidth': strokeWidth,
          },
        };
      }).toList();

      final featureCollection = {
        'type': 'FeatureCollection',
        'features': features,
      };
      await ctrl.addGeoJsonSource('others_source', featureCollection);

      await ctrl.addCircleLayer(
        'others_source',
        'others_layer',
        CircleLayerProperties(
          circleColor: ['to-color', ['get', 'color']],
          circleRadius: ['get', 'radius'],
          circleStrokeColor: '#FFFFFF',
          circleStrokeWidth: ['get', 'strokeWidth'],
        ),
        belowLayerId: _userLayerReady ? 'user_location_layer' : null,
      );

      await ctrl.addSymbolLayer(
        'others_source',
        'others_labels_layer',
        SymbolLayerProperties(
          textField: ['get', 'label'],
          textSize: 12,
          textColor: '#FFFFFF',
          textHaloColor: '#000000',
          textHaloWidth: 2,
          textFont: ['Noto Sans Regular'],
          textAllowOverlap: false,
          textOffset: [0, -1.8],
        ),
        minzoom: _labelsMinZoom,
        belowLayerId: _userLayerReady ? 'user_location_layer' : null,
      );
    } catch (e) {
      debugPrint('Ошибка обновления слоя других охотников: $e');
    }
  }

  Future<void> _updateEventsLayer() async {
    final ctrl = _mapCtrl;
    if (ctrl == null) return;

    try {
      try { await ctrl.removeLayer('events_labels_layer'); } catch (_) {}
      try { await ctrl.removeLayer('events_icons_layer'); } catch (_) {}
      try { await ctrl.removeSource('events_source'); } catch (_) {}

      if (_events.isEmpty) return;
      final now = DateTime.now().toUtc();

      final features = _events.map((e) {
        final type = e['type'] as String;
        final hunterName = e['hunter_name'] as String? ?? 'Охотник';
        final note = e['note'] as String?;
        final dt = _parseUpdatedAt(e['created_at']);
        final age = dt != null ? now.difference(dt) : null;

        String typeLabel = '';
        String iconId = 'event_spotted';

        if (type == 'spotted') {
          typeLabel = 'Видел';
          iconId = 'event_spotted';
        } else if (type == 'wounded') {
          typeLabel = 'Подранен';
          iconId = 'event_wounded';
        } else if (type == 'harvested') {
          typeLabel = 'Добыт';
          iconId = 'event_harvested';
        }

        String label = '$hunterName: $typeLabel';
        if (note != null && note.isNotEmpty) {
          label += ' ($note)';
        }
        if (age != null && age > const Duration(minutes: 5)) {
          label += ' · ${_formatAge(age)}';
        }

        return {
          'type': 'Feature',
          'geometry': {
            'type': 'Point',
            'coordinates': [e['lon'], e['lat']],
          },
          'properties': {
            'icon': iconId,
            'label': label,
          },
        };
      }).toList();

      final featureCollection = {
        'type': 'FeatureCollection',
        'features': features,
      };
      await ctrl.addGeoJsonSource('events_source', featureCollection);

      await ctrl.addSymbolLayer(
        'events_source',
        'events_icons_layer',
        SymbolLayerProperties(
          iconImage: ['get', 'icon'],
          iconSize: 1.5,
          iconAllowOverlap: true,
          iconIgnorePlacement: true,
        ),
        belowLayerId: _userLayerReady ? 'user_location_layer' : null,
      );

      await ctrl.addSymbolLayer(
        'events_source',
        'events_labels_layer',
        SymbolLayerProperties(
          textField: ['get', 'label'],
          textSize: 11,
          textColor: '#FFFFFF',
          textHaloColor: '#000000',
          textHaloWidth: 2,
          textFont: ['Noto Sans Regular'],
          textAllowOverlap: false,
          textOffset: [0, 2.0],
        ),
        minzoom: _labelsMinZoom,
        belowLayerId: _userLayerReady ? 'user_location_layer' : null,
      );
    } catch (e) {
      debugPrint('Ошибка обновления слоя событий: $e');
    }
  }

  void _showEventBottomSheet() {
    if (_myPos == null) {
      _toast('Ожидание GPS-сигнала...');
      return;
    }

    String selectedType = 'spotted';
    final noteCtrl = TextEditingController();

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Padding(
              padding: EdgeInsets.only(
                left: 24,
                right: 24,
                top: 8,
                bottom: MediaQuery.of(ctx).viewInsets.bottom + 24,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Событие на охоте',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      _buildEventOption(
                          'spotted',
                          'Видел',
                          Colors.amber,
                          selectedType,
                          (val) => setModalState(() => selectedType = val)),
                      const SizedBox(width: 8),
                      _buildEventOption(
                          'wounded',
                          'Подранен',
                          Colors.deepOrange,
                          selectedType,
                          (val) => setModalState(() => selectedType = val)),
                      const SizedBox(width: 8),
                      _buildEventOption(
                          'harvested',
                          'Добыт',
                          Colors.green,
                          selectedType,
                          (val) => setModalState(() => selectedType = val)),
                    ],
                  ),
                  const SizedBox(height: 24),
                  TextField(
                    controller: noteCtrl,
                    maxLines: 2,
                    maxLength: 200,
                    decoration: const InputDecoration(
                      labelText: 'Заметка (необязательно)',
                      hintText: 'Например: крупный секач, ушёл на север',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    icon: const Icon(Icons.send),
                    label: const Text('Отправить событие'),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                    onPressed: () async {
                      final note = noteCtrl.text.trim();
                      Navigator.of(ctx).pop();
                      await _sendEvent(selectedType, note);
                    },
                  ),
                ],
              ),
            );
          },
        );
      },
    ).whenComplete(() => noteCtrl.dispose());
  }

  Widget _buildEventOption(
    String type,
    String label,
    MaterialColor color,
    String selectedType,
    Function(String) onSelect,
  ) {
    final isSelected = type == selectedType;
    return Expanded(
      child: InkWell(
        onTap: () => onSelect(type),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 16),
          decoration: BoxDecoration(
            color: isSelected ? color.withOpacity(0.2) : Colors.transparent,
            border: Border.all(
              color: isSelected ? color : Colors.white24,
              width: isSelected ? 2 : 1,
            ),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            children: [
              Icon(Icons.location_on, color: color, size: 28),
              const SizedBox(height: 8),
              Text(
                label,
                style: TextStyle(
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                  color: isSelected ? Colors.white : Colors.white70,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _sendEvent(String type, String note) async {
    final groupId = AppSession.groupId;
    final hunterId = AppSession.hunterId;
    final hunterName = AppSession.hunterName;
    final pos = _myPos;

    if (groupId == null ||
        hunterId == null ||
        hunterName == null ||
        pos == null) {
      return;
    }

    try {
      await Supabase.instance.client.from('events').insert({
        'group_id': groupId,
        'hunter_id': hunterId,
        'hunter_name': hunterName,
        'type': type,
        'lat': pos.latitude,
        'lon': pos.longitude,
        'note': note.isEmpty ? null : note,
      });
      _toast('Событие добавлено');
    } catch (e) {
      _toast('Ошибка отправки события: $e');
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Widget _buildCompass() {
    final normalized = ((_mapBearing % 360) + 360) % 360;
    final isRotated = normalized > 0.5 && normalized < 359.5;
    if (!isRotated) return const SizedBox.shrink();

    return Tooltip(
      message: 'Повернуть на север',
      child: GestureDetector(
        onTap: () {
          _mapCtrl?.animateCamera(
            CameraUpdate.bearingTo(0),
            duration: const Duration(milliseconds: 350),
          );
        },
        child: Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.55),
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white70, width: 1.5),
            boxShadow: const [
              BoxShadow(
                color: Colors.black38,
                blurRadius: 6,
                offset: Offset(0, 2),
              ),
            ],
          ),
          child: Center(
            child: Transform.rotate(
              angle: -_mapBearing * (math.pi / 180.0),
              child: CustomPaint(
                size: const Size(32, 32),
                painter: _CompassNeedlePainter(),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTrackControl() {
    if (!_isRecordingTrack) {
      return FloatingActionButton.extended(
        heroTag: 'track_fab',
        onPressed: _startTrackRecording,
        backgroundColor: const Color(0xFF2E4A2C),
        foregroundColor: Colors.white,
        icon: const Icon(Icons.route),
        label: const Text('Запись трека'),
      );
    }

    final elapsed = _trackStartedAt != null
        ? DateTime.now().toUtc().difference(_trackStartedAt!)
        : Duration.zero;
    final timeStr = TrackRecorder.formatDuration(
      elapsed.isNegative ? Duration.zero : elapsed,
    );
    final distStr = TrackRecorder.formatDistance(_activeTrackDistance);

    return Material(
      color: const Color(0xFFB71C1C).withOpacity(0.92),
      borderRadius: BorderRadius.circular(28),
      elevation: 4,
      child: InkWell(
        borderRadius: BorderRadius.circular(28),
        onTap: _showStopTrackDialog,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.fiber_manual_record,
                  color: Colors.white, size: 16),
              const SizedBox(width: 8),
              Text(
                '$timeStr · $distStr',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                ),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.stop_circle_outlined,
                  color: Colors.white, size: 20),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final center = _lastCenter ?? _myPos ?? const LatLng(55.751244, 37.618423);
    final zoom = _lastZoom ?? (_myPos != null ? 15.0 : 3.0);

    final myRole = _roleLabel(AppSession.hunterRole);
    final myTitle = myRole.isEmpty
        ? (AppSession.hunterName ?? '')
        : '${AppSession.hunterName ?? ''} · $myRole';

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Группа ${AppSession.groupCode ?? ""}',
                style: const TextStyle(fontSize: 12),
                overflow: TextOverflow.ellipsis),
            Text(myTitle,
                style:
                    const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                overflow: TextOverflow.ellipsis),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.people, color: Colors.white),
            tooltip: 'Список группы',
            onPressed: _showLegend,
          ),
          IconButton(
            icon: Icon(
              Icons.warning_rounded,
              color: _mySosActive ? Colors.red : Colors.white,
            ),
            tooltip: _mySosActive ? 'Отменить SOS' : 'Подать сигнал SOS',
            onPressed: _toggleMySos,
          ),
          TextButton.icon(
            onPressed: _isSwitchingStyle ? null : _cycleStyle,
            icon: _isSwitchingStyle
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.layers, color: Colors.white, size: 18),
            label: Text(
              _isSwitchingStyle ? '...' : _styleNames[_currentStyleIndex],
              style: const TextStyle(color: Colors.white, fontSize: 13),
            ),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, color: Colors.white),
            tooltip: 'Меню',
            onSelected: (value) {
              if (value == 'tracks_history') {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => const TracksHistoryScreen()),
                );
              } else if (value == 'export_events') {
                _exportGroupEvents();
              } else if (value == 'rings') {
                _toggleDistanceRings(!AppSettings.showDistanceRings);
              } else if (value == 'settings') {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const SettingsScreen()),
                ).then((_) async {
                  await AppSettings.load();
                  if (mounted) setState(() {});
                  _startLocation();
                  _startCompass();
                  await _syncMyLocationLayers(updateRings: true);
                  FlutterBackgroundService().invoke('updateSettings');
                });
              } else if (value == 'offline') {
                _toggleOfflineMode(!_isOfflineMode);
              } else if (value == 'logout') {
                _logout();
              }
            },
            itemBuilder: (ctx) => [
              const PopupMenuItem<String>(
                value: 'tracks_history',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.history),
                  title: Text('История треков'),
                ),
              ),
              const PopupMenuItem<String>(
                value: 'export_events',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.share_outlined),
                  title: Text('Экспорт событий (GPX / CSV)'),
                ),
              ),
              CheckedPopupMenuItem<String>(
                value: 'rings',
                checked: AppSettings.showDistanceRings,
                child: Text(
                  'Круги (${AppSettings.ringDistancesMeters.map(AppSettings.formatRingDistance).join(' / ')})',
                ),
              ),
              const PopupMenuItem<String>(
                value: 'settings',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.settings),
                  title: Text('Настройки'),
                ),
              ),
              CheckedPopupMenuItem<String>(
                value: 'offline',
                checked: _isOfflineMode,
                child: const Text('Офлайн-режим (кэш)'),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem<String>(
                value: 'logout',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.logout, color: Colors.redAccent),
                  title: Text('Выйти из группы',
                      style: TextStyle(color: Colors.redAccent)),
                ),
              ),
            ],
          ),
        ],
      ),
      body: Stack(
        children: [
          MapLibreMap(
            styleString: _baseStyleUrl,
            initialCameraPosition: CameraPosition(
              target: center,
              zoom: zoom,
            ),
            onMapCreated: _onMapCreated,
            onStyleLoadedCallback: _onStyleLoaded,
            trackCameraPosition: true,
            onCameraMove: _onCameraMove,
            onCameraIdle: _onCameraMoveEnd,
            compassEnabled: false,
          ),
          Positioned(
            top: 16,
            right: 16,
            child: _buildCompass(),
          ),
          if (_isOfflineMode)
            Positioned(
              top: 16,
              left: 16,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.orange.shade900.withOpacity(0.9),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.cloud_off, size: 16, color: Colors.white),
                    SizedBox(width: 6),
                    Text('Офлайн-кэш',
                        style: TextStyle(
                            fontSize: 12,
                            color: Colors.white,
                            fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
            ),
          Positioned(
            left: 16,
            bottom: 16,
            child: _buildTrackControl(),
          ),
        ],
      ),
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          FloatingActionButton(
            heroTag: 'event_fab',
            onPressed: _showEventBottomSheet,
            backgroundColor: const Color(0xFFE64A19),
            tooltip: 'Добавить событие',
            child: const Icon(Icons.add_alert, color: Colors.white),
          ),
          const SizedBox(height: 16),
          FloatingActionButton(
            heroTag: 'location_fab',
            onPressed: _locating ? null : _centerOnMe,
            tooltip: 'Найти меня',
            child: _locating
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.gps_fixed),
          ),
        ],
      ),
    );
  }
}

class _CompassNeedlePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final tipOffset = size.height * 0.42;
    final halfWidth = size.width * 0.17;

    final northPath = Path()
      ..moveTo(cx, cy - tipOffset)
      ..lineTo(cx + halfWidth, cy)
      ..lineTo(cx - halfWidth, cy)
      ..close();

    final southPath = Path()
      ..moveTo(cx, cy + tipOffset)
      ..lineTo(cx + halfWidth, cy)
      ..lineTo(cx - halfWidth, cy)
      ..close();

    final northPaint = Paint()
      ..color = const Color(0xFFE53935)
      ..style = PaintingStyle.fill;

    final southPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;

    final borderPaint = Paint()
      ..color = Colors.black54
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8;

    canvas.drawPath(northPath, northPaint);
    canvas.drawPath(southPath, southPaint);
    canvas.drawPath(northPath, borderPaint);
    canvas.drawPath(southPath, borderPaint);

    canvas.drawCircle(
      Offset(cx, cy),
      3.0,
      Paint()..color = const Color(0xFF263238),
    );
    canvas.drawCircle(
      Offset(cx, cy),
      3.0,
      Paint()
        ..color = Colors.white70
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
