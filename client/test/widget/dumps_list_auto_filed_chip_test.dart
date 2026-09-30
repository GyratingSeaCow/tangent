// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The auto-file receipt (spec 2026-09-30, queued item #3): when the server
// filed a capture, its card shows "Auto-filed to <folder> · Undo"; Undo
// moves it back. An unsure server files nothing, so no chip ever exists —
// zero noise. The chip also hides when the named folder no longer exists:
// a receipt pointing nowhere is worse than none.
import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/local_db.dart';

import '../support/dump_selection_fixture.dart';
import '../support/dump_view_fixture.dart';
import '../support/fake_folders_db.dart';
import 'dumps_list_folders_test.dart' show mountWithFolders;

class _UndoTrackingDb extends FakeFoldersDb {
  final List<String> undone = <String>[];

  @override
  Future<void> undoAutoFile(String dumpId) async {
    undone.add(dumpId);
  }
}

DumpRow _autoFiledRow(String id, String folderId) =>
    viewRowInFolder(id, folderId).copyWith(autoFiledAt: const Value<int?>(1234));

void main() {
  testWidgets('an auto-filed row shows the chip with its folder name',
      (tester) async {
    final _UndoTrackingDb db = _UndoTrackingDb()
      ..seedFolder(Folder(id: 'f-1', name: 'Woodworking', createdAt: 1));
    addTearDown(db.dispose);
    await mountWithFolders(
      tester,
      rows: <DumpRow>[_autoFiledRow('d-1', 'f-1')],
      db: db,
    );

    expect(find.byKey(const ValueKey('auto-filed-chip-d-1')), findsOneWidget);
    expect(find.text('Auto-filed to Woodworking'), findsOneWidget);
    expect(find.text('Undo'), findsOneWidget);
  });

  testWidgets('a filed row without the marker shows no chip', (tester) async {
    final _UndoTrackingDb db = _UndoTrackingDb()
      ..seedFolder(Folder(id: 'f-1', name: 'Woodworking', createdAt: 1));
    addTearDown(db.dispose);
    await mountWithFolders(
      tester,
      rows: <DumpRow>[viewRowInFolder('d-1', 'f-1')],
      db: db,
    );

    expect(find.byKey(const ValueKey('auto-filed-chip-d-1')), findsNothing);
    expect(find.text('Undo'), findsNothing);
  });

  testWidgets('tapping Undo asks the db to move the capture back',
      (tester) async {
    final _UndoTrackingDb db = _UndoTrackingDb()
      ..seedFolder(Folder(id: 'f-1', name: 'Woodworking', createdAt: 1));
    addTearDown(db.dispose);
    await mountWithFolders(
      tester,
      rows: <DumpRow>[_autoFiledRow('d-1', 'f-1')],
      db: db,
    );

    await tester.tap(find.byKey(const ValueKey('auto-filed-undo-d-1')));
    await pumpSelection(tester);

    expect(db.undone, <String>['d-1']);
  });

  testWidgets('a marker pointing at a vanished folder shows no chip',
      (tester) async {
    final _UndoTrackingDb db = _UndoTrackingDb();
    addTearDown(db.dispose);
    await mountWithFolders(
      tester,
      rows: <DumpRow>[_autoFiledRow('d-1', 'f-gone')],
      db: db,
    );

    expect(find.byKey(const ValueKey('auto-filed-chip-d-1')), findsNothing);
  });
}
