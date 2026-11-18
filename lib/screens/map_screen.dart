import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:flutter_compass/flutter_compass.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
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
    
    FlutterBackgroundService().startService();

    _audioPlayer.setAudioContext(AudioContext(
      android: AudioContextAndroid(
        isSpeakerphoneOn: true,
        stayAwake: true,
        contentType: AndroidContentType.sonification,
        usageType: AndroidUsageType.alarm,
        audioFocus: AndroidAudioFocus.gainTransient,
      ),
    ));

    _sirenPlayer.setReleaseMode(ReleaseMode.stop);
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
      _startLocation();
      _startCompass();
    });

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
    _sirenPlayer.dispose();
    
    super.dispose();
  }

  void _showLegend() {
    final myColor = const Color(0xFF2E7D32);
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
                        leading: CircleAvatar(
                          radius: 12,
                          backgroundColor: myColor,
                          child: const Icon(Icons.my_location, size: 14, color: Colors.white),
                        ),
                        title: Text(
                          '${AppSession.hunterName ?? ""} (вы)',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        subtitle: const Text('ваша позиция'),
                      ),
                      ..._otherHunters.map((h) {
                        String hex = h['color']?.toString() ?? '#1976D2';
                        Color color = Color(int.parse('0xFF${hex.replaceAll('#', '')}'));
                        
                        final dt = _parseUpdatedAt(h['updated_at']);
                        final age = dt != null ? now.difference(dt) : null;
                        
                        return ListTile(
                          leading: CircleAvatar(
                            radius: 12,
                            backgroundColor: color,
                          ),
                          title: Text((h['name'] ?? '').toString()),
                          subtitle: Text(age != null ? _formatAge(age) : 'нет данных'),
                          trailing: h['sos'] == true 
                              ? const Icon(Icons.warning_rounded, color: Colors.red) 
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

  void _toggleOfflineMode(bool value) {
    setState(() => _isOfflineMode = value);
    if (_isOfflineMode) {
      _toast('Офлайн-режим: карта использует только кэш.');
    } else {
      _toast('Онлайн-режим карты.');
    }
  }

  Future<void> _cycleStyle() async {
    if (_isSwitchingStyle) return;
    
    setState(() => _isSwitchingStyle = true);
    _rememberCamera();

    final nextIndex = (_currentStyleIndex + 1) % _styleNames.length;
    setState(() => _currentStyleIndex = nextIndex);

    await _updateStyleLayers();

    await Future.delayed(const Duration(seconds: 1));
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
        await ctrl.addSource('satellite_source', RasterSourceProperties(
          tiles: [_satelliteTileUrl],
          tileSize: 256,
          minzoom: 0,
          maxzoom: 14,
          attribution: '<a href="https://cloudless.eox.at">EOxCloudless</a> by EOX IT Services GmbH',
        ));
        await ctrl.addRasterLayer('satellite_source', 'satellite_layer', RasterLayerProperties());
      }

      if (_currentStyleIndex == 2) {
        await ctrl.addLineLayer('openmaptiles', 'roads_layer', LineLayerProperties(
          lineColor: '#FFFFFF',
          lineWidth: 1.5,
          lineOpacity: 0.8,
        ), sourceLayer: 'streets');

        await ctrl.addSymbolLayer('openmaptiles', 'labels_layer', SymbolLayerProperties(
          textField: '{name}',
          textSize: 13,
          textColor: '#FFFFFF',
          textHaloColor: '#000000',
          textHaloWidth: 1.8,
          textFont: ['Noto Sans Regular'],
          textAllowOverlap: false,
        ), sourceLayer: 'place');
      }

      try { await ctrl.removeLayer('user_location_layer'); } catch (_) {}
      try { await ctrl.removeLayer('others_layer'); } catch (_) {}
      try { await ctrl.removeLayer('others_labels_layer'); } catch (_) {}
      try { await ctrl.removeLayer('events_icons_layer'); } catch (_) {}
      try { await ctrl.removeLayer('events_labels_layer'); } catch (_) {}
      
      _userLayerReady = false;

      await _updateUserLocationLayer();
      await _updateOthersLayer();
      await _updateEventsLayer();

    } catch (e) {
      debugPrint('Error updating style layers: $e');
    }
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
    if (!AppSettings.compassEnabled) {
      _compassHeading = null;
      return;
    }
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

  void _triggerIncomingSos(String name) async {
    try {
      await _sirenPlayer.stop();
      await _sirenPlayer.play(AssetSource('sounds/sos_siren.mp3'));

      _sirenPlayer.onPlayerComplete.first.then((_) {
        _sirenPlayer.play(AssetSource('sounds/sos_siren.mp3'));
      });
    } catch (e) {
      debugPrint('Ошибка сирены: $e');
    }

    if (!mounted) return;
    
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: const Color(0xFFB71C1C),
          title: const Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: Colors.white, size: 32),
              SizedBox(width: 8),
              Text('SOS!', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            ],
          ),
          content: Text(
            'Охотник "$name" просит о помощи!\n\nПосмотрите на карту, его точка мигает красным.',
            style: const TextStyle(color: Colors.white, fontSize: 16),
          ),
          actions: [
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.white, foregroundColor: Colors.red),
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
  }

  Future<void> _toggleMySos() async {
    final hunterId = AppSession.hunterId;
    if (hunterId == null) return;

    if (!_mySosActive) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Отправить сигнал SOS?'),
          content: const Text('Все участники группы услышат громкую сирену и увидят вашу точку красным. Используйте только в экстренной ситуации.'),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Отмена')),
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
    if (state == AppLifecycleState.resumed) {
      _rememberCamera();
      AppSettings.load().then((_) {
        _startCompass();
      });
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
    final cam = _mapCtrl?.cameraPosition;
    if (cam != null) {
      _lastCenter = cam.target;
      _lastZoom = cam.zoom;
    }
  }

  void _onCameraMoveEnd() => _rememberCamera();

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

    FlutterBackgroundService().invoke("stopTracking");

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
        locationSettings: geo.LocationSettings(accuracy: AppSettings.gpsAccuracy),
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
    final newPos = LatLng(pos.latitude, pos.longitude);
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
    if (_lastDbUpdate != null && now.difference(_lastDbUpdate!) < AppSettings.dbInterval) return;
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
    _userUpdateInProgress = false;
    _userUpdatePending = false;
    _lastBearingUpdate = null;

    try {
      final arrowBytes = await rootBundle.load('assets/icons/arrow.png');
      await ctrl.addImage('user_arrow', arrowBytes.buffer.asUint8List());

      final spottedBytes = await _createMapIcon(icon: Icons.remove_red_eye, backgroundColor: const Color(0xFFFFC107));
      await ctrl.addImage('event_spotted', spottedBytes);

      final woundedBytes = await _createMapIcon(icon: Icons.water_drop, backgroundColor: const Color(0xFFE64A19));
      await ctrl.addImage('event_wounded', woundedBytes);

      final harvestedBytes = await _createMapIcon(icon: Icons.track_changes, backgroundColor: const Color(0xFF388E3C));
      await ctrl.addImage('event_harvested', harvestedBytes);
    } catch (e) {
      debugPrint('Не удалось загрузить/сгенерировать иконки: $e');
    }

    await _updateStyleLayers();
  }

  Future<void> _updateUserLocationLayer() async {
    final ctrl = _mapCtrl;
    final pos = _myPos;
    if (ctrl == null || pos == null) return;
    if (_userUpdateInProgress) {
      _userUpdatePending = true;
      return;
    }
    _userUpdateInProgress = true;

    try {
      final bearing = _myBearing ?? 0.0;
      final geoJsonData = {
        'type': 'Feature',
        'geometry': {'type': 'Point', 'coordinates': [pos.longitude, pos.latitude]},
        'properties': {'bearing': bearing},
      };

      try { await ctrl.removeSource('user_location_source'); } catch (_) {}
      await ctrl.addGeoJsonSource('user_location_source', geoJsonData);

      if (!_userLayerReady) {
        await ctrl.addSymbolLayer('user_location_source', 'user_location_layer', SymbolLayerProperties(
          iconImage: 'user_arrow',
          iconSize: 2.5, 
          iconRotate: ['get', 'bearing'],
          iconRotationAlignment: 'map',
          iconAllowOverlap: true,
          iconIgnorePlacement: true,
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
          'geometry': {'type': 'Point', 'coordinates': [h['lon'], h['lat']]},
          'properties': {
            'name': name, 
            'color': color, 
            'label': label,
            'radius': radius,
            'strokeWidth': strokeWidth,
          },
        };
      }).toList();

      final featureCollection = {'type': 'FeatureCollection', 'features': features};
      await ctrl.addGeoJsonSource('others_source', featureCollection);

      await ctrl.addCircleLayer('others_source', 'others_layer', CircleLayerProperties(
        circleColor: ['to-color', ['get', 'color']],
        circleRadius: ['get', 'radius'],
        circleStrokeColor: '#FFFFFF',
        circleStrokeWidth: ['get', 'strokeWidth'],
      ));

      await ctrl.addSymbolLayer('others_source', 'others_labels_layer', SymbolLayerProperties(
        textField: ['get', 'label'],
        textSize: 12,
        textColor: '#FFFFFF',
        textHaloColor: '#000000',
        textHaloWidth: 2,
        textFont: ['Noto Sans Regular'],
        textAllowOverlap: false,
        textOffset: [0, -1.8],
      ), minzoom: _labelsMinZoom);
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
          'geometry': {'type': 'Point', 'coordinates': [e['lon'], e['lat']]},
          'properties': {
            'icon': iconId,
            'label': label,
          },
        };
      }).toList();

      final featureCollection = {'type': 'FeatureCollection', 'features': features};
      await ctrl.addGeoJsonSource('events_source', featureCollection);

      await ctrl.addSymbolLayer('events_source', 'events_icons_layer', SymbolLayerProperties(
        iconImage: ['get', 'icon'],
        iconSize: 1.5,
        iconAllowOverlap: true,
        iconIgnorePlacement: true,
      ));

      await ctrl.addSymbolLayer('events_source', 'events_labels_layer', SymbolLayerProperties(
        textField: ['get', 'label'],
        textSize: 11,
        textColor: '#FFFFFF',
        textHaloColor: '#000000',
        textHaloWidth: 2,
        textFont: ['Noto Sans Regular'],
        textAllowOverlap: false,
        textOffset: [0, 2.0],
      ), minzoom: _labelsMinZoom);

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

  @override
  Widget build(BuildContext context) {
    final center = _lastCenter ?? _myPos ?? const LatLng(55.751244, 37.618423);
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
          IconButton(
            icon: const Icon(Icons.people, color: Colors.white),
            tooltip: 'Список группы',
            onPressed: _showLegend,
          ),
          IconButton(
            icon: const Icon(Icons.settings, color: Colors.white),
            tooltip: 'Настройки',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const SettingsScreen()),
              ).then((_) {
                _startLocation();
                _startCompass();
              });
            },
          ),
          IconButton(
            icon: Icon(
              Icons.warning_rounded,
              color: _mySosActive ? Colors.red : Colors.white,
            ),
            tooltip: _mySosActive ? 'Отменить SOS' : 'Подать сигнал SOS',
            onPressed: _toggleMySos,
          ),
          
          Transform.scale(
            scale: 0.8,
            child: Switch(
              value: _isOfflineMode,
              onChanged: _toggleOfflineMode,
              activeColor: Colors.orange,
            ),
          ),

          TextButton.icon(
            onPressed: _isSwitchingStyle ? null : _cycleStyle,
            icon: _isSwitchingStyle 
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.layers, color: Colors.white, size: 20),
            label: Text(
              _isSwitchingStyle ? '...' : _styleNames[_currentStyleIndex], 
              style: const TextStyle(color: Colors.white, fontSize: 13)
            ),
          ),
          IconButton(
            icon: const Icon(Icons.logout, size: 20),
            tooltip: 'Выйти из группы',
            onPressed: _logout,
          ),
        ],
      ),
      body: MapLibreMap(
        styleString: _baseStyleUrl,
        initialCameraPosition: CameraPosition(
          target: center,
          zoom: zoom,
        ),
        onMapCreated: _onMapCreated,
        onStyleLoadedCallback: _onStyleLoaded,
        trackCameraPosition: true,
        onCameraIdle: _onCameraMoveEnd,
        compassEnabled: true, // ✅ ВКЛЮЧАЕМ ВСТРОЕННЫЙ КОМПАС КАРТЫ
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
