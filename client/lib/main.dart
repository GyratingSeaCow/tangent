// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'theme/tangent_theme.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'data/audio_storage.dart';
import 'data/local_db.dart';

import 'data/storage/filesystem_storage_backend.dart';
import 'data/storage/saf_storage_backend.dart';
import 'data/storage/recording_access.dart';
import 'data/storage/recording_mutation_coordinator.dart';
import 'data/storage/storage_catalog.dart';
import 'data/storage/recording_importer.dart';
import 'data/storage/local_deletion_service.dart';
import 'data/storage/storage_providers.dart';
import 'data/secure_storage.dart';
import 'data/settings_store.dart';
import 'screens/home/home_providers.dart';
import 'screens/home/home_screen.dart';
import 'screens/recording/recording_controller.dart';
import 'screens/server/server_connection_screen.dart';
import 'screens/settings/settings_screen.dart';
import 'package:workmanager/workmanager.dart';

import 'package:device_info_plus/device_info_plus.dart';

import 'services/background_sync_scheduler.dart';
import 'services/connectivity_service.dart';
import 'services/document_sync_engine.dart';
import 'services/platform_audio.dart';
import 'services/transcription_client.dart';

/// Device label for the background isolate, which cannot reach the app's
/// providers. Duplicated deliberately rather than shared: the UI copy lives
/// behind a provider this isolate has no access to.
Future<String> _backgroundDeviceLabel() async {
  try {
    final AndroidDeviceInfo info = await DeviceInfoPlugin().androidInfo;
    final String model = info.model.trim();
    return model.isNotEmpty ? model : 'Android device';
  } catch (_) {
    return 'Android device';
  }
}

/// Entry point for WorkManager's background isolate.
///
/// This runs in a SEPARATE isolate with no access to the app's providers, so
/// it builds its own database handle, client, and engine from scratch. That
/// is the whole reason the sync engine takes its dependencies by injection.
///
/// Must be a top-level function annotated for tree-shaking, or the release
/// build drops it and the task silently never fires.
@pragma('vm:entry-point')
void backgroundSyncDispatcher() {
  Workmanager().executeTask((String task, Map<String, dynamic>? input) async {
    if (task != kDocumentSyncTaskName) return true;
    LocalDb? db;
    try {
      WidgetsFlutterBinding.ensureInitialized();
      final SecureStore store = SecureStore();
      final String? url = await store.getServerUrl();
      final String? token = await store.getToken();
      // Never paired, so there is nothing to sync with. Reporting success
      // keeps the schedule alive for when the user does pair.
      if (url == null || token == null) return true;

      db = LocalDb();
      final LocalDb handle = db;
      final DocumentSyncEngine engine = DocumentSyncEngine(
        db: () => handle,
        client: () => TranscriptionClient(baseUrl: url, token: token),
        connectivity: ConnectivityService(),
        deviceLabel: _backgroundDeviceLabel,
        newDeviceId: const Uuid().v4(),
      );
      final SyncReport report = await engine.syncNow();
      engine.dispose();
      // Returning false asks Android to retry with backoff. A transient
      // failure deserves that; being offline does not, since the network
      // constraint will fire the task again anyway.
      return report.outcome != SyncOutcome.failed;
    } catch (_) {
      // Never let a background failure crash the isolate: Android would treat
      // repeated crashes as a reason to stop scheduling the task at all.
      return false;
    } finally {
      await db?.close();
    }
  });
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Desktop playback backend. Must precede any AudioPlayer construction,
  // which providers below can trigger.
  initPlatformAudio();

  final appDocuments = await getApplicationDocumentsDirectory();
  final temp = await getTemporaryDirectory();
  final audio = await AudioStorage.resolve(
    durableDirectory: appDocuments,
    stagingDirectory: Directory('${temp.path}/TangentStaging'),
  );

  final secureStore = SecureStore();
  String? url;
  String? token;
  try {
    url = await secureStore.getServerUrl();
    token = await secureStore.getToken();
  } catch (e) {
    // Linux without a Secret Service (KWallet/gnome-keyring): reads throw.
    // Startup must not die before runApp — launch unpaired; the connect
    // screen surfaces the same failure with an explanation when opened.
    debugPrint('tangent.secure-storage unavailable at startup: $e');
  }
  final client = TranscriptionClient(
    baseUrl: url ?? 'http://10.0.2.2:8000',
    token: token,
  );
  final db = LocalDb();
  final settings = await SettingsStore.load();
  // Periodic background sync. Registered before the UI so a user who opens
  // the app once and never returns still gets background syncs.
  if (Platform.isAndroid) {
    final Workmanager workmanager = Workmanager();
    await workmanager.initialize(backgroundSyncDispatcher);
    await registerPeriodicDocumentSync(workmanager);
  }
  final backend =
      Platform.isAndroid ? SafStorageBackend() : FilesystemStorageBackend();
  final mutations = DefaultRecordingMutationCoordinator(db: db);
  // Heal receipts orphaned by server resurrection BEFORE fences restore:
  // a zombie receipt admitted into the coordinator fences its live row for
  // the whole session.
  await db.repairResurrectedRetirements();
  await mutations.restoreFences(unsettled: await backend.unsettledUses());
  final access = BoundRecordingAccess(
    db: db,
    backend: backend,
    mutations: mutations,
  );
  final catalog = SqliteStorageCatalog(
    db: db,
    backend: backend,
    mutations: mutations,
    stagingDirectory: audio.stagingDir.path,
    idFactory: const Uuid().v4,
    now: DateTime.now,
    canChooseDefault: Platform.isAndroid,
  );
  final importer = BoundRecordingImporter(
    db: db,
    backend: backend,
    mutations: mutations,
  );
  final deletion = DefaultLocalDeletionService(
    db: db,
    backend: backend,
    mutations: mutations,
  );

  runApp(
    ProviderScope(
      overrides: [
        secureStoreProvider.overrideWithValue(secureStore),
        transcriptionClientProvider.overrideWith((ref) => client),
        localDbProvider.overrideWithValue(db),
        storageAudioStorageProvider.overrideWithValue(audio),
        storageBackendProvider.overrideWithValue(backend),
        recordingMutationsProvider.overrideWithValue(mutations),
        recordingAccessProvider.overrideWithValue(access),
        storageCatalogProvider.overrideWithValue(catalog),
        recordingImporterProvider.overrideWithValue(importer),
        localDeletionServiceProvider.overrideWithValue(deletion),
        settingsStoreProvider.overrideWithValue(settings),
      ],
      child: const TangentApp(),
    ),
  );
}

class TangentApp extends StatelessWidget {
  const TangentApp({super.key});

  @override
  Widget build(BuildContext context) {
    return _TranscriptionLifecycleHost(
      child: MaterialApp(
        // The stock DEBUG ribbon reads as a defect on a device in hand;
        // debug builds are self-evident to us without it.
        debugShowCheckedModeBanner: false,
        title: 'Tangent',
        // Tangent ships one theme: an instrument does not restyle itself
        // with the system setting.
        theme: tangentTheme(),
        darkTheme: tangentTheme(),
        themeMode: ThemeMode.dark,
        home: const _Router(),
        routes: {'/home': (_) => const HomeScreen()},
      ),
    );
  }
}

class _TranscriptionLifecycleHost extends ConsumerStatefulWidget {
  const _TranscriptionLifecycleHost({required this.child});

  final Widget child;

  @override
  ConsumerState<_TranscriptionLifecycleHost> createState() =>
      _TranscriptionLifecycleHostState();
}

class _TranscriptionLifecycleHostState
    extends ConsumerState<_TranscriptionLifecycleHost>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback(_reconcileAfterStartup);
  }

  void _reconcileAfterStartup(Duration _) async {
    if (!mounted) return;
    try {
      await ref.read(storageBootstrapProvider.future);
    } catch (_) {
      // Library and Settings remain usable; storage providers expose failures.
    }
    if (!mounted) return;
    ref.read(transcriptionRecoveryOwnerProvider);
    // Subscribes the notification shade to transcription progress for the
    // whole session. Without this read the notifier is never constructed and
    // the feature silently does nothing while every test still passes.
    ref.read(transcriptionNotificationOwnerProvider);
    // Auto-sync: from here on, edits push themselves a few seconds after the
    // user pauses — the sync button is a manual override, not a requirement.
    ref.read(autoSyncOwnerProvider);
    unawaited(ref.read(serverTranscriptionServiceProvider).reconcilePending());
    // The scheduler's registration comment promises "a foreground sync at
    // startup" — this is it. Cold launch must not show yesterday's notebooks
    // for up to 30 minutes while edits from the other device sit on the
    // server.
    unawaited(ref.read(documentSyncEngineProvider).syncNow());
    // The 7-day trash promise is enforced here, once per launch. Purging in
    // the background task instead would race the user browsing the trash.
    // A failed purge is deferred, not fatal: the rows keep until next launch.
    unawaited(
      ref.read(localDbProvider).purgeExpiredTrash().catchError((Object e) {
        debugPrint('tangent.trash purge deferred: $e');
        return 0;
      }),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // The background sync isolate writes through its own DB connection,
      // which this connection's stream watchers cannot observe. Resume is
      // the moment the user looks at the screen again — re-emit the synced
      // tables so notebooks pulled while the app slept actually appear.
      unawaited(ref.read(localDbProvider).refreshExternalWrites());
      // Fresh eyes deserve fresh data: without this, an edit made on the
      // other device inside the last half hour sits invisible until the
      // 30-minute background task happens to fire. The engine refuses
      // reentrancy, so colliding with a running cycle is a no-op.
      unawaited(ref.read(documentSyncEngineProvider).syncNow());
      // A storage grant revoked-then-restored writes no DB row, so the
      // default-folder watcher latches "unavailable" until something makes
      // it look again. Resume is exactly when a re-grant comes back (the
      // user returns from Settings), so look again now. Guarded read: the
      // catalog's dependency chain includes main()-overridden providers
      // that hosts without full storage wiring (widget tests) don't supply,
      // and a lifecycle observer must not crash the app over a recheck.
      try {
        unawaited(ref.read(storageCatalogProvider).recheckDefault());
      } on UnimplementedError {
        // No storage wiring in this host; nothing to recheck.
      }
      unawaited(
        ref.read(serverTranscriptionServiceProvider).reconcilePending(),
      );
      // Re-apply the Bluetooth headset route so SCO is up before the user
      // reaches for record. Routing at record time proved too late on device:
      // the recorder binds its input stream before the asynchronous route
      // lands, so capture stayed on the built-in mic.
      unawaited(ref.read(recordingServiceProvider).warmRoute());
    } else if (state == AppLifecycleState.paused) {
      // Release it while idle so the phone does not sit in call-audio mode,
      // which degrades music playback and pins the headset to its low-quality
      // SCO profile. Never releases during an active recording.
      unawaited(ref.read(recordingServiceProvider).releaseRouteIfIdle());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _Router extends ConsumerWidget {
  const _Router();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return const HomeScreen();
  }
}
