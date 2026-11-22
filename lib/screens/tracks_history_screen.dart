import 'package:flutter/material.dart';
import '../track_exporter.dart';
import '../track_recorder.dart';
import 'track_preview_screen.dart';

class TracksHistoryScreen extends StatefulWidget {
  const TracksHistoryScreen({super.key});

  @override
  State<TracksHistoryScreen> createState() => _TracksHistoryScreenState();
}

class _TracksHistoryScreenState extends State<TracksHistoryScreen> {
  bool _loading = true;
  String? _cloudError;
  List<SavedTrack> _pendingTracks = [];
  List<SavedTrack> _remoteTracks = [];

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  Future<void> _loadAll() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _cloudError = null;
      });
    }

    try {
      await TrackRecorder.syncPendingTracks();
    } catch (_) {}

    final pending = await TrackRecorder.loadPendingTracks();
    List<SavedTrack> remote = [];
    String? err;

    try {
      remote = await TrackRecorder.fetchRemoteTracks();
    } catch (e) {
      err = 'Не удалось загрузить облачные треки (нет сети?)';
      debugPrint('fetchRemoteTracks error: $e');
    }

    if (!mounted) return;
    setState(() {
      _pendingTracks = pending;
      _remoteTracks = remote;
      _cloudError = err;
      _loading = false;
    });
  }

  Future<void> _deleteTrack(SavedTrack track) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить трек?'),
        content: Text('Трек «${track.title}» будет удалён без возможности восстановления.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      if (track.isPending) {
        await TrackRecorder.deletePendingTrack(track.id);
      } else {
        await TrackRecorder.deleteRemoteTrack(track.id);
      }
      await _loadAll();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ошибка удаления: $e')),
      );
    }
  }

  String _formatDateTime(DateTime utc) {
    final local = utc.toLocal();
    final d = local.day.toString().padLeft(2, '0');
    final m = local.month.toString().padLeft(2, '0');
    final y = local.year;
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    return '$d.$m.$y, $hh:$mm';
  }

  @override
  Widget build(BuildContext context) {
    final allTracks = [..._pendingTracks, ..._remoteTracks];

    return Scaffold(
      appBar: AppBar(
        title: const Text('История треков'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Обновить и синхронизировать',
            onPressed: _loading ? null : _loadAll,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _loadAll,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  if (_cloudError != null)
                    Card(
                      color: Colors.orange.shade900.withOpacity(0.5),
                      margin: const EdgeInsets.only(bottom: 12),
                      child: ListTile(
                        leading: const Icon(Icons.cloud_off, color: Colors.white),
                        title: Text(_cloudError!),
                        trailing: TextButton(
                          onPressed: _loadAll,
                          child: const Text('Повторить'),
                        ),
                      ),
                    ),
                  if (allTracks.isEmpty)
                    const Padding(
                      padding: EdgeInsets.only(top: 80),
                      child: Column(
                        children: [
                          Icon(Icons.route, size: 64, color: Colors.white24),
                          SizedBox(height: 16),
                          Text(
                            'Сохранённых треков пока нет',
                            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                          ),
                          SizedBox(height: 8),
                          Text(
                            'Нажмите «Запись трека» на экране карты, чтобы записать свой маршрут.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.white60),
                          ),
                        ],
                      ),
                    )
                  else
                    ...allTracks.map((t) {
                      final distStr = TrackRecorder.formatDistance(t.distanceMeters);
                      final durStr = TrackRecorder.formatDuration(t.duration);
                      final dateStr = _formatDateTime(t.startedAt);
                      return Card(
                        margin: const EdgeInsets.only(bottom: 10),
                        child: ListTile(
                          leading: CircleAvatar(
                            backgroundColor: t.isPending
                                ? Colors.orange.shade800
                                : const Color(0xFF2E4A2C),
                            child: Icon(
                              t.isPending ? Icons.cloud_upload : Icons.route,
                              color: Colors.white,
                            ),
                          ),
                          title: Text(
                            t.title,
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const SizedBox(height: 2),
                              Text('$dateStr · $distStr · $durStr'),
                              Text(
                                t.isPending
                                    ? 'Ожидает отправки · ${t.pointsCount} тчк'
                                    : '${t.pointsCount} тчк (сжато)',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: t.isPending
                                      ? Colors.orangeAccent
                                      : Colors.white54,
                                ),
                              ),
                            ],
                          ),
                          isThreeLine: true,
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.share_outlined),
                                tooltip: 'Экспорт GPX / CSV',
                                onPressed: () =>
                                    TrackExporter.showTrackExportSheet(context, t),
                              ),
                              IconButton(
                                icon: const Icon(Icons.delete_outline,
                                    color: Colors.redAccent),
                                tooltip: 'Удалить',
                                onPressed: () => _deleteTrack(t),
                              ),
                            ],
                          ),
                          onTap: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => TrackPreviewScreen(track: t),
                              ),
                            );
                          },
                        ),
                      );
                    }),
                ],
              ),
            ),
    );
  }
}
