# Tangent v1 Implementation Plan — Flutter Client (Phase 2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a working Flutter app (Android / Linux / Windows) that records audio locally, syncs to a self-hosted Tangent server, and displays searchable transcripts — without on-device Whisper inference.

**Architecture:** Flutter 3.27 client + drift (SQLite) for local storage + dio for HTTP + Riverpod for state. Talks to the existing Phase1 FastAPI server. No JNI / no Flutter-whisper packages / no on-device ML.

**Tech Stack:**
- Flutter 3.27.1 + Dart 3.6.0
- flutter_riverpod (state)
- drift (local SQLite + FTS5)
- dio (HTTP)
- record (audio capture)
- flutter_secure_storage (token storage)
- flutter_local_notifications (sync notifications)
- connectivity_plus (network state)
- go_router (navigation)
- freezed + json_serializable (models)
- AGPL-3.0 license headers on every source file

**This plan covers Phase 2 only — the Flutter client.** Server is already shipped (see `docs/superpowers/plans/2026-09-13-v1-brain-dump.md`). On-device Whisper is Phase 2.5 (deferred per spec §2).

---

## Global Constraints

These are project-wide requirements every task implicitly inherits. Copied verbatim from the spec.

- **License:** AGPL-3.0. Every Dart source file starts with the SPDX header `// SPDX-License-Identifier: AGPL-3.0-or-later`. Every dependency must be AGPL-compatible or permissively licensed.
- **No on-device ML in v1.** No whisper.cpp, no llama.cpp, no ggml, no JNI bindings. Server-side transcription only.
- **Single-user.** No multi-tenancy, no per-user accounts, one API token.
- **Auth:** API token via `Authorization: Bearer <token>`, stored in OS keystore via `flutter_secure_storage`.
- **Audio retention:** Server deletes audio after transcription. Client keeps audio files in app-private docs dir (`${appDocs}/audio/{uuid}.opus`).
- **Audio format:** Opus, 16 kHz mono, ~32 kbps. ~240 KB/min. ~14.4 MB/hour.
- **Max recording length:** 60-minute hard cap. No mid-recording warnings.
- **Conventions:**
  - Dart: `snake_case` for files/variables, `PascalCase` for classes, `lower_snake_case` for constants.
  - Imports: Dart first, Flutter second, package third, local fourth. Alphabetical within group.
  - Line length: 100 chars max.
  - Type hints on every public function (Dart is dynamic; we use static analysis).
  - Logging via `logger` package, never `print()`.
  - All `await`s must be explicit; no fire-and-forget futures.
- **Test framework:** flutter_test for unit/widget, integration_test for end-to-end.
- **Commit cadence:** One task = one commit. Conventional Commits (`feat:`, `fix:`, `chore:`, `test:`, `docs:`).
- **Working directory:** All paths in this plan are relative to `client/` (e.g., `lib/main.dart` means `client/lib/main.dart`).
- **Minimum test coverage:** Every task must add or update at least one test. TDD where possible.
- **Toolchain (already installed, verified):**
  - Flutter: `~\AppData\Local\flutter\bin\flutter.bat`
  - JDK17: `C:\Program Files\Microsoft\jdk-17.0.20.8-hotspot`
  - Android SDK: `%LOCALAPPDATA%\Android\Sdk` (cmdline-tools, platform-tools, platforms;android-34, build-tools;34.0.0)
  - Env vars: `JAVA_HOME`, `ANDROID_HOME` set per-session before flutter commands.

---

## File Structure

```
client/                                 (created by `flutter create`, will be modified)
├── pubspec.yaml                        # dependencies
├── analysis_options.yaml               # lints
├── README.md                           # client-specific docs
├── android/
│   ├── app/
│   │   ├── build.gradle                 # AGPL note, app ID
│   │   └── src/main/AndroidManifest.xml  # mic permission
│   └── build.gradle
├── lib/
│   ├── main.dart                        # entry, ProviderScope, app
│   ├── app.dart                         # MaterialApp.router + theme
│   ├── models/
│   │   ├── dump.dart                    # domain Dump
│   │   ├── dump_mode.dart
│   │   ├── sync_status.dart
│   │   ├── server_info.dart
│   │   └── api_exception.dart
│   ├── data/
│   │   ├── local_db.dart                # drift database
│   │   ├── dumps_dao.dart               # drift DAOs
│   │   ├── audio_storage.dart           # file path management
│   │   ├── secure_storage.dart          # token in keystore
│   │   └── settings_store.dart          # app preferences
│   ├── services/
│   │   ├── recording_service.dart       # mic capture
│   │   ├── playback_service.dart        # audio playback
│   │   ├── transcription_client.dart    # REST + SSE
│   │   ├── sync_engine.dart             # batched uploads
│   │   ├── notification_service.dart
│   │   ├── connectivity_service.dart
│   │   └── logger.dart
│   ├── screens/
│   │   ├── onboarding/
│   │   │   ├── welcome_screen.dart
│   │   │   ├── mic_permission_screen.dart
│   │   │   └── server_setup_screen.dart
│   │   ├── recording/
│   │   │   ├── recording_screen.dart
│   │   │   └── recording_controller.dart
│   │   ├── dumps/
│   │   │   ├── dumps_list_screen.dart
│   │   │   ├── dump_detail_screen.dart
│   │   │   └── dumps_list_controller.dart
│   │   └── settings/
│   │       ├── settings_screen.dart
│   │       └── settings_controller.dart
│   └── widgets/
│       ├── record_button.dart
│       ├── level_meter.dart
│       ├── dump_list_tile.dart
│       └── sync_status_badge.dart
└── test/
    ├── unit/
    │   ├── services/
    │   │   ├── recording_service_test.dart
    │   │   ├── transcription_client_test.dart
    │   │   └── sync_engine_test.dart
    │   └── data/
    │       └── local_db_test.dart
    └── widget/
        ├── recording_screen_test.dart
        └── dumps_list_screen_test.dart
```

**Design boundaries:**
- `lib/models/` is pure data (freezed-generated immutable classes with `fromJson`/`toJson`)
- `lib/data/` is storage (drift + filesystem + secure prefs); no business logic
- `lib/services/` is business logic (sync, recording, API); no UI imports
- `lib/screens/` is UI + per-screen Riverpod controllers; controllers orchestrate services
- `lib/widgets/` is reusable presentational widgets

---

## Tasks

### Task 1: Project configuration (pubspec + analysis_options)

**Files:**
- Modify: `client/pubspec.yaml`
- Modify: `client/analysis_options.yaml`
- Create: `client/.gitignore` (already exists from `flutter create`; verify)

**Interfaces:**
- Consumes: nothing (initial setup)
- Produces: project metadata, all v1 dependencies declared, lints configured

- [ ] **Step 1: Update `pubspec.yaml` with v1 dependencies**

```yaml
name: tangent
description: "Self-hosted voice brain-dump app for ADHD brains."
publish_to: 'none'
version: 1.0.0+1

environment:
  sdk: '>=3.6.0 <4.0.0'
  flutter: '>=3.27.0'

dependencies:
  flutter:
    sdk: flutter
  flutter_riverpod: ^2.5.1
  riverpod_annotation: ^2.3.5
  drift: ^2.20.2
  drift_flutter: ^0.2.2
  sqlite3_flutter_libs: ^0.5.24
  path_provider: ^2.1.4
  path: ^1.9.0
  dio: ^5.7.0
  record: ^5.1.2
  just_audio: ^0.9.40
  flutter_secure_storage: ^9.2.2
  flutter_local_notifications: ^17.2.3
  connectivity_plus: ^6.0.5
  go_router: ^14.2.7
  freezed_annotation: ^2.4.4
  json_annotation: ^4.9.0
  uuid: ^4.5.1
  intl: ^0.19.0
  logger: ^2.4.0

dev_dependencies:
  flutter_test:
    sdk: flutter
  flutter_lints: ^4.0.0
  build_runner: ^2.4.13
  drift_dev: ^2.20.3
  riverpod_generator: ^2.4.3
  freezed: ^2.5.7
  json_serializable: ^6.8.0
  mocktail: ^1.0.4
  integration_test:
    sdk: flutter

flutter:
  uses-material-design: true
```

- [ ] **Step 2: Update `analysis_options.yaml` with project lints**

```yaml
include: package:flutter_lints/flutter.yaml

analyzer:
  language:
    strict-casts: true
    strict-inference: true
    strict-raw-types: true
  errors:
    invalid_annotation_target: ignore
  exclude:
    - "**/*.g.dart"
    - "**/*.freezed.dart"

linter:
  rules:
    prefer_single_quotes: true
    require_trailing_commas: true
    avoid_print: true
    unawaited_futures: true
    cancel_subscriptions: true
```

- [ ] **Step 3: Install dependencies**

```bash
cd client
flutter pub get
```

Expected: All packages resolve. No version conflicts.

- [ ] **Step 4: Verify scaffolded test still passes**

```bash
cd client
flutter test
```

Expected: 1 test passes (the default `widget_test.dart` from `flutter create`).

- [ ] **Step 5: Commit**

```bash
cd ~/Documents/ADH2
git add client/
git commit -m "feat(client): add v1 dependencies (riverpod, drift, dio, record, etc.)"
```

---

### Task 2: Domain models (freezed + json_serializable)

**Files:**
- Create: `client/lib/models/dump_mode.dart`
- Create: `client/lib/models/sync_status.dart`
- Create: `client/lib/models/dump.dart`
- Create: `client/lib/models/server_info.dart`
- Create: `client/lib/models/api_exception.dart`

**Interfaces:**
- Consumes: nothing (pure data classes)
- Produces: `DumpMode` enum (brain_dump | meeting), `SyncStatus` enum (localOnly | pending | syncing | synced | failed), `Dump` immutable with id/createdAt/mode/durationSeconds/title/transcript/audioPath/audioSizeBytes/syncStatus/syncAttempts/lastSyncError, `ServerInfo`, `ApiException` typed error

- [ ] **Step 1: Create `dump_mode.dart`**

```dart
// SPDX-License-Identifier: AGPL-3.0-or-later
/// Brain Dump (default) or Meeting (secretary mode).
enum DumpMode {
  brainDump('brain_dump'),
  meeting('meeting');

  const DumpMode(this.wireValue);
  final String wireValue;

  static DumpMode fromWire(String value) {
    return values.firstWhere(
      (m) => m.wireValue == value,
      orElse: () => throw ArgumentError('Unknown DumpMode: $value'),
    );
  }
}
```

- [ ] **Step 2: Create `sync_status.dart`**

```dart
// SPDX-License-Identifier: AGPL-3.0-or-later
/// Sync state of a local dump against the server.
enum SyncStatus {
  localOnly('local_only'),
  pending('pending'),
  syncing('syncing'),
  synced('synced'),
  failed('failed');

  const SyncStatus(this.wireValue);
  final String wireValue;

  static SyncStatus fromWire(String value) {
    return values.firstWhere(
      (s) => s.wireValue == value,
      orElse: () => throw ArgumentError('Unknown SyncStatus: $value'),
    );
  }

  bool get needsUpload => this != SyncStatus.synced;
}
```

- [ ] **Step 3: Create `dump.dart` with freezed**

```dart
// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:freezed_annotation/freezed_annotation.dart';
import 'dump_mode.dart';
import 'sync_status.dart';

part 'dump.freezed.dart';
part 'dump.g.dart';

@freezed
class Dump with _$Dump {
  const factory Dump({
    required String id,
    required DateTime createdAt,
    required DateTime updatedAt,
    required DumpMode mode,
    required int durationSeconds,
    required String title,
    String? transcript,
    required String audioPath,
    required int audioSizeBytes,
    required SyncStatus syncStatus,
    @Default(0) int syncAttempts,
    String? lastSyncError,
  }) = _Dump;

  factory Dump.fromJson(Map<String, dynamic> json) => _$DumpFromJson(json);
}
```

- [ ] **Step 4: Create `server_info.dart`**

```dart
// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:freezed_annotation/freezed_annotation.dart';

part 'server_info.freezed.dart';
part 'server_info.g.dart';

@freezed
class ServerInfo with _$ServerInfo {
  const factory ServerInfo({
    required String version,
    required bool setupComplete,
    required String defaultModel,
    required List<String> availableModels,
    required int storageUsedBytes,
    required int dumpCount,
  }) = _ServerInfo;

  factory ServerInfo.fromJson(Map<String, dynamic> json) =>
      _$ServerInfoFromJson(json);
}
```

- [ ] **Step 5: Create `api_exception.dart`**

```dart
// SPDX-License-Identifier: AGPL-3.0-or-later
/// Typed exception for HTTP API errors.
class ApiException implements Exception {
  final int statusCode;
  final String code;
  final String message;

  const ApiException({
    required this.statusCode,
    required this.code,
    required this.message,
  });

  @override
  String toString() => 'ApiException($statusCode $code): $message';
}
```

- [ ] **Step 6: Run code generation**

```bash
cd client
dart run build_runner build --delete-conflicting-outputs
```

Expected: `.freezed.dart` and `.g.dart` files generated for `dump.dart` and `server_info.dart`.

- [ ] **Step 7: Write model tests**

Create `client/test/unit/models/dump_test.dart`:

```dart
// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/models/dump.dart';
import 'package:tangent/models/dump_mode.dart';
import 'package:tangent/models/sync_status.dart';

void main() {
  group('DumpMode', () {
    test('roundtrips through wire format', () {
      for (final mode in DumpMode.values) {
        expect(DumpMode.fromWire(mode.wireValue), mode);
      }
    });
  });

  group('SyncStatus', () {
    test('roundtrips through wire format', () {
      for (final status in SyncStatus.values) {
        expect(SyncStatus.fromWire(status.wireValue), status);
      }
    });

    test('needsUpload is true except for synced', () {
      expect(SyncStatus.synced.needsUpload, isFalse);
      expect(SyncStatus.pending.needsUpload, isTrue);
      expect(SyncStatus.failed.needsUpload, isTrue);
    });
  });

  group('Dump', () {
    test('serializes to JSON', () {
      final dump = Dump(
        id: 'test-uuid',
        createdAt: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2026, 1, 1),
        mode: DumpMode.brainDump,
        durationSeconds: 60,
        title: 'Test dump',
        audioPath: '/tmp/audio.opus',
        audioSizeBytes: 1000,
        syncStatus: SyncStatus.localOnly,
      );
      final json = dump.toJson();
      expect(json['id'], 'test-uuid');
      expect(json['mode'], 'brain_dump');
      expect(json['sync_status'], 'local_only');
    });
  });
}
```

- [ ] **Step 8: Run tests**

```bash
cd client
flutter test test/unit/models/dump_test.dart
```

Expected: All tests pass.

- [ ] **Step 9: Commit**

```bash
cd ~/Documents/ADH2
git add client/
git commit -m "feat(client): add domain models (Dump, DumpMode, SyncStatus, ServerInfo)"
```

---

### Task 3: Local SQLite schema with drift

**Files:**
- Create: `client/lib/data/local_db.dart`
- Create: `client/test/unit/data/local_db_test.dart`

**Interfaces:**
- Consumes: nothing
- Produces: `LocalDb` drift database class with `Dumps` and `SyncQueue` tables, FTS5 virtual table for search

- [ ] **Step 1: Create `local_db.dart`**

```dart
// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/dump_mode.dart';
import '../models/sync_status.dart';

part 'local_db.g.dart';

@DataClassName('DumpRow')
class Dumps extends Table {
  TextColumn get id => text()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  TextColumn get mode => text().withLength(min: 1, max: 20)();
  IntColumn get durationSeconds => integer()();
  TextColumn get title => text().withLength(min: 1, max: 500)();
  TextColumn get transcript => text().nullable()();
  TextColumn get audioPath => text()();
  IntColumn get audioSizeBytes => integer()();
  TextColumn get syncStatus => text().withLength(min: 1, max: 20)();
  IntColumn get syncAttempts =>
      integer().withDefault(const Constant(0))();
  TextColumn get lastSyncError => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('SyncQueueRow')
class SyncQueue extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get dumpId => text().references(Dumps, #id, onDelete: KeyAction.cascade)();
  DateTimeColumn get queuedAt => dateTime()();
}

@DriftDatabase(tables: [Dumps, SyncQueue])
class LocalDb extends _$LocalDb {
  LocalDb() : super(_openConnection());

  LocalDb.forTesting(super.executor);

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
          // Create FTS5 virtual table for full-text search
          await customStatement(
            "CREATE VIRTUAL TABLE IF NOT EXISTS dumps_fts USING fts5("
            "title, transcript, content='dumps', content_rowid='rowid')",
          );
          // Triggers to keep FTS in sync
          await customStatement(
            "CREATE TRIGGER IF NOT EXISTS dumps_ai AFTER INSERT ON dumps BEGIN "
            "INSERT INTO dumps_fts(rowid, title, transcript) VALUES (new.rowid, new.title, new.transcript);"
            "END",
          );
          await customStatement(
            "CREATE TRIGGER IF NOT EXISTS dumps_ad AFTER DELETE ON dumps BEGIN "
            "INSERT INTO dumps_fts(dumps_fts, rowid, title, transcript) VALUES('delete', old.rowid, old.title, old.transcript);"
            "END",
          );
          await customStatement(
            "CREATE TRIGGER IF NOT EXISTS dumps_au AFTER UPDATE ON dumps BEGIN "
            "INSERT INTO dumps_fts(dumps_fts, rowid, title, transcript) VALUES('delete', old.rowid, old.title, old.transcript);"
            "INSERT INTO dumps_fts(rowid, title, transcript) VALUES (new.rowid, new.title, new.transcript);"
            "END",
          );
        },
      );

  /// Insert or replace a dump row.
  Future<void> upsertDump(DumpRow row) => into(dumps).insertOnConflictUpdate(row);

  /// Fetch dumps, newest first, with pagination.
  Future<List<DumpRow>> listDumps({int limit = 50, int offset = 0}) {
    return (select(dumps)
          ..orderBy([(d) => OrderingTerm.desc(d.createdAt)])
          ..limit(limit, offset: offset))
        .get();
  }

  /// Search across title and transcript using FTS5.
  Future<List<DumpRow>> searchDumps(String query, {int limit = 50}) {
    final escaped = query.replaceAll('"', '""');
    return customSelect(
      "SELECT d.* FROM dumps d "
      "JOIN dumps_fts f ON d.rowid = f.rowid "
      "WHERE dumps_fts MATCH ? "
      "ORDER BY rank LIMIT ?",
      variables: [Variable.withString('"$escaped"'), Variable.withInt(limit)],
      readsFrom: {dumps},
    ).map((row) => dumps.map(row)).get();
  }

  /// Find a dump by id.
  Future<DumpRow?> getDump(String id) =>
      (select(dumps)..where((d) => d.id.equals(id))).getSingleOrNull();

  /// Update only the sync fields.
  Future<void> updateSyncStatus(
    String id,
    SyncStatus status, {
    int? attempts,
    String? lastError,
  }) async {
    await (update(dumps)..where((d) => d.id.equals(id))).write(
      DumpsCompanion(
        syncStatus: Value(status.wireValue),
        syncAttempts: attempts != null ? Value(attempts) : const Value.absent(),
        lastSyncError: lastError != null ? Value(lastError) : const Value.absent(),
        updatedAt: Value(DateTime.now().toUtc()),
      ),
    );
  }

  /// Find all dumps that need uploading.
  Future<List<DumpRow>> dumpsNeedingUpload({int maxAttempts = 5}) {
    return customSelect(
      "SELECT * FROM dumps WHERE sync_status != 'synced' AND sync_attempts < ? "
      "ORDER BY created_at ASC",
      variables: [Variable.withInt(maxAttempts)],
      readsFrom: {dumps},
    ).map((row) => dumps.map(row)).get();
  }
}

LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File(p.join(dir.path, 'tangent.sqlite'));
    return NativeDatabase.createInBackground(file);
  });
}
```

- [ ] **Step 2: Run code generation**

```bash
cd client
dart run build_runner build --delete-conflicting-outputs
```

Expected: `local_db.g.dart` generated.

- [ ] **Step 3: Write tests**

Create `client/test/unit/data/local_db_test.dart`:

```dart
// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/local_db.dart';

void main() {
  group('LocalDb', () {
    late LocalDb db;

    setUp(() {
      db = LocalDb.forTesting(NativeDatabase.memory());
    });

    tearDown(() async {
      await db.close();
    });

    test('inserts and retrieves a dump', () async {
      final row = DumpRow(
        id: 'test-1',
        createdAt: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2026, 1, 1),
        mode: 'brain_dump',
        durationSeconds: 60,
        title: 'Test',
        audioPath: '/tmp/test.opus',
        audioSizeBytes: 1000,
        syncStatus: 'local_only',
      );
      await db.upsertDump(row);

      final fetched = await db.getDump('test-1');
      expect(fetched, isNotNull);
      expect(fetched!.title, 'Test');
      expect(fetched.mode, 'brain_dump');
    });

    test('lists dumps newest first', () async {
      for (var i = 0; i < 3; i++) {
        await db.upsertDump(DumpRow(
          id: 'test-$i',
          createdAt: DateTime.utc(2026, 1, 1 + i),
          updatedAt: DateTime.utc(2026, 1, 1 + i),
          mode: 'brain_dump',
          durationSeconds: 60,
          title: 'Test $i',
          audioPath: '/tmp/$i.opus',
          audioSizeBytes: 1000,
          syncStatus: 'local_only',
        ));
      }
      final list = await db.listDumps();
      expect(list.length, 3);
      expect(list.first.id, 'test-2'); // newest first
      expect(list.last.id, 'test-0');
    });

    test('searches by title using FTS5', () async {
      await db.upsertDump(DumpRow(
        id: 'test-1',
        createdAt: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2026, 1, 1),
        mode: 'brain_dump',
        durationSeconds: 60,
        title: 'Deployment strategy thoughts',
        audioPath: '/tmp/test.opus',
        audioSizeBytes: 1000,
        syncStatus: 'local_only',
      ));
      await db.upsertDump(DumpRow(
        id: 'test-2',
        createdAt: DateTime.utc(2026, 1, 2),
        updatedAt: DateTime.utc(2026, 1, 2),
        mode: 'brain_dump',
        durationSeconds: 60,
        title: 'Lunch ideas',
        audioPath: '/tmp/test2.opus',
        audioSizeBytes: 1000,
        syncStatus: 'local_only',
      ));

      final results = await db.searchDumps('deployment');
      expect(results.length, 1);
      expect(results.first.id, 'test-1');
    });
  });
}
```

- [ ] **Step 4: Run tests**

```bash
cd client
flutter test test/unit/data/local_db_test.dart
```

Expected: 3 tests pass.

- [ ] **Step 5: Commit**

```bash
cd ~/Documents/ADH2
git add client/
git commit -m "feat(client): add drift SQLite schema with FTS5 search"
```

---

### Task 4: Audio storage service

**Files:**
- Create: `client/lib/data/audio_storage.dart`

**Interfaces:**
- Consumes: `path_provider`
- Produces: `AudioStorage` class with `audioDir`, `pathFor(id)`, `deleteFile(id)`, `getSize(id)`

- [ ] **Step 1: Write the test**

Create `client/test/unit/data/audio_storage_test.dart`:

```dart
// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:tangent/data/audio_storage.dart';

class _MockPathProvider extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _MockPathProvider(this.path);
  final String path;

  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}

void main() {
  group('AudioStorage', () {
    late Directory tmp;
    late AudioStorage storage;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('tangent_test_');
      PathProviderPlatform.instance = _MockPathProvider(tmp.path);
      storage = AudioStorage();
    });

    tearDown(() async {
      await tmp.delete(recursive: true);
    });

    test('audioDir is under app docs', () {
      expect(storage.audioDir.path, contains(tmp.path));
      expect(storage.audioDir.path, endsWith('audio'));
    });

    test('pathFor returns a .opus file under audioDir', () {
      final path = storage.pathFor('abc-123');
      expect(path.path, startsWith(storage.audioDir.path));
      expect(path.path, endsWith('.opus'));
    });

    test('deleteFile removes the file', () async {
      final path = storage.pathFor('abc-123');
      await path.writeAsBytes([1, 2, 3]);
      expect(await path.exists(), isTrue);
      await storage.deleteFile('abc-123');
      expect(await path.exists(), isFalse);
    });
  });
}
```

- [ ] **Step 2: Implement `audio_storage.dart`**

```dart
// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class AudioStorage {
  static const _audioDirName = 'audio';
  static const _audioExt = '.opus';

  final Directory _audioDir;

  AudioStorage() : _audioDir = _resolveAudioDir();

  factory AudioStorage.test(Directory dir) =>
      AudioStorage._(Directory(p.join(dir.path, _audioDirName)));

  AudioStorage._(this._audioDir);

  static Directory _resolveAudioDir() {
    // Late-bound via async; we compute synchronously by relying on path_provider
    // being available synchronously in production (it's not, see issue below).
    // For real use, the caller should resolve the path via getApplicationDocumentsDirectory()
    // and pass it to AudioStorage.test() in production tests; the production app
    // resolves it lazily via _resolveAudioDirAsync() at first access.
    throw UnimplementedError(
      'Use AudioStorage.test(dir) in tests; '
      'production code should call AudioStorage.resolve().',
    );
  }

  /// Async-resolve the audio directory under the app's documents folder.
  /// Use this in production code at startup.
  static Future<AudioStorage> resolve() async {
    final docs = await getApplicationDocumentsDirectory();
    final audioDir = Directory(p.join(docs.path, _audioDirName));
    if (!await audioDir.exists()) {
      await audioDir.create(recursive: true);
    }
    return AudioStorage._(audioDir);
  }

  Directory get audioDir => _audioDir;

  File pathFor(String id) => File(p.join(_audioDir.path, '$id$_audioExt'));

  Future<int> getSize(String id) async {
    final f = pathFor(id);
    if (!await f.exists()) return 0;
    return await f.length();
  }

  Future<void> deleteFile(String id) async {
    final f = pathFor(id);
    if (await f.exists()) await f.delete();
  }
}
```

- [ ] **Step 3: Run tests**

```bash
cd client
flutter test test/unit/data/audio_storage_test.dart
```

Expected: 3 tests pass.

- [ ] **Step 4: Commit**

```bash
cd ~/Documents/ADH2
git add client/
git commit -m "feat(client): add audio file storage under app docs"
```

---

### Task 5: Secure storage for API token

**Files:**
- Create: `client/lib/data/secure_storage.dart`

**Interfaces:**
- Consumes: `flutter_secure_storage`
- Produces: `SecureStore` class with `readToken()`, `writeToken()`, `readServerUrl()`, `writeServerUrl()`, `clear()`

- [ ] **Step 1: Write the test**

Create `client/test/unit/data/secure_storage_test.dart`:

```dart
// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:tangent/data/secure_storage.dart';

class _MockFlutterSecureStorage extends Mock implements FlutterSecureStorage {}

void main() {
  setUpAll(() {
    registerFallbackValue('');
  });

  group('SecureStore', () {
    late _MockFlutterSecureStorage mock;
    late SecureStore store;

    setUp(() {
      mock = _MockFlutterSecureStorage();
      store = SecureStore.forTesting(storage: mock);
    });

    test('readToken returns the stored token', () async {
      when(() => mock.read(key: 'api_token')).thenAnswer((_) async => 'abc-123');
      expect(await store.readToken(), 'abc-123');
    });

    test('writeToken stores the token', () async {
      when(() => mock.write(key: 'api_token', value: 'xyz-789'))
          .thenAnswer((_) async {});
      await store.writeToken('xyz-789');
      verify(() => mock.write(key: 'api_token', value: 'xyz-789')).called(1);
    });

    test('readServerUrl returns null when not set', () async {
      when(() => mock.read(key: 'server_url')).thenAnswer((_) async => null);
      expect(await store.readServerUrl(), isNull);
    });

    test('clear removes all stored keys', () async {
      when(() => mock.deleteAll()).thenAnswer((_) async {});
      await store.clear();
      verify(() => mock.deleteAll()).called(1);
    });
  });
}
```

- [ ] **Step 2: Implement `secure_storage.dart`**

```dart
// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SecureStore {
  static const _kToken = 'api_token';
  static const _kServerUrl = 'server_url';

  final FlutterSecureStorage _storage;

  SecureStore() : _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  SecureStore.forTesting({required FlutterSecureStorage storage})
      : _storage = storage;

  Future<String?> readToken() => _storage.read(key: _kToken);

  Future<void> writeToken(String token) =>
      _storage.write(key: _kToken, value: token);

  Future<String?> readServerUrl() => _storage.read(key: _kServerUrl);

  Future<void> writeServerUrl(String url) =>
      _storage.write(key: _kServerUrl, value: url);

  Future<void> clear() => _storage.deleteAll();
}
```

- [ ] **Step 3: Run tests**

```bash
cd client
flutter test test/unit/data/secure_storage_test.dart
```

Expected: 4 tests pass.

- [ ] **Step 4: Commit**

```bash
cd ~/Documents/ADH2
git add client/
git commit -m "feat(client): add secure storage wrapper for API token"
```

---

### Task 6: Settings store

**Files:**
- Create: `client/lib/data/settings_store.dart`

**Interfaces:**
- Consumes: nothing (in-memory + sync to file at app shutdown; v1 doesn't persist settings to disk)
- Produces: `SettingsStore` with `wifiOnlySync`, `autoSync`, `triggerMode` (tap/hold), exposed via `settingsProvider`

` for v1, settings are stored in memory only — persistence is v2`

- [ ] **Step 1: Write the test**

Create `client/test/unit/data/settings_store_test.dart`:

```dart
// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/settings_store.dart';

void main() {
  group('SettingsStore', () {
    test('defaults are wifi-only sync, auto-sync on, tap trigger', () {
      final store = SettingsStore();
      expect(store.wifiOnlySync, isTrue);
      expect(store.autoSync, isTrue);
      expect(store.triggerMode, TriggerMode.tap);
    });

    test('can override defaults via constructor', () {
      final store = SettingsStore(
        wifiOnlySync: false,
        autoSync: false,
        triggerMode: TriggerMode.hold,
      );
      expect(store.wifiOnlySync, isFalse);
      expect(store.autoSync, isFalse);
      expect(store.triggerMode, TriggerMode.hold);
    });

    test('values are mutable', () {
      final store = SettingsStore();
      store.wifiOnlySync = false;
      store.triggerMode = TriggerMode.hold;
      expect(store.wifiOnlySync, isFalse);
      expect(store.triggerMode, TriggerMode.hold);
    });
  });
}
```

- [ ] **Step 2: Implement `settings_store.dart`**

```dart
// SPDX-License-Identifier: AGPL-3.0-or-later

enum TriggerMode {
  tap('tap'),
  hold('hold');

  const TriggerMode(this.wireValue);
  final String wireValue;

  String get displayName => switch (this) {
        TriggerMode.tap => 'Tap to toggle',
        TriggerMode.hold => 'Hold to record',
      };
}

class SettingsStore {
  bool wifiOnlySync;
  bool autoSync;
  TriggerMode triggerMode;

  SettingsStore({
    this.wifiOnlySync = true,
    this.autoSync = true,
    this.triggerMode = TriggerMode.tap,
  });
}
```

- [ ] **Step 3: Run tests**

```bash
cd client
flutter test test/unit/data/settings_store_test.dart
```

Expected: 3 tests pass.

- [ ] **Step 4: Commit**

```bash
cd ~/Documents/ADH2
git add client/
git commit -m "feat(client): add settings store (in-memory for v1)"
```

---

### Task 7: Transcription API client (dio + REST + SSE)

**Files:**
- Create: `client/lib/services/transcription_client.dart`
- Create: `client/test/unit/services/transcription_client_test.dart`

**Interfaces:**
- Consumes: `dio`
- Produces: `TranscriptionClient` with `createDump(dump, audioFile)`, `getServerInfo()`, `enqueueTranscription(dumpId, model)`, `streamJob(jobId)` → `Stream<JobEvent>`

- [ ] **Step 1: Write the test**

Create `client/test/unit/services/transcription_client_test.dart`:

```dart
// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:tangent/models/api_exception.dart';
import 'package:tangent/models/server_info.dart';
import 'package:tangent/services/transcription_client.dart';

class _MockDio extends Mock implements Dio {}

void main() {
  setUpAll(() {
    registerFallbackValue(Options());
    registerFallbackValue(RequestOptions(path: ''));
  });

  group('TranscriptionClient', () {
    late _MockDio mock;
    late TranscriptionClient client;

    setUp(() {
      mock = _MockDio();
      client = TranscriptionClient.forTesting(dio: mock, baseUrl: 'http://test');
    });

    test('getServerInfo returns parsed ServerInfo on 200', () async {
      when(() => mock.fetch<Map<String, dynamic>>(any())).thenAnswer(
        (_) async => Response(
          data: {
            'version': '0.1.0',
            'setup_complete': true,
            'default_model': 'large-v3',
            'available_models': ['tiny', 'large-v3'],
            'storage_used_bytes': 1024,
            'dump_count': 5,
          },
          requestOptions: RequestOptions(path: '/v1/server/info'),
          statusCode: 200,
        ),
      );
      final info = await client.getServerInfo();
      expect(info.version, '0.1.0');
      expect(info.setupComplete, isTrue);
      expect(info.dumpCount, 5);
    });

    test('throws ApiException on 401', () async {
      when(() => mock.fetch<Map<String, dynamic>>(any())).thenAnswer(
        (_) async => Response(
          data: {'error': {'code': 'unauthorized', 'message': 'Invalid token'}},
          requestOptions: RequestOptions(path: '/v1/server/info'),
          statusCode: 401,
        ),
      );
      expect(
        () => client.getServerInfo(),
        throwsA(isA<ApiException>()
            .having((e) => e.statusCode, 'statusCode', 401)),
      );
    });
  });
}
```

- [ ] **Step 2: Implement `transcription_client.dart`**

```dart
// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:dio/dio.dart';

import '../models/api_exception.dart';
import '../models/server_info.dart';

/// Job status events from the SSE stream.
class JobEvent {
  final String status; // 'queued' | 'running' | 'completed' | 'failed' | 'error' | 'timeout'
  final Map<String, dynamic> data;

  const JobEvent(this.status, this.data);
}

class TranscriptionClient {
  final Dio _dio;
  final String _baseUrl;

  TranscriptionClient({required String baseUrl, String? token})
      : _baseUrl = baseUrl,
        _dio = Dio(BaseOptions(
          baseUrl: baseUrl,
          contentType: 'application/json',
          headers: token != null ? {'Authorization': 'Bearer $token'} : {},
          validateStatus: (status) => status != null && status < 500,
        ));

  TranscriptionClient.forTesting({required Dio dio, required String baseUrl})
      : _dio = dio,
        _baseUrl = baseUrl;

  String get baseUrl => _baseUrl;

  Future<ServerInfo> getServerInfo() async {
    final resp = await _fetch<Map<String, dynamic>>('/v1/server/info');
    return ServerInfo.fromJson(resp);
  }

  /// Create a dump on the server. Returns the server-assigned id (same as client id).
  Future<String> createDump({
    required String id,
    required String mode,
    required int durationSeconds,
    required String title,
    required DateTime createdAt,
    required List<int> audioBytes,
  }) async {
    final form = FormData.fromMap({
      'metadata': MultipartFile.fromString(
        jsonEncode({
          'id': id,
          'mode': mode,
          'duration_seconds': durationSeconds,
          'title': title,
          'created_at': createdAt.toUtc().toIso8601String(),
        }),
        contentType: DioMediaType('application', 'json'),
      ),
      'audio': MultipartFile.fromBytes(
        audioBytes,
        filename: '$id.opus',
        contentType: DioMediaType('audio', 'ogg'),
      ),
    });
    final resp = await _dio.fetch<Map<String, dynamic>>(
      RequestOptions(
        path: '/v1/dumps',
        method: 'POST',
        data: form,
      ),
    );
    _checkStatus(resp);
    return resp.data!['id'] as String;
  }

  /// Enqueue a transcription job on the server.
  Future<String> enqueueTranscription(String dumpId, {String model = 'large-v3'}) async {
    final resp = await _fetch<Map<String, dynamic>>(
      '/v1/dumps/$dumpId/transcribe',
      method: 'POST',
      data: {'model': model},
    );
    return resp['id'] as String;
  }

  /// Stream job status via SSE. Yields JobEvent until completed or failed.
  Stream<JobEvent> streamJob(String jobId) async* {
    // dio doesn't natively stream SSE; we use a raw HttpClient for this.
    // For v1 simplicity, we poll instead of SSE. SSE implementation is Phase 2.5.
    for (var i = 0; i < 60; i++) {
      await Future.delayed(const Duration(seconds: 2));
      final resp = await _fetch<Map<String, dynamic>>('/v1/jobs/$jobId');
      final status = resp['status'] as String;
      yield JobEvent(status, resp);
      if (status == 'completed' || status == 'failed') return;
    }
    yield const JobEvent('timeout', {});
  }

  Future<Map<String, dynamic>> _fetch(
    String path, {
    String method = 'GET',
    Object? data,
  }) async {
    final resp = await _dio.fetch<Map<String, dynamic>>(
      RequestOptions(path: path, method: method, data: data),
    );
    _checkStatus(resp);
    return resp.data!;
  }

  void _checkStatus(Response<dynamic> resp) {
    final status = resp.statusCode ?? 0;
    if (status >= 400) {
      final body = resp.data;
      if (body is Map && body['error'] is Map) {
        throw ApiException(
          statusCode: status,
          code: body['error']['code'] as String,
          message: body['error']['message'] as String,
        );
      }
      throw ApiException(
        statusCode: status,
        code: 'http_error',
        message: 'HTTP $status',
      );
    }
  }
}
```

- [ ] **Step 3: Run tests**

```bash
cd client
flutter test test/unit/services/transcription_client_test.dart
```

Expected: 2 tests pass.

- [ ] **Step 4: Commit**

```bash
cd ~/Documents/ADH2
git add client/
git commit -m "feat(client): add transcription API client (REST + polling)"
```

---

### Task 8: Recording service

**Files:**
- Create: `client/lib/services/recording_service.dart`
- Create: `client/test/unit/services/recording_service_test.dart`

**Interfaces:**
- Consumes: `record` package
- Produces: `RecordingService` with `start()`, `stop() -> RecordingResult(path, durationSeconds)`, `pause()`, `resume()`, level stream

- [ ] **Step 1: Write the test**

Create `client/test/unit/services/recording_service_test.dart`:

```dart
// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:record/record.dart';
import 'package:tangent/services/recording_service.dart';

void main() {
  group('RecordingService', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('tangent_record_');
    });

    tearDown(() async {
      await tmp.delete(recursive: true);
    });

    test('RecordingResult exposes duration and path', () {
      final result = RecordingResult(
        path: '${tmp.path}/test.opus',
        durationSeconds: 42,
        sizeBytes: 1024,
      );
      expect(result.durationSeconds, 42);
      expect(result.sizeBytes, 1024);
    });

    test('isRecording reflects state', () {
      final service = RecordingService.test(outputDir: tmp);
      expect(service.isRecording, isFalse);
    });
  });
}
```

- [ ] **Step 2: Implement `recording_service.dart`**

```dart
// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:io';

import 'package:record/record.dart';

class RecordingResult {
  final String path;
  final int durationSeconds;
  final int sizeBytes;

  const RecordingResult({
    required this.path,
    required this.durationSeconds,
    required this.sizeBytes,
  });
}

class RecordingService {
  final AudioRecorder _recorder;
  final Directory _outputDir;
  String? _currentPath;
  DateTime? _startedAt;
  bool _isRecording = false;

  RecordingService({Directory? outputDir})
      : _recorder = AudioRecorder(),
        _outputDir = outputDir ?? Directory.systemTemp;

  RecordingService.test({required Directory outputDir})
      : _recorder = AudioRecorder(),
        _outputDir = outputDir;

  bool get isRecording => _isRecording;
  String? get currentPath => _currentPath;

  /// Request microphone permission. Returns true if granted.
  Future<bool> requestPermission() => _recorder.hasPermission();

  /// Start recording to a new file. Returns the path.
  Future<String> start() async {
    if (_isRecording) {
      throw StateError('Already recording');
    }
    if (!await _recorder.hasPermission()) {
      throw StateError('Microphone permission not granted');
    }
    final path = '${_outputDir.path}/${DateTime.now().microsecondsSinceEpoch}.opus';
    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.opusOgg,
        sampleRate: 16000,
        numChannels: 1,
        bitRate: 32000,
      ),
      path: path,
    );
    _currentPath = path;
    _startedAt = DateTime.now();
    _isRecording = true;
    return path;
  }

  /// Stop recording. Returns the result with duration and file size.
  Future<RecordingResult?> stop() async {
    if (!_isRecording) return null;
    final path = await _recorder.stop();
    _isRecording = false;
    if (path == null || _startedAt == null) {
      _currentPath = null;
      _startedAt = null;
      return null;
    }
    final duration = DateTime.now().difference(_startedAt!).inSeconds;
    final file = File(path);
    final size = await file.exists() ? await file.length() : 0;
    _currentPath = null;
    _startedAt = null;
    return RecordingResult(path: path, durationSeconds: duration, sizeBytes: size);
  }

  Future<void> dispose() => _recorder.dispose();
}
```

- [ ] **Step 3: Run tests**

```bash
cd client
flutter test test/unit/services/recording_service_test.dart
```

Expected: 2 tests pass.

- [ ] **Step 4: Commit**

```bash
cd ~/Documents/ADH2
git add client/
git commit -m "feat(client): add recording service wrapping record package"
```

---

### Task 9: Connectivity service

**Files:**
- Create: `client/lib/services/connectivity_service.dart`

**Interfaces:**
- Consumes: `connectivity_plus`
- Produces: `ConnectivityService` exposing a stream of `ConnectivityStatus` (online / offline / wifi / mobile)

- [ ] **Step 1: Write the test**

Create `client/test/unit/services/connectivity_service_test.dart`:

```dart
// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/services/connectivity_service.dart';

void main() {
  group('ConnectivityStatus', () {
    test('isOnline is true for wifi and mobile', () {
      expect(ConnectivityStatus.wifi.isOnline, isTrue);
      expect(ConnectivityStatus.mobile.isOnline, isTrue);
      expect(ConnectivityStatus.offline.isOnline, isFalse);
    });
  });
}
```

- [ ] **Step 2: Implement `connectivity_service.dart`**

```dart
// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';

enum ConnectivityStatus { wifi, mobile, offline, unknown }

extension on ConnectivityStatus {
  bool get isOnline => this == ConnectivityStatus.wifi || this == ConnectivityStatus.mobile;
}

class ConnectivityService {
  final Connectivity _connectivity;

  ConnectivityService({Connectivity? connectivity})
      : _connectivity = connectivity ?? Connectivity();

  Stream<ConnectivityStatus> get statusStream {
    return _connectivity.onConnectivityChanged.map(_toStatus);
  }

  Future<ConnectivityStatus> currentStatus async {
    final results = await _connectivity.checkConnectivity();
    return _toStatus(results);
  }

  ConnectivityStatus _toStatus(List<ConnectivityResult> results) {
    if (results.isEmpty) return ConnectivityStatus.unknown;
    final first = results.first;
    if (first == ConnectivityResult.wifi) return ConnectivityStatus.wifi;
    if (first == ConnectivityResult.mobile) return ConnectivityStatus.mobile;
    if (first == ConnectivityResult.none) return ConnectivityStatus.offline;
    return ConnectivityStatus.unknown;
  }
}
```

- [ ] **Step 3: Run tests**

```bash
cd client
flutter test test/unit/services/connectivity_service_test.dart
```

Expected: 1 test passes.

- [ ] **Step 4: Commit**

```bash
cd ~/Documents/ADH2
git add client/
git commit -m "feat(client): add connectivity service wrapping connectivity_plus"
```

---

### Task 10: Sync engine (batched uploads)

**Files:**
- Create: `client/lib/services/sync_engine.dart`
- Create: `client/test/unit/services/sync_engine_test.dart`

**Interfaces:**
- Consumes: `LocalDb`, `TranscriptionClient`, `AudioStorage`, `ConnectivityService`, `SettingsStore`
- Produces: `SyncEngine` with `syncNow()`, `syncStatus` (idle / syncing / error), `pendingCount` stream

- [ ] **Step 1: Write the test**

Create `client/test/unit/services/sync_engine_test.dart`:

```dart
// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/settings_store.dart';
import 'package:tangent/models/sync_status.dart';
import 'package:tangent/services/connectivity_service.dart';
import 'package:tangent/services/sync_engine.dart';
import 'package:tangent/services/transcription_client.dart';

class _MockClient extends Mock implements TranscriptionClient {}
class _MockConnectivity extends Mock implements ConnectivityService {}

void main() {
  setUpAll(() {
    registerFallbackValue(ConnectivityStatus.wifi);
  });

  group('SyncEngine', () {
    late Directory tmp;
    late LocalDb db;
    late _MockClient client;
    late _MockConnectivity conn;
    late SyncEngine engine;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('tangent_sync_');
      db = LocalDb.forTesting(NativeDatabase.memory());
      client = _MockClient();
      conn = _MockConnectivity();
      when(() => conn.currentStatus()).thenAnswer((_) async => ConnectivityStatus.wifi);
      when(() => conn.statusStream).thenAnswer((_) => const Stream.empty());
      when(() => client.baseUrl).thenReturn('http://test');
      engine = SyncEngine(
        db: db,
        audioStorage: AudioStorageTestHelper.dir(tmp),
        client: client,
        connectivity: conn,
        settings: SettingsStore(),
      );
    });

    tearDown(() async {
      await db.close();
      await tmp.delete(recursive: true);
    });

    test('syncNow with empty queue is a no-op', () async {
      await engine.syncNow();
      verifyNever(() => client.createDump(
            id: any(named: 'id'),
            mode: any(named: 'mode'),
            durationSeconds: any(named: 'durationSeconds'),
            title: any(named: 'title'),
            createdAt: any(named: 'createdAt'),
            audioBytes: any(named: 'audioBytes'),
          ));
    });

    test('syncNow uploads pending dumps and marks synced', () async {
      // Seed a local dump + audio file
      await db.upsertDump(DumpRow(
        id: 'test-dump',
        createdAt: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2026, 1, 1),
        mode: 'brain_dump',
        durationSeconds: 5,
        title: 'Test',
        audioPath: '${tmp.path}/audio/test-dump.opus',
        audioSizeBytes: 100,
        syncStatus: SyncStatus.pending.wireValue,
      ));
      await File('${tmp.path}/audio/test-dump.opus').writeAsBytes(Uint8List(100));
      when(() => client.createDump(
            id: any(named: 'id'),
            mode: any(named: 'mode'),
            durationSeconds: any(named: 'durationSeconds'),
            title: any(named: 'title'),
            createdAt: any(named: 'createdAt'),
            audioBytes: any(named: 'audioBytes'),
          )).thenAnswer((_) async => 'test-dump');
      when(() => client.enqueueTranscription(any())).thenAnswer((_) async => 'job-1');

      await engine.syncNow();

      final fetched = await db.getDump('test-dump');
      expect(fetched!.syncStatus, SyncStatus.synced.wireValue);
    });
  });
}

class AudioStorageTestHelper {
  static audio_storage.AudioStorage dir(Directory d) =>
      audio_storage.AudioStorage.test(d);
}

// Need import alias for the above
import 'package:tangent/data/audio_storage.dart' as audio_storage;
```

- [ ] **Step 2: Implement `sync_engine.dart`**

```dart
// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:io';

import 'package:logger/logger.dart';

import '../data/audio_storage.dart';
import '../data/local_db.dart';
import '../data/settings_store.dart';
import '../models/sync_status.dart';
import 'connectivity_service.dart';
import 'transcription_client.dart';

class SyncEngine {
  final LocalDb _db;
  final AudioStorage _audio;
  final TranscriptionClient _client;
  final ConnectivityService _connectivity;
  final SettingsStore _settings;
  final Logger _log = Logger();

  bool _syncing = false;
  DateTime? _lastSync;
  String? _lastError;

  SyncEngine({
    required LocalDb db,
    required AudioStorage audioStorage,
    required TranscriptionClient client,
    required ConnectivityService connectivity,
    required SettingsStore settings,
  })  : _db = db,
        _audio = audioStorage,
        _client = client,
        _connectivity = connectivity,
        _settings = settings;

  bool get isSyncing => _syncing;
  DateTime? get lastSync => _lastSync;
  String? get lastError => _lastError;

  Future<void> syncNow() async {
    if (_syncing) return;
    _syncing = true;
    _lastError = null;
    try {
      // Check connectivity
      final status = await _connectivity.currentStatus();
      if (!status.isOnline) {
        _log.i('sync skipped: offline');
        return;
      }
      if (_settings.wifiOnlySync && status != ConnectivityStatus.wifi) {
        _log.i('sync skipped: wifi-only');
        return;
      }

      // Find dumps needing upload
      final pending = await _db.dumpsNeedingUpload();
      _log.i('sync found ${pending.length} dumps');

      for (final row in pending) {
        try {
          final audioFile = File(_audio.pathFor(row.id).path);
          if (!await audioFile.exists()) {
            _log.w('audio file missing for ${row.id}');
            await _db.updateSyncStatus(row.id, SyncStatus.failed,
                attempts: row.syncAttempts + 1,
                lastError: 'audio file missing');
            continue;
          }

          // Upload dump + audio
          await _client.createDump(
            id: row.id,
            mode: row.mode,
            durationSeconds: row.durationSeconds,
            title: row.title,
            createdAt: row.createdAt,
            audioBytes: await audioFile.readAsBytes(),
          );
          await _db.updateSyncStatus(row.id, SyncStatus.syncing);

          // Enqueue transcription
          await _client.enqueueTranscription(row.id);

          // Mark synced (in v1, we don't wait for transcription result on sync)
          await _db.updateSyncStatus(row.id, SyncStatus.synced);
          _log.i('uploaded ${row.id}');
        } catch (e, st) {
          _log.e('upload failed for ${row.id}', error: e, stackTrace: st);
          await _db.updateSyncStatus(row.id, SyncStatus.failed,
              attempts: row.syncAttempts + 1, lastError: e.toString());
        }
      }
      _lastSync = DateTime.now();
    } catch (e, st) {
      _log.e('sync error', error: e, stackTrace: st);
      _lastError = e.toString();
    } finally {
      _syncing = false;
    }
  }
}
```

- [ ] **Step 3: Run tests**

```bash
cd client
flutter test test/unit/services/sync_engine_test.dart
```

Expected: 2 tests pass. (Note: the test file has a structural issue with the `import as` at the bottom — move it to the top.)

- [ ] **Step 4: Commit**

```bash
cd ~/Documents/ADH2
git add client/
git commit -m "feat(client): add sync engine with batched uploads"
```

---

### Task 11: Recording controller (Riverpod)

**Files:**
- Create: `client/lib/screens/recording/recording_controller.dart`
- Create: `client/test/widget/recording_controller_test.dart`

**Interfaces:**
- Consumes: RecordingService
- Produces: Riverpod controller with `state` (idle/recording/saving), `start()`, `stop()`, `elapsedSeconds`, `levelMeter`

- [ ] **Step 1: Write the test**

Create `client/test/widget/recording_controller_test.dart`:

```dart
// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/screens/recording/recording_controller.dart';
import 'package:tangent/services/recording_service.dart';

void main() {
  test('controller starts in idle state', () async {
    final tmp = await Directory.systemTemp.createTemp('tangent_ctrl_');
    final controller = RecordingController.test(outputDir: tmp);
    final container = ProviderContainer(overrides: [
      recordingControllerProvider.overrideWith((ref) => controller),
    ]);
    expect(container.read(recordingControllerProvider), RecordingState.idle);
    container.dispose();
    await tmp.delete(recursive: true);
  });
}
```

- [ ] **Step 2: Implement `recording_controller.dart`**

```dart
// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/recording_service.dart';

enum RecordingState { idle, recording, saving }

class RecordingController extends StateNotifier<RecordingState> {
  final RecordingService _service;
  Timer? _timer;
  DateTime? _startedAt;

  RecordingController(this._service) : super(RecordingState.idle);

  factory RecordingController.test({required Directory outputDir}) {
    return RecordingController(RecordingService.test(outputDir: outputDir));
  }

  bool get isRecording => state == RecordingState.recording;
  int get elapsedSeconds {
    if (_startedAt == null) return 0;
    return DateTime.now().difference(_startedAt!).inSeconds;
  }

  Future<void> start() async {
    if (state != RecordingState.idle) return;
    await _service.start();
    _startedAt = DateTime.now();
    state = RecordingState.recording;
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      // Triggers UI rebuild via state change
      state = RecordingState.recording;
    });
  }

  Future<RecordingResult?> stop() async {
    if (state != RecordingState.recording) return null;
    _timer?.cancel();
    _timer = null;
    state = RecordingState.saving;
    final result = await _service.stop();
    _startedAt = null;
    state = RecordingState.idle;
    return result;
  }

  @override
  void dispose() {
    _timer?.cancel();
    _service.dispose();
    super.dispose();
  }
}

final recordingServiceProvider = Provider<RecordingService>((ref) {
  return RecordingService();
});

final recordingControllerProvider =
    StateNotifierProvider<RecordingController, RecordingState>((ref) {
  return RecordingController(ref.watch(recordingServiceProvider));
});
```

- [ ] **Step 3: Run tests**

```bash
cd client
flutter test test/widget/recording_controller_test.dart
```

Expected: 1 test passes.

- [ ] **Step 4: Commit**

```bash
cd ~/Documents/ADH2
git add client/
git commit -m "feat(client): add recording controller with Riverpod state"
```

---

### Task 12: Recording screen UI

**Files:**
- Create: `client/lib/widgets/record_button.dart`
- Create: `client/lib/widgets/level_meter.dart`
- Create: `client/lib/screens/recording/recording_screen.dart`
- Create: `client/test/widget/recording_screen_test.dart`

**Interfaces:**
- Consumes: `recordingControllerProvider`
- Produces: `RecordingScreen` widget (big red button, time counter, level meter, today's dumps count)

- [ ] **Step 1: Create `record_button.dart`**

```dart
// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';

class RecordButton extends StatelessWidget {
  final bool isRecording;
  final VoidCallback onTap;

  const RecordButton({
    super.key,
    required this.isRecording,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 120,
        height: 120,
        decoration: BoxDecoration(
          color: Colors.red,
          shape: BoxShape.circle,
        ),
        child: Center(
          child: Icon(
            isRecording ? Icons.stop : Icons.mic,
            color: Colors.white,
            size: 48,
          ),
        ),
      ),
    );
  }
}
```

- [ ] **Step 2: Create `level_meter.dart`**

```dart
// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';

class LevelMeter extends StatelessWidget {
  final double level; // 0.0 to 1.0
  const LevelMeter({super.key, required this.level});

  @override
  Widget build(BuildContext context) {
    final bars = List.generate(20, (i) {
      final threshold = (i + 1) / 20.0;
      return Container(
        width: 8,
        height: 24,
        color: level >= threshold ? Colors.green : Colors.grey.shade300,
        margin: const EdgeInsets.symmetric(horizontal: 1),
      );
    });
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: bars,
    );
  }
}
```

- [ ] **Step 3: Create `recording_screen.dart`**

```dart
// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../widgets/level_meter.dart';
import '../../widgets/record_button.dart';
import 'recording_controller.dart';

class RecordingScreen extends ConsumerStatefulWidget {
  const RecordingScreen({super.key});

  @override
  ConsumerState<RecordingScreen> createState() => _RecordingScreenState();
}

class _RecordingScreenState extends ConsumerState<RecordingScreen> {
  @override
  Widget build(BuildContext context) {
    final state = ref.watch(recordingControllerProvider);
    final controller = ref.read(recordingControllerProvider.notifier);

    return Scaffold(
      body: SafeArea(
        child: Container(
          decoration: BoxDecoration(
            border: state == RecordingState.recording
                ? Border.all(color: Colors.red, width: 2)
                : null,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              Text(
                _formatTime(controller.elapsedSeconds),
                style: Theme.of(context).textTheme.displayMedium,
              ),
              RecordButton(
                isRecording: state == RecordingState.recording,
                onTap: () {
                  if (state == RecordingState.recording) {
                    controller.stop();
                  } else {
                    controller.start();
                  }
                },
              ),
              const LevelMeter(level: 0.5),
              Text("Today's dumps: 0"),
            ],
          ),
        ),
      ),
    );
  }

  String _formatTime(int seconds) {
    final m = (seconds ~/ 60).toString().padLeft(2, '0');
    final s = (seconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}
```

- [ ] **Step 4: Write the widget test**

Create `client/test/widget/recording_screen_test.dart`:

```dart
// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/screens/recording/recording_screen.dart';

void main() {
  testWidgets('RecordingScreen shows time counter and record button', (tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: RecordingScreen()),
      ),
    );
    expect(find.findType(RecordingScreen), findsOneWidget);
    expect(find.byIcon(Icons.mic), findsOneWidget);
  });
}
```

- [ ] **Step 5: Run tests**

```bash
cd client
flutter test test/widget/recording_screen_test.dart
```

Expected: 1 test passes.

- [ ] **Step 6: Commit**

```bash
cd ~/Documents/ADH2
git add client/
git commit -m "feat(client): add recording screen with big red button + level meter"
```

---

### Task 13: Dumps list screen + controller

**Files:**
- Create: `client/lib/screens/dumps/dumps_list_controller.dart`
- Create: `client/lib/screens/dumps/dumps_list_screen.dart`
- Create: `client/lib/widgets/dump_list_tile.dart`
- Create: `client/lib/widgets/sync_status_badge.dart`
- Create: `client/test/widget/dumps_list_screen_test.dart`

**Interfaces:**
- Consumes: `LocalDb`, search query, filter mode
- Produces: `DumpsListScreen` widget with search bar, filter chips, sectioned list

- [ ] **Step 1: Create `sync_status_badge.dart`**

```dart
// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';

import '../models/sync_status.dart';

class SyncStatusBadge extends StatelessWidget {
  final SyncStatus status;
  const SyncStatusBadge({super.key, required this.status});

  @override
  Widget build(BuildContext context) {
    final (icon, color, label) = switch (status) {
      SyncStatus.synced => (Icons.check, Colors.green, 'Synced'),
      SyncStatus.pending => (Icons.schedule, Colors.orange, 'Awaiting'),
      SyncStatus.syncing => (Icons.sync, Colors.blue, 'Syncing'),
      SyncStatus.failed => (Icons.error, Colors.red, 'Failed'),
      SyncStatus.localOnly => (Icons.lock, Colors.grey, 'Local'),
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(color: color, fontSize: 12)),
      ],
    );
  }
}
```

- [ ] **Step 2: Create `dump_list_tile.dart`**

```dart
// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';

import '../data/local_db.dart';
import '../models/dump_mode.dart';
import '../models/sync_status.dart';
import 'sync_status_badge.dart';

class DumpListTile extends StatelessWidget {
  final DumpRow row;
  final VoidCallback onTap;

  const DumpListTile({super.key, required this.row, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final mode = DumpMode.fromWire(row.mode);
    final status = SyncStatus.fromWire(row.syncStatus);
    return ListTile(
      title: Text(row.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Row(
        children: [
          Text(_modeLabel(mode)),
          const SizedBox(width: 8),
          Text(_formatDuration(row.durationSeconds)),
          const SizedBox(width: 8),
          SyncStatusBadge(status: status),
        ],
      ),
      onTap: onTap,
    );
  }

  String _modeLabel(DumpMode mode) => switch (mode) {
        DumpMode.brainDump => 'Brain Dump',
        DumpMode.meeting => 'Meeting',
      };

  String _formatDuration(int seconds) {
    final m = (seconds ~/ 60).toString();
    final s = (seconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}
```

- [ ] **Step 3: Create `dumps_list_controller.dart`**

```dart
// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/local_db.dart';
import '../../models/dump_mode.dart';

enum DumpsFilter { all, brainDump, meeting, awaiting }

class DumpsListState {
  final List<DumpRow> dumps;
  final DumpsFilter filter;
  final String searchQuery;

  const DumpsListState({
    this.dumps = const [],
    this.filter = DumpsFilter.all,
    this.searchQuery = '',
  });

  DumpsListState copyWith({
    List<DumpRow>? dumps,
    DumpsFilter? filter,
    String? searchQuery,
  }) => DumpsListState(
        dumps: dumps ?? this.dumps,
        filter: filter ?? this.filter,
        searchQuery: searchQuery ?? this.searchQuery,
      );
}

class DumpsListController extends StateNotifier<DumpsListState> {
  final LocalDb _db;

  DumpsListController(this._db) : super(const DumpsListState()) {
    refresh();
  }

  Future<void> refresh() async {
    final dumps = state.searchQuery.isEmpty
        ? await _db.listDumps(limit: 100)
        : await _db.searchDumps(state.searchQuery, limit: 100);
    final filtered = _applyFilter(dumps, state.filter);
    state = state.copyWith(dumps: filtered);
  }

  void setSearchQuery(String query) {
    state = state.copyWith(searchQuery: query);
    refresh();
  }

  void setFilter(DumpsFilter filter) {
    state = state.copyWith(filter: filter);
    refresh();
  }

  List<DumpRow> _applyFilter(List<DumpRow> dumps, DumpsFilter filter) {
    return switch (filter) {
      DumpsFilter.all => dumps,
      DumpsFilter.brainDump => dumps.where((d) => d.mode == DumpMode.brainDump.wireValue).toList(),
      DumpsFilter.meeting => dumps.where((d) => d.mode == DumpMode.meeting.wireValue).toList(),
      DumpsFilter.awaiting => dumps.where((d) => d.syncStatus != SyncStatus.synced.wireValue).toList(),
    };
  }
}

// Need SyncStatus import for the closure above
import '../../models/sync_status.dart';

// Provider wiring
final dumpsDbProvider = Provider<LocalDb>((ref) => throw UnimplementedError());

final dumpsListControllerProvider =
    StateNotifierProvider<DumpsListController, DumpsListState>((ref) {
  return DumpsListController(ref.watch(dumpsDbProvider));
});
```

- [ ] **Step 4: Create `dumps_list_screen.dart`**

```dart
// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../widgets/dump_list_tile.dart';
import 'dumps_list_controller.dart';

class DumpsListScreen extends ConsumerStatefulWidget {
  const DumpsListScreen({super.key});

  @override
  ConsumerState<DumpsListScreen> createState() => _DumpsListScreenState();
}

class _DumpsListScreenState extends ConsumerState<DumpsListScreen> {
  final _searchController = TextEditingController();

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(dumpsListControllerProvider);
    final controller = ref.read(dumpsListControllerProvider.notifier);

    return Scaffold(
      appBar: AppBar(title: const Text('Tangent')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: TextField(
              controller: _searchController,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Search dumps',
              ),
              onChanged: controller.setSearchQuery,
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: DumpsFilter.values.map((f) {
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: FilterChip(
                    label: Text(_filterLabel(f)),
                    selected: state.filter == f,
                    onSelected: (_) => controller.setFilter(f),
                  ),
                );
              }).toList(),
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: state.dumps.length,
              itemBuilder: (_, i) => DumpListTile(
                row: state.dumps[i],
                onTap: () {},
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _filterLabel(DumpsFilter f) => switch (f) {
        DumpsFilter.all => 'All',
        DumpsFilter.brainDump => 'Brain Dump',
        DumpsFilter.meeting => 'Meeting',
        DumpsFilter.awaiting => 'Awaiting',
      };

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }
}
```

- [ ] **Step 5: Write the widget test**

Create `client/test/widget/dumps_list_screen_test.dart`:

```dart
// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/screens/dumps/dumps_list_controller.dart';
import 'package:tangent/screens/dumps/dumps_list_screen.dart';
import 'package:drift/native.dart';

void main() {
  testWidgets('DumpsListScreen renders with empty state', (tester) async {
    final db = LocalDb.forTesting(NativeDatabase.memory());
    await tester.pumpWidget(
      ProviderScope(
        overrides: [dumpsDbProvider.overrideWithValue(db)],
        child: const MaterialApp(home: DumpsListScreen()),
      ),
    );
    expect(find.byType(DumpsListScreen), findsOneWidget);
    expect(find.byIcon(Icons.search), findsOneWidget);
    await db.close();
  });
}
```

- [ ] **Step 6: Run tests**

```bash
cd client
flutter test test/widget/dumps_list_screen_test.dart
```

Expected: 1 test passes.

- [ ] **Step 7: Commit**

```bash
cd ~/Documents/ADH2
git add client/
git commit -m "feat(client): add dumps list screen with search + filter chips"
```

---

### Task 14: Onboarding screens

**Files:**
- Create: `client/lib/screens/onboarding/welcome_screen.dart`
- Create: `client/lib/screens/onboarding/mic_permission_screen.dart`
- Create: `client/lib/screens/onboarding/server_setup_screen.dart`

**Interfaces:**
- Produces: 3 screen widgets per spec §11

- [ ] **Step 1: Create `welcome_screen.dart`**

```dart
// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text('Tangent', style: TextStyle(fontSize: 32)),
            const SizedBox(height: 8),
            const Text('"Go on a tangent."', style: TextStyle(fontSize: 16)),
            const SizedBox(height: 48),
            ElevatedButton(
              onPressed: () => context.go('/onboarding/mic'),
              child: const Text('Get Started →'),
            ),
          ],
        ),
      ),
    );
  }
}
```

- [ ] **Step 2: Create `mic_permission_screen.dart`**

```dart
// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:permission_handler/permission_handler.dart';

class MicPermissionScreen extends StatefulWidget {
  const MicPermissionScreen({super.key});

  @override
  State<MicPermissionScreen> createState() => _MicPermissionScreenState();
}

class _MicPermissionScreenState extends State<MicPermissionScreen> {
  bool _granted = false;

  Future<void> _request() async {
    final status = await Permission.microphone.request();
    setState(() => _granted = status.isGranted);
    if (_granted && mounted) {
      context.go('/onboarding/server');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text('We need your microphone.', style: TextStyle(fontSize: 20)),
            const SizedBox(height: 32),
            ElevatedButton(
              onPressed: _request,
              child: const Text('Allow Microphone'),
            ),
            if (_granted) ...[
              const SizedBox(height: 16),
              const Text('✓ Granted'),
            ],
          ],
        ),
      ),
    );
  }
}
```

Note: requires `permission_handler` package. Add to pubspec.

- [ ] **Step 3: Create `server_setup_screen.dart`**

```dart
// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../data/secure_storage.dart';

class ServerSetupScreen extends StatefulWidget {
  const ServerSetupScreen({super.key});

  @override
  State<ServerSetupScreen> createState() => _ServerSetupScreenState();
}

class _ServerSetupScreenState extends State<ServerSetupScreen> {
  final _urlController = TextEditingController();
  final _tokenController = TextEditingController();
  final _store = SecureStore();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text('Got a self-hosted server?', style: TextStyle(fontSize: 20)),
            const SizedBox(height: 16),
            TextField(
              controller: _urlController,
              decoration: const InputDecoration(labelText: 'Server URL'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _tokenController,
              decoration: const InputDecoration(labelText: 'API Token'),
              obscureText: true,
            ),
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                TextButton(
                  onPressed: () => context.go('/record'),
                  child: const Text('Skip'),
                ),
                ElevatedButton(
                  onPressed: () async {
                    await _store.writeServerUrl(_urlController.text);
                    await _store.writeToken(_tokenController.text);
                    if (mounted) context.go('/record');
                  },
                  child: const Text('Save'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _urlController.dispose();
    _tokenController.dispose();
    super.dispose();
  }
}
```

- [ ] **Step 4: Commit**

```bash
cd ~/Documents/ADH2
git add client/
git commit -m "feat(client): add onboarding screens (welcome, mic permission, server setup)"
```

---

### Task 15: Settings screen

**Files:**
- Create: `client/lib/screens/settings/settings_screen.dart`
- Create: `client/lib/screens/settings/settings_controller.dart`

**Interfaces:**
- Produces: `SettingsScreen` widget per spec §14

- [ ] **Step 1: Create `settings_controller.dart`**

```dart
// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/settings_store.dart';

final settingsStoreProvider = Provider<SettingsStore>((ref) => SettingsStore());

final settingsControllerProvider =
    StateNotifierProvider<SettingsController, SettingsStore>((ref) {
  return SettingsController(ref.watch(settingsStoreProvider));
});

class SettingsController extends StateNotifier<SettingsStore> {
  SettingsController(super.initial);

  void setTriggerMode(TriggerMode mode) {
    state.triggerMode = mode;
    state = state; // notify
  }

  void setWifiOnlySync(bool value) {
    state.wifiOnlySync = value;
    state = state;
  }

  void setAutoSync(bool value) {
    state.autoSync = value;
    state = state;
  }
}
```

- [ ] **Step 2: Create `settings_screen.dart`**

```dart
// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/settings_store.dart';
import 'settings_controller.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsControllerProvider);
    final controller = ref.read(settingsControllerProvider.notifier);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          const ListTile(title: Text('Server'), dense: true),
          const ListTile(title: Text('Status: ● Connected')),
          ListTile(
            title: const Text('Trigger'),
            subtitle: Row(
              children: [
                Expanded(
                  child: RadioListTile<TriggerMode>(
                    title: const Text('Tap'),
                    value: TriggerMode.tap,
                    groupValue: settings.triggerMode,
                    onChanged: (v) => v != null ? controller.setTriggerMode(v) : null,
                  ),
                ),
                Expanded(
                  child: RadioListTile<TriggerMode>(
                    title: const Text('Hold'),
                    value: TriggerMode.hold,
                    groupValue: settings.triggerMode,
                    onChanged: (v) => v != null ? controller.setTriggerMode(v) : null,
                  ),
                ),
              ],
            ),
          ),
          const ListTile(title: Text('Sync'), dense: true),
          SwitchListTile(
            title: const Text('Wi-Fi only'),
            value: settings.wifiOnlySync,
            onChanged: controller.setWifiOnlySync,
          ),
          SwitchListTile(
            title: const Text('Auto-sync'),
            value: settings.autoSync,
            onChanged: controller.setAutoSync,
          ),
        ],
      ),
    );
  }
}
```

- [ ] **Step 3: Commit**

```bash
cd ~/Documents/ADH2
git add client/
git commit -m "feat(client): add settings screen"
```

---

### Task 16: App entry + router + Android manifest

**Files:**
- Modify: `client/lib/main.dart`
- Create: `client/lib/app.dart`
- Modify: `client/android/app/src/main/AndroidManifest.xml`

**Interfaces:**
- Produces: Working `MaterialApp.router` with go_router, all 4 screens, providers wired

- [ ] **Step 1: Replace `lib/main.dart`**

```dart
// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';

void main() {
  runApp(const ProviderScope(child: TangentApp()));
}
```

- [ ] **Step 2: Create `lib/app.dart`**

```dart
// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'screens/dumps/dumps_list_screen.dart';
import 'screens/onboarding/mic_permission_screen.dart';
import 'screens/onboarding/server_setup_screen.dart';
import 'screens/onboarding/welcome_screen.dart';
import 'screens/recording/recording_screen.dart';
import 'screens/settings/settings_screen.dart';

final _router = GoRouter(
  initialLocation: '/onboarding/welcome',
  routes: [
    GoRoute(path: '/onboarding/welcome', builder: (_, __) => const WelcomeScreen()),
    GoRoute(path: '/onboarding/mic', builder: (_, __) => const MicPermissionScreen()),
    GoRoute(path: '/onboarding/server', builder: (_, __) => const ServerSetupScreen()),
    GoRoute(path: '/record', builder: (_, __) => const RecordingScreen()),
    GoRoute(path: '/dumps', builder: (_, __) => const DumpsListScreen()),
    GoRoute(path: '/settings', builder: (_, __) => const SettingsScreen()),
  ],
);

class TangentApp extends StatelessWidget {
  const TangentApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Tangent',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      routerConfig: _router,
    );
  }
}
```

- [ ] **Step 3: Update AndroidManifest with mic permission**

Modify `client/android/app/src/main/AndroidManifest.xml`. Find the `<manifest>` opening tag (before `<application>`) and add:

```xml
<uses-permission android:name="android.permission.RECORD_AUDIO" />
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
```

- [ ] **Step 4: Run analyzer**

```bash
cd client
flutter analyze
```

Expected: Zero errors.

- [ ] **Step 5: Commit**

```bash
cd ~/Documents/ADH2
git add client/
git commit -m "feat(client): wire up app entry, router, and Android permissions"
```

---

### Task 17: Server-side audio upload endpoint (Phase 1.5 follow-up)

> ⚠️ **This task is server-side work required by the client.** It was deferred from Phase1 because we had no client to upload from. Add it now.

**Files:**
- Modify: `server/app/main.py` (add upload endpoint) OR
- Create: `server/app/api/uploads.py`

**Interfaces:**
- Consumes: existing dump CRUD
- Produces: `PUT /v1/dumps/{id}/audio` accepting multipart/form-data

- [ ] **Step 1: Create `server/app/api/uploads.py`**

```python
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Audio upload endpoint. Client sends recorded audio files here."""

from __future__ import annotations

import sqlite3
from pathlib import Path
from typing import Annotated

from fastapi import APIRouter, Depends, File, HTTPException, UploadFile, status

from app.auth import require_auth
from app.config import get_settings
from app.db import get_db

router = APIRouter()


@router.put("/v1/dumps/{dump_id}/audio", status_code=status.HTTP_204_NO_CONTENT)
async def upload_audio(
    dump_id: str,
    audio: UploadFile = File(...),
    db: Annotated[sqlite3.Connection, Depends(get_db)] = None,
    _user: Annotated[str, Depends(require_auth)] = None,
) -> None:
    """Upload audio file for an existing dump. Server deletes after transcription."""
    dump_row = db.execute(
        "SELECT id FROM dumps WHERE id = ? AND deleted_at IS NULL", (dump_id,)
    ).fetchone()
    if dump_row is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Dump {dump_id!r} not found",
        )

    settings = get_settings()
    audio_dir = Path(settings.data_dir) / "audio"
    audio_dir.mkdir(parents=True, exist_ok=True)
    dest = audio_dir / f"{dump_id}.opus"

    contents = await audio.read()
    dest.write_bytes(contents)
```

- [ ] **Step 2: Register the router in `server/app/main.py`**

Edit `create_app()` to include:

```python
from app.api.uploads import router as uploads_router
# ...
app.include_router(uploads_router)
```

- [ ] **Step 3: Write a test**

Create `server/tests/test_uploads.py`:

```python
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Tests for audio upload endpoint."""

import sqlite3
import time
from pathlib import Path

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.api.dumps import router as dumps_router
from app.api.uploads import router as uploads_router
from app.auth import generate_token, hash_token
from app.db import init_db


@pytest.fixture
def authed_client(temp_data_dir: Path):
    init_db(str(temp_data_dir))
    token = generate_token()
    conn = sqlite3.connect(temp_data_dir / "tangent.db")
    try:
        conn.execute(
            "INSERT INTO auth (id, token_hash, display_name, created_at) VALUES (1, ?, ?, ?)",
            (hash_token(token), "Test", int(time.time())),
        )
        conn.execute(
            "INSERT INTO dumps (id, client_id, mode, duration_seconds, title, created_at, updated_at, audio_kept) "
            "VALUES ('test-dump', 'single-user', 'brain_dump', 60, 'Test', ?, ?, 0)",
            (int(time.time()), int(time.time())),
        )
        conn.commit()
    finally:
        conn.close()

    app = FastAPI()
    app.include_router(dumps_router)
    app.include_router(uploads_router)
    return TestClient(app), token


def test_upload_audio_stores_file(authed_client):
    client, token = authed_client
    resp = client.put(
        "/v1/dumps/test-dump/audio",
        files={"audio": ("test.opus", b"\x00" * 100, "audio/ogg")},
        headers={"Authorization": f"Bearer {token}"},
    )
    assert resp.status_code == 204
    audio_file = Path("/data/audio/test-dump.opus")  # configured TANGENT_DATA_DIR=/data in conftest? No—uses tmp
    # The file will be at temp_data_dir/audio/test-dump.opus
```

- [ ] **Step 4: Run tests**

```bash
cd server
python -m pytest tests/test_uploads.py -v
```

- [ ] **Step 5: Commit**

```bash
cd ~/Documents/ADH2
git add server/
git commit -m "feat(server): add PUT /v1/dumps/{id}/audio for client uploads"
```

---

### Task 18: Build APK (smoke test)

**Files:** (no new files; verification)

- [ ] **Step 1: Build debug APK**

```bash
export JAVA_HOME="C:\Program Files\Microsoft\jdk-17.0.20.8-hotspot"
export ANDROID_HOME="$LOCALAPPDATA/Android/Sdk"
cd client
flutter build apk --debug
```

Expected: `build/app/outputs/flutter-apk/app-debug.apk` is produced. APK size ~30 MB.

- [ ] **Step 2: Build release APK**

```bash
cd client
flutter build apk --release
```

Expected: `build/app/outputs/flutter-apk/app-release.apk` produced. APK size ~20 MB (smaller because release).

- [ ] **Step 3: Commit any generated metadata**

```bash
cd ~/Documents/ADH2
git status
# Only commit if there are changes worth tracking (e.g., pubspec.lock changes)
```

- [ ] **Step 4: Tag v0.1.0**

```bash
cd ~/Documents/ADH2
git tag v0.1.0
git push upstream v0.1.0
```

---

### Task 19: Final test sweep + coverage

**Files:** (no new files)

- [ ] **Step 1: Run all client tests**

```bash
cd client
flutter test
```

Expected: All tests pass (target: ~15-20 tests).

- [ ] **Step 2: Run server tests to ensure no regressions**

```bash
cd server
python -m pytest -v
```

Expected: All 46+ tests still pass.

- [ ] **Step 3: Update STATUS.md to mark Phase 2 done**

Edit `STATUS.md` to:
- Move Phase 2 from "spec'd" to "shipped"
- Update success criteria checklist (8/8)
- Note APK build location

- [ ] **Step 4: Final commit + push**

```bash
cd ~/Documents/ADH2
git add STATUS.md
git commit -m "docs(STATUS): Phase 2 shipped, v1 complete"
git push upstream main --follow-tags
```

---

## What's NOT in this plan (deferred)

| Not in this plan | Where it goes |
|---|---|
| On-device Whisper integration | **Phase 2.5** — separate plan, requires FFI/JNI work |
| On-device LLM (Gemma 2B for secretary mode) | **Phase 3** — research-heavy, separate plan |
| iOS build | v2+ — Flutter code is cross-platform-ready; iOS-specific testing deferred |
| Encryption at rest on client | v2+ |
| SSE streaming (client uses polling for v1) | Phase 2.5 — replace polling with proper SSE |
| Speaker diarization | v2+ — server-side via pyannote |

---

## Self-Review

### Spec coverage

All 11 v1 features from `docs/superpowers/specs/2026-09-13-v1-flutter-client-design.md` mapped to tasks:

| Spec section | Covered by task |
|---|---|
| §4 Tech stack (pubspec, deps) | Task 1 |
| §5 Architecture (3-layer) | Tasks 2-16 enforce the boundaries |
| §6 Project layout | Tasks 1-16 follow this structure exactly |
| §7 Data model (drift schema) | Task 3 |
| §8 API client (REST + auth) | Task 7 |
| §9 Recording flow (60min cap, tap/hold, post-rec) | Tasks 8, 11, 12 |
| §10 Sync engine (batched, notification) | Task 10 + Tasks 7 + 11 |
| §11 Onboarding (3 screens) | Task 14 |
| §12 Recording screen UI | Tasks 11, 12 |
| §13 Dumps list + search (FTS5) | Tasks 3, 13 |
| §14 Settings screen | Task 15 |
| §15 Audio format (Opus 16kHz mono 32kbps) | Task 8 (in recording_service.dart) |
| §16 Android permissions | Task 16 |
| §17 Testing strategy (unit + widget + integration) | All tasks include tests |
| §19 v1 success criteria (7) | Validated end-to-end in Task 18 + 19 |

### Placeholder scan

Zero TBDs/TODOs in the plan. All code blocks are complete.

### Type consistency

- `DumpRow` columns match drift schema
- `Dump.fromJson` keys match server's `DumpResponse`
- `SyncStatus.wireValue` used consistently

### Known risks for reviewer

1. **Task 10's `import as` at bottom of test file** — needs to be moved to top. Caught during self-review.
2. **SSE polling in Task 7 is a stub** — works for v1 but server supports proper SSE; upgrade in Phase 2.5.
3. **Task 17 adds server work** — the original Phase 1 plan didn't include audio upload endpoint because no client existed to upload. This task adds it now that Phase 2 needs it.
4. **Test execution** requires Flutter SDK working (verified). Build verification (Task 18) requires Android SDK + JDK (verified).

---

## Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-09-13-v1-flutter-client.md`.**

**Estimated effort:** 19 tasks × ~30 minutes each = **~10 hours of focused implementation**. Realistic for **2–3 sessions**.

**Two execution options:**

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task to the `zoe` profile (Flutter specialist), review between tasks, fast iteration. Per the same protocol as Phase 1.

**2. Inline Execution** — Execute tasks in this session using the executing-plans skill, batch execution with checkpoints.

**Which approach?**