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

class _MapScreenState extends State<MapScreen> {
  MaplibreMapController? _mapCtrl;
  LatLng? _myPos;
  Circle? _myCircle;
  StreamSubscription<Position>? _posSub;
  bool _locating = false;
  bool _firstFix = true;

  static const String _onlineStyle = '''
{
  "version": 8,
  "name": "OSM",
  "sources": {
    "osm": {
      "type": "raster",
      "tiles": ["https://tile.openstreetmap.org/{z}/{x}/{y}.png"],
      "tileSize": 256,
      "attribution": "© OpenStreetMap contributors"
    }
  },
  "layers": [
    { "id": "osm", "type": "raster", "source": "osm" }
  ]
}
''';

  @override
  void initState() {
    super.initState();
    _startLocation();
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
    await _updateCircle(ll);
    if (_firstFix && _mapCtrl != null) {
      _firstFix = false;
      await _mapCtrl!.animateCamera(CameraUpdate.newLatLngZoom(ll, 15));
    }
  }

  Future<void> _updateCircle(LatLng pos) async {
    final ctrl = _mapCtrl;
    if (ctrl == null) return;
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
    } catch (_) {}
  }

  Future<void> _onMapCreated(MaplibreMapController ctrl) async {
    _mapCtrl = ctrl;
    if (_myPos != null) {
      await _updateCircle(_myPos!);
      await ctrl.animateCamera(CameraUpdate.newLatLngZoom(_myPos!, 15));
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  void dispose() {
    _posSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('GeoHunt')),
      body: MaplibreMap(
        styleString: _onlineStyle,
        initialCameraPosition: const CameraPosition(
          target: LatLng(55.751244, 37.618423),
          zoom: 3,
        ),
        onMapCreated: _onMapCreated,
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
