// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/local_db.dart';
import '../../data/storage/storage_contract.dart';
import '../../models/transcription_status.dart';
import '../../screens/home/home_screen.dart' show localDbProvider;

import 'dart:convert';
import '../../data/storage/storage_providers.dart';
import '../../services/synced_audio_download.dart';
import '../../screens/home/home_providers.dart'
    show connectivityServiceProvider;
import '../../screens/server/server_connection_screen.dart'
    show transcriptionClientProvider;
import '../../screens/settings/settings_screen.dart' show settingsStoreProvider;

/// Builds the audio downloader against the currently selected folder.
///
/// Returns null while no folder is available: without one there is nowhere
/// to publish, and offering a download that cannot land would be a lying
/// control. The UI reads null as "not offerable yet".
final syncedAudioDownloaderProvider =
    Provider<SyncedAudioDownloader?>((Ref ref) {
  final AsyncValue<DefaultFolderState> folder =
      ref.watch(defaultFolderProvider);
  final StorageLocation? location = folder.valueOrNull?.location;
  if (location == null || folder.valueOrNull?.available != true) return null;

  return SyncedAudioDownloader(
    db: ref.watch(localDbProvider),
    backend: ref.watch(storageBackendProvider),
    location: location,
    fetch: (String dumpId) =>
        ref.read(transcriptionClientProvider).downloadAudio(dumpId),
    // Read at fetch time, not construction: the user may flip either between
    // opening the list and tapping download.
    wifiOnly: () async => ref.read(settingsStoreProvider).wifiOnlySync,
    connection: () => ref.read(connectivityServiceProvider).currentStatus(),
  );
});

/// True when this row's audio lives only on the server.
///
/// Both halves matter: `audioOnServer` says the bytes exist to fetch, and
/// `remoteOnly` says this device does not already hold them. A row failing
/// either is not downloadable, and the action must not be offered.
bool dumpNeedsAudioDownload(DumpRow row) =>
    row.audioOnServer == true && row.remoteOnly == true;

class _PresentedEpoch {
  int generation = 0;
}

final _presentedEpochProvider = Provider<_PresentedEpoch>((ref) {
  final epoch = _PresentedEpoch();
  ref.listen(searchQueryProvider, (_, __) => epoch.generation++);
  ref.listen(dumpModeFilterProvider, (_, __) => epoch.generation++);
  ref.listen(transcriptFilterProvider, (_, __) => epoch.generation++);
  return epoch;
});

final presentedDumpsProvider =
    Provider<AsyncValue<PresentedDumpResults>>((ref) {
  final epoch = ref.watch(_presentedEpochProvider);
  final query = ref.watch(searchQueryProvider);
  final mode = ref.watch(dumpModeFilterProvider);
  final transcript = ref.watch(transcriptFilterProvider);
  final search = query.trim().isNotEmpty;
  final source = search
      ? ref.watch(searchResultsProvider)
      : ref.watch(filteredDumpsProvider);
  final settled = source.hasValue && !source.isLoading && !source.hasError;
  final PresentedDumpResults results = (
    scopeKey: jsonEncode([query, mode.name, transcript.name]),
    generation: epoch.generation,
    settled: settled,
    rows: List.unmodifiable(settled ? source.requireValue : <DumpRow>[]),
    limit: search ? 100 : null,
  );
  if (source.hasError) {
    return AsyncError<PresentedDumpResults>(source.error!, source.stackTrace!)
        .copyWithPrevious(AsyncData(results));
  }
  return AsyncData(results);
});

final deletionEligibilityProvider = StreamProvider<Map<String, Eligibility>>(
  (ref) => ref.watch(localDeletionServiceProvider).watchEligibility(),
);

enum DumpModeFilter { all, brainDump, meeting, textNote }

extension DumpModeFilterX on DumpModeFilter {
  String get label => switch (this) {
        DumpModeFilter.all => 'All',
        DumpModeFilter.brainDump => 'Brain Dump',
        DumpModeFilter.meeting => 'Meeting',
        DumpModeFilter.textNote => 'Text Note',
      };
}

enum TranscriptFilter { all, needsTranscript, inProgress, transcribed, failed }

extension TranscriptFilterX on TranscriptFilter {
  String get label => switch (this) {
        TranscriptFilter.all => 'All',
        TranscriptFilter.needsTranscript => 'Needs transcript',
        TranscriptFilter.inProgress => 'In progress',
        TranscriptFilter.transcribed => 'Transcribed',
        TranscriptFilter.failed => 'Failed',
      };
}

List<DumpRow> filterDumps(
  Iterable<DumpRow> rows,
  DumpModeFilter modeFilter,
  TranscriptFilter transcriptFilter,
) {
  return rows.where((row) {
    final modeMatches = switch (modeFilter) {
      DumpModeFilter.all => true,
      DumpModeFilter.brainDump => row.mode == 'brain_dump',
      DumpModeFilter.meeting => row.mode == 'meeting',
      DumpModeFilter.textNote => row.mode == 'text_note',
    };
    final status = TranscriptionStatus.fromWire(row.transcriptionStatus);
    final transcriptMatches = switch (transcriptFilter) {
      TranscriptFilter.all => true,
      TranscriptFilter.needsTranscript =>
        status == TranscriptionStatus.notTranscribed,
      TranscriptFilter.inProgress => status.isInProgress,
      TranscriptFilter.transcribed => status == TranscriptionStatus.completed,
      TranscriptFilter.failed => status == TranscriptionStatus.failed,
    };
    return modeMatches && transcriptMatches;
  }).toList(growable: false);
}

/// These providers intentionally are not auto-disposed so both selections
/// survive detail-screen navigation for the lifetime of the app process.
final dumpModeFilterProvider =
    StateProvider<DumpModeFilter>((_) => DumpModeFilter.all);
final transcriptFilterProvider =
    StateProvider<TranscriptFilter>((_) => TranscriptFilter.all);

/// Watch all dumps ordered by created_at DESC.
final dumpsProvider = StreamProvider<List<DumpRow>>((ref) {
  final db = ref.watch(localDbProvider);
  return db.watchAllDumps();
});

final filteredDumpsProvider = Provider<AsyncValue<List<DumpRow>>>((ref) {
  final modeFilter = ref.watch(dumpModeFilterProvider);
  final transcriptFilter = ref.watch(transcriptFilterProvider);
  return ref.watch(dumpsProvider).whenData(
        (rows) => filterDumps(rows, modeFilter, transcriptFilter),
      );
});

/// Reactive search across title + transcript, constrained by both filters.
final searchQueryProvider = StateProvider<String>((_) => '');

/// Per-row snippet + match count for the active search (search-depth spec
/// §2). Keyed by dump id; empty while no search is active. Kept separate
/// from [searchResultsProvider] so the row list is unaffected by it.
final searchMatchesProvider =
    StreamProvider<Map<String, DumpSearchMatch>>((ref) {
  final query = ref.watch(searchQueryProvider);
  if (query.trim().isEmpty) {
    return Stream.value(const <String, DumpSearchMatch>{});
  }
  return ref.watch(localDbProvider).watchSearchDumpMatches(query.trim());
});

final searchResultsProvider = StreamProvider<List<DumpRow>>((ref) {
  final query = ref.watch(searchQueryProvider);
  final modeFilter = ref.watch(dumpModeFilterProvider);
  final transcriptFilter = ref.watch(transcriptFilterProvider);
  final db = ref.watch(localDbProvider);
  if (query.trim().isEmpty) return Stream.value(const <DumpRow>[]);
  return db.watchSearchDumps(query.trim(), limit: 100).map(
        (rows) => filterDumps(rows, modeFilter, transcriptFilter),
      );
});
