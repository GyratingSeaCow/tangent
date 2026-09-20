// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Dumps organized into folders, the same way notebooks are.
//
// The contract mirrors the notebooks list exactly:
//  * No folders at all -> the flat list nobody opted out of.
//  * Folders sort alphabetically, come first, appear even when empty for
//    dumps (so there is somewhere visible to file into).
//  * Unfiled dumps land under 'No folder', which is omitted when empty.
//  * Headers collapse on tap and carry rename/delete on long-press; the
//    'No folder' pseudo-header carries no actions.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/notebook_repository.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/screens/home/home_screen.dart' show localDbProvider;

import '../support/dump_selection_fixture.dart';
import '../support/dump_view_fixture.dart';
import '../support/fake_folders_db.dart';

Future<ProviderContainer> mountWithFolders(
  WidgetTester tester, {
  required List<DumpRow> rows,
  required FakeFoldersDb db,
}) {
  return mountSelection(
    tester,
    CountingDeletion(),
    extraOverrides: <Override>[
      presentedFixture.overrideWith(
        (_) => AsyncData<PresentedDumpResults>((
          scopeKey: 'all',
          generation: 1,
          settled: true,
          rows: rows,
          limit: null
        ),),
      ),
      foldersProvider.overrideWith((_) => db.watchFolders()),
      localDbProvider.overrideWithValue(db),
    ],
  );
}

void main() {
  testWidgets('no folders means the flat list, no headers', (tester) async {
    final FakeFoldersDb db = FakeFoldersDb();
    addTearDown(db.dispose);
    await mountWithFolders(
      tester,
      rows: <DumpRow>[viewRow('d-1'), viewRow('d-2')],
      db: db,
    );

    expect(find.byKey(const ValueKey('dump-row-d-1')), findsOneWidget);
    expect(find.text('No folder'), findsNothing);
  });

  testWidgets('filed dumps group under sorted headers, unfiled last',
      (tester) async {
    final FakeFoldersDb db = FakeFoldersDb()
      ..seedFolder(Folder(id: 'f-work', name: 'Work', createdAt: 1))
      ..seedFolder(Folder(id: 'f-errands', name: 'errands', createdAt: 2));
    addTearDown(db.dispose);
    await mountWithFolders(
      tester,
      rows: <DumpRow>[
        viewRow('d-loose'),
        viewRowInFolder('d-work', 'f-work'),
      ],
      db: db,
    );

    // Case-insensitive alphabetical: errands before Work; No folder last.
    expect(
      find.byKey(const ValueKey('dump-section-f-errands')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('dump-section-f-work')), findsOneWidget);
    expect(find.byKey(const ValueKey('dump-section-unfiled')), findsOneWidget);
    final double errandsY = tester
        .getTopLeft(find.byKey(const ValueKey('dump-section-f-errands')))
        .dy;
    final double workY =
        tester.getTopLeft(find.byKey(const ValueKey('dump-section-f-work'))).dy;
    final double unfiledY = tester
        .getTopLeft(find.byKey(const ValueKey('dump-section-unfiled')))
        .dy;
    expect(errandsY, lessThan(workY));
    expect(workY, lessThan(unfiledY));

    // Rows sit with their sections.
    expect(find.byKey(const ValueKey('dump-row-d-work')), findsOneWidget);
    expect(find.byKey(const ValueKey('dump-row-d-loose')), findsOneWidget);
  });

  testWidgets('tapping a header collapses its section', (tester) async {
    final FakeFoldersDb db = FakeFoldersDb()
      ..seedFolder(Folder(id: 'f-1', name: 'Work', createdAt: 1));
    addTearDown(db.dispose);
    await mountWithFolders(
      tester,
      rows: <DumpRow>[viewRowInFolder('d-1', 'f-1')],
      db: db,
    );

    expect(find.byKey(const ValueKey('dump-row-d-1')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('dump-section-f-1')));
    await pumpSelection(tester);
    expect(find.byKey(const ValueKey('dump-row-d-1')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('dump-section-f-1')));
    await pumpSelection(tester);
    expect(find.byKey(const ValueKey('dump-row-d-1')), findsOneWidget);
  });

  testWidgets('long-press on a header offers rename and delete',
      (tester) async {
    final FakeFoldersDb db = FakeFoldersDb()
      ..seedFolder(Folder(id: 'f-1', name: 'Work', createdAt: 1));
    addTearDown(db.dispose);
    await mountWithFolders(
      tester,
      rows: <DumpRow>[viewRowInFolder('d-1', 'f-1')],
      db: db,
    );

    await tester.longPress(find.byKey(const ValueKey('dump-section-f-1')));
    await pumpSelection(tester);

    expect(find.byKey(const ValueKey('folder-action-rename')), findsOneWidget);
    expect(find.byKey(const ValueKey('folder-action-delete')), findsOneWidget);
  });

  testWidgets('deleting a folder from dumps unfiles its rows', (tester) async {
    final FakeFoldersDb db = FakeFoldersDb()
      ..seedFolder(Folder(id: 'f-1', name: 'Work', createdAt: 1));
    addTearDown(db.dispose);
    await mountWithFolders(
      tester,
      rows: <DumpRow>[viewRowInFolder('d-1', 'f-1')],
      db: db,
    );

    await tester.longPress(find.byKey(const ValueKey('dump-section-f-1')));
    await pumpSelection(tester);
    await tester.tap(find.byKey(const ValueKey('folder-action-delete')));
    await pumpSelection(tester);
    await tester.tap(find.byKey(const ValueKey('folder-delete-confirm')));
    await pumpSelection(tester);
    await pumpSelection(tester);

    expect(db.deletedFolderIds, <String>['f-1']);
    expect(
      find.byKey(const ValueKey('dump-section-f-1')),
      findsNothing,
      reason: 'the header must leave the list once its folder is gone',
    );
    expect(
      find.byKey(const ValueKey('dump-row-d-1')),
      findsOneWidget,
      reason: 'the dump survives its folder',
    );
  });

  testWidgets('a dump pointing at a vanished folder shows as unfiled',
      (tester) async {
    // Rule 6: another device can delete a folder this dump still points
    // at. Dropping the row would lose sight of work; it must surface
    // under 'No folder' while other folders still exist.
    final FakeFoldersDb db = FakeFoldersDb()
      ..seedFolder(Folder(id: 'f-1', name: 'Work', createdAt: 1));
    addTearDown(db.dispose);
    await mountWithFolders(
      tester,
      rows: <DumpRow>[viewRowInFolder('d-ghost', 'f-gone')],
      db: db,
    );

    expect(find.byKey(const ValueKey('dump-section-unfiled')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('dump-row-d-ghost')),
      findsOneWidget,
      reason: 'a dangling folder id must never hide the dump',
    );
  });

  testWidgets('the No folder header has no actions', (tester) async {
    final FakeFoldersDb db = FakeFoldersDb()
      ..seedFolder(Folder(id: 'f-1', name: 'Work', createdAt: 1));
    addTearDown(db.dispose);
    await mountWithFolders(
      tester,
      rows: <DumpRow>[viewRow('d-loose')],
      db: db,
    );

    await tester.longPress(find.byKey(const ValueKey('dump-section-unfiled')));
    await pumpSelection(tester);

    expect(find.byKey(const ValueKey('folder-action-delete')), findsNothing);
  });
}
