import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import '../track_exporter.dart';
import '../track_recorder.dart';

class TrackPreviewScreen extends StatefulWidget {
  final SavedTrack track;

  const TrackPreviewScreen({super.key, required this.track});

  @override
  State<TrackPreviewScreen> createState() => _TrackPreviewScreenState();
}

class _TrackPreviewScreenState extends State<TrackPreviewScreen> {
  MapLibreMapController? _mapCtrl;
  int _currentStyleIndex = 0;
  bool _isSwitchingStyle = false;

  static const String _satelliteTileUrl =
      'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}';
  static const String _baseStyleUrl =
      'https://tiles.openfreemap.org/styles/positron';
  static const List<String> _styleNames = ['Улицы', 'Спутник', 'Гибрид'];

  LatLng _initialTarget() {
    final pts = widget.track.points;
    if (pts.isEmpty) return const LatLng(55.751244, 37.618423);
    return LatLng(pts.first.lat, pts.first.lon);
  }

  Future<void> _cycleStyle() async {
    if (_isSwitchingStyle) return;
    setState(() {
      _isSwitchingStyle = true;
      _currentStyleIndex = (_currentStyleIndex + 1) % _styleNames.length;
    });
    await _renderLayers();
    await Future.delayed(const Duration(milliseconds: 400));
    if (mounted) setState(() => _isSwitchingStyle = false);
  }

  Future<void> _onStyleLoaded() async {
    await _renderLayers();
    await _fitBounds();
  }

  Future<void> _fitBounds() async {
    final ctrl = _mapCtrl;
    final pts = widget.track.points;
    if (ctrl == null || pts.isEmpty) return;

    if (pts.length == 1) {
      await ctrl.animateCamera(
        CameraUpdate.newLatLngZoom(LatLng(pts.first.lat, pts.first.lon), 15),
      );
      return;
    }

    double minLat = pts.first.lat;
    double maxLat = pts.first.lat;
    double minLon = pts.first.lon;
    double maxLon = pts.first.lon;

    for (final p in pts) {
      minLat = math.min(minLat, p.lat);
      maxLat = math.max(maxLat, p.lat);
      minLon = math.min(minLon, p.lon);
      maxLon = math.max(maxLon, p.lon);
    }

    if ((maxLat - minLat).abs() < 0.0005) {
      minLat -= 0.001;
      maxLat += 0.001;
    }
    if ((maxLon - minLon).abs() < 0.0005) {
      minLon -= 0.001;
      maxLon += 0.001;
    }

    final bounds = LatLngBounds(
      southwest: LatLng(minLat, minLon),
      northeast: LatLng(maxLat, maxLon),
    );

    await ctrl.animateCamera(
      CameraUpdate.newLatLngBounds(
        bounds,
        left: 48,
        top: 80,
        right: 48,
        bottom: 180,
      ),
    );
  }

  Future<void> _renderLayers() async {
    final ctrl = _mapCtrl;
    if (ctrl == null) return;

    try {
      try { await ctrl.removeLayer('satellite_layer'); } catch (_) {}
      try { await ctrl.removeSource('satellite_source'); } catch (_) {}
      try { await ctrl.removeLayer('waterway_layer'); } catch (_) {}
      try { await ctrl.removeLayer('roads_layer'); } catch (_) {}
      try { await ctrl.removeLayer('roads_casing_layer'); } catch (_) {}
      try { await ctrl.removeLayer('labels_layer'); } catch (_) {}
      try { await ctrl.removeLayer('preview_endpoints_layer'); } catch (_) {}
      try { await ctrl.removeLayer('preview_track_layer'); } catch (_) {}
      try { await ctrl.removeLayer('preview_track_casing_layer'); } catch (_) {}
      try { await ctrl.removeSource('preview_endpoints_source'); } catch (_) {}
      try { await ctrl.removeSource('preview_track_source'); } catch (_) {}

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

      final pts = widget.track.points;
      if (pts.isEmpty) return;

      if (pts.length >= 2) {
        final coords = pts.map((p) => [p.lon, p.lat]).toList();
        await ctrl.addGeoJsonSource('preview_track_source', {
          'type': 'Feature',
          'geometry': {
            'type': 'LineString',
            'coordinates': coords,
          },
          'properties': {},
        });

        await ctrl.addLineLayer(
          'preview_track_source',
          'preview_track_casing_layer',
          LineLayerProperties(
            lineColor: '#000000',
            lineWidth: 5.5,
            lineOpacity: 0.7,
            lineCap: 'round',
            lineJoin: 'round',
          ),
        );

        await ctrl.addLineLayer(
          'preview_track_source',
          'preview_track_layer',
          LineLayerProperties(
            lineColor: '#FFB300',
            lineWidth: 3.5,
            lineOpacity: 0.95,
            lineCap: 'round',
            lineJoin: 'round',
          ),
        );
      }

      final endpoints = <Map<String, dynamic>>[
        {
          'type': 'Feature',
          'geometry': {
            'type': 'Point',
            'coordinates': [pts.first.lon, pts.first.lat],
          },
          'properties': {'color': '#4CAF50'},
        },
        if (pts.length >= 2)
          {
            'type': 'Feature',
            'geometry': {
              'type': 'Point',
              'coordinates': [pts.last.lon, pts.last.lat],
            },
            'properties': {'color': '#F44336'},
          },
      ];

      await ctrl.addGeoJsonSource('preview_endpoints_source', {
        'type': 'FeatureCollection',
        'features': endpoints,
      });

      await ctrl.addCircleLayer(
        'preview_endpoints_source',
        'preview_endpoints_layer',
        CircleLayerProperties(
          circleColor: ['to-color', ['get', 'color']],
          circleRadius: 8.0,
          circleStrokeColor: '#FFFFFF',
          circleStrokeWidth: 2.5,
        ),
      );
    } catch (e) {
      debugPrint('TrackPreview render error: $e');
    }
  }

  String _formatDate(DateTime utc) {
    final l = utc.toLocal();
    final d = l.day.toString().padLeft(2, '0');
    final m = l.month.toString().padLeft(2, '0');
    final hh = l.hour.toString().padLeft(2, '0');
    final mm = l.minute.toString().padLeft(2, '0');
    return '$d.$m.${l.year} $hh:$mm';
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.track;
    return Scaffold(
      appBar: AppBar(
        title: Text(t.title, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            icon: const Icon(Icons.share_outlined),
            tooltip: 'Экспорт GPX / CSV',
            onPressed: () => TrackExporter.showTrackExportSheet(context, t),
          ),
          IconButton(
            icon: const Icon(Icons.fit_screen),
            tooltip: 'Показать весь трек',
            onPressed: _fitBounds,
          ),
          TextButton.icon(
            onPressed: _isSwitchingStyle ? null : _cycleStyle,
            icon: const Icon(Icons.layers, color: Colors.white, size: 18),
            label: Text(
              _styleNames[_currentStyleIndex],
              style: const TextStyle(color: Colors.white, fontSize: 13),
            ),
          ),
        ],
      ),
      body: Stack(
        children: [
          MapLibreMap(
            styleString: _baseStyleUrl,
            initialCameraPosition: CameraPosition(
              target: _initialTarget(),
              zoom: 14,
            ),
            onMapCreated: (c) => _mapCtrl = c,
            onStyleLoadedCallback: _onStyleLoaded,
            compassEnabled: true,
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 20,
            child: SafeArea(
              child: Card(
                color: Colors.black.withOpacity(0.82),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${_formatDate(t.startedAt)}  ·  ${t.hunterName}',
                        style: const TextStyle(fontSize: 12, color: Colors.white70),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          _stat('Дистанция', TrackRecorder.formatDistance(t.distanceMeters)),
                          _stat('Время', TrackRecorder.formatDuration(t.duration)),
                          _stat('Точек', '${t.pointsCount}'),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _stat(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 11, color: Colors.white54)),
        Text(value, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
      ],
    );
  }
}
