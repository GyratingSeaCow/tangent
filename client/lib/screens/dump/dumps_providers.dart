// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/local_db.dart';
import '../../models/transcription_status.dart';
import '../../screens/home/home_screen.dart' show localDbProvider;

enum DumpModeFilter { all, brainDump, meeting }

extension DumpModeFilterX on DumpModeFilter {
  String get label => switch (this) {
        DumpModeFilter.all => 'All',
        DumpModeFilter.brainDump => 'Brain Dump',
        DumpModeFilter.meeting => 'Meeting',
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
