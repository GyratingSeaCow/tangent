// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/screens/dump/dump_selection_controller.dart';
import '../../../support/dump_view_fixture.dart';

void main() {
  test('stable IDs include offscreen rows, prune and reject stale scopes', () {
    final c = DumpSelectionController();
    addTearDown(c.dispose);
    final rows = List.generate(120, (i) => viewRow('fixture-$i'));
    final eligible = {for (final r in rows) r.id: Eligibility.eligible};
    c.apply((
      scopeKey: 'all',
      generation: 1,
      settled: true,
      rows: rows,
      limit: null
    ), eligible,);
    c.enter('fixture-0');
    c.toggleAll();
    expect(c.state.selectedIds, hasLength(120));
    c.apply((
      scopeKey: 'all',
      generation: 1,
      settled: true,
      rows: [viewRow('new'), ...rows.reversed],
      limit: null
    ), {
      ...eligible,
      'new': Eligibility.eligible,
    });
    expect(c.state.selectedIds, hasLength(120));
    expect(c.state.selectedIds, isNot(contains('new')));
    c.apply((
      scopeKey: 'all',
      generation: 1,
      settled: true,
      rows: rows.skip(1).toList(),
      limit: null
    ), {
      ...eligible,
      'fixture-1': Eligibility.busy,
    });
    expect(c.state.selectedIds, isNot(contains('fixture-0')));
    expect(c.state.selectedIds, isNot(contains('fixture-1')));
    c.apply(
        (scopeKey: 'all', generation: 1, settled: false, rows: [], limit: null),
        eligible,);
    expect(c.state.selectedIds, hasLength(118));
    c.toggleAll();
    expect(c.state.selectedIds, hasLength(118));
    c.apply((
      scopeKey: 'search',
      generation: 2,
      settled: false,
      rows: [],
      limit: 100
    ), eligible,);
    expect(c.state.selectedIds, isEmpty);
    c.apply((
      scopeKey: 'all',
      generation: 1,
      settled: true,
      rows: rows,
      limit: null
    ), eligible,);
    expect(c.state.scopeKey, 'search');
    expect(c.state.selectedIds, isEmpty);
    c.cancel();
    expect(c.state.active, isFalse);
  });
}
