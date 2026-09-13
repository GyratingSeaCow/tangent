// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/local_db.dart';
import '../../screens/home/home_screen.dart' show localDbProvider;

/// Watch all dumps ordered by created_at DESC.
final dumpsProvider = StreamProvider<List<DumpRow>>((ref) {
  final db = ref.watch(localDbProvider);
  return db.watchAllDumps();
});

/// Reactive search across title + transcript (FTS5).
final searchQueryProvider = StateProvider<String>((_) => '');

final searchResultsProvider = FutureProvider<List<DumpRow>>((ref) async {
  final query = ref.watch(searchQueryProvider);
  final db = ref.watch(localDbProvider);
  if (query.trim().isEmpty) return <DumpRow>[];
  return db.searchDumps(query.trim(), limit: 100);
});