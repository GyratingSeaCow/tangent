// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/local_db.dart';
import '../../data/storage/storage_contract.dart';
import '../../models/transcription_status.dart';
import '../../screens/home/home_screen.dart' show localDbProvider;

import 'dart:convert';
import '../../data/storage/storage_providers.dart';

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
