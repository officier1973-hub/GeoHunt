# 📋 ПОЛНЫЙ ТЕХНИЧЕСКИЙ АУДИТ И ПАСПОРТ ПРОЕКТА: Коллективная охота / GeoHunt (Release 8.0)

> **Инструкция для ИИ / разработчика (контекст рабочего процесса):**
> 1. **Рабочая среда владельца:** разработка ведётся на **Mac исключительно через веб-интерфейсы** (GitHub Web Editor, Supabase Dashboard, RuStore Консоль) без локальной установки Flutter / Android Studio и без локальных сборок на Mac. (Единственное установленное локальное средство — Temurin JDK 21, использовавшееся разово для генерации release `keystore`).
> 2. **Облачная сборка (CI/CD):** публичный репозиторий GitHub; вся сборка APK выполняется в облаке через GitHub Actions (`.github/workflows/build-apk.yml`, `ubuntu-24.04`, Flutter `stable` / `3.50.1`).
> 3. **Правила выдачи кода в чате:**
>    * **Не предлагайте** локальные команды `flutter run`, `flutter build`, `flutter doctor` и т.п.
>    * Для **новых и компактных/средних файлов** выдавайте **полный готовый код файла** (чтобы вставить целиком в браузере).
>    * Для **точечных правок в больших файлах** (`lib/screens/map_screen.dart`) указывайте **номера строк + текстовый якорь для поиска (`Cmd + F`) + блоки «Что удалить» / «Что вставить»**. *(Внимание: в копии `map_screen.dart` на GitHub из-за вставок через браузер могут быть лишние пустые строки, поэтому фактические номера строк могут быть ~в 1.9 раза больше эталонных).*
>    * В `build-apk.yml` включён `concurrency: cancel-in-progress: true`, поэтому при последовательных коммитах нескольких файлов через веб-интерфейс промежуточные запуски Actions отменяются — это норма; собирается самый последний коммит.

---

## 1. 🎯 О проекте и публикации в RuStore

### 1.1. Паспорт приложения для RuStore
* **Отображаемое название (витрина RuStore и `android:label`):** `Коллективная охота` *(на русском языке — требование ФЗ-168 с 01.03.2026 и п. 6.4 правил модерации RuStore при отсутствии зарегистрированного товарного знака; название в APK и в Консоли должно совпадать 1-в-1)*.
* **Техническое название проекта / репозитория:** `GeoHunt` (`name: hunt_together` в `pubspec.yaml`).
* **Идентификатор пакета (`applicationId` / `namespace`):** `ru.geohunt.app` *(перенесён с шаблонного `com.example.hunt_together`; `MainActivity.kt` перенесён в `android/app/src/main/kotlin/ru/geohunt/app/MainActivity.kt`)*.
* **Версия релиза:** `1.0.0+1` (`versionName: 1.0.0`, `versionCode: 1` в `pubspec.yaml`).
* **Тип аккаунта RuStore Консоли:** Физическое лицо (вход через VK ID, `https://console.rustore.ru`), бесплатное приложение без встроенных платежей (IAP).
* **Релизная подпись (`keystore`):**
  * Сгенерирована локально на Mac (`geohunt-release.jks`, алгоритм `RSA 2048`, alias `geohunt`, срок `10000` дней).
  * **НЕ хранится в публичном репозитории!** Хранится у владельца локально + закодирована в Base64 в **GitHub Secrets**:
    * `KEYSTORE_BASE64`
    * `KEYSTORE_PASSWORD`
    * `KEY_ALIAS` (`geohunt`)
    * `KEY_PASSWORD`
  * В `build-apk.yml` ключ декодируется в `${{ runner.temp }}/release-keystore.jks` и подписывает `GeoHunt-release.apk` (с проверкой подписи в логе через `keytool -printcert`).
* **Требования модерации RuStore (реализовано в коде и документации):**
  * **Политика конфиденциальности на русском языке:**
    * Веб-версия для ссылки в карточке RuStore: `docs/privacy-policy.html` (публикуется через GitHub Pages: `Settings → Pages → main / /docs`).
    * Встроенный экран внутри приложения: `lib/screens/privacy_policy_screen.dart` (доступен из Настроек).
  * **Удаление данных пользователя:** в `SettingsScreen` реализована кнопка **«Удалить все мои данные»** (удаляет облачные записи пользователя в `tracks` и `hunters` при наличии интернета, сбрасывает активный/отложенные треки, останавливает фоновый сервис, очищает `AppSession` и возвращает на `HomeScreen`).
  * **Атрибуция источников карт:** диалог «О приложении и источники карт» в `SettingsScreen` (OpenFreeMap / © OpenStreetMap contributors + Esri World Imagery / Maxar, Earthstar Geographics).
  * **Параметры карточки RuStore:**
    * Категория: `Спорт` или `Карты и навигация` / `Путешествия`.
    * Возрастной рейтинг: **`16+`** *(рекомендуется для охотничьей тематики с терминами «стрелок / подранен / добыт», чтобы избежать отказа по строгому правилу `0+` «без упоминания насилия»)*.
    * Иконка: `icon_master.png` (512×512).
    * Артефакт сборки: `GeoHunt-release.apk` (из `GitHub Actions → Artifacts`).

### 1.2. Реализованные возможности приложения
* **Стартовая инструкция (`OnboardingScreen`):**
  * 5 интерактивных слайдов со всеми возможностями (группы/роли, карта/слои/кэш/круги, события/SOS, треки/экспорт GPX и CSV, батарея и разрешения).
  * Чекбокс «Не показывать при каждом запуске» (`setting_skip_onboarding`).
  * В Настройках: тумблер «Показывать инструкцию при запуске» и пункт «Открыть инструкцию».
* **Группы по коду:** создание группы с 4-значным кодом, поиск через RPC `get_group_by_code`, уникальное имя в группе, роль (`Стрелок`, `Загонщик`, `Егерь`, `Нет`) с цветовой индикацией.
* **Карта в реальном времени (`MapLibre GL ^0.28.0`):**
  * **3 слоя:**
    * **Улицы:** OpenFreeMap Positron (`https://tiles.openfreemap.org/styles/positron`).
    * **Спутник:** Esri World Imagery / Maxar (детальные снимки, `maxzoom: 17`, `{z}/{y}/{x}`).
    * **Гибрид:** Esri World Imagery + векторные водотоки (`waterway`), дороги с тёмным контуром (`roads_casing` + `roads`) и контрастные подписи (`place`).
  * **Офлайн-кэш (`setOffline`)** + бейдж на экране.
  * Вращающийся по компасу/GPS маркер пользователя (плавное обновление через `setGeoJsonSource`).
  * Геодезические **круги расстояния** (по умолчанию `100 / 200 / 300 м`, настраиваются в UI) и **умный компас** (возврат на Север при повороте `> 0.5°`).
* **Меню карты (`⋮` в `AppBar` `MapScreen`, актуальный порядок):**
  1. `История треков` (`Icons.history`)
  2. `Экспорт событий (GPX / CSV)` (`Icons.share_outlined`)
  3. `Круги (...)` (`Icons.radar` слева + чекбокс `check_box` / `check_box_outline_blank` справа)
  4. `Офлайн-режим (кэш)` (`Icons.cloud_off` слева + чекбокс `check_box` / `check_box_outline_blank` справа; расположен **выше** Настроек)
  5. `Настройки` (`Icons.settings`)
  6. Разделитель + `Выйти из группы` (`Icons.logout`, красный)
* **Координация, события и SOS:**
  * Живое отображение позиций напарников через Supabase Realtime + легенда группы с возрастом последней связи (метки старше 1 часа — серые).
  * События (**«Видел»**, **«Подранен»**, **«Добыт»**) с заметками, программными иконками (`Canvas`) и звуковыми оповещениями.
  * Сигнал **SOS** с зацикленной сиреной, тревожным окном и выделением маркера красным.
* **Запись треков, история и экспорт (`TrackRecorder`, `TrackExporter`):**
  * Непрерывная запись маршрута в `active_track.jsonl` (в UI и в фоне при выключенном экране независимо от интервала БД; изоляты синхронизируются через `TrackRecorder.invalidateCache()`).
  * Фильтр GPS-шума (`accuracy <= 35 м`, шаг `>= 8 м`), сжатие алгоритмом **Дугласа–Пекера** (`epsilon = 5 м`), офлайн-очередь (`pending_tracks/`).
  * Экраны **«История треков»** и **«Просмотр трека»** (линия, старт/финиш, автозум, 3 слоя карты).
  * **Экспорт в GPX 1.1 и CSV (`share_plus: ^13.3.1`):**
    * Экспорт трека (из истории или просмотра) вместе с событиями группы `<wpt>` за интервал трека (офлайн-устойчиво).
    * Экспорт текущих событий группы напрямую из меню карты.
    * CSV с UTF-8 BOM (`\uFEFF`) для Excel.
* **Настройки (`SettingsScreen`):** точность GPS (`high/balanced/low`), частота БД (`30/60/300` с), тумблер и редактор радиусов кругов (`InputChip`, ввод `10..50000 м`, пресеты `50..2000 м`, сброс), управление стартовой инструкцией, Политика конфиденциальности, «О приложении», «Удалить все мои данные».

---

## 2. 🛠 Технологический стек и зависимости
* **Язык и фреймворк:** Dart `>=3.0.0 <4.0.0`, Flutter `>=3.0.0` (CI использует `stable` / `3.50.1`).
* **Карты:** `maplibre_gl: ^0.28.0`.
* **Бэкенд:** Supabase (`supabase_flutter: ^2.8.0`) — PostgreSQL, Anonymous Auth, RLS, Realtime, `pg_cron`.
* **Геолокация и сенсоры:** `geolocator: ^14.0.0`, `flutter_compass: ^0.8.1`.
* **Фон и уведомления:** `flutter_background_service: ^5.0.10`, `flutter_local_notifications: ^17.2.3`.
* **Хранилище, медиа и экспорт:** `shared_preferences: ^2.3.0`, `path_provider: ^2.1.3`, `audioplayers: ^6.0.0`, `share_plus: ^13.3.1` (`SharePlus.instance.share(ShareParams(...))`).
* **CI/CD и Android:** GitHub Actions (`ubuntu-24.04`), Java 21 (Temurin), Gradle `9.3.1`, AGP `9.1.1`, Kotlin `2.4.10`, `compileSdk 36`, NDK `28.2.13676358`, `flutter_launcher_icons: ^0.14.1`.

---

## 3. 📂 Структура проекта

```text
GeoHunt/
├── .github/workflows/
│   ├── build-apk.yml                 # Release APK с декодированием keystore, проверкой подписи и кэшем Gradle
│   └── supabase-keepalive.yml        # Внешний пинг Supabase раз в 2 дня против паузы Free-тарифа
├── android/
│   ├── gradle.properties             # Параметры JVM и AndroidX
│   ├── gradle/wrapper/               # Gradle 9.3.1
│   ├── build.gradle                  # Корневой build.gradle (Maven MapLibre, Google, MavenCentral)
│   └── app/
│       ├── build.gradle              # namespace/applicationId: ru.geohunt.app, compileSdk 36, signingConfigs.release
│       └── src/main/
│           ├── AndroidManifest.xml   # android:label="Коллективная охота", разрешения, Foreground Service (location)
│           ├── kotlin/ru/geohunt/app/MainActivity.kt # package ru.geohunt.app
│           └── res/values/styles.xml # Theme.AppCompat.Light.NoActionBar (требование MapLibre)
├── assets/
│   ├── icons/arrow.png               # Зелёная стрелка пользователя
│   ├── images/home_hero.png          # Иллюстрация главного экрана
│   └── sounds/                       # sound_spotted.mp3, sound_wounded.mp3, sound_harvested.mp3, sos_siren.mp3
├── docs/
│   ├── AUDIT.md                      # Настоящий документ технического аудита и паспорта
│   └── privacy-policy.html           # Публичная Политика конфиденциальности (для GitHub Pages и RuStore)
├── lib/
│   ├── main.dart                     # Supabase/Auth, выбор старта (Onboarding vs App), фоновый изолят onStart
│   ├── app_session.dart              # Сессия группы/охотника + AppSession.ensureSignedIn()
│   ├── app_settings.dart             # Настройки GPS, БД, кругов, skipOnboarding, formatRingDistance()
│   ├── track_recorder.dart           # Запись трека (JSONL), invalidateCache(), Дуглас–Пекер, офлайн-очередь
│   ├── track_exporter.dart           # Экспорт треков и событий в GPX 1.1 и CSV (UTF-8 BOM) + share_plus
│   └── screens/
│       ├── onboarding_screen.dart    # 5 экранов инструкции при старте / просмотре из настроек
│       ├── privacy_policy_screen.dart# Встроенный экран Политики конфиденциальности
│       ├── home_screen.dart          # Главный экран (Создать / Присоединиться)
│       ├── create_group_screen.dart  # Генерация 4-символьного кода и создание группы
│       ├── join_group_screen.dart    # Ввод кода и поиск через RPC get_group_by_code
│       ├── name_input_screen.dart    # Ввод уникального имени в группе и выбор роли
│       ├── map_screen.dart           # Карта, слои, события, SOS, круги, трек, меню и экспорт событий
│       ├── settings_screen.dart      # Настройки GPS/БД/кругов, инструкция, политика, удаление данных, о приложении
│       ├── tracks_history_screen.dart# Список облачных/ожидающих треков, удаление, экспорт GPX/CSV
│       └── track_preview_screen.dart # Просмотр сохранённого трека на карте (3 слоя), экспорт GPX/CSV
├── icon_master.png                   # Мастер-иконка приложения (также для карточки RuStore)
├── icon_foreground.png               # Foreground для adaptive icon Android
├── pubspec.yaml                      # version: 1.0.0+1, зависимости, ассеты
└── README.md
