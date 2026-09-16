// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/screens/dump/dumps_providers.dart';
import '../support/dump_view_fixture.dart';

final data = StateProvider<AsyncValue<List<DumpRow>>>(
    (_) => AsyncData([viewRow('fixture-a')]),);
void main() {
  test(
      'presented scope tracks raw query and each filter, not ordinary rows; retained loading is not settled',
      () {
    final c = ProviderContainer(overrides: [
      filteredDumpsProvider.overrideWith((ref) => ref.watch(data)),
      searchResultsProvider.overrideWith((_) => const Stream.empty()),
    ],);
    addTearDown(c.dispose);
    final sub = c.listen(presentedDumpsProvider, (_, __) {});
    addTearDown(sub.close);
    final first = c.read(presentedDumpsProvider).requireValue;
    expect(first.rows.single.id, 'fixture-a');
    expect(first.settled, isTrue);
    c.read(data.notifier).state = AsyncData([viewRow('fixture-b')]);
    expect(c.read(presentedDumpsProvider).requireValue.generation,
        first.generation,);
    c.read(data.notifier).state =
        const AsyncLoading<List<DumpRow>>().copyWithPrevious(c.read(data));
    expect(c.read(presentedDumpsProvider).requireValue.settled, isFalse);
    var last = c.read(presentedDumpsProvider).requireValue;
    for (final q in ['query', ' query', 'query ']) {
      c.read(searchQueryProvider.notifier).state = q;
      final next = c.read(presentedDumpsProvider).requireValue;
      expect(next.generation, greaterThan(last.generation));
      expect(next.scopeKey, isNot(last.scopeKey));
      expect(next.limit, 100);
      expect(next.settled, isFalse);
      last = next;
    }
    c.read(dumpModeFilterProvider.notifier).state = DumpModeFilter.meeting;
    final mode = c.read(presentedDumpsProvider).requireValue;
    expect(mode.generation, greaterThan(last.generation));
    c.read(transcriptFilterProvider.notifier).state = TranscriptFilter.failed;
    expect(c.read(presentedDumpsProvider).requireValue.generation,
        greaterThan(mode.generation),);
  });
}
