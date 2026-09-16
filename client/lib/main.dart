// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
import 'screens/server/server_connection_screen.dart';
import 'screens/settings/settings_screen.dart';
import 'services/transcription_client.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final appDocuments = await getApplicationDocumentsDirectory();
  final temp = await getTemporaryDirectory();
  final audio = await AudioStorage.resolve(
    durableDirectory: appDocuments,
    stagingDirectory: Directory('${temp.path}/TangentStaging'),
  );

  final secureStore = SecureStore();
  final url = await secureStore.getServerUrl();
  final token = await secureStore.getToken();
  final client = TranscriptionClient(
    baseUrl: url ?? 'http://10.0.2.2:8000',
    token: token,
  );
  final db = LocalDb();
  final settings = await SettingsStore.load();
  final backend =
      Platform.isAndroid ? SafStorageBackend() : FilesystemStorageBackend();
  final mutations = DefaultRecordingMutationCoordinator(db: db);
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
        title: 'Tangent',
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
          useMaterial3: true,
        ),
        darkTheme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.indigo,
            brightness: Brightness.dark,
          ),
          useMaterial3: true,
        ),
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
    unawaited(ref.read(serverTranscriptionServiceProvider).reconcilePending());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(
        ref.read(serverTranscriptionServiceProvider).reconcilePending(),
      );
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
