// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'data/audio_storage.dart';
import 'data/local_db.dart';
import 'data/secure_storage.dart';
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

  runApp(
    ProviderScope(
      overrides: [
        secureStoreProvider.overrideWithValue(store),
        transcriptionClientProvider.overrideWithValue(client),
        localDbProvider.overrideWithValue(db),
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
    final url = ref.read(secureStoreProvider).getServerUrl();
    if (url == null) {
      return const ServerConnectionScreen();
    }
    return const HomeScreen();
  }
}

// Make sure imports are used (silence lint)
// ignore: unused_element
final _ = AudioStorage;