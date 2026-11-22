import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import '../app_settings.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  static const List<int> _presetMeters = [50, 100, 150, 200, 300, 500, 1000, 2000];

  @override
  void initState() {
    super.initState();
    AppSettings.load().then((_) {
      if (mounted) setState(() {});
    });
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _removeRing(int meters) async {
    if (AppSettings.ringDistancesMeters.length <= 1) {
      _toast('Должен остаться хотя бы один радиус');
      return;
    }
    final next = AppSettings.ringDistancesMeters.where((d) => d != meters).toList();
    await AppSettings.saveRingDistances(next);
    if (mounted) setState(() {});
  }

  Future<void> _resetRings() async {
    await AppSettings.saveRingDistances(AppSettings.defaultRingDistances);
    if (mounted) setState(() {});
    _toast('Сброшено к стандартным радиусам (100, 200, 300 м)');
  }

  Future<void> _showAddRingDialog() async {
    final ctrl = TextEditingController();
    final result = await showDialog<int>(
      context: context,
      builder: (ctx) {
        String? errorText;
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('Добавить радиус круга'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: ctrl,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    autofocus: true,
                    decoration: InputDecoration(
                      labelText: 'Расстояние в метрах',
                      hintText: 'Например: 500',
                      suffixText: 'м',
                      errorText: errorText,
                      border: const OutlineInputBorder(),
                    ),
                    onChanged: (_) {
                      if (errorText != null) {
                        setDialogState(() => errorText = null);
                      }
                    },
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Быстрый выбор:',
                    style: TextStyle(fontSize: 12, color: Colors.white60),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: _presetMeters.map((p) {
                      final alreadyExists =
                          AppSettings.ringDistancesMeters.contains(p);
                      return ActionChip(
                        label: Text(AppSettings.formatRingDistance(p)),
                        onPressed: alreadyExists
                            ? null
                            : () {
                                ctrl.text = '$p';
                                setDialogState(() => errorText = null);
                              },
                      );
                    }).toList(),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('Отмена'),
                ),
                FilledButton(
                  onPressed: () {
                    final parsed = int.tryParse(ctrl.text.trim());
                    if (parsed == null || parsed < 10 || parsed > 50000) {
                      setDialogState(() {
                        errorText = 'Введите от 10 до 50 000 м';
                      });
                      return;
                    }
                    if (AppSettings.ringDistancesMeters.contains(parsed)) {
                      setDialogState(() {
                        errorText = 'Такой радиус уже есть';
                      });
                      return;
                    }
                    Navigator.of(ctx).pop(parsed);
                  },
                  child: const Text('Добавить'),
                ),
              ],
            );
          },
        );
      },
    );
    ctrl.dispose();

    if (result != null) {
      final next = [...AppSettings.ringDistancesMeters, result];
      await AppSettings.saveRingDistances(next);
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final accValue = AppSettings.gpsAccuracy == LocationAccuracy.high
        ? 'high'
        : (AppSettings.gpsAccuracy == LocationAccuracy.medium
            ? 'balanced'
            : 'low');

    final distances = AppSettings.ringDistancesMeters;
    final ringsText = distances.map(AppSettings.formatRingDistance).join(', ');
    final isDefaultRings =
        listEquals(distances, AppSettings.defaultRingDistances);

    return Scaffold(
      appBar: AppBar(title: const Text('Настройки')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Точность GPS',
            style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: Colors.white70),
          ),
          const SizedBox(height: 8),
          Card(
            child: Column(
              children: [
                RadioListTile<String>(
                  title: const Text('Высокая (для точного поиска)'),
                  subtitle: const Text('Быстрее садит батарею'),
                  value: 'high',
                  groupValue: accValue,
                  onChanged: (val) async {
                    await AppSettings.saveAccuracy(val!);
                    if (mounted) setState(() {});
                  },
                ),
                RadioListTile<String>(
                  title: const Text('Средняя'),
                  value: 'balanced',
                  groupValue: accValue,
                  onChanged: (val) async {
                    await AppSettings.saveAccuracy(val!);
                    if (mounted) setState(() {});
                  },
                ),
                RadioListTile<String>(
                  title: const Text('Низкая (экономия)'),
                  subtitle: const Text('Для долгих охот'),
                  value: 'low',
                  groupValue: accValue,
                  onChanged: (val) async {
                    await AppSettings.saveAccuracy(val!);
                    if (mounted) setState(() {});
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          const Text(
            'Частота отправки координат',
            style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: Colors.white7
