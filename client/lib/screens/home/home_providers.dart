// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/audio_storage.dart';
import '../../services/connectivity_service.dart';
import '../../services/sync_engine.dart';
import '../server/server_connection_screen.dart'
    show transcriptionClientProvider;
import '../settings/settings_screen.dart' show settingsStoreProvider;
import 'home_screen.dart' show localDbProvider;

/// Provider for AudioStorage. Production wires this up in main().
final audioStorageProvider = Provider<AudioStorage>((ref) {
  throw UnimplementedError('Override in main()');
});

final connectivityServiceProvider = Provider<ConnectivityService>((ref) {
  return ConnectivityService();
});

/// Sync engine instance.
final syncEngineProvider = Provider<SyncEngine>((ref) {
  return SyncEngine(
    db: ref.watch(localDbProvider),
    audioStorage: ref.watch(audioStorageProvider),
    client: ref.watch(transcriptionClientProvider),
    connectivity: ref.watch(connectivityServiceProvider),
    settings: ref.watch(settingsStoreProvider),
  );
});