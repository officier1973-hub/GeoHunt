import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart'; // ✅ Добавлен импорт для LocationAccuracy
import '../app_settings.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  @override
  void initState() {
    super.initState();
    AppSettings.load().then((_) => setState(() {}));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Настройки')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Точность GPS',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white70),
          ),
          const SizedBox(height: 8),
          Card(
            child: Column(
              children: [
                RadioListTile<String>(
                  title: const Text('Высокая (для точного поиска)'),
                  subtitle: const Text('Быстрее садит батарею'),
                  value: 'high',
                  groupValue: AppSettings.gpsAccuracy == LocationAccuracy.high ? 'high' : (AppSettings.gpsAccuracy == LocationAccuracy.medium ? 'balanced' : 'low'),
                  onChanged: (val) {
                    AppSettings.saveAccuracy(val!);
                    setState(() {});
                  },
                ),
                RadioListTile<String>(
                  title: const Text('Средняя'),
                  value: 'balanced',
                  groupValue: AppSettings.gpsAccuracy == LocationAccuracy.high ? 'high' : (AppSettings.gpsAccuracy == LocationAccuracy.medium ? 'balanced' : 'low'),
                  onChanged: (val) {
                    AppSettings.saveAccuracy(val!);
                    setState(() {});
                  },
                ),
                RadioListTile<String>(
                  title: const Text('Низкая (экономия)'),
                  subtitle: const Text('Для долгих охот'),
                  value: 'low',
                  groupValue: AppSettings.gpsAccuracy == LocationAccuracy.high ? 'high' : (AppSettings.gpsAccuracy == LocationAccuracy.medium ? 'balanced' : 'low'),
                  onChanged: (val) {
                    AppSettings.saveAccuracy(val!);
                    setState(() {});
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          const Text(
            'Частота отправки координат',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white70),
          ),
          const SizedBox(height: 8),
          Card(
            child: Column(
              children: [
                RadioListTile<int>(
                  title: const Text('Каждые 30 секунд'),
                  value: 30,
                  groupValue: AppSettings.dbInterval.inSeconds,
                  onChanged: (val) {
                    AppSettings.saveDbInterval(val!);
                    setState(() {});
                  },
                ),
                RadioListTile<int>(
                  title: const Text('Раз в минуту'),
                  value: 60,
                  groupValue: AppSettings.dbInterval.inSeconds,
                  onChanged: (val) {
                    AppSettings.saveDbInterval(val!);
                    setState(() {});
                  },
                ),
                RadioListTile<int>(
                  title: const Text('Раз в 5 минут (экономия)'),
                  value: 300,
                  groupValue: AppSettings.dbInterval.inSeconds,
                  onChanged: (val) {
                    AppSettings.saveDbInterval(val!);
                    setState(() {});
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          const Text(
            'Дополнительно',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white70),
          ),
          const SizedBox(height: 8),
          Card(
            child: SwitchListTile(
              title: const Text('Магнитный компас'),
              subtitle: const Text('Выключите для экономии батареи'),
              value: AppSettings.compassEnabled,
              onChanged: (val) {
                AppSettings.saveCompass(val);
                setState(() {});
              },
            ),
          ),
        ],
      ),
    );
  }
}
