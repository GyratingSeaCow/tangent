// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'data/audio_storage.dart';
import 'data/local_db.dart';
import 'data/recording_metadata.dart';
import 'data/secure_storage.dart';
import 'data/settings_store.dart';
import 'screens/home/home_providers.dart';
import 'screens/home/home_screen.dart';
import 'screens/server/server_connection_screen.dart';
import 'screens/settings/settings_screen.dart';
import 'services/transcription_client.dart';

final storageReadyProvider = StateProvider<bool>((ref) => false);

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

  if (audio.isReady) await importDurableRecordings(db, audio);

  runApp(
    ProviderScope(
      overrides: [
        secureStoreProvider.overrideWithValue(secureStore),
        transcriptionClientProvider.overrideWith((ref) => client),
        localDbProvider.overrideWithValue(db),
        audioStorageProvider.overrideWithValue(audio),
        settingsStoreProvider.overrideWithValue(settings),
        storageReadyProvider.overrideWith((ref) => audio.isReady),
      ],
      child: const TangentApp(),
    ),
  );
}

Future<void> importDurableRecordings(LocalDb db, AudioStorage audio) async {
  final recordings = await audio.listAll();
  for (final recording in recordings) {
    if (await db.getDump(recording.id) != null) continue;
    await db.upsertDump(
      importedDumpRow(
        id: recording.id,
        locator: recording.locator,
        sizeBytes: recording.sizeBytes,
        modifiedAt: recording.modifiedAt,
        metadata: recording.metadata,
      ),
    );
  }
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

  void _reconcileAfterStartup(Duration _) {
    if (!mounted) return;
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
    if (!ref.watch(storageReadyProvider)) {
      return const StorageSetupScreen();
    }
    return const HomeScreen();
  }
}

class StorageSetupScreen extends ConsumerStatefulWidget {
  const StorageSetupScreen({super.key});

  @override
  ConsumerState<StorageSetupScreen> createState() => _StorageSetupScreenState();
}

class _StorageSetupScreenState extends ConsumerState<StorageSetupScreen> {
  bool _choosing = false;
  String? _error;

  Future<void> _choose() async {
    setState(() {
      _choosing = true;
      _error = null;
    });
    try {
      final audio = ref.read(audioStorageProvider);
      if (!await audio.requestAccess()) return;
      await importDurableRecordings(ref.read(localDbProvider), audio);
      unawaited(
        ref.read(serverTranscriptionServiceProvider).reconcilePending(),
      );
      ref.read(storageReadyProvider.notifier).state = true;
    } catch (error) {
      if (mounted) setState(() => _error = 'Folder access failed: $error');
    } finally {
      if (mounted) setState(() => _choosing = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Choose recording folder')),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.folder_open, size: 72),
              const SizedBox(height: 24),
              const Text(
                'Tangent needs a public folder so recordings survive uninstall. '
                'Choose Documents (recommended) or the existing Tangent folder. '
                'Tangent will only access that folder.',
                textAlign: TextAlign.center,
              ),
              if (_error != null) ...[
                const SizedBox(height: 16),
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: _choosing ? null : _choose,
                icon: const Icon(Icons.folder),
                label: Text(_choosing ? 'Opening…' : 'Choose folder'),
              ),
              const SizedBox(height: 12),
              const Text(
                'Recording is disabled until durable folder access is granted.',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
}
