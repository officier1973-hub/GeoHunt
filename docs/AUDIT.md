# 📋 ПОЛНЫЙ ТЕХНИЧЕСКИЙ АУДИТ ПРОЕКТА: GeoHunt (Release 6.0)

## 1. 🎯 О проекте
**GeoHunt** — мобильное приложение (Android, кодовая база Flutter) для координации группы охотников в реальном времени при отсутствии голосовой связи и нестабильном интернете.

### Реализованные возможности
* **Группы по коду:** создание группы с 4-значным кодом, безопасный поиск и вход по коду через RPC, выбор уникального имени в группе и роли (`Стрелок`, `Загонщик`, `Егерь`, `Нет`) с цветовой индикацией.
* **Карта в реальном времени (`MapLibre GL`):**
  * 3 режима: **Улицы** (OpenFreeMap Positron), **Спутник** (EOxCloudless), **Гибрид** (спутник + векторные дороги и подписи).
  * Переключение в **офлайн-режим кэша** (`setOffline`).
  * Вращающийся по компасу/GPS маркер пользователя (плавное обновление через `setGeoJsonSource`).
  * Геодезические **круги расстояния** вокруг маркера (`100 / 200 / 300 м`) с подписями и настройкой отображения.
  * **Умный компас**: красно-белая стрелка появляется только при повороте карты (`> 0.5°`) и возвращает ориентацию на Север по нажатию.
* **Координация группы:**
  * Живое отображение позиций напарников через Supabase Realtime + легенда группы с возрастом последней связи.
  * События на охоте (**«Видел»**, **«Подранен»**, **«Добыт»**) с заметками, программной генерацией иконок (`Canvas`) и звуковыми оповещениями.
  * Экстренный сигнал **SOS** с зацикленной сиреной, тревожным окном и выделением точки красным.
* **Запись треков и история:**
  * Непрерывная запись маршрута в локальный файл `active_track.jsonl` (работает и при выключенном экране в фоновом сервисе независимо от интервала отправки координат в БД).
  * Фильтрация GPS-шума (`accuracy <= 35 м`, шаг `>= 8 м`), отображение линии трека на карте, сжатие алгоритмом **Дугласа–Пекера** (`epsilon = 5 м`) при сохранении.
  * Офлайн-очередь сохранения треков (`pending_tracks/`) с автоматической доотправкой при появлении интернета.
  * Экраны **«История треков»** и **«Просмотр трека»** (линия, старт/финиш, автозум, смена слоёв).
* **Фоновый GPS-трекинг и энергосбережение:** настройка точности GPS (`high / medium / low`) и интервала отправки координат в БД (`30с / 60с / 300с`).

---

## 2. 🛠 Технологический стек
* **Язык и фреймворк:** Dart `>=3.0.0 <4.0.0`, Flutter `>=3.0.0` (CI использует `stable` / `3.50.1`).
* **Карты:** `maplibre_gl: ^0.28.0`.
* **Бэкенд:** Supabase (`supabase_flutter: ^2.8.0`) — PostgreSQL, Anonymous Auth, RLS, Realtime, `pg_cron`.
* **Геолокация и сенсоры:** `geolocator: ^14.0.0`, `flutter_compass: ^0.8.1`.
* **Фон и уведомления:** `flutter_background_service: ^5.0.10`, `flutter_local_notifications: ^17.2.3`.
* **Хранилище и медиа:** `shared_preferences: ^2.3.0`, `path_provider: ^2.1.3`, `audioplayers: ^6.0.0`.
* **CI/CD и Android:** GitHub Actions (`ubuntu-24.04`), Java 21 (Temurin), Gradle `9.3.1`, `compileSdk 36`, NDK `28.2.13676358`, `flutter_launcher_icons: ^0.14.1`.

---

## 3. 📂 Структура проекта

```text
GeoHunt/
├── .github/workflows/
│   └── build-apk.yml                 # Автосборка APK (flutter_launcher_icons + release APK)
├── android/
│   ├── gradle.properties             # Параметры JVM и AndroidX
│   ├── gradle/wrapper/               # Gradle 9.3.1
│   └── app/
│       ├── build.gradle              # applicationId com.example.hunt_together, compileSdk 36
│       └── src/main/
│           ├── AndroidManifest.xml   # Разрешения, Foreground Service (location), WatchdogReceiver disabled
│           ├── kotlin/com/example/GeoHunt/MainActivity.kt # package com.example.hunt_together
│           └── res/values/styles.xml # Theme.AppCompat.Light.NoActionBar (требование MapLibre)
├── assets/
│   ├── icons/arrow.png               # Зелёная стрелка пользователя
│   ├── images/home_hero.png          # Иллюстрация главного экрана
│   └── sounds/                       # sound_spotted.mp3, sound_wounded.mp3, sound_harvested.mp3, sos_siren.mp3
├── docs/
│   └── AUDIT.md                      # Настоящий документ технического аудита
├── lib/
│   ├── main.dart                     # Инициализация Supabase/Auth, старт UI, фоновый изолят onStart
│   ├── app_session.dart              # Сессия группы/охотника + AppSession.ensureSignedIn()
│   ├── app_settings.dart             # Настройки GPS, интервала БД, кругов расстояния
│   ├── track_recorder.dart           # Запись трека (JSONL), Дуглас–Пекер, офлайн-очередь, Supabase API
│   └── screens/
│       ├── home_screen.dart          # Главный экран (Создать / Присоединиться)
│       ├── create_group_screen.dart  # Генерация 4-символьного кода и создание группы
│       ├── join_group_screen.dart    # Ввод кода и поиск через RPC get_group_by_code
│       ├── name_input_screen.dart    # Ввод уникального имени в группе и выбор роли
│       ├── map_screen.dart           # Основной экран карты, слои, события, SOS, круги, запись трека
│       ├── settings_screen.dart      # Настройки точности GPS, частоты БД, тумблер кругов
│       ├── tracks_history_screen.dart# Список облачных и ожидающих отправки треков
│       └── track_preview_screen.dart # Просмотр сохранённого трека на карте
├── pubspec.yaml
└── README.md
```

---

## 4. 🗄 База данных и безопасность (Supabase)

**Проект:** `https://qucrbwsudcwqetcullsp.supabase.co`

### 4.1. Таблицы
1. **`groups`**: `id` (`uuid` PK), `code` (`text unique not null`), `created_by` (`uuid` default `auth.uid()`), `created_at` (`timestamptz`).
2. **`hunters`**: `id` (`uuid` PK), `group_id` (`uuid` FK `on delete cascade`), `user_id` (`uuid not null unique` FK `on delete cascade`), `name` (`text`), `role` (`shooter | driver | ranger | none`), `lat` (`float8`), `lon` (`float8`), `color` (`text`), `sos` (`bool`), `sos_at` (`timestamptz`), `updated_at` (`timestamptz`).
   * Индексы: `hunters_group_id_idx`, `hunters_updated_at_idx`, `hunters_user_id_uidx` (unique), `hunters_group_name_uidx` (unique по `(group_id, lower(name))`).
   * Триггер: `trg_hunters_updated_at` (`BEFORE UPDATE`, автоматически выставляет `new.updated_at = now()`).
3. **`events`**: `id` (`uuid` PK), `group_id` (`uuid` FK `on delete cascade`), `hunter_id` (`uuid` FK `on delete set null`), `hunter_name` (`text`), `type` (`spotted | wounded | harvested`), `lat` (`float8`), `lon` (`float8`), `note` (`text`), `created_at` (`timestamptz`).
4. **`tracks`**: `id` (`uuid` PK), `group_id` (`uuid` FK `on delete set null`), `user_id` (`uuid not null` FK `on delete cascade`), `hunter_name` (`text`), `title` (`text`), `started_at` (`timestamptz`), `ended_at` (`timestamptz`), `distance_meters` (`float8`), `points_count` (`int`), `points` (`jsonb` формата `[[lat, lon, epochSec], ...]`), `created_at` (`timestamptz`).
   * Индексы: `tracks_user_id_started_idx`, `tracks_group_id_idx`.

### 4.2. Безопасность (RLS), функции и Realtime
* Все RLS-политики ограничены ролью `to authenticated` (используется анонимный вход `signInAnonymously()`).
* `get_my_group_id() -> uuid` (`SECURITY DEFINER`) — возвращает `group_id` пользователя без рекурсии в RLS.
* `get_group_by_code(p_code text) -> table(id uuid, code text)` (`SECURITY DEFINER`) — поиск группы только по точному совпадению кода.
* `groups`: `SELECT` только для своей/созданной группы; `INSERT` с `created_by = auth.uid()`.
* `hunters`: `SELECT` в рамках группы; `INSERT/UPDATE/DELETE` только для своего `user_id` (`UPDATE` запрещает менять `group_id` на чужой).
* `events`: `SELECT` в рамках группы; `INSERT` в свою группу с проверкой принадлежности `hunter_id`.
* `tracks`: `SELECT/INSERT/DELETE` только для `user_id = auth.uid()` (личные треки сохраняются даже после автоудаления временной группы).
* **Realtime:** `hunters` и `events` включены в `supabase_realtime` с `replica identity full`.
* **Автоочистка (`pg_cron`):** `hunters` (`> 2ч` — каждые 10 мин), `events` (`> 7д` — каждые 30 мин), пустые `groups` (`> 7д` — каждый час). Таблица `tracks` не чистится.

---

## 5. 🧩 Технические контракты для продолжения разработки

### 5.1. Доступы и ключи
* Supabase URL и Publishable/Anon key находятся в `lib/main.dart` (`supabaseUrl`, `supabaseAnonKey`). Секретные ключи (`service_role`) в клиент не добавляются.

### 5.2. Ключи `SharedPreferences` (читаются из UI и фонового изолята)
* **Сессия (`AppSession`):** `active_group_id`, `active_group_code`, `active_hunter_id`, `active_hunter_name`, `active_hunter_role`, `active_user_id`.
* **Настройки (`AppSettings`):**
  * `setting_accuracy`: `'high' | 'balanced' | 'low'`
  * `setting_db_interval`: `int` (`30 | 60 | 300`)
  * `setting_show_distance_rings`: `bool`
  * `setting_ring_distances`: `List<String>` (по умолчанию `['100', '200', '300']`)
* **Правило:** фоновый изолят `onStart` обязан вызывать `await prefs.reload()` перед чтением настроек/сессии.

### 5.3. Команды фонового сервиса (`FlutterBackgroundService`)
* `'appState'` (`{'foreground': bool}`) — отключает дублирующую запись в БД и активный трек из фона, пока экран карты открыт.
* `'trackState'` (`{'recording': bool}`) — сообщает фону о старте/остановке записи трека.
* `'updateSettings'` — перечитывает настройки из `SharedPreferences` и перезапускает `Geolocator.getPositionStream`.
* `'stopService'` / `'stopTracking'` / `'onTaskRemoved'` — отменяют подписку GPS и вызывают `service.stopSelf()`.

### 5.4. Локальные файлы треков (`path_provider` -> `Documents`)
* `active_track_meta.json` — метаданные текущей записи (`recording`, `started_at`, `group_id`, `hunter_name`).
* `active_track.jsonl` — построчный лог точек `[lat, lon, epochSec]` (устойчив к сбоям).
* `pending_tracks/*.json` — завершённые треки, ожидающие отправки в Supabase при появлении сети.

### 5.5. Контракты слоёв MapLibre (`maplibre_gl ^0.28.0`)
* **Базовый стиль:** `https://tiles.openfreemap.org/styles/positron` (источник `openmaptiles`, `sourceLayer`: `'transportation'` для дорог, `'place'` для подписей).
* **Спутник:** `https://tiles.maps.eox.at/wmts/1.0.0/s2cloudless-2025_3857/default/g/{z}/{y}/{x}.jpg` (`satellite_source` / `satellite_layer`).
* **Гибрид:** `roads_layer`, `labels_layer`.
* **Активный трек:** `active_track_source` (`active_track_casing_layer`, `active_track_layer`).
* **Круги дистанции:** `distance_rings_source` (`distance_rings_casing_layer`, `distance_rings_layer`), `distance_rings_labels_source` (`distance_rings_labels_layer`).
* **Охотники и события:** `others_source` (`others_layer`, `others_labels_layer`), `events_source` (`events_icons_layer`, `events_labels_layer`).
* **Маркер пользователя:** `user_location_source` (`user_location_layer`), иконка `'user_arrow'`.
* **Иконки событий (`Canvas`):** `'event_spotted'`, `'event_wounded'`, `'event_harvested'`.
* **Жёсткие правила MapLibre:**
  1. Не ставить `ValueKey` на `MapLibreMap` при переключении стилей (иначе чёрный экран).
  2. Обновлять часто меняющиеся слои (`user_location`, `distance_rings`, `active_track`) через `setGeoJsonSource(...)`, а не пересоздавать слои на каждый тик (иначе маркер/линии моргают).
  3. При пересоздании источника сначала удалять привязанные слои, потом источник.
  4. `_syncMyLocationLayers` сериализует обновления, чтобы маркер и круги всегда строились по одной координате `_myPos` без сдвига.

---

## 6. 🔍 Технический аудит: выявленные риски и технический долг

### Критический / Высокий приоритет
1. **Рассинхронизация `_cachedLastPoint` в `TrackRecorder` между изолятами:**
   Статическое поле `_cachedLastPoint` живёт отдельно в памяти UI-изолята и фонового изолята `onStart`. Если пользователь сначала шёл с включённым экраном (пишет UI), затем выключил экран (пишет фон), а затем снова включил/выключил, фон может сравнивать шаг `8 м` со своей устаревшей последней точкой. *Решение:* при переключении `appState -> foreground: false` сбрасывать `_cachedLastPoint = null` в фоне (чтобы перечитал хвост файла один раз).
2. **Поведение при смахивании приложения (`stopWithTask="true"`):**
   При случайном смахивании из списка недавних задач сервис останавливается (`onTaskRemoved -> stopSelf()`). Накопленные точки трека сохраняются в `active_track.jsonl`, но новые не пишутся до повторного запуска приложения. Для длительных охот стоит рассмотреть опцию удержания сервиса, пока активна запись трека.
3. **Фоновое разрешение геолокации и энергосбережение Android:**
   Запрашивается стандартное разрешение (`whileInUse`), без явного сценария запроса `ACCESS_BACKGROUND_LOCATION` («Разрешить всегда») и без напоминания об исключениях батареи (Huawei EMUI, Xiaomi MIUI, Samsung).

### Средний приоритет
4. **Офлайн-работа без предзагрузки карты:**
   Переключатель `setOffline(true)` использует только ранее просмотренный кэш. Полноценная работа в тайге без интернета требует загрузки регионов через `OfflineManager`.
5. **Настройка пользовательских радиусов в UI:**
   `AppSettings.saveRingDistances` уже реализован, но в `SettingsScreen` пока нет UI ввода/изменения радиусов (зафиксировано `100, 200, 300 м`).
6. **Подпись релизного APK и идентификатор пакета:**
   * `build.gradle` использует `signingConfigs.debug` для `release` — при смене ключа обновления не ставятся поверх старой версии.
   * `applicationId` имеет шаблонное значение `com.example.hunt_together`, а `MainActivity.kt` лежит в директории `.../GeoHunt/` при `package com.example.hunt_together`.

### Низкий приоритет
7. **Предупреждения совместимости инструментов сборки (Flutter 3.50.1):**
   CI сообщает о скором прекращении поддержки Gradle `9.3.1` (нужен `>= 9.5.0`), AGP `9.1.1` (`>= 9.3.1`), Kotlin `2.4.10` (`>= 2.4.20`) и рекомендует миграцию на Built-in Kotlin.
8. **Хардкод URL/ключа Supabase и `test/`:**
   Ключи лежат в `lib/main.dart` (publishable key защищён RLS, но для публичного репозитория аккуратнее передавать через `--dart-define`). Автотесты (`test/`) отсутствуют.
9. **Неиспользуемые директории/контракты на будущее:**
   В `TrackPreviewScreen` отображается только сам трек; события охоты (`events`), зафиксированные во время трека, пока не привязываются к сохранённому маршруту.

---

## 7. 🗺 Дорожная карта (Roadmap)

### ✅ Выполнено (по Release 6.0)
* Карта (3 стиля: Улицы, Спутник, Гибрид) и переключатель кэш-офлайна (`setOffline`).
* Изоляция групп по коду, роли, цвета, легенда, защита через RLS + RPC + `pg_cron`.
* События («Видел / Подранен / Добыт») со звуком и программными иконками, тревога SOS с сиреной.
* Фоновый GPS-сервис, настройки точности и частоты отправки, разгрузка `AppBar`.
* Красно-белый компас карты (появляется при повороте) и круги дистанции `100 / 200 / 300 м` без сдвига и моргания.
* Запись треков (фон + UI), сжатие Дугласа–Пекера, офлайн-очередь, таблица `tracks`, экраны истории и просмотра трека.

### ⏳ Следующие этапы
1. **Настройка радиусов кругов расстояния в `SettingsScreen`** (использовать готовый `AppSettings.saveRingDistances`) + фикс сброса `_cachedLastPoint` при смене `appState`.
2. **Экспорт треков и событий в GPX / CSV** (`share_plus` + генератор GPX 1.1 с путевыми точками событий).
3. **Скачивание офлайн-карт (`OfflineManager`)**: выбор области и зумов, прогресс скачивания, управление регионами.
4. **Релизная инфраструктура**: собственный release keystore в GitHub Secrets, смена `applicationId`, обновление Gradle/AGP/Kotlin, базовые unit-тесты (`TrackRecorder`, `AppSettings`).
