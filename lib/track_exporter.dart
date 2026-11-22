import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'app_session.dart';
import 'track_recorder.dart';

class ExportEvent {
  final double lat;
  final double lon;
  final String type;
  final String hunterName;
  final String? note;
  final DateTime createdAt;

  const ExportEvent({
    required this.lat,
    required this.lon,
    required this.type,
    required this.hunterName,
    this.note,
    required this.createdAt,
  });

  factory ExportEvent.fromMap(Map<String, dynamic> row) {
    final rawDt = (row['created_at'] ?? '').toString().trim();
    final dt = DateTime.tryParse(rawDt)?.toUtc() ?? DateTime.now().toUtc();
    return ExportEvent(
      lat: (row['lat'] as num).toDouble(),
      lon: (row['lon'] as num).toDouble(),
      type: (row['type'] ?? 'spotted').toString(),
      hunterName: (row['hunter_name'] ?? 'Охотник').toString(),
      note: row['note']?.toString(),
      createdAt: dt,
    );
  }

  String get typeRu {
    switch (type) {
      case 'spotted':
        return 'Видел';
      case 'wounded':
        return 'Подранен';
      case 'harvested':
        return 'Добыт';
      default:
        return type;
    }
  }

  String get gpxSym {
    switch (type) {
      case 'spotted':
        return 'Flag, Yellow';
      case 'wounded':
        return 'Flag, Red';
      case 'harvested':
        return 'Flag, Green';
      default:
        return 'Waypoint';
    }
  }
}

class TrackExporter {
  static Future<List<ExportEvent>> fetchEventsForTrack(SavedTrack track) async {
    // RLS разрешает чтение событий только своей текущей группы
    if (track.groupId == null || track.groupId != AppSession.groupId) {
      return const [];
    }
    try {
      final fromUtc =
          track.startedAt.subtract(const Duration(minutes: 1)).toUtc().toIso8601String();
      final toUtc =
          track.endedAt.add(const Duration(minutes: 1)).toUtc().toIso8601String();

      final rows = await Supabase.instance.client
          .from('events')
          .select('lat, lon, type, hunter_name, note, created_at')
          .eq('group_id', track.groupId!)
          .gte('created_at', fromUtc)
          .lte('created_at', toUtc)
          .order('created_at', ascending: true);

      return (rows as List<dynamic>)
          .map((r) => ExportEvent.fromMap(Map<String, dynamic>.from(r as Map)))
          .toList();
    } catch (e) {
      debugPrint('Export fetchEventsForTrack skipped: $e');
      return const [];
    }
  }

  static String buildGpx(
    SavedTrack track, {
    List<ExportEvent> events = const [],
  }) {
    final sb = StringBuffer()
      ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
      ..writeln(
          '<gpx version="1.1" creator="GeoHunt" xmlns="http://www.topografix.com/GPX/1/1">')
      ..writeln('  <metadata>')
      ..writeln('    <name>${_xmlEscape(track.title)}</name>')
      ..writeln('    <author><name>${_xmlEscape(track.hunterName)}</name></author>')
      ..writeln('    <time>${track.startedAt.toUtc().toIso8601String()}</time>')
      ..writeln('  </metadata>');

    for (final ev in events) {
      _writeWpt(sb, ev);
    }

    sb
      ..writeln('  <trk>')
      ..writeln('    <name>${_xmlEscape(track.title)}</name>')
      ..writeln(
          '    <desc>${_xmlEscape('Охотник: ${track.hunterName}; Дистанция: ${TrackRecorder.formatDistance(track.distanceMeters)}; Точек: ${track.points.length}')}</desc>')
      ..writeln('    <trkseg>');

    for (final p in track.points) {
      final iso =
          DateTime.fromMillisecondsSinceEpoch(p.tsMs, isUtc: true).toIso8601String();
      sb
        ..writeln(
            '      <trkpt lat="${p.lat.toStringAsFixed(6)}" lon="${p.lon.toStringAsFixed(6)}">')
        ..writeln('        <time>$iso</time>')
        ..writeln('      </trkpt>');
    }

    sb
      ..writeln('    </trkseg>')
      ..writeln('  </trk>')
      ..writeln('</gpx>');

    return sb.toString();
  }

  static String buildEventsGpx(
    List<ExportEvent> events, {
    String? groupCode,
  }) {
    final title = groupCode != null && groupCode.isNotEmpty
        ? 'События группы $groupCode'
        : 'События охоты GeoHunt';
    final sb = StringBuffer()
      ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
      ..writeln(
          '<gpx version="1.1" creator="GeoHunt" xmlns="http://www.topografix.com/GPX/1/1">')
      ..writeln('  <metadata>')
      ..writeln('    <name>${_xmlEscape(title)}</name>')
      ..writeln('    <time>${DateTime.now().toUtc().toIso8601String()}</time>')
      ..writeln('  </metadata>');

    for (final ev in events) {
      _writeWpt(sb, ev);
    }

    sb.writeln('</gpx>');
    return sb.toString();
  }

  static void _writeWpt(StringBuffer sb, ExportEvent ev) {
    final name = '${ev.typeRu} (${ev.hunterName})';
    sb
      ..writeln(
          '  <wpt lat="${ev.lat.toStringAsFixed(6)}" lon="${ev.lon.toStringAsFixed(6)}">')
      ..writeln('    <time>${ev.createdAt.toUtc().toIso8601String()}</time>')
      ..writeln('    <name>${_xmlEscape(name)}</name>');
    if (ev.note != null && ev.note!.trim().isNotEmpty) {
      sb.writeln('    <cmt>${_xmlEscape(ev.note!.trim())}</cmt>');
      sb.writeln('    <desc>${_xmlEscape(ev.note!.trim())}</desc>');
    }
    sb
      ..writeln('    <sym>${_xmlEscape(ev.gpxSym)}</sym>')
      ..writeln('    <type>${_xmlEscape(ev.type)}</type>')
      ..writeln('  </wpt>');
  }

  static String buildCsv(
    SavedTrack track, {
    List<ExportEvent> events = const [],
  }) {
    final sb = StringBuffer('\uFEFF');
    sb.writeln(
      'record_type,timestamp_utc,timestamp_local,lat,lon,hunter_name,event_type,note,track_title,distance_m',
    );

    final distStr = track.distanceMeters.toStringAsFixed(1);
    for (final p in track.points) {
      final utc = DateTime.fromMillisecondsSinceEpoch(p.tsMs, isUtc: true);
      final local = utc.toLocal();
      sb.writeln([
        'TRACK_POINT',
        utc.toIso8601String(),
        _formatLocal(local),
        p.lat.toStringAsFixed(6),
        p.lon.toStringAsFixed(6),
        track.hunterName,
        '',
        '',
        track.title,
        distStr,
      ].map(_csvEscape).join(','));
    }

    for (final ev in events) {
      final utc = ev.createdAt.toUtc();
      sb.writeln([
        'EVENT',
        utc.toIso8601String(),
        _formatLocal(utc.toLocal()),
        ev.lat.toStringAsFixed(6),
        ev.lon.toStringAsFixed(6),
        ev.hunterName,
        ev.typeRu,
        ev.note ?? '',
        track.title,
        '',
      ].map(_csvEscape).join(','));
    }

    return sb.toString();
  }

  static String buildEventsCsv(
    List<ExportEvent> events, {
    String? groupCode,
  }) {
    final sb = StringBuffer('\uFEFF');
    sb.writeln(
      'record_type,timestamp_utc,timestamp_local,lat,lon,hunter_name,event_type,note,group_code',
    );
    for (final ev in events) {
      final utc = ev.createdAt.toUtc();
      sb.writeln([
        'EVENT',
        utc.toIso8601String(),
        _formatLocal(utc.toLocal()),
        ev.lat.toStringAsFixed(6),
        ev.lon.toStringAsFixed(6),
        ev.hunterName,
        ev.typeRu,
        ev.note ?? '',
        groupCode ?? '',
      ].map(_csvEscape).join(','));
    }
    return sb.toString();
  }

  static Future<void> showTrackExportSheet(
    BuildContext context,
    SavedTrack track,
  ) async {
    final format = await _pickFormat(context, title: 'Экспорт трека');
    if (format == null || !context.mounted) return;
    await _exportTrack(context, track, format);
  }

  static Future<void> showEventsExportSheet(
    BuildContext context, {
    required List<ExportEvent> events,
    String? groupCode,
  }) async {
    if (events.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Событий для экспорта пока нет')),
      );
      return;
    }
    final format = await _pickFormat(
      context,
      title: 'Экспорт событий (${events.length})',
    );
    if (format == null || !context.mounted) return;
    await _exportEvents(context, events: events, groupCode: groupCode, format: format);
  }

  static Future<String?> _pickFormat(
    BuildContext context, {
    required String title,
  }) {
    return showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  title,
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.bold),
                ),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.map_outlined, color: Colors.lightGreen),
              title: const Text('Экспорт в GPX'),
              subtitle: const Text('Трек и события для OsmAnd, Garmin, AlpineQuest'),
              onTap: () => Navigator.of(ctx).pop('gpx'),
            ),
            ListTile(
              leading: const Icon(Icons.table_chart_outlined, color: Colors.amber),
              title: const Text('Экспорт в CSV'),
              subtitle: const Text('Таблица координат и событий для Excel'),
              onTap: () => Navigator.of(ctx).pop('csv'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  static Future<void> _exportTrack(
    BuildContext context,
    SavedTrack track,
    String format,
  ) async {
    final origin = _shareOrigin(context);
    try {
      final events = await fetchEventsForTrack(track);
      if (track.points.isEmpty && events.isEmpty) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('В треке нет точек для экспорта')),
          );
        }
        return;
      }

      final baseName = _safeFileName(track.title);
      final isGpx = format == 'gpx';
      final content = isGpx
          ? buildGpx(track, events: events)
          : buildCsv(track, events: events);
      final ext = isGpx ? 'gpx' : 'csv';
      final mime = isGpx ? 'application/gpx+xml' : 'text/csv';

      await _writeAndShare(
        fileName: '$baseName.$ext',
        content: content,
        mimeType: mime,
        subject: 'GeoHunt: ${track.title}',
        text:
            'Трек «${track.title}» (${TrackRecorder.formatDistance(track.distanceMeters)}, событий: ${events.length})',
        origin: origin,
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ошибка экспорта: $e')),
        );
      }
    }
  }

  static Future<void> _exportEvents(
    BuildContext context, {
    required List<ExportEvent> events,
    String? groupCode,
    required String format,
  }) async {
    final origin = _shareOrigin(context);
    try {
      final isGpx = format == 'gpx';
      final codePart = (groupCode != null && groupCode.isNotEmpty)
          ? '_$groupCode'
          : '';
      final baseName = _safeFileName('geohunt_events$codePart');
      final content = isGpx
          ? buildEventsGpx(events, groupCode: groupCode)
          : buildEventsCsv(events, groupCode: groupCode);
      final ext = isGpx ? 'gpx' : 'csv';
      final mime = isGpx ? 'application/gpx+xml' : 'text/csv';

      await _writeAndShare(
        fileName: '$baseName.$ext',
        content: content,
        mimeType: mime,
        subject: 'GeoHunt: События группы ${groupCode ?? ""}'.trim(),
        text: 'События охоты GeoHunt (${events.length} шт.)',
        origin: origin,
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ошибка экспорта: $e')),
        );
      }
    }
  }

  static Future<void> _writeAndShare({
    required String fileName,
    required String content,
    required String mimeType,
    required String subject,
    required String text,
    Rect? origin,
  }) async {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/$fileName');
    await file.writeAsString(content, encoding: utf8);

    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(file.path, mimeType: mimeType)],
        subject: subject,
        text: text,
        sharePositionOrigin: origin,
      ),
    );
  }

  static Rect? _shareOrigin(BuildContext context) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || box.size.isEmpty) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  static String _xmlEscape(String input) {
    return input
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&apos;');
  }

  static String _csvEscape(String input) {
    final needsQuotes = input.contains(',') ||
        input.contains('"') ||
        input.contains('\n') ||
        input.contains('\r');
    if (!needsQuotes) return input;
    return '"${input.replaceAll('"', '""')}"';
  }

  static String _formatLocal(DateTime l) {
    final d = l.day.toString().padLeft(2, '0');
    final m = l.month.toString().padLeft(2, '0');
    final hh = l.hour.toString().padLeft(2, '0');
    final mm = l.minute.toString().padLeft(2, '0');
    final ss = l.second.toString().padLeft(2, '0');
    return '${l.year}-$m-$d $hh:$mm:$ss';
  }

  static String _safeFileName(String raw) {
    final cleaned = raw
        .trim()
        .replaceAll(RegExp(r'[\\/:*?"<>|\r\n]+'), '_')
        .replaceAll(RegExp(r'\s+'), '_')
        .replaceAll(RegExp(r'_+'), '_');
    if (cleaned.isEmpty) return 'geohunt_export';
    return cleaned.length > 60 ? cleaned.substring(0, 60) : cleaned;
  }
}
