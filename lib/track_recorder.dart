import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'app_session.dart';

class TrackPoint {
  final double lat;
  final double lon;
  final int tsMs;

  const TrackPoint({
    required this.lat,
    required this.lon,
    required this.tsMs,
  });

  List<num> toCompactJson() => [
        double.parse(lat.toStringAsFixed(6)),
        double.parse(lon.toStringAsFixed(6)),
        tsMs ~/ 1000,
      ];

  factory TrackPoint.fromCompactJson(List<dynamic> arr) {
    final rawTs = (arr.length > 2 ? arr[2] as num : 0).toInt();
    final tsMs = rawTs < 100000000000 ? rawTs * 1000 : rawTs;
    return TrackPoint(
      lat: (arr[0] as num).toDouble(),
      lon: (arr[1] as num).toDouble(),
      tsMs: tsMs,
    );
  }
}

class ActiveTrackState {
  final bool isRecording;
  final DateTime? startedAt;
  final List<TrackPoint> points;
  final double distanceMeters;

  const ActiveTrackState({
    required this.isRecording,
    required this.startedAt,
    required this.points,
    required this.distanceMeters,
  });

  static const empty = ActiveTrackState(
    isRecording: false,
    startedAt: null,
    points: [],
    distanceMeters: 0,
  );
}

class SavedTrack {
  final String id;
  final String? groupId;
  final String hunterName;
  final String title;
  final DateTime startedAt;
  final DateTime endedAt;
  final double distanceMeters;
  final int pointsCount;
  final List<TrackPoint> points;
  final bool isPending;

  const SavedTrack({
    required this.id,
    this.groupId,
    required this.hunterName,
    required this.title,
    required this.startedAt,
    required this.endedAt,
    required this.distanceMeters,
    required this.pointsCount,
    required this.points,
    this.isPending = false,
  });

  Duration get duration {
    final diff = endedAt.difference(startedAt);
    return diff.isNegative ? Duration.zero : diff;
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'group_id': groupId,
      'hunter_name': hunterName,
      'title': title,
      'started_at': startedAt.toUtc().toIso8601String(),
      'ended_at': endedAt.toUtc().toIso8601String(),
      'distance_meters': distanceMeters,
      'points_count': pointsCount,
      'points': points.map((p) => p.toCompactJson()).toList(),
    };
  }

  factory SavedTrack.fromMap(Map<String, dynamic> map, {bool isPending = false}) {
    final rawPoints = (map['points'] as List<dynamic>?) ?? const [];
    final pts = <TrackPoint>[];
    for (final item in rawPoints) {
      if (item is List && item.length >= 2) {
        pts.add(TrackPoint.fromCompactJson(item));
      }
    }
    return SavedTrack(
      id: (map['id'] ?? '').toString(),
      groupId: map['group_id']?.toString(),
      hunterName: (map['hunter_name'] ?? 'Охотник').toString(),
      title: (map['title'] ?? 'Трек').toString(),
      startedAt: DateTime.tryParse((map['started_at'] ?? '').toString())?.toUtc() ??
          DateTime.now().toUtc(),
      endedAt: DateTime.tryParse((map['ended_at'] ?? '').toString())?.toUtc() ??
          DateTime.now().toUtc(),
      distanceMeters: (map['distance_meters'] as num?)?.toDouble() ?? 0.0,
      pointsCount: (map['points_count'] as num?)?.toInt() ?? pts.length,
      points: pts,
      isPending: isPending,
    );
  }
}

class TrackRecorder {
  static const double _maxAccuracyMeters = 35.0;
  static const double _minStepMeters = 8.0;
  static const double _simplifyEpsilonMeters = 5.0;

  static TrackPoint? _cachedLastPoint;
  static Future<void> _ioChain = Future.value();

  static Future<T> _synchronized<T>(Future<T> Function() action) {
    final next = _ioChain.then((_) => action());
    _ioChain = next.then((_) {}, onError: (_) {});
    return next;
  }

  static Future<Directory> _baseDir() => getApplicationDocumentsDirectory();

  static Future<File> _metaFile() async {
    final dir = await _baseDir();
    return File('${dir.path}/active_track_meta.json');
  }

  static Future<File> _pointsFile() async {
    final dir = await _baseDir();
    return File('${dir.path}/active_track.jsonl');
  }

  static Future<Directory> _pendingDir() async {
    final dir = await _baseDir();
    final sub = Directory('${dir.path}/pending_tracks');
    if (!await sub.exists()) {
      await sub.create(recursive: true);
    }
    return sub;
  }

  static Future<bool> isRecording() async {
    try {
      final meta = await _metaFile();
      if (!await meta.exists()) return false;
      final data = jsonDecode(await meta.readAsString()) as Map<String, dynamic>;
      return data['recording'] == true;
    } catch (_) {
      return false;
    }
  }

  static Future<ActiveTrackState> loadActiveState() async {
    return _synchronized(() async {
      final meta = await _metaFile();
      if (!await meta.exists()) {
        _cachedLastPoint = null;
        return ActiveTrackState.empty;
      }

      Map<String, dynamic> metaJson;
      try {
        metaJson = jsonDecode(await meta.readAsString()) as Map<String, dynamic>;
      } catch (_) {
        return ActiveTrackState.empty;
      }

      if (metaJson['recording'] != true) {
        _cachedLastPoint = null;
        return ActiveTrackState.empty;
      }

      final startedAt = DateTime.tryParse(
            (metaJson['started_at'] ?? '').toString(),
          )?.toUtc() ??
          DateTime.now().toUtc();

      final points = await _readActivePoints();
      _cachedLastPoint = points.isNotEmpty ? points.last : null;

      return ActiveTrackState(
        isRecording: true,
        startedAt: startedAt,
        points: points,
        distanceMeters: computeDistanceMeters(points),
      );
    });
  }

  static Future<ActiveTrackState> startNewTrack({
    double? initialLat,
    double? initialLon,
    double? initialAccuracy,
  }) async {
    return _synchronized(() async {
      final now = DateTime.now().toUtc();
      final meta = await _metaFile();
      final ptsFile = await _pointsFile();

      await meta.writeAsString(jsonEncode({
        'recording': true,
        'started_at': now.toIso8601String(),
        'group_id': AppSession.groupId,
        'hunter_name': AppSession.hunterName ?? 'Охотник',
      }));

      if (await ptsFile.exists()) {
        await ptsFile.delete();
      }
      await ptsFile.create(recursive: true);
      _cachedLastPoint = null;

      final initialPoints = <TrackPoint>[];
      if (initialLat != null &&
          initialLon != null &&
          (initialAccuracy == null ||
              initialAccuracy <= 0 ||
              initialAccuracy <= _maxAccuracyMeters)) {
        final first = TrackPoint(
          lat: initialLat,
          lon: initialLon,
          tsMs: now.millisecondsSinceEpoch,
        );
        await ptsFile.writeAsString('${jsonEncode(first.toCompactJson())}\n',
            mode: FileMode.append);
        _cachedLastPoint = first;
        initialPoints.add(first);
      }

      return ActiveTrackState(
        isRecording: true,
        startedAt: now,
        points: initialPoints,
        distanceMeters: 0.0,
      );
    });
  }

  /// Возвращает новую точку, если она прошла фильтр и была записана на диск.
  static Future<TrackPoint?> appendPoint({
    required double lat,
    required double lon,
    double? accuracy,
  }) async {
    if (accuracy != null && accuracy > 0 && accuracy > _maxAccuracyMeters) {
      return null;
    }

    return _synchronized(() async {
      final meta = await _metaFile();
      if (!await meta.exists()) return null;

      if (_cachedLastPoint == null) {
        final existing = await _readActivePoints();
        if (existing.isNotEmpty) {
          _cachedLastPoint = existing.last;
        }
      }

      final prev = _cachedLastPoint;
      if (prev != null) {
        final dist = Geolocator.distanceBetween(prev.lat, prev.lon, lat, lon);
        if (dist < _minStepMeters) {
          return null;
        }
      }

      final point = TrackPoint(
        lat: lat,
        lon: lon,
        tsMs: DateTime.now().toUtc().millisecondsSinceEpoch,
      );
      final ptsFile = await _pointsFile();
      await ptsFile.writeAsString(
        '${jsonEncode(point.toCompactJson())}\n',
        mode: FileMode.append,
      );
      _cachedLastPoint = point;
      return point;
    });
  }

  static Future<void> discardActiveTrack() async {
    await _synchronized(() async {
      _cachedLastPoint = null;
      final meta = await _metaFile();
      final pts = await _pointsFile();
      if (await meta.exists()) await meta.delete();
      if (await pts.exists()) await pts.delete();
    });
  }

  /// Завершает активный трек, сжимает точки, сохраняет локально и пытается отправить в Supabase.
  /// Возвращает `true`, если трек сразу ушёл в облако, и `false`, если сохранён в офлайн-очередь.
  static Future<bool> finishAndSaveTrack({required String title}) async {
    final prepared = await _synchronized<SavedTrack?>(() async {
      final meta = await _metaFile();
      if (!await meta.exists()) return null;

      Map<String, dynamic> metaJson;
      try {
        metaJson = jsonDecode(await meta.readAsString()) as Map<String, dynamic>;
      } catch (_) {
        return null;
      }

      final startedAt = DateTime.tryParse(
            (metaJson['started_at'] ?? '').toString(),
          )?.toUtc() ??
          DateTime.now().toUtc();
      final endedAt = DateTime.now().toUtc();

      final rawPoints = await _readActivePoints();
      final totalDist = computeDistanceMeters(rawPoints);
      final compressed = simplifyDouglasPeucker(
        rawPoints,
        epsilonMeters: _simplifyEpsilonMeters,
      );

      final trackId =
          'local_${endedAt.millisecondsSinceEpoch}_${math.Random().nextInt(9999)}';
      final saved = SavedTrack(
        id: trackId,
        groupId: metaJson['group_id']?.toString() ?? AppSession.groupId,
        hunterName: (metaJson['hunter_name'] ?? AppSession.hunterName ?? 'Охотник')
            .toString(),
        title: title.trim().isEmpty ? defaultTrackTitle(startedAt) : title.trim(),
        startedAt: startedAt,
        endedAt: endedAt,
        distanceMeters: totalDist,
        pointsCount: compressed.length,
        points: compressed,
        isPending: true,
      );

      final dir = await _pendingDir();
      final pendingFile = File('${dir.path}/$trackId.json');
      await pendingFile.writeAsString(jsonEncode(saved.toMap()));

      _cachedLastPoint = null;
      final ptsFile = await _pointsFile();
      if (await meta.exists()) await meta.delete();
      if (await ptsFile.exists()) await ptsFile.delete();

      return saved;
    });

    if (prepared == null) return false;
    final uploaded = await _uploadTrackAndRemoveLocal(prepared);
    return uploaded;
  }

  static Future<bool> _uploadTrackAndRemoveLocal(SavedTrack track) async {
    try {
      final userId = await AppSession.ensureSignedIn();
      if (userId == null) return false;

      await Supabase.instance.client.from('tracks').insert({
        'group_id': track.groupId,
        'user_id': userId,
        'hunter_name': track.hunterName,
        'title': track.title,
        'started_at': track.startedAt.toUtc().toIso8601String(),
        'ended_at': track.endedAt.toUtc().toIso8601String(),
        'distance_meters': track.distanceMeters,
        'points_count': track.pointsCount,
        'points': track.points.map((p) => p.toCompactJson()).toList(),
      });

      final dir = await _pendingDir();
      final file = File('${dir.path}/${track.id}.json');
      if (await file.exists()) {
        await file.delete();
      }
      return true;
    } catch (e) {
      debugPrint('Track upload deferred (offline): $e');
      return false;
    }
  }

  static Future<int> syncPendingTracks() async {
    final pending = await loadPendingTracks();
    int uploadedCount = 0;
    for (final t in pending) {
      final ok = await _uploadTrackAndRemoveLocal(t);
      if (ok) uploadedCount++;
    }
    return uploadedCount;
  }

  static Future<List<SavedTrack>> loadPendingTracks() async {
    final dir = await _pendingDir();
    final files = await dir.list().toList();
    final result = <SavedTrack>[];
    for (final entity in files) {
      if (entity is File && entity.path.endsWith('.json')) {
        try {
          final map =
              jsonDecode(await entity.readAsString()) as Map<String, dynamic>;
          result.add(SavedTrack.fromMap(map, isPending: true));
        } catch (e) {
          debugPrint('Broken pending track ${entity.path}: $e');
        }
      }
    }
    result.sort((a, b) => b.startedAt.compareTo(a.startedAt));
    return result;
  }

  static Future<void> deletePendingTrack(String id) async {
    final dir = await _pendingDir();
    final file = File('${dir.path}/$id.json');
    if (await file.exists()) {
      await file.delete();
    }
  }

  static Future<List<SavedTrack>> fetchRemoteTracks() async {
    final userId = await AppSession.ensureSignedIn();
    if (userId == null) return [];

    final rows = await Supabase.instance.client
        .from('tracks')
        .select(
            'id, group_id, hunter_name, title, started_at, ended_at, distance_meters, points_count, points')
        .eq('user_id', userId)
        .order('started_at', ascending: false);

    return (rows as List<dynamic>)
        .map((r) => SavedTrack.fromMap(Map<String, dynamic>.from(r as Map)))
        .toList();
  }

  static Future<void> deleteRemoteTrack(String id) async {
    await Supabase.instance.client.from('tracks').delete().eq('id', id);
  }

  static Future<List<TrackPoint>> _readActivePoints() async {
    final ptsFile = await _pointsFile();
    if (!await ptsFile.exists()) return [];

    final lines = await ptsFile.readAsLines();
    final result = <TrackPoint>[];
    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is List && decoded.length >= 2) {
          result.add(TrackPoint.fromCompactJson(decoded));
        }
      } catch (_) {
        // Игнорируем возможную оборванную последнюю строку после аварийного завершения
      }
    }
    return result;
  }

  static double computeDistanceMeters(List<TrackPoint> points) {
    if (points.length < 2) return 0.0;
    double total = 0.0;
    for (int i = 1; i < points.length; i++) {
      total += Geolocator.distanceBetween(
        points[i - 1].lat,
        points[i - 1].lon,
        points[i].lat,
        points[i].lon,
      );
    }
    return total;
  }

  static List<TrackPoint> simplifyDouglasPeucker(
    List<TrackPoint> points, {
    double epsilonMeters = 5.0,
  }) {
    if (points.length <= 2) return List<TrackPoint>.from(points);

    final keep = List<bool>.filled(points.length, false);
    keep[0] = true;
    keep[points.length - 1] = true;

    final stack = <(int, int)>[(0, points.length - 1)];

    while (stack.isNotEmpty) {
      final (start, end) = stack.removeLast();
      if (end - start <= 1) continue;

      final a = points[start];
      final b = points[end];

      double maxDist = 0.0;
      int maxIdx = start;

      for (int i = start + 1; i < end; i++) {
        final d = _perpendicularDistanceMeters(points[i], a, b);
        if (d > maxDist) {
          maxDist = d;
          maxIdx = i;
        }
      }

      if (maxDist > epsilonMeters) {
        keep[maxIdx] = true;
        stack.add((start, maxIdx));
        stack.add((maxIdx, end));
      }
    }

    final simplified = <TrackPoint>[];
    for (int i = 0; i < points.length; i++) {
      if (keep[i]) simplified.add(points[i]);
    }
    return simplified;
  }

  static double _perpendicularDistanceMeters(
    TrackPoint p,
    TrackPoint a,
    TrackPoint b,
  ) {
    const double mPerDegLat = 111320.0;
    final double mPerDegLon =
        111320.0 * math.cos(a.lat * math.pi / 180.0);

    final bx = (b.lon - a.lon) * mPerDegLon;
    final by = (b.lat - a.lat) * mPerDegLat;
    final px = (p.lon - a.lon) * mPerDegLon;
    final py = (p.lat - a.lat) * mPerDegLat;

    final lenSq = bx * bx + by * by;
    if (lenSq == 0.0) {
      return math.sqrt(px * px + py * py);
    }

    final t = ((px * bx + py * by) / lenSq).clamp(0.0, 1.0);
    final projX = t * bx;
    final projY = t * by;
    final dx = px - projX;
    final dy = py - projY;
    return math.sqrt(dx * dx + dy * dy);
  }

  static String defaultTrackTitle(DateTime utcTime) {
    final local = utcTime.toLocal();
    final d = local.day.toString().padLeft(2, '0');
    final m = local.month.toString().padLeft(2, '0');
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    return 'Охота $d.$m $hh:$mm';
  }

  static String formatDistance(double meters) {
    if (meters >= 1000) {
      return '${(meters / 1000).toStringAsFixed(2)} км';
    }
    return '${meters.round()} м';
  }

  static String formatDuration(Duration d) {
    final hours = d.inHours;
    final mins = (d.inMinutes % 60).toString().padLeft(2, '0');
    final secs = (d.inSeconds % 60).toString().padLeft(2, '0');
    if (hours > 0) {
      return '$hours:$mins:$secs';
    }
    return '$mins:$secs';
  }
}
