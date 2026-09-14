// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/local_db.dart';
import '../../models/sync_status.dart';
import '../../screens/home/home_screen.dart' show localDbProvider;

enum DumpFilter { all, brainDump, meeting, awaiting }

extension DumpFilterX on DumpFilter {
  String get label => switch (this) {
        DumpFilter.all => 'All',
        DumpFilter.brainDump => 'Brain Dump',
        DumpFilter.meeting => 'Meeting',
        DumpFilter.awaiting => 'Awaiting',
      };
}

List<DumpRow> filterDumps(Iterable<DumpRow> rows, DumpFilter filter) {
  return rows.where((row) {
    return switch (filter) {
      DumpFilter.all => true,
      DumpFilter.brainDump => row.mode == 'brain_dump',
      DumpFilter.meeting => row.mode == 'meeting',
      DumpFilter.awaiting => row.syncStatus != SyncStatus.synced.wireValue &&
          row.syncStatus != SyncStatus.localOnly.wireValue,
    };
  }).toList(growable: false);
}

/// This provider intentionally is not auto-disposed so selection survives
/// detail-screen navigation for the lifetime of the app process.
final dumpFilterProvider = StateProvider<DumpFilter>((_) => DumpFilter.all);

/// Watch all dumps ordered by created_at DESC.
final dumpsProvider = StreamProvider<List<DumpRow>>((ref) {
  final db = ref.watch(localDbProvider);
  return db.watchAllDumps();
});

final filteredDumpsProvider = Provider<AsyncValue<List<DumpRow>>>((ref) {
  final filter = ref.watch(dumpFilterProvider);
  return ref.watch(dumpsProvider).whenData((rows) => filterDumps(rows, filter));
});

/// Reactive search across title + transcript, constrained by the active filter.
final searchQueryProvider = StateProvider<String>((_) => '');

final searchResultsProvider = FutureProvider<List<DumpRow>>((ref) async {
  final query = ref.watch(searchQueryProvider);
  final filter = ref.watch(dumpFilterProvider);
  final db = ref.watch(localDbProvider);
  if (query.trim().isEmpty) return <DumpRow>[];
  final rows = await db.searchDumps(query.trim(), limit: 100);
  return filterDumps(rows, filter);
});
