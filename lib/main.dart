import 'dart:async';
import 'package:flutter/material.dart';
import 'package:maplibre/maplibre.dart';
import 'package:geolocator/geolocator.dart' as geo;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const GeoHuntApp());
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
      home: const MapScreen(),
    );
  }
}

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});
  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> with WidgetsBindingObserver {
  MapController? _mapCtrl;
  StyleController? _styleCtrl;
  StreamSubscription<geo.Position>? _posSub;

  Geographic? _myPos;
  bool _locating = false;
  bool _firstFix = true;
  bool _pendingCenter = false;

  Geographic? _lastCenter;
  double? _lastZoom;

  int _currentStyleIndex = 0;

  static const String _satelliteTileUrl =
      'https://tiles.maps.eox.at/wmts/1.0.0/s2cloudless-2025_3857/default/g/{z}/{y}/{x}.jpg';
  static const String _baseStyleUrl = 'https://tiles.openfreemap.org/styles/positron';

  final List<String> _styleNames = ['Улицы', 'Спутник', 'Гибрид'];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startLocation();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _posSub?.cancel();
    super.dispose();
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
    setState(() {
      _myPos = newPos;
      _locating = false;
    });

    await _updateUserLocationLayer();

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

  void _onMapCreated(MapController ctrl) {
    _mapCtrl = ctrl;
  }

  Future<void> _onStyleLoaded(StyleController style) async {
    _styleCtrl = style;

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
      // Дороги гибрида: LineStyleLayer.color (без префикса line)
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

      // Подписи гибрида
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
  }

  Future<void> _updateUserLocationLayer() async {
    final style = _styleCtrl;
    final pos = _myPos;
    if (style == null || pos == null) return;

    try {
      try {
        await style.layers.remove('user_location_layer');
      } catch (_) {}
      try {
        await style.sources.remove('user_location_source');
      } catch (_) {}

      const sourceId = 'user_location_source';
      final geoJsonSource = GeoJsonSource.data(
        id: sourceId,
        data: {
          'type': 'Feature',
          'geometry': {
            'type': 'Point',
            'coordinates': [pos.lon, pos.lat],
          },
          'properties': <String, dynamic>{},
        },
      );
      await style.sources.add(geoJsonSource);

      // Точка пользователя: CircleStyleLayer.color (без префикса circle)
      final circleLayer = CircleStyleLayer(
        id: 'user_location_layer',
        sourceId: sourceId,
        color: Expression.literal(const Color(0xFF2E7D32)),
        radius: Expression.literal(10),
        strokeColor: Expression.literal(const Color(0xFFFFFFFF)),
        strokeWidth: Expression.literal(2),
      );
      await style.layers.add(circleLayer);
    } catch (e) {
      debugPrint('Ошибка обновления слоя пользователя: $e');
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

    return Scaffold(
      appBar: AppBar(
        title: const Text('GeoHunt'),
        actions: [
          TextButton.icon(
            onPressed: _cycleStyle,
            icon: const Icon(Icons.layers, color: Colors.white),
            label: Text(
              _styleNames[_currentStyleIndex],
              style: const TextStyle(color: Colors.white),
            ),
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
