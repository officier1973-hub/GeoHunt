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
  StreamSubscription<geo.Position>? _posSub;

  Geographic? _myPos;
  bool _locating = false;
  bool _firstFix = true;

  Geographic? _lastCenter;
  double? _lastZoom;

  int _currentStyleIndex = 0;

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
    'https://tiles.openfreemap.org/styles/positron',
    _satelliteStyle,
    _hybridStyle,
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
      _currentStyleIndex = (_currentStyleIndex + 1) % _styleUrls.length;
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
    if (_firstFix && _mapCtrl != null) {
      _firstFix = false;
      // ✅ nativeDuration вместо duration
      await _mapCtrl?.animateCamera(
        CameraUpdate.position(center: newPos, zoom: 15),
        nativeDuration: const Duration(milliseconds: 500),
      );
      _lastCenter = newPos;
      _lastZoom = 15;
    }
  }

  void _onMapCreated(MapController ctrl) {
    _mapCtrl = ctrl;
    if (_myPos != null && _firstFix) {
      _firstFix = false;
      ctrl.animateCamera(CameraUpdate.position(center: _myPos!, zoom: 15));
      _lastCenter = _myPos;
      _lastZoom = 15;
    }
  }

  void _onStyleLoaded(StyleController style) {
    // Стиль загружен. Декларативные слои обновляются автоматически.
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  List<Layer<Feature<Geometry>>> _buildLayers() {
    final layers = <Layer<Feature<Geometry>>>[];
    if (_myPos != null) {
      layers.add(
        CircleLayer(
          points: [
            Feature(geometry: Point(_myPos!)),
          ],
          // ✅ обычные значения вместо .literal
          color: const Color(0xFF2E7D32),
          radius: 10,
          strokeColor: const Color(0xFFFFFFFF),
          strokeWidth: 2,
        ),
      );
    }
    return layers;
  }

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
        options: MapOptions(
          style: MapStyle.url(_styleUrls[_currentStyleIndex]),
          // ✅ InitialCamera.position вместо .position
          initCamera: InitialCamera.position(center: center, zoom: zoom),
        ),
        onMapCreated: _onMapCreated,
        onStyleLoaded: _onStyleLoaded,
        onCameraMoveEnd: _onCameraMoveEnd,
        layers: _buildLayers(),
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
