# 📋 ПОЛНЫЙ ТЕХНИЧЕСКИЙ АУДИТ И ПАСПОРТ ПРОЕКТА: Коллективная охота / GeoHunt (Release 8.0)

> **Инструкция для нового чата / ИИ (критически важно прочитать перед работой):**
> 1. **Среда разработки владельца:** работа ведётся на **Mac исключительно через веб-интерфейсы в браузере**:
>    * **Код и файлы:** GitHub Web Editor (редактирование/создание/удаление файлов напрямую на сайте GitHub).
>    * **Сборка APK:** только в облаке через **GitHub Actions** (локально Flutter / Android Studio не установлены).
>    * **Бэкенд:** **Supabase Dashboard** (SQL Editor, Table Editor, Auth, Cron) через браузер.
>    * **Публикация и веб-страницы:** **RuStore Консоль** и **GitHub Pages** через браузер.
>    * *(Единственный локальный инструмент, установленный на Mac разово — Temurin JDK 21, использовался в Терминале для генерации `geohunt-release.jks`).*
> 2. **Правила выдачи кода и инструкций:**
>    * **Не предлагайте** локальные команды `flutter run`, `flutter build`, `flutter doctor` и т.п.
>    * Для **новых и компактных/средних файлов** выдавайте **полный готовый код файла целиком** (для копирования в веб-редактор).
>    * Для **точечных правок в больших файлах** (`lib/screens/map_screen.dart`) указывайте **точные номера строк, текстовый якорь для поиска (`Cmd + F`) и блоки «Что удалить» / «Что вставить»**. *(Примечание: в копии `map_screen.dart` на GitHub из-за вставок через браузер могут присутствовать лишние пустые строки — фактические номера строк могут быть примерно в ~1.9 раза больше эталонных).*
>    * В `build-apk.yml` включён `concurrency: cancel-in-progress: true`: при поочерёдном сохранении нескольких файлов через веб-интерфейс промежуточные запуски Actions отменяются — это норма, собирается последний коммит.

---

## 1. 🎯 Статус проекта и публикация в RuStore

* **Текущий статус:** Релиз `1.0.0+1` собран, подписан релизным ключом и **отправлен на модерацию в RuStore Консоль**.
* **Отображаемое название (RuStore и `android:label`):** `Коллективная охота` *(на русском языке согласно ФЗ-168 с 01.03.2026 и п. 6.4 правил модерации RuStore; название в APK и в карточке магазина совпадает 1-в-1)*.
* **Техническое имя репозитория / проекта:** `GeoHunt` (`name: hunt_together` в `pubspec.yaml`).
* **Идентификатор пакета (`applicationId` / `namespace`):** `ru.geohunt.app` *(перенесён с шаблонного `com.example.hunt_together`; `MainActivity.kt` перенесён в `android/app/src/main/kotlin/ru/geohunt/app/MainActivity.kt`)*.
* **Версия релиза:** `1.0.0+1` (`versionName: 1.0.0`, `versionCode: 1` в `pubspec.yaml`).
* **Аккаунт RuStore:** Физическое лицо (вход через VK ID, `https://console.rustore.ru`), бесплатное приложение без встроенных платежей (IAP), рекомендуемый возрастной рейтинг `16+`.
* **Релизная подпись (`keystore`):**
  * Файл `geohunt-release.jks` (`RSA 2048`, `alias: geohunt`, срок `10000` дней) сгенерирован на Mac и хранится локально у владельца (**нельзя терять** — без него невозможны будущие обновления в RuStore; **нельзя коммитить** в публичный репозиторий).
  * Передан в облачную сборку через **GitHub Secrets**: `KEYSTORE_BASE64`, `KEYSTORE_PASSWORD`, `KEY_ALIAS` (`geohunt`), `KEY_PASSWORD`.
  * `build-apk.yml` декодирует ключ в `${{ runner.temp }}/release-keystore.jks`, подписывает APK через `signingConfigs.release` и проверяет сертификат в логе (`keytool -printcert`).
* **Соответствие требованиям модерации RuStore (реализовано и опубликовано):**
  * **Политика конфиденциальности (веб):** `docs/privacy-policy.html` с реальным контактным email владельца; опубликована через **GitHub Pages** (`Settings → Pages → main / /docs`).
  * **Политика конфиденциальности (внутри приложения):** `lib/screens/privacy_policy_screen.dart` с тем же email, открывается из Настроек.
  * **Удаление данных пользователя:** в `SettingsScreen` кнопка **«Удалить все мои данные»** (удаляет облачные записи в `tracks` и `hunters` при наличии интернета, сбрасывает активный и отложенные треки, останавливает фоновый сервис, очищает `AppSession` и возвращает на `HomeScreen`).
  * **Атрибуция карт:** диалог «О приложении и источники карт» в `SettingsScreen` (`OpenFreeMap / © OpenStreetMap contributors` и `Esri World Imagery / Maxar, Earthstar Geographics`).

---

## 2. 🚀 Реализованные возможности приложения

* **Стартовая инструкция (`OnboardingScreen`):**
  * 5 интерактивных экранов с руководством по всем функциям (группы/роли, карта/слои/кэш/круги, события/SOS, треки/экспорт GPX и CSV, батарея и разрешения Android).
  * Чекбокс **«Не показывать при каждом запуске»** (`setting_skip_onboarding`).
  * В Настройках (раздел «Инструкция и обучение»): тумблер «Показывать инструкцию при запуске» + кнопка «Открыть инструкцию».
* **Группы по 4-значному коду:** создание группы, поиск через RPC `get_group_by_code`, уникальное имя в группе, выбор роли (`Стрелок`, `Загонщик`, `Егерь`, `Нет`) с цветовой индикацией.
* **Карта в реальном времени (`MapLibre GL ^0.28.0`):**
  * **3 слоя карты (`MapScreen` и `TrackPreviewScreen`):**
    * **Улицы:** OpenFreeMap Positron (`https://tiles.openfreemap.org/styles/positron`).
    * **Спутник:** Esri World Imagery / Maxar (детальные снимки, `maxzoom: 17`, `{z}/{y}/{x}`).
    * **Гибрид:** Esri World Imagery + векторные водотоки (`waterway`), дороги с тёмным контуром (`roads_casing` + `roads`) и контрастные подписи (`place`).
  * **Офлайн-кэш (`setOffline`)** + бейдж на карте.
  * Вращающийся по компасу/GPS маркер пользователя (плавное обновление через `setGeoJsonSource`).
  * Геодезические **круги расстояния** вокруг маркера (по умолчанию `100 / 200 / 300 м`, настраиваются в UI) и **умный компас** (возврат на Север при повороте `> 0.5°`).
* **Меню карты (`⋮` в `AppBar` `MapScreen`, актуальный порядок):**
  1. `История треков` (`Icons.history`)
  2. `Экспорт событий (GPX / CSV)` (`Icons.share_outlined`)
  3. `Круги (...)` (`Icons.radar` слева + чекбокс `check_box` / `check_box_outline_blank` справа)
  4. `Офлайн-режим (кэш)` (`Icons.cloud_off` слева + чекбокс `check_box` / `check_box_outline_blank` справа; расположен **выше** Настроек)
  5. `Настройки` (`Icons.settings`)
  6. Разделитель + `Выйти из группы` (`Icons.logout`, красный)
* **Координация, события и SOS:**
  * Живое отображение напарников через Supabase Realtime + легенда группы с возрастом последней связи (метки старше 1 часа — серые, heartbeat каждые 15 мин).
  * События (**«Видел»**, **«Подранен»**, **«Добыт»**) с заметками, программными иконками (`Canvas`) и звуковыми оповещениями.
  * Сигнал **SOS** с зацикленной сиреной, неблокируемым тревожным окном и выделением маркера красным.
* **Запись треков, история и экспорт (`TrackRecorder`, `TrackExporter`):**
  * Непрерывная запись маршрута в `active_track.jsonl` (в UI и в фоне при выключенном экране независимо от интервала БД; изоляты синхронизируются через `TrackRecorder.invalidateCache()`).
  * Фильтр GPS-шума (`accuracy <= 35 м`, шаг `>= 8 м`), сжатие алгоритмом **Дугласа–Пекера** (`epsilon = 5 м`), офлайн-очередь (`pending_tracks/`).
  * Экраны **«История треков»** и **«Просмотр трека»** (линия, старт/финиш, автозум, 3 слоя карты).
  * **Экспорт в GPX 1.1 и CSV (`share_plus: ^13.3.1`):**
    * Экспорт любого трека вместе с событиями группы `<wpt>` за период трека (офлайн-устойчиво).
    * Экспорт текущих событий группы напрямую из меню карты `⋮`.
    * CSV в UTF-8 с BOM (`\uFEFF`) для Excel.
* **Настройки (`SettingsScreen`):** точность GPS (`high/balanced/low`), интервал отправки в БД (`30/60/300` с), тумблер и редактор радиусов кругов (`InputChip`, ввод `10..50000 м`, пресеты `50..2000 м`, сброс), управление инструкцией, Политика конфиденциальности, «О приложении и источники карт», «Удалить все мои данные».

---

## 3. 🛠 Технологический стек и облачные ресурсы

* **Frontend:** Flutter `>=3.0.0` (CI собирает на `stable` / `3.50.1`), Dart `>=3.0.0 <4.0.0`.
* **Пакеты (`pubspec.yaml`):**
  * Карты: `maplibre_gl: ^0.28.0`
  * Бэкенд: `supabase_flutter: ^2.8.0`
  * Геолокация и сенсоры: `geolocator: ^14.0.0`, `flutter_compass: ^0.8.1`
  * Фон и уведомления: `flutter_background_service: ^5.0.10`, `flutter_local_notifications: ^17.2.3`
  * Хранилище, медиа и экспорт: `shared_preferences: ^2.3.0`, `path_provider: ^2.1.3`, `audioplayers: ^6.0.0`, `share_plus: ^13.3.1`
  * Иконки: `flutter_launcher_icons: ^0.14.1`
* **CI/CD и Android:** GitHub Actions (`ubuntu-24.04`), Java 21 (Temurin), Gradle `9.3.1`, AGP `9.1.1`, Kotlin `2.4.10`, `compileSdk 36`, NDK `28.2.13676358`.
* **Внешние облачные ресурсы проекта:**
  * **GitHub** (публичный репозиторий + Actions для сборки APK и keep-alive + GitHub Pages для `docs/privacy-policy.html`).
  * **Supabase (Free tier):** `https://qucrbwsudcwqetcullsp.supabase.co` (PostgreSQL, Anonymous Auth, RLS, Realtime, `pg_cron`).
  * **Тайловые серверы:** OpenFreeMap (`tiles.openfreemap.org`) и Esri World Imagery (`server.arcgisonline.com`).
  * **RuStore Консоль:** `https://console.rustore.ru` (публикация APK `ru.geohunt.app`).

---

## 4. 📂 Структура проекта

```text
GeoHunt/
├── .github/workflows/
│   ├── build-apk.yml                 # Release APK: кэш Gradle, декодирование keystore, подпись, keytool verify
│   └── supabase-keepalive.yml        # (Опционально/настраивается) Пинг Supabase раз в 2 дня против паузы Free-тарифа
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
│   └── privacy-policy.html           # Публичная Политика конфиденциальности (GitHub Pages -> RuStore)
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
│       ├── map_screen.dart           # Карта, слои, события, SOS, круги, трек, меню ⋮ и экспорт событий
│       ├── settings_screen.dart      # Настройки GPS/БД/кругов, инструкция, политика, удаление данных, о приложении
│       ├── tracks_history_screen.dart# Список облачных/ожидающих треков, удаление, экспорт GPX/CSV
│       └── track_preview_screen.dart # Просмотр сохранённого трека на карте (3 слоя), экспорт GPX/CSV
├── icon_master.png                   # Мастер-иконка приложения (также иконка для RuStore)
├── icon_foreground.png               # Foreground для adaptive icon Android
├── pubspec.yaml                      # version: 1.0.0+1, зависимости, ассеты
└── README.md
