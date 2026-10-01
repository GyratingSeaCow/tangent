// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Instrument Console v2 on the Recordings list:
//  * the top rail rides above the screen's own app bar with Recordings lit
//    and inert — a pushed screen keeps its root highlighted;
//  * the screen keeps its OWN create FAB: the pop-with-[DumpsCreateAction]
//    contract (home consumes the result) cannot travel through the global
//    create sheet, so the local FAB stays in the override slot;
//  * folder headers render as inset cards (1px edge border, panel-radius
//    corners, ~10px horizontal margin) WITHOUT losing their gestures;
//  * the list reserves at least 90px of bottom inset so the FAB and the
//    system bar never cover the last row.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/notebook_repository.dart' show foldersProvider;
import 'package:tangent/data/storage/storage_contract.dart'
    show PresentedDumpResults;
import 'package:tangent/screens/home/home_screen.dart' show localDbProvider;
import 'package:tangent/theme/tangent_tokens.dart';
import 'package:tangent/widgets/top_nav_rail.dart';

import '../support/dump_selection_fixture.dart';
import '../support/dump_view_fixture.dart';
import '../support/fake_folders_db.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'the rail rides above the Recordings app bar, lit and inert, and the '
      'screen keeps its own Add FAB', (tester) async {
    await mountSelection(tester, CountingDeletion());

    final Finder active = find.byKey(railKey(TangentRoot.recordings));
    expect(active, findsOneWidget);
    expect(
      tester.widget<IconButton>(active).onPressed,
      isNull,
      reason: 'the active destination is lit, not a navigation target',
    );
    // The rail sits ABOVE the screen app bar.
    expect(
      tester.getBottomLeft(find.byType(TopNavRail)).dy,
      lessThanOrEqualTo(tester.getTopLeft(find.text('Recordings')).dy),
    );
    // Exactly one FAB — the screen's own Add key, not the global create key.
    final Finder fabFinder = find.byType(FloatingActionButton);
    expect(fabFinder, findsOneWidget);
    expect(
      tester.widget<FloatingActionButton>(fabFinder).tooltip,
      'Add',
      reason: 'the DumpsCreateAction pop contract keeps the local FAB',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'folder headers are inset cards — edge border, panel radius, inset '
      'from the screen edge — and long-press still opens the folder menu',
      (tester) async {
    final FakeFoldersDb db = FakeFoldersDb()
      ..seedFolder(Folder(id: 'f-1', name: 'Work', createdAt: 1));
    addTearDown(db.dispose);
    await mountSelection(
      tester,
      CountingDeletion(),
      extraOverrides: <Override>[
        presentedFixture.overrideWith(
          (_) => AsyncData<PresentedDumpResults>((
            scopeKey: 'all',
            generation: 1,
            settled: true,
            rows: <DumpRow>[viewRowInFolder('d-1', 'f-1')],
            limit: null
          ),),
        ),
        foldersProvider.overrideWith((_) => db.watchFolders()),
        localDbProvider.overrideWithValue(db),
      ],
    );

    final Finder header = find.byKey(const ValueKey<String>('dump-section-f-1'));
    expect(header, findsOneWidget);
    final Material card = tester.widget<Material>(
      find.ancestor(of: header, matching: find.byType(Material)).first,
    );
    final RoundedRectangleBorder shape = card.shape! as RoundedRectangleBorder;
    expect(shape.borderRadius, BorderRadius.circular(TangentShapes.panelRadius));
    expect(shape.side.color, TangentColors.edge);
    expect(shape.side.width, TangentShapes.edgeWidth);
    expect(
      card.color,
      TangentColors.panel,
      reason: 'the card floats one step above the surface',
    );
    // Geometry, not widget counts: the card is inset from the screen edge
    // while plain rows still span the full width.
    expect(tester.getTopLeft(header).dx, 10);
    expect(
      tester.getTopLeft(find.byKey(const ValueKey<String>('dump-row-d-1'))).dx,
      0,
    );

    // The gesture contract is law: long-press on the header is the folder
    // menu, never selection.
    await tester.longPress(header);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('folder-action-rename')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('folder-action-delete')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'the list reserves at least 90px of bottom inset after scrolling to '
      'the end', (tester) async {
    await mountSelection(
      tester,
      CountingDeletion(),
      extraOverrides: <Override>[
        presentedFixture.overrideWith(
          (_) => AsyncData<PresentedDumpResults>((
            scopeKey: 'all',
            generation: 1,
            settled: true,
            rows: <DumpRow>[for (int i = 0; i < 40; i++) viewRow('d-$i')],
            limit: null
          ),),
        ),
      ],
    );

    await tester.drag(find.byType(ListView), const Offset(0, -8000));
    await tester.pumpAndSettle();

    final double viewportBottom = tester.getRect(find.byType(Scaffold)).bottom;
    final double lastRowBottom = tester
        .getBottomLeft(find.byKey(const ValueKey<String>('dump-row-d-39')))
        .dy;
    expect(
      viewportBottom - lastRowBottom,
      greaterThanOrEqualTo(90),
      reason: 'the FAB and system bar must never cover the last row',
    );
    expect(tester.takeException(), isNull);
  });
}
