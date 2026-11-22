import 'package:flutter/material.dart';
import '../app_session.dart';
import '../app_settings.dart';
import 'home_screen.dart';
import 'map_screen.dart';

class _OnboardingBullet {
  final IconData icon;
  final String title;
  final String text;

  const _OnboardingBullet({
    required this.icon,
    required this.title,
    required this.text,
  });
}

class _OnboardingSlide {
  final IconData heroIcon;
  final Color accentColor;
  final String title;
  final String subtitle;
  final List<_OnboardingBullet> bullets;

  const _OnboardingSlide({
    required this.heroIcon,
    required this.accentColor,
    required this.title,
    required this.subtitle,
    required this.bullets,
  });
}

class OnboardingScreen extends StatefulWidget {
  final bool isReviewMode;

  const OnboardingScreen({super.key, this.isReviewMode = false});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final PageController _pageCtrl = PageController();
  int _currentPage = 0;
  late bool _dontShowAgain;

  static const List<_OnboardingSlide> _slides = [
    _OnboardingSlide(
      heroIcon: Icons.explore,
      accentColor: Color(0xFF4CAF50),
      title: 'Координация группы',
      subtitle: 'Работайте слаженно даже без голосовой связи',
      bullets: [
        _OnboardingBullet(
          icon: Icons.qr_code_2,
          title: 'Вход по 4-значному коду',
          text:
              'Создайте новую группу и передайте код напарникам или подключитесь к уже созданной.',
        ),
        _OnboardingBullet(
          icon: Icons.badge_outlined,
          title: 'Роли и цвета участников',
          text:
              'Укажите имя и роль (Стрелок, Загонщик, Егерь) — у каждого будет своя цветная метка на карте.',
        ),
        _OnboardingBullet(
          icon: Icons.people_outline,
          title: 'Контроль активности',
          text:
              'В списке группы видно время последней связи каждого охотника. Метки старше 1 часа становятся серыми.',
        ),
      ],
    ),
    _OnboardingSlide(
      heroIcon: Icons.layers,
      accentColor: Color(0xFF29B6F6),
      title: 'Карта, слои и круги',
      subtitle: 'Быстрое ориентирование на любой местности',
      bullets: [
        _OnboardingBullet(
          icon: Icons.map_outlined,
          title: 'Три режима карты',
          text:
              'Переключайте вверху: Улицы, Спутник (детальные снимки) и Гибрид (спутник + дороги, реки и подписи).',
        ),
        _OnboardingBullet(
          icon: Icons.cloud_off,
          title: 'Офлайн-режим (кэш)',
          text:
              'Заранее пролистайте район охоты со спутником дома, затем включите «Офлайн-режим (кэш)» в меню ⋮.',
        ),
        _OnboardingBullet(
          icon: Icons.radar,
          title: 'Компас и круги дистанции',
          text:
              'При повороте карты появляется стрелка компаса (нажатие вернёт на Север). В Настройках можно задать любые радиусы кругов.',
        ),
      ],
    ),
    _OnboardingSlide(
      heroIcon: Icons.notifications_active_outlined,
      accentColor: Color(0xFFE64A19),
      title: 'События и сигнал SOS',
      subtitle: 'Мгновенные отметки и тревога для всей группы',
      bullets: [
        _OnboardingBullet(
          icon: Icons.add_alert,
          title: 'Отметки на охоте',
          text:
              'Оранжевая кнопка справа добавляет событие «Видел», «Подранен» или «Добыт» с заметкой и звуковым оповещением.',
        ),
        _OnboardingBullet(
          icon: Icons.warning_rounded,
          title: 'Экстренный сигнал SOS',
          text:
              'Кнопка ⚠ в верхней панели включает громкую сирену на телефонах всей группы и выделяет вашу точку красным.',
        ),
        _OnboardingBullet(
          icon: Icons.volume_up_outlined,
          title: 'Отмена тревоги',
          text:
              'Повторное нажатие на иконку SOS в верхней панели отключает ваш сигнал тревоги.',
        ),
      ],
    ),
    _OnboardingSlide(
      heroIcon: Icons.route,
      accentColor: Color(0xFFFFB300),
      title: 'Треки, история и экспорт',
      subtitle: 'Полная запись маршрута даже без интернета',
      bullets: [
        _OnboardingBullet(
          icon: Icons.fiber_manual_record,
          title: 'Запись трека в фоне',
          text:
              'Нажмите «Запись трека» внизу слева — маршрут пишется при выключенном экране с фильтрацией GPS-шума.',
        ),
        _OnboardingBullet(
          icon: Icons.cloud_upload_outlined,
          title: 'Офлайн-очередь',
          text:
              'Если при сохранении нет связи, трек останется на телефоне и автоматически загрузится при появлении сети.',
        ),
        _OnboardingBullet(
          icon: Icons.share_outlined,
          title: 'Экспорт в GPX и CSV',
          text:
              'В «Истории треков» и меню карты доступна выгрузка треков и событий в GPX (OsmAnd, Garmin) и CSV (Excel).',
        ),
      ],
    ),
    _OnboardingSlide(
      heroIcon: Icons.battery_saver,
      accentColor: Color(0xFF66BB6A),
      title: 'Батарея и советы перед выходом',
      subtitle: 'Чтобы телефон проработал всю охоту',
      bullets: [
        _OnboardingBullet(
          icon: Icons.tune,
          title: 'Баланс точности и заряда',
          text:
              'В Настройках можно выбрать точность GPS и частоту отправки координат в группу (30 с, 1 мин или 5 мин).',
        ),
        _OnboardingBullet(
          icon: Icons.my_location,
          title: 'Разрешения Android',
          text:
              'Для стабильного фонового трекинга разрешите геолокацию «Всегда» и отключите жёсткую экономию батареи для GeoHunt.',
        ),
        _OnboardingBullet(
          icon: Icons.check_circle_outline,
          title: 'Инструкция всегда под рукой',
          text:
              'Вы можете отключить показ этих экранов при запуске — вернуть их или перечитать можно в любое время в Настройках.',
        ),
      ],
    ),
  ];

  @override
  void initState() {
    super.initState();
    _dontShowAgain = AppSettings.skipOnboarding;
  }

  @override
  void dispose() {
    _pageCtrl.dispose();
    super.dispose();
  }

  Future<void> _finish() async {
    if (!widget.isReviewMode) {
      await AppSettings.saveSkipOnboarding(_dontShowAgain);
    }
    if (!mounted) return;
    if (widget.isReviewMode) {
      Navigator.of(context).pop();
      return;
    }
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) =>
            AppSession.hasSession ? const MapScreen() : const HomeScreen(),
      ),
    );
  }

  void _nextOrFinish() {
    if (_currentPage < _slides.length - 1) {
      _pageCtrl.nextPage(
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
      );
    } else {
      _finish();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isLast = _currentPage == _slides.length - 1;
    final finishLabel = widget.isReviewMode
        ? 'Закрыть'
        : (AppSession.hasSession ? 'Перейти на карту' : 'Начать работу');

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 12, 4),
              child: Row(
                children: [
                  Text(
                    'Инструкция · ${_currentPage + 1} / ${_slides.length}',
                    style: const TextStyle(
                      fontSize: 13,
                      color: Colors.white60,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: _finish,
                    child: Text(widget.isReviewMode ? 'Закрыть' : 'Пропустить'),
                  ),
                ],
              ),
            ),
            Expanded(
              child: PageView.builder(
                controller: _pageCtrl,
                itemCount: _slides.length,
                onPageChanged: (idx) => setState(() => _currentPage = idx),
                itemBuilder: (ctx, idx) => _buildSlide(_slides[idx]),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(_slides.length, (idx) {
                final active = idx == _currentPage;
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 220),
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  width: active ? 22 : 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: active
                        ? _slides[_currentPage].accentColor
                        : Colors.white24,
                    borderRadius: BorderRadius.circular(4),
                  ),
                );
              }),
            ),
            const SizedBox(height: 10),
            if (!widget.isReviewMode)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: CheckboxListTile(
                  value: _dontShowAgain,
                  onChanged: (val) =>
                      setState(() => _dontShowAgain = val ?? false),
                  controlAffinity: ListTileControlAffinity.leading,
                  dense: true,
                  title: const Text(
                    'Не показывать при каждом запуске',
                    style: TextStyle(fontSize: 14),
                  ),
                  subtitle: const Text(
                    'Можно снова включить в Настройках',
                    style: TextStyle(fontSize: 12, color: Colors.white54),
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 6, 20, 18),
              child: Row(
                children: [
                  if (_currentPage > 0) ...[
                    OutlinedButton(
                      onPressed: () {
                        _pageCtrl.previousPage(
                          duration: const Duration(milliseconds: 260),
                          curve: Curves.easeOutCubic,
                        );
                      },
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 18, vertical: 14),
                      ),
                      child: const Text('Назад'),
                    ),
                    const SizedBox(width: 12),
                  ],
                  Expanded(
                    child: FilledButton(
                      onPressed: _nextOrFinish,
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      child: Text(isLast ? finishLabel : 'Далее'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSlide(_OnboardingSlide slide) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
      child: Column(
        children: [
          Container(
            width: 76,
            height: 76,
            decoration: BoxDecoration(
              color: slide.accentColor.withOpacity(0.16),
              shape: BoxShape.circle,
              border: Border.all(
                color: slide.accentColor.withOpacity(0.55),
                width: 1.5,
              ),
            ),
            child: Icon(slide.heroIcon, size: 38, color: slide.accentColor),
          ),
          const SizedBox(height: 16),
          Text(
            slide.title,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 6),
          Text(
            slide.subtitle,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 14, color: Colors.white70),
          ),
          const SizedBox(height: 20),
          ...slide.bullets.map((b) {
            return Card(
              margin: const EdgeInsets.only(bottom: 10),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(b.icon, color: slide.accentColor, size: 24),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            b.title,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            b.text,
                            style: const TextStyle(
                              fontSize: 13,
                              color: Colors.white70,
                              height: 1.35,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          }),
        ],
      ),
    );
  }
}
