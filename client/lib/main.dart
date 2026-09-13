// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'data/audio_storage.dart';
import 'data/local_db.dart';
import 'data/secure_storage.dart';
import 'screens/home/home_providers.dart';
import 'screens/home/home_screen.dart';
import 'screens/server/server_connection_screen.dart';
import 'services/transcription_client.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Resolve the audio storage directory. This will land in the public
  // Documents/Tangent/ folder if storage permissions are granted, otherwise
  // it falls back to the app's internal directory (which is wiped on uninstall).
  final audio = await AudioStorage.fromDirectoryFallback(
    await getApplicationDocumentsDirectory(),
  );

  final store = SecureStore();
  final url = await store.getServerUrl();
  final token = await store.getToken();
  final client = TranscriptionClient(
    baseUrl: url ?? 'http://10.0.2.2:8000',
    token: token,
  );

  final db = LocalDb();

  // Import any audio files that already exist in the storage directory
  // (e.g. from a previous install) into the local DB. Each orphan file
  // becomes a 'pending' dump awaiting title + transcription.
  await _importOrphanAudio(db, audio);

  runApp(
    ProviderScope(
      overrides: [
        secureStoreProvider.overrideWithValue(store),
        transcriptionClientProvider.overrideWithValue(client),
        localDbProvider.overrideWithValue(db),
        audioStorageProvider.overrideWithValue(audio),
      ],
      child: const TangentApp(),
    ),
  );
}

/// Walk the audio dir and register any .opus files that aren't in the DB.
Future<void> _importOrphanAudio(LocalDb db, AudioStorage audio) async {
  try {
    final orphans = await audio.listAll();
    if (orphans.isEmpty) return;
    final known = <String>{
      for (final row in await db.listDumps(limit: 10000)) row.id,
    };
    for (final o in orphans) {
      if (known.contains(o.id)) continue;
      await db.upsertDump(DumpRow(
        id: o.id,
        createdAt: o.modifiedAt,
        updatedAt: o.modifiedAt,
        mode: 'brain_dump',
        durationSeconds: 0,
        title: '',
        audioPath: o.file.path,
        audioSizeBytes: o.sizeBytes,
        syncStatus: 'pending',
        syncAttempts: 0,
      ));
    }
  } catch (_) {
    // Import is best-effort; missing storage access shouldn't crash startup.
  }
}

class TangentApp extends StatelessWidget {
  const TangentApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
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
      // Route used by pushReplacementNamed() from server_connection_screen
      // after a successful connection test. Without this entry, Flutter
      // throws "Could not find a generator for route /home".
      routes: {
        '/home': (_) => const HomeScreen(),
      },
    );
  }
}

class _Router extends ConsumerWidget {
  const _Router();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Read with a 3s timeout. If secure storage hangs (rare, but seen on some
    // Samsung Android 13+ devices when Tink/keystore service is slow to boot),
    // fall back to the server-connection screen rather than spinning forever.
    final urlFuture = ref.read(secureStoreProvider).getServerUrl().timeout(
      const Duration(seconds: 3),
      onTimeout: () => null,
    );
    return FutureBuilder<String?>(
      future: urlFuture,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        final url = snap.data;
        if (url == null || url.isEmpty) {
          return const ServerConnectionScreen();
        }
        return const HomeScreen();
      },
    );
  }
}