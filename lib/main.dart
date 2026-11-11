import 'dart:async';
import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:geolocator/geolocator.dart';

void main() => runApp(const GeoHuntApp());

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
  MapLibreMapController? _mapCtrl;
  LatLng? _myPos;
  Circle? _myCircle;
  StreamSubscription<Position>? _posSub;
  bool _locating = false;
  bool _firstFix = true;
  int _mapKey = 0;
  bool _styleLoaded = false;

  /// Последняя известная камера. Сохраняется при любом движении карты
  /// (onCameraIdle) и при переключении стиля. Используется как
  /// initialCameraPosition при пересоздании MapLibreMap.
  CameraPosition? _currentCamera;

  int _currentStyleIndex = 0;

  // 1. Чистый спутник (EOxCloudless 2025)
  static const String _satelliteStyle = '''
  {
    "version": 8,
    "name": "Satellite",
    "sources": {
      "satellite": {
        "type": "raster",
        "tiles": ["https://tiles.maps.eox.at/wmts/1.0.0/s2cloudless-2025_3857/default/g/{z}/{y}/{x}.jpg"],
        "tileSize": 256,
        "minzoom": 0,
        "maxzoom": 14,
        "attribution": "<a href=\\"https://cloudless.eox.at\\">EOxCloudless</a> by EOX IT Services GmbH (Contains modified Copernicus Sentinel data 2025)"
      }
    },
    "layers": [
      { "id": "satellite", "type": "raster", "source": "satellite" }
    ]
  }
  ''';

  // 2. Гибрид (EOxCloudless satellite + векторные подписи и дороги OpenFreeMap)
  //
  // Ключевые моменты:
  //  - "glyphs" обязателен для symbol-слоёв (текст), иначе они не рендерятся;
  //  - дублируем source-layer имена для обеих схем (Shortbread: water_polygons /
  //    streets / place_labels и OpenMapTiles: water / transportation / place),
  //    чтобы работало независимо от того, какая схема реально отдаётся.
  static const String _hybridStyle = '''
  {
    "version": 8,
    "name": "Hybrid",
    "glyphs": "https://tiles.openfreemap.org/fonts/{fontstack}/{range}.pbf",
    "sources": {
      "satellite": {
        "type": "raster",
        "tiles": ["https://tiles.maps.eox.at/wmts/1.0.0/s2cloudless-2025_3857/default/g/{z}/{y}/{x}.jpg"],
        "tileSize": 256,
        "minzoom": 0,
        "maxzoom": 14,
        "attribution": "<a href=\\"https://cloudless.eox.at\\">EOxCloudless</a> by EOX IT Services GmbH (Contains modified Copernicus Sentinel data 2025)"
      },
      "openmaptiles": {
        "type": "vector",
        "url": "https://tiles.openfreemap.org/planet"
      }
    },
    "layers": [
      { "id": "satellite", "type": "raster", "source": "satellite", "minzoom": 0, "maxzoom": 22 },

      {
        "id": "water_shortbread",
        "type": "fill",
        "source": "openmaptiles",
        "source-layer": "water_polygons",
        "paint": { "fill-color": "#5b8fc9", "fill-opacity": 0.45 }
      },
      {
        "id": "water_openmaptiles",
        "type": "fill",
        "source": "openmaptiles",
        "source-layer": "water",
        "paint": { "fill-color": "#5b8fc9", "fill-opacity": 0.45 }
      },

      {
        "id": "streets_shortbread",
        "type": "line",
        "source": "openmaptiles",
        "source-layer": "streets",
        "paint": { "line-color": "#ffffff", "line-width": 1.6, "line-opacity": 0.75 }
      },
      {
        "id": "streets_openmaptiles",
        "type": "line",
        "source": "openmaptiles",
        "source-layer": "transportation",
        "paint": { "line-color": "#ffffff", "line-width": 1.6, "line-opacity": 0.75 }
      },

      {
        "id": "place_labels_shortbread",
        "type": "symbol",
        "source": "openmaptiles",
        "source-layer": "place_labels",
        "layout": {
          "text-field": "{name}",
          "text-size": 13,
          "text-font": ["Noto Sans Regular"],
          "text-allow-overlap": false
        },
        "paint": {
          "text-color": "#ffffff",
          "text-halo-color": "#000000",
          "text-halo-width": 1.8
        }
      },
      {
        "id": "place_labels_openmaptiles",
        "type": "symbol",
        "source": "openmaptiles",
        "source-layer": "place",
        "layout": {
          "text-field": "{name}",
          "text-size": 13,
          "text-font": ["Noto Sans Regular"],
          "text-allow-overlap": false
        },
        "paint": {
          "text-color": "#ffffff",
          "text-halo-color": "#000000",
          "text-halo-width": 1.8
        }
      }
    ]
  }
  ''';

  final List<String> _styleUrls = [
    'https://tiles.openfreemap.org/styles/positron', // Улицы
    _satelliteStyle,                                  // Спутник
    _hybridStyle,                                     // Гибрид
  ];

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
    _mapCtrl?.dispose();
    _mapCtrl = null;
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Сохраняем камеру перед пересозданием, чтобы не потерять масштаб и центр
      _rememberCamera();
      _mapCtrl = null;
      _myCircle = null;
      _styleLoaded = false;
      _firstFix = true;
      if (mounted) setState(() => _mapKey++);
    }
  }

  /// Считывает текущую камеру из контроллера и сохраняет её.
  void _rememberCamera() {
    final cp = _mapCtrl?.cameraPosition;
    if (cp != null) _currentCamera = cp;
  }

  void _onCameraIdle() {
    _rememberCamera();
  }

  void _cycleStyle() {
    _rememberCamera(); // фиксируем текущий масштаб и центр до пересоздания
    setState(() {
      _currentStyleIndex = (_currentStyleIndex + 1) % _styleUrls.length;
      _mapCtrl = null;
      _myCircle = null;
      _styleLoaded = false;
      _mapKey++;
    });
  }

  Future<void> _startLocation() async {
    final ok = await _ensurePermission();
    if (!ok) {
      _toast('Нет разрешения на геолокацию');
      return;
    }
    if (mounted) setState(() => _locating = true);
    _posSub?.cancel();
    _posSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 5,
      ),
    ).listen(_onPosition);
    try {
      final cur = await Geolocator.getCurrentPosition(
        locationSettings:
            const LocationSettings(accuracy: LocationAccuracy.high),
      );
      _onPosition(cur);
    } catch (_) {}
  }

  Future<bool> _ensurePermission() async {
    if (!await Geolocator.isLocationServiceEnabled()) return false;
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    return perm == LocationPermission.whileInUse ||
        perm == LocationPermission.always;
  }

  Future<void> _onPosition(Position pos) async {
    if (!mounted) return;
    final ll = LatLng(pos.latitude, pos.longitude);
    setState(() {
      _myPos = ll;
      _locating = false;
    });
    if (_styleLoaded) {
      await _updateCircle(ll);
    }
    if (_firstFix && _mapCtrl != null) {
      _firstFix = false;
      try {
        await _mapCtrl!.animateCamera(CameraUpdate.newLatLngZoom(ll, 15));
        _currentCamera = _mapCtrl!.cameraPosition;
      } catch (_) {}
    }
  }

  Future<void> _updateCircle(LatLng pos) async {
    final ctrl = _mapCtrl;
    if (ctrl == null || !_styleLoaded) return;
    try {
      if (_myCircle == null) {
        _myCircle = await ctrl.addCircle(CircleOptions(
          geometry: pos,
          circleColor: '#2E7D32',
          circleRadius: 10,
          circleStrokeWidth: 2,
          circleStrokeColor: '#FFFFFF',
        ));
      } else {
        await ctrl.updateCircle(_myCircle!, CircleOptions(geometry: pos));
      }
    } catch (e) {
      debugPrint('Ошибка при работе с кругом: $e');
    }
  }

  Future<void> _onMapCreated(MapLibreMapController ctrl) async {
    _mapCtrl = ctrl;
    _myCircle = null;
  }

  void _onStyleLoaded() {
    _styleLoaded = true;
    if (_myPos != null) {
      _updateCircle(_myPos!);
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// Камера для initialCameraPosition: сначала последняя известная,
  /// иначе — позиция пользователя (если есть), иначе — Москва.
  CameraPosition get _initialCamera {
    final saved = _currentCamera;
    if (saved != null) return saved;
    if (_myPos != null) {
      return CameraPosition(target: _myPos!, zoom: 15);
    }
    return const CameraPosition(
      target: LatLng(55.751244, 37.618423),
      zoom: 3,
    );
  }

  @override
  Widget build(BuildContext context) {
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
        key: ValueKey(_mapKey),
        styleString: _styleUrls[_currentStyleIndex],
        initialCameraPosition: _initialCamera,
        onMapCreated: _onMapCreated,
        onStyleLoadedCallback: _onStyleLoaded,
        onCameraIdle: _onCameraIdle,
        dragEnabled: true,
        zoomGesturesEnabled: true,
        rotateGesturesEnabled: true,
        tiltGesturesEnabled: true,
        scrollGesturesEnabled: true,
        doubleClickZoomEnabled: true,
        compassEnabled: true,
        trackCameraPosition: true,
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _locating ? null : _startLocation,
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
