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
  MaplibreMapController? _mapCtrl;
  LatLng? _myPos;
  Circle? _myCircle;
  StreamSubscription<Position>? _posSub;
  bool _locating = false;
  bool _firstFix = true;
  int _mapKey = 0;
  bool _styleLoaded = false;

  // 0: Улицы (Liberty), 1: Спутник (Sentinel-2), 2: Гибрид (OpenFreeMap Satellite)
  int _currentStyleIndex = 0;

  // --- Определения стилей ---

  // 1. Спутник (чистый) на основе растровых тайлов EOX Sentinel-2
  static const String _satelliteStyle = '''
  {
    "version": 8,
    "name": "Satellite",
    "sources": {
      "satellite": {
        "type": "raster",
        "tiles": ["https://tiles.maps.eox.at/wmts/1.0.0/s2cloudless-2020_3857/default/g/{z}/{y}/{x}.jpg"],
        "tileSize": 256,
        "attribution": "Sentinel-2 cloudless by EOX"
      }
    },
    "layers": [
      { "id": "satellite", "type": "raster", "source": "satellite" }
    ]
  }
  ''';

  // Список URL стилей для переключения
  final List<String> _styleUrls = [
    'https://tiles.openfreemap.org/styles/liberty', // Улицы
    _satelliteStyle, // Спутник (наш JSON)
    'https://tiles.openfreemap.org/styles/satellite', // Гибрид
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
      _mapCtrl = null;
      _myCircle = null;
      _styleLoaded = false;
      _firstFix = true;
      if (mounted) setState(() => _mapKey++);
    }
  }

  void _cycleStyle() {
    setState(() {
      _currentStyleIndex = (_currentStyleIndex + 1) % _styleUrls.length;
      _mapCtrl = null;
      _myCircle = null;
      _styleLoaded = false;
      _mapKey++; // Принудительное пересоздание карты с новым стилем
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

  Future<void> _onMapCreated(MaplibreMapController ctrl) async {
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('GeoHunt'),
        actions: [
          // Кнопка переключения стиля
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
      body: MaplibreMap(
        key: ValueKey(_mapKey), // Пересоздание карты при смене стиля
        styleString: _styleUrls[_currentStyleIndex],
        initialCameraPosition: CameraPosition(
          target: _myPos ?? const LatLng(55.751244, 37.618423),
          zoom: _myPos != null ? 15 : 3,
        ),
        onMapCreated: _onMapCreated,
        onStyleLoadedCallback: _onStyleLoaded,
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
