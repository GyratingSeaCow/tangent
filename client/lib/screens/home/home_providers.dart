// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../data/audio_storage.dart';
import '../../services/android_audio_decoder.dart';
import '../../services/connectivity_service.dart';
import '../../services/local_transcription_coordinator.dart';
import '../../services/on_device_transcription.dart';
import '../../services/recording_playback.dart';
import '../../services/sync_engine.dart';
import '../../services/whisper_local_runtime.dart';
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

final onDeviceTranscriptionProvider = Provider<OnDeviceTranscriptionService>(
  (ref) => OnDeviceTranscriptionService(
    decoder: const AndroidAudioDecoder(),
    runtime: WhisperLocalRuntime(),
    temporaryDirectory: getTemporaryDirectory,
  ),
);

final localTranscriptionCoordinatorProvider =
    ChangeNotifierProvider<LocalTranscriptionCoordinator>((ref) {
  return LocalTranscriptionCoordinator(
    service: ref.watch(onDeviceTranscriptionProvider),
    db: ref.watch(localDbProvider),
    audioStorage: ref.watch(audioStorageProvider),
  );
});

final recordingPlaybackEngineFactoryProvider =
    Provider<RecordingPlaybackEngine Function()>((ref) {
  return JustAudioRecordingPlaybackEngine.new;
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
