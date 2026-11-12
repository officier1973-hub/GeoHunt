import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:maplibre/maplibre.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:flutter_compass/flutter_compass.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
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

  // ✅ Порог «свежести»: после 1 часа точка становится серой
  static const _staleThreshold = Duration(hours: 1);

  // ✅ Heartbeat: обновляем updated_at раз в 15 минут
  static const _heartbeatInterval = Duration(minutes: 15);

  Timer? _heartbeatTimer;
  Timer? _freshnessTimer;

  static const double _labelsMinZoom = 12;

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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startLocation();
    _startCompass();
    _subscribeToGroupHunters();
    _startHeartbeat();
    _startFreshnessTimer();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _posSub?.cancel();
    _compassSub?.cancel();
    _huntersSub?.cancel();
    _heartbeatTimer?.cancel();
    _freshnessTimer?.cancel();
    super.dispose();
  }

  // ---------------------------------------------------------------
  // ✅ Heartbeat: обновляем updated_at каждые 15 минут,
  //    даже если охотник стоит на месте (нет GPS-событий).
  // ---------------------------------------------------------------
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

  // ---------------------------------------------------------------
  // ✅ Раз в минуту пересчитываем «свежесть» маркеров других
  //    (realtime не сработает, если чужая строка не меняется).
  // ---------------------------------------------------------------
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
    }, onError: (e) {
      debugPrint('Ошибка подписки на охотников: $e');
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _rememberCamera();
      if (mounted) setState(() {});
    }
  }

  void _rememberCamera() {
    final cam = _mapCtrl?.camera;
    if (cam != null) {
      _lastCenter = cam.center;
      _lastZoom = cam.zoom;
    }
  }

  void _onCameraMoveEnd(MapEventCameraMoveEnd event) {
    _rememberCamera();
  }

  void _cycleStyle() {
    _rememberCamera();
    setState(() {
      _currentStyleIndex = (_currentStyleIndex + 1) % _styleNames.length;
    });
  }

  Future<void> _logout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Выйти из группы?'),
        content: const Text(
            'Вы покинете группу на этом устройстве. Чтобы вернуться, снова введите код.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Выйти'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final hunterId = AppSession.hunterId;
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

    await AppSession.clear();
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
      CameraUpdate.position(center: pos, zoom: 15),
      animation: CameraAnimation.fly(
        duration: const Duration(milliseconds: 500),
      ),
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
      locationSettings: const geo.LocationSettings(
        accuracy: geo.LocationAccuracy.high,
        distanceFilter: 5,
      ),
    ).listen(_onPosition);
    try {
      final cur = await geo.Geolocator.getCurrentPosition(
        locationSettings: const geo.LocationSettings(
          accuracy: geo.LocationAccuracy.high,
        ),
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
        animation: CameraAnimation.fly(
          duration: const Duration(milliseconds: 500),
        ),
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
        animation: CameraAnimation.fly(
          duration: const Duration(milliseconds: 500),
        ),
      );
      _lastCenter = newPos;
      _lastZoom = 15;
    }
  }

  Future<void> _updateMyPositionInDb(Geographic pos) async {
    final hunterId = AppSession.hunterId;
    if (hunterId == null) return;

    final now = DateTime.now();
    if (_lastDbUpdate != null &&
        now.difference(_lastDbUpdate!) < _dbUpdateInterval) {
      return;
    }
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

  void _onMapCreated(MapController ctrl) {
    _mapCtrl = ctrl;
  }

  Future<void> _onStyleLoaded(StyleController style) async {
    _styleCtrl = style;

    _userLayerReady = false;
    _userUpdateInProgress = false;
    _userUpdatePending = false;
    _lastBearingUpdate = null;

    try {
      final bytes = await rootBundle.load('assets/icons/arrow.png');
      await style.addImage('user_arrow', bytes.buffer.asUint8List());
    } catch (e) {
      debugPrint('Не удалось загрузить иконку стрелки: $e');
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
          attribution:
              '<a href="https://cloudless.eox.at">EOxCloudless</a> by EOX IT Services GmbH',
        );
        await style.sources.add(rasterSource);

        final rasterLayer = RasterStyleLayer(
          id: 'satellite_layer',
          sourceId: sourceId,
        );
        await style.layers.add(rasterLayer);
      } catch (e) {
        debugPrint('Ошибка добавления растрового слоя: $e');
      }
    }

    if (_currentStyleIndex == 2) {
      try {
        final roadsLayer = LineStyleLayer(
          id: 'roads_layer',
          sourceId: 'openmaptiles',
          sourceLayerId: 'streets',
          color: Expression.literal(const Color(0xFFFFFFFF)),
          width: Expression.literal(1.5),
          opacity: Expression.literal(0.8),
        );
        await style.layers.add(roadsLayer);
      } catch (e) {
        debugPrint('Ошибка добавления слоя дорог: $e');
      }

      try {
        final labelsLayer = SymbolStyleLayer(
          id: 'labels_layer',
          sourceId: 'openmaptiles',
          sourceLayerId: 'place',
          textField: Expression.literal('{name}'),
          textSize: Expression.literal(13),
          textColor: Expression.literal(const Color(0xFFFFFFFF)),
          textHaloColor: Expression.literal(const Color(0xFF000000)),
          textHaloWidth: Expression.literal(1.8),
          textFont: Expression.literal(const ['Noto Sans Regular']),
          textAllowOverlap: Expression.literal(false),
        );
        await style.layers.add(labelsLayer);
      } catch (e) {
        debugPrint('Ошибка добавления слоя подписей: $e');
      }
    }

    await _updateUserLocationLayer();
    await _updateOthersLayer();
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
        'geometry': {
          'type': 'Point',
          'coordinates': [pos.lon, pos.lat],
        },
        'properties': {'bearing': bearing},
      }));

      try {
        await style.sources.remove('user_location_source');
      } catch (_) {}

      await style.sources.add(GeoJsonSource.data(
        id: 'user_location_source',
        data: geoJsonData,
      ));

      if (!_userLayerReady) {
        await style.layers.add(SymbolStyleLayer(
          id: 'user_location_layer',
          sourceId: 'user_location_source',
          iconImage: Expression.literal('user_arrow'),
          iconSize: Expression.literal(1.0),
          iconRotate: Expression.get('bearing').asNumber(),
          iconRotationAlignment:
              Expression.literal(IconRotationAlignment.map),
          iconAllowOverlap: Expression.literal(true),
          iconIgnorePlacement: Expression.literal(true),
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

  // ---------------------------------------------------------------
  // ✅ Свежесть: цвет и подпись зависят от updated_at
  // ---------------------------------------------------------------
  Future<void> _updateOthersLayer() async {
    final style = _styleCtrl;
    if (style == null) return;

    try {
      try {
        await style.layers.remove('others_labels_layer');
      } catch (_) {}
      try {
        await style.layers.remove('others_layer');
      } catch (_) {}
      try {
        await style.sources.remove('others_source');
      } catch (_) {}

      if (_otherHunters.isEmpty) return;

      final now = DateTime.now().toUtc();

      final features = _otherHunters.map((h) {
        final name = (h['name'] ?? '').toString();
        final updatedAtRaw = h['updated_at'];
        final dt = updatedAtRaw != null
            ? DateTime.tryParse(updatedAtRaw.toString())
            : null;
        final age = dt != null ? now.difference(dt.toUtc()) : null;

        final isStale = age != null && age > _staleThreshold;

        String color =
            isStale ? '#9E9E9E' : (h['color'] ?? '#1976D2').toString();

        String label = name;
        if (age != null && age > const Duration(minutes: 5)) {
          if (age.inMinutes < 60) {
            label = '$name · ${age.inMinutes} мин';
          } else if (age.inHours < 24) {
            label = '$name · ${age.inHours} ч';
          } else {
            label = '$name · ${age.inDays} дн';
          }
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
          },
        };
      }).toList();

      final featureCollection = {
        'type': 'FeatureCollection',
        'features': features,
      };

      const sourceId = 'others_source';
      final source = GeoJsonSource.data(
        id: sourceId,
        data: GeoJsonData.text(jsonEncode(featureCollection)),
      );
      await style.sources.add(source);

      final circleLayer = CircleStyleLayer(
        id: 'others_layer',
        sourceId: sourceId,
        color: Expression.get('color').convertToColor(),
        radius: Expression.literal(9),
        strokeColor: Expression.literal(const Color(0xFFFFFFFF)),
        strokeWidth: Expression.literal(2),
      );
      await style.layers.add(circleLayer);

      final labelsLayer = SymbolStyleLayer(
        id: 'others_labels_layer',
        sourceId: sourceId,
        textField: Expression.get('label').asString(),
        textSize: Expression.literal(12),
        textColor: Expression.literal(const Color(0xFFFFFFFF)),
        textHaloColor: Expression.literal(const Color(0xFF000000)),
        textHaloWidth: Expression.literal(2),
        textFont: Expression.literal(const ['Noto Sans Regular']),
        textAllowOverlap: Expression.literal(false),
        textOffset: Expression.literal(const Offset(0, -1.2)),
        minZoom: _labelsMinZoom,
      );
      await style.layers.add(labelsLayer);
    } catch (e) {
      debugPrint('Ошибка обновления слоя других охотников: $e');
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  List<Layer<Feature<Geometry>>> _buildLayers() => [];

  @override
  Widget build(BuildContext context) {
    final center = _lastCenter ??
        _myPos ??
        const Geographic(lon: 37.618423, lat: 55.751244);
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
            Text(
              'Группа ${AppSession.groupCode ?? ""}',
              style: const TextStyle(fontSize: 13),
            ),
            Text(
              myTitle,
              style: const TextStyle(
                  fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        actions: [
          TextButton.icon(
            onPressed: _cycleStyle,
            icon: const Icon(Icons.layers, color: Colors.white),
            label: Text(
              _styleNames[_currentStyleIndex],
              style: const TextStyle(color: Colors.white),
            ),
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
        children: const [
          MapCompass(),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _locating ? null : _centerOnMe,
        child: _locating
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.gps_fixed),
      ),
    );
  }
}
