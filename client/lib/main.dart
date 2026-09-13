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

  final store = SecureStore();
  final url = await store.getServerUrl();
  final token = await store.getToken();
  final client = TranscriptionClient(
    baseUrl: url ?? 'http://10.0.2.2:8000',
    token: token,
  );

  final db = LocalDb();
  final docsDir = await getApplicationDocumentsDirectory();
  final audio = AudioStorage.fromDirectory(docsDir);

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
    );
  }
}

class _Router extends ConsumerWidget {
  const _Router();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final urlFuture = ref.read(secureStoreProvider).getServerUrl();
    return FutureBuilder<String?>(
      future: urlFuture,
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        if (snap.data == null) {
          return const ServerConnectionScreen();
        }
        return const HomeScreen();
      },
    );
  }
}