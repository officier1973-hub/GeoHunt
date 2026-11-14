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
import '../app_session.dart';
import 'home_screen.dart';

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});
  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> with WidgetsBindingObserver {
  MapController? _mapCtrl;
  StyleController? _styleCtrl;
  StreamSubscription<geo.Position>? _posSub;
  StreamSubscription<CompassEvent>? _compassSub;

  StreamSubscription<List<Map<String, dynamic>>>? _huntersSub;
  List<Map<String, dynamic>> _otherHunters = [];

  StreamSubscription<List<Map<String, dynamic>>>? _eventsSub;
  List<Map<String, dynamic>> _events = [];
  final Set<String> _seenEventIds = {};
  bool _initialEventsLoaded = false;

  Geographic? _myPos;
  double? _myBearing;
  double? _compassHeading;
  double? _gpsHeading;

  bool _locating = false;
  bool _firstFix = true;
  bool _pendingCenter = false;

  Geographic? _lastCenter;
  double? _lastZoom;

  int _currentStyleIndex = 0;

  DateTime? _lastDbUpdate;
  static const _dbUpdateInterval = Duration(seconds: 30);

  DateTime? _lastBearingUpdate;
  static const _bearingUpdateInterval = Duration(milliseconds: 100);

  bool _userLayerReady = false;
  bool _userUpdateInProgress = false;
  bool _userUpdatePending = false;

  static const _staleThreshold = Duration(hours: 1);
  static const _heartbeatInterval = Duration(minutes: 15);
  static const _cleanupInterval = Duration(hours: 1);

  Timer? _heartbeatTimer;
  Timer? _freshnessTimer;
  Timer? _cleanupTimer;

  static const double _labelsMinZoom = 12;

  final AudioPlayer _audioPlayer = AudioPlayer();

  static const String _satelliteTileUrl =
      'https://tiles.maps.eox.at/wmts/1.0.0/s2cloudless-2025_3857/default/g/{z}/{y}/{x}.jpg';
  static const String _baseStyleUrl =
      'https://tiles.openfreemap.org/styles/positron';

  final List<String> _styleNames = ['Улицы', 'Спутник', 'Гибрид'];

  String _roleLabel(String? role) {
    switch (role) {
      case 'shooter': return 'стрелок';
      case 'driver': return 'загонщик';
      case 'ranger': return 'егерь';
      case 'none': return '';
      default: return '';
    }
  }

  DateTime? _parseUpdatedAt(dynamic raw) {
    if (raw == null) return null;
    final s = raw.toString().trim();
    if (s.isEmpty) return null;
    final hasTz = s.endsWith('Z') ||
        RegExp(r'[+\-]\d{2}:?\d{2}$').hasMatch(s) ||
        RegExp(r'[+\-]\d{2}$').hasMatch(s.substring(s.length > 3 ? s.length - 3 : 0));
    final normalized = hasTz ? s : '${s}Z';
    final dt = DateTime.tryParse(normalized);
    return dt?.toUtc();
  }

  String _formatAge(Duration age) {
    if (age.inDays >= 1) return '${age.inDays} дн';
    if (age.inHours >= 1) {
      final m = age.inMinutes % 60;
      return m > 0 ? '${age.inHours} ч ${m} м' : '${age.inHours} ч';
    }
    if (age.inMinutes >= 1) return '${age.inMinutes} мин';
    return 'меньше минуты';
  }

  // ===============================================================
  // ✅ ГЕНЕРАЦИЯ ИКОНОК ЧЕРЕЗ CANVAS (ГАРАНТИЯ ПРОЗРАЧНОСТИ)
  // ===============================================================
  Future<Uint8List> _createMapIcon({
    required IconData icon,
    required Color backgroundColor,
  }) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    const size = 64.0;
    const radius = size / 2 - 3; // Оставляем отступ для обводки
    const center = Offset(size / 2, size / 2);

    // 1. Заливаем цветной круг
    final paintFill = Paint()..color = backgroundColor;
    canvas.drawCircle(center, radius, paintFill);

    // 2. Рисуем белую обводку (чтобы выделялось на любой карте)
    final paintBorder = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0;
    canvas.drawCircle(center, radius, paintBorder);

    // 3. Рисуем белую иконку внутри
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

    // 4. Конвертируем в PNG-байты
    final picture = recorder.endRecording();
    final image = await picture.toImage(size.toInt(), size.toInt());
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  }
  // ===============================================================

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    
    _audioPlayer.setAudioContext(AudioContext(
      android: AudioContextAndroid(
        isSpeakerphoneOn: true,
        stayAwake: true,
        contentType: AndroidContentType.sonification,
        usageType: AndroidUsageType.alarm,
        audioFocus: AndroidAudioFocus.gainTransient,
      ),
    ));

    _startLocation();
    _startCompass();
    _subscribeToGroupHunters();
    _subscribeToEvents();
    _startHeartbeat();
    _startFreshnessTimer();
    _startCleanupTimer();
    _cleanupStaleData();
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
    _cleanupTimer?.cancel();
    _audioPlayer.dispose();
    super.dispose();
  }

  void _startCleanupTimer() {
    _cleanupTimer?.cancel();
    _cleanupTimer = Timer.periodic(_cleanupInterval, (_) => _cleanupStaleData());
  }

  Future<void> _cleanupStaleData() async {
    final groupId = AppSession.groupId;
    final myId = AppSession.hunterId;
    if (groupId == null) return;

    try {
      final supabase = Supabase.instance.client;
      
      final hunterCutoff = DateTime.now().toUtc().subtract(const Duration(hours: 2)).toIso8601String();
      var hunterQuery = supabase.from('hunters').delete().eq('group_id', groupId).lt('updated_at', hunterCutoff);
      if (myId != null) hunterQuery = hunterQuery.neq('id', myId);
      await hunterQuery;

      final eventCutoff = DateTime.now().toUtc().subtract(const Duration(days: 7)).toIso8601String();
      await supabase.from('events').delete().eq('group_id', groupId).lt('created_at', eventCutoff);
    } catch (e) {
      debugPrint('Cleanup error: $e');
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
    _heartbeatTimer = Timer.periodic(_heartbeatInterval, (_) => _sendHeartbeat());
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
    if (_lastBearingUpdate != null && now.difference(_lastBearingUpdate!) < _bearingUpdateInterval) return;
    _lastBearingUpdate = now;
    _myBearing = bearing;
    _updateUserLocationLayer();
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
      final others = rows
          .where((r) => r['id'] != myId)
          .where((r) => r['lat'] != null && r['lon'] != null)
          .toList();
      if (!mounted) return;
      setState(() => _otherHunters = others);
      _updateOthersLayer();
    }, onError: (e) => debugPrint('Ошибка подписки на охотников: $e'));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _rememberCamera();
      if (mounted) {
        setState(() {});
        _updateOthersLayer();
        _updateEventsLayer();
        _sendHeartbeat();
        _cleanupStaleData();
      }
    }
  }

  void _rememberCamera() {
    final cam = _mapCtrl?.camera;
    if (cam != null) {
      _lastCenter = cam.center;
      _lastZoom = cam.zoom;
    }
  }

  void _onCameraMoveEnd(MapEventCameraMoveEnd event) => _rememberCamera();

  void _cycleStyle() {
    _rememberCamera();
    setState(() => _currentStyleIndex = (_currentStyleIndex + 1) % _styleNames.length);
  }

  Future<void> _logout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Выйти из группы?'),
        content: const Text('Вы покинете группу на этом устройстве. Чтобы вернуться, снова введите код.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Выйти')),
        ],
      ),
    );
    if (confirmed != true) return;

    final hunterId = AppSession.hunterId;
    if (hunterId != null) {
      try {
        await Supabase.instance.client.from('hunters').delete().eq('id', hunterId);
      } catch (e) {
        debugPrint('Не удалось удалить охотника при выходе: $e');
      }
    }

    await AppSession.clear();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(MaterialPageRoute(builder: (_) => const HomeScreen()), (_) => false);
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
      CameraUpdate.position(center: pos, zoom: 15),
      animation: CameraAnimation.fly(duration: const Duration(milliseconds: 500)),
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
      locationSettings: const geo.LocationSettings(accuracy: geo.LocationAccuracy.high, distanceFilter: 5),
    ).listen(_onPosition);
    try {
      final cur = await geo.Geolocator.getCurrentPosition(
        locationSettings: const geo.LocationSettings(accuracy: geo.LocationAccuracy.high),
      );
      _onPosition(cur);
    } catch (_) {}
  }

  Future<bool> _ensurePermission() async {
    if (!await geo.Geolocator.isLocationServiceEnabled()) return false;
    var perm = await geo.Geolocator.checkPermission();
    if (perm == geo.LocationPermission.denied) perm = await geo.Geolocator.requestPermission();
    return perm == geo.LocationPermission.whileInUse || perm == geo.LocationPermission.always;
  }

  Future<void> _onPosition(geo.Position pos) async {
    if (!mounted) return;
    final newPos = Geographic(lon: pos.longitude, lat: pos.latitude);
    _gpsHeading = pos.heading;

    setState(() {
      _myPos = newPos;
      _locating = false;
    });

    _applyBearing();
    await _updateMyPositionInDb(newPos);

    if (_firstFix && _mapCtrl != null) {
      _firstFix = false;
      await _mapCtrl!.animateCamera(
        CameraUpdate.position(center: newPos, zoom: 15),
        animation: CameraAnimation.fly(duration: const Duration(milliseconds: 500)),
      );
      _lastCenter = newPos;
      _lastZoom = 15;
      _pendingCenter = false;
      return;
    }

    if (_pendingCenter && _mapCtrl != null) {
      _pendingCenter = false;
      await _mapCtrl!.animateCamera(
        CameraUpdate.position(center: newPos, zoom: 15),
        animation: CameraAnimation.fly(duration: const Duration(milliseconds: 500)),
      );
      _lastCenter = newPos;
      _lastZoom = 15;
    }
  }

  Future<void> _updateMyPositionInDb(Geographic pos) async {
    final hunterId = AppSession.hunterId;
    if (hunterId == null) return;
    final now = DateTime.now();
    if (_lastDbUpdate != null && now.difference(_lastDbUpdate!) < _dbUpdateInterval) return;
    _lastDbUpdate = now;

    try {
      await Supabase.instance.client.from('hunters').update({
        'lat': pos.lat,
        'lon': pos.lon,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', hunterId);
    } catch (e) {
      debugPrint('Не удалось обновить позицию в БД: $e');
    }
  }

  void _onMapCreated(MapController ctrl) => _mapCtrl = ctrl;

  Future<void> _onStyleLoaded(StyleController style) async {
    _styleCtrl = style;
    _userLayerReady = false;
    _userUpdateInProgress = false;
    _userUpdatePending = false;
    _lastBearingUpdate = null;

    // ✅ Генерируем иконки событий программно (идеальная прозрачность)
    try {
      final arrowBytes = await rootBundle.load('assets/icons/arrow.png');
      await style.addImage('user_arrow', arrowBytes.buffer.asUint8List());

      final spottedBytes = await _createMapIcon(
        icon: Icons.remove_red_eye,
        backgroundColor: const Color(0xFFFFC107), // Янтарный
      );
      await style.addImage('event_spotted', spottedBytes);

      final woundedBytes = await _createMapIcon(
        icon: Icons.water_drop,
        backgroundColor: const Color(0xFFE64A19), // Оранжево-красный
      );
      await style.addImage('event_wounded', woundedBytes);

      final harvestedBytes = await _createMapIcon(
        icon: Icons.track_changes, // Мишень
        backgroundColor: const Color(0xFF388E3C), // Зеленый
      );
      await style.addImage('event_harvested', harvestedBytes);
    } catch (e) {
      debugPrint('Не удалось загрузить/сгенерировать иконки: $e');
    }

    if (_currentStyleIndex > 0) {
      try {
        const sourceId = 'satellite_source';
        final rasterSource = RasterSource.tiles(
          id: sourceId,
          tiles: [_satelliteTileUrl],
          tileSize: 256,
          minZoom: 0,
          maxZoom: 14,
          attribution: '<a href="https://cloudless.eox.at">EOxCloudless</a> by EOX IT Services GmbH',
        );
        await style.sources.add(rasterSource);
        await style.layers.add(RasterStyleLayer(id: 'satellite_layer', sourceId: sourceId));
      } catch (e) {
        debugPrint('Ошибка добавления растрового слоя: $e');
      }
    }

    if (_currentStyleIndex == 2) {
      try {
        await style.layers.add(LineStyleLayer(
          id: 'roads_layer', sourceId: 'openmaptiles', sourceLayerId: 'streets',
          color: Expression.literal(const Color(0xFFFFFFFF)), width: Expression.literal(1.5), opacity: Expression.literal(0.8),
        ));
      } catch (e) { debugPrint('Ошибка добавления слоя дорог: $e'); }

      try {
        await style.layers.add(SymbolStyleLayer(
          id: 'labels_layer', sourceId: 'openmaptiles', sourceLayerId: 'place',
          textField: Expression.literal('{name}'), textSize: Expression.literal(13),
          textColor: Expression.literal(const Color(0xFFFFFFFF)), textHaloColor: Expression.literal(const Color(0xFF000000)),
          textHaloWidth: Expression.literal(1.8), textFont: Expression.literal(const ['Noto Sans Regular']),
          textAllowOverlap: Expression.literal(false),
        ));
      } catch (e) { debugPrint('Ошибка добавления слоя подписей: $e'); }
    }

    try { await style.layers.remove('user_location_layer'); } catch (_) {}
    _userLayerReady = false; 
    await _updateUserLocationLayer();
    await _updateOthersLayer();
    await _updateEventsLayer();
  }

  Future<void> _updateUserLocationLayer() async {
    final style = _styleCtrl;
    final pos = _myPos;
    if (style == null || pos == null) return;
    if (_userUpdateInProgress) {
      _userUpdatePending = true;
      return;
    }
    _userUpdateInProgress = true;

    try {
      final bearing = _myBearing ?? 0.0;
      final geoJsonData = GeoJsonData.text(jsonEncode({
        'type': 'Feature',
        'geometry': {'type': 'Point', 'coordinates': [pos.lon, pos.lat]},
        'properties': {'bearing': bearing},
      }));

      try { await style.sources.remove('user_location_source'); } catch (_) {}
      await style.sources.add(GeoJsonSource.data(id: 'user_location_source', data: geoJsonData));

      if (!_userLayerReady) {
        await style.layers.add(SymbolStyleLayer(
          id: 'user_location_layer', sourceId: 'user_location_source',
          iconImage: Expression.literal('user_arrow'), iconSize: Expression.literal(1.0),
          iconRotate: Expression.get('bearing').asNumber(), iconRotationAlignment: Expression.literal(IconRotationAlignment.map),
          iconAllowOverlap: Expression.literal(true), iconIgnorePlacement: Expression.literal(true),
        ));
        _userLayerReady = true;
      }
    } catch (e) {
      debugPrint('Ошибка обновления слоя пользователя: $e');
    } finally {
      _userUpdateInProgress = false;
      if (_userUpdatePending) {
        _userUpdatePending = false;
        _updateUserLocationLayer();
      }
    }
  }

  Future<void> _updateOthersLayer() async {
    final style = _styleCtrl;
    if (style == null) return;

    try {
      try { await style.layers.remove('others_labels_layer'); } catch (_) {}
      try { await style.layers.remove('others_layer'); } catch (_) {}
      try { await style.sources.remove('others_source'); } catch (_) {}

      if (_otherHunters.isEmpty) return;
      final now = DateTime.now().toUtc();

      final features = _otherHunters.map((h) {
        final name = (h['name'] ?? '').toString();
        final dt = _parseUpdatedAt(h['updated_at']);
        final age = dt != null ? now.difference(dt) : null;
        final isStale = age != null && age > _staleThreshold;
        String color = isStale ? '#9E9E9E' : (h['color'] ?? '#1976D2').toString();
        String label = name;
        if (age != null && age > const Duration(minutes: 5)) {
          label = '$name · ${_formatAge(age)}';
        }

        return {
          'type': 'Feature',
          'geometry': {'type': 'Point', 'coordinates': [h['lon'], h['lat']]},
          'properties': {'name': name, 'color': color, 'label': label},
        };
      }).toList();

      final featureCollection = {'type': 'FeatureCollection', 'features': features};
      await style.sources.add(GeoJsonSource.data(id: 'others_source', data: GeoJsonData.text(jsonEncode(featureCollection))));

      await style.layers.add(CircleStyleLayer(
        id: 'others_layer', sourceId: 'others_source',
        color: Expression.get('color').convertToColor(), radius: Expression.literal(9),
        strokeColor: Expression.literal(const Color(0xFFFFFFFF)), strokeWidth: Expression.literal(2),
      ));

      await style.layers.add(SymbolStyleLayer(
        id: 'others_labels_layer', sourceId: 'others_source',
        textField: Expression.get('label').asString(), textSize: Expression.literal(12),
        textColor: Expression.literal(const Color(0xFFFFFFFF)), textHaloColor: Expression.literal(const Color(0xFF000000)),
        textHaloWidth: Expression.literal(2), textFont: Expression.literal(const ['Noto Sans Regular']),
        textAllowOverlap: Expression.literal(false), textOffset: Expression.literal(const Offset(0, -1.2)),
        minZoom: _labelsMinZoom,
      ));
    } catch (e) {
      debugPrint('Ошибка обновления слоя других охотников: $e');
    }
  }

  Future<void> _updateEventsLayer() async {
    final style = _styleCtrl;
    if (style == null) return;

    try {
      try { await style.layers.remove('events_labels_layer'); } catch (_) {}
      try { await style.layers.remove('events_icons_layer'); } catch (_) {}
      try { await style.sources.remove('events_source'); } catch (_) {}

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
          'geometry': {'type': 'Point', 'coordinates': [e['lon'], e['lat']]},
          'properties': {
            'icon': iconId,
            'label': label,
          },
        };
      }).toList();

      final featureCollection = {'type': 'FeatureCollection', 'features': features};
      await style.sources.add(GeoJsonSource.data(id: 'events_source', data: GeoJsonData.text(jsonEncode(featureCollection))));

      await style.layers.add(SymbolStyleLayer(
        id: 'events_icons_layer', sourceId: 'events_source',
        iconImage: Expression.get('icon').asString(),
        iconSize: Expression.literal(0.6),
        iconAllowOverlap: Expression.literal(true), 
        iconIgnorePlacement: Expression.literal(true),
      ));

      await style.layers.add(SymbolStyleLayer(
        id: 'events_labels_layer', sourceId: 'events_source',
        textField: Expression.get('label').asString(), textSize: Expression.literal(11),
        textColor: Expression.literal(const Color(0xFFFFFFFF)), textHaloColor: Expression.literal(const Color(0xFF000000)),
        textHaloWidth: Expression.literal(2), textFont: Expression.literal(const ['Noto Sans Regular']),
        textAllowOverlap: Expression.literal(false), textOffset: Expression.literal(const Offset(0, 1.5)),
        minZoom: _labelsMinZoom,
      ));

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
                left: 24, right: 24, top: 8,
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
                      _buildEventOption('spotted', 'Видел', Colors.amber, selectedType, (val) => setModalState(() => selectedType = val)),
                      const SizedBox(width: 8),
                      _buildEventOption('wounded', 'Подранен', Colors.deepOrange, selectedType, (val) => setModalState(() => selectedType = val)),
                      const SizedBox(width: 8),
                      _buildEventOption('harvested', 'Добыт', Colors.green, selectedType, (val) => setModalState(() => selectedType = val)),
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
                      Navigator.of(ctx).pop();
                      await _sendEvent(selectedType, noteCtrl.text.trim());
                    },
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildEventOption(String type, String label, MaterialColor color, String selectedType, Function(String) onSelect) {
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

    if (groupId == null || hunterId == null || hunterName == null || pos == null) return;

    try {
      await Supabase.instance.client.from('events').insert({
        'group_id': groupId,
        'hunter_id': hunterId,
        'hunter_name': hunterName,
        'type': type,
        'lat': pos.lat,
        'lon': pos.lon,
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

  List<Layer<Feature<Geometry>>> _buildLayers() => [];

  @override
  Widget build(BuildContext context) {
    final center = _lastCenter ?? _myPos ?? const Geographic(lon: 37.618423, lat: 55.751244);
    final zoom = _lastZoom ?? (_myPos != null ? 15.0 : 3.0);

    final myRole = _roleLabel(AppSession.hunterRole);
    final myTitle = myRole.isEmpty ? (AppSession.hunterName ?? '') : '${AppSession.hunterName ?? ''} · $myRole';

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Группа ${AppSession.groupCode ?? ""}', style: const TextStyle(fontSize: 13)),
            Text(myTitle, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          ],
        ),
        actions: [
          TextButton.icon(
            onPressed: _cycleStyle,
            icon: const Icon(Icons.layers, color: Colors.white),
            label: Text(_styleNames[_currentStyleIndex], style: const TextStyle(color: Colors.white)),
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Выйти из группы',
            onPressed: _logout,
          ),
        ],
      ),
      body: MapLibreMap(
        key: ValueKey(_currentStyleIndex),
        options: MapOptions(
          style: MapStyle.url(_baseStyleUrl),
          initCamera: CameraUpdate.position(center: center, zoom: zoom),
        ),
        onMapCreated: _onMapCreated,
        onStyleLoaded: _onStyleLoaded,
        onCameraMoveEnd: _onCameraMoveEnd,
        layers: _buildLayers(),
        children: const [MapCompass()],
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
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.gps_fixed),
          ),
        ],
      ),
    );
  }
}
