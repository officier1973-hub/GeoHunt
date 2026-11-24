import 'package:flutter/material.dart';

class PrivacyPolicyScreen extends StatelessWidget {
  const PrivacyPolicyScreen({super.key});

  static const String _contactEmail = 'officier@mail.ru';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Политика конфиденциальности')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: const [
          Text(
            'Политика конфиденциальности приложения «Коллективная охота»',
            style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold),
          ),
          SizedBox(height: 6),
          Text(
            'Пакет: ru.geohunt.app · Обновлено: 24.11.2026',
            style: TextStyle(fontSize: 12, color: Colors.white54),
          ),
          SizedBox(height: 16),
          _PolicySection(
            title: '1. Какие данные обрабатываются',
            body:
                'Приложение не требует регистрации по телефону, почте или паспорту — используется анонимная техническая сессия.\n\n'
                '• Геолокация (в том числе в фоновом режиме во время активной группы или записи трека): используется для отображения вашей позиции напарникам, работы сигнала SOS и записи маршрута при выключенном экране.\n'
                '• Имя и роль в группе: произвольный никнейм и роль (Стрелок, Загонщик, Егерь), заданные вами добровольно.\n'
                '• События охоты и треки: координаты, тип события, необязательные заметки и записанные маршруты.\n'
                '• Локальные настройки и кэш карт хранятся на вашем устройстве.',
          ),
          _PolicySection(
            title: '2. Цели обработки данных',
            body:
                'Данные используются исключительно для координации участников группы по коду, оповещения о событиях и сигнале SOS, а также для записи, просмотра и экспорта (GPX / CSV) ваших треков.',
          ),
          _PolicySection(
            title: '3. Хранение и сторонние сервисы',
            body:
                '• Облачная синхронизация и хранение треков выполняются через Supabase по защищённому соединению HTTPS/TLS с изоляцией доступа (RLS).\n'
                '• Временные данные групп удаляются сервером автоматически: позиции неактивных участников — через 2 часа, события — через 7 дней, пустые группы — через 7 дней.\n'
                '• Картографические тайлы загружаются с серверов OpenFreeMap (© OpenStreetMap contributors) и Esri World Imagery (Tiles © Esri — Maxar, Earthstar Geographics).\n'
                '• Данные не передаются рекламным сетям и не продаются третьим лицам.',
          ),
          _PolicySection(
            title: '4. Удаление данных',
            body:
                'Вы можете в любой момент выйти из группы, удалить отдельные треки в «Истории треков» или полностью удалить все свои облачные и локальные данные кнопкой «Удалить все мои данные» в разделе «Настройки».',
          ),
          _PolicySection(
            title: '5. Контакты разработчика',
            body: 'По всем вопросам обращайтесь на электронную почту: $_contactEmail',
          ),
        ],
      ),
    );
  }
}

class _PolicySection extends StatelessWidget {
  final String title;
  final String body;

  const _PolicySection({required this.title, required this.body});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              body,
              style: const TextStyle(
                fontSize: 13.5,
                color: Colors.white70,
                height: 1.45,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
