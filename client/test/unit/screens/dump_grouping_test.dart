// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/screens/dump/dump_grouping.dart';
import 'package:tangent/screens/notebook/notebook_grouping.dart';

import '../../support/dump_view_fixture.dart';

void main() {
  test('pinned recordings lead only their own folder and unpin restores order',
      () {
    List<DumpSection> grouped({required bool secondPinned}) => groupDumps(
          dumps: <DumpRow>[
            viewRowInFolder('first', 'work'),
            viewRowInFolder('second', 'work').copyWith(
              pinned: Value<bool?>(secondPinned),
            ),
            viewRowInFolder('third', 'work').copyWith(
              pinned: const Value<bool?>(true),
            ),
            viewRow('loose', pinned: true),
          ],
          folders: const <FolderSummary>[
            FolderSummary(id: 'work', name: 'Work'),
          ],
        );

    expect(
      grouped(secondPinned: true).first.dumps.map((DumpRow row) => row.id),
      <String>['second', 'third', 'first'],
    );
    expect(
      grouped(secondPinned: true).last.dumps.map((DumpRow row) => row.id),
      <String>['loose'],
      reason: 'a pin never moves a recording out of its existing group',
    );
    expect(
      grouped(secondPinned: false).first.dumps.map((DumpRow row) => row.id),
      <String>['third', 'first', 'second'],
      reason: 'unpin restores caller order among ordinary rows',
    );
  });
}
