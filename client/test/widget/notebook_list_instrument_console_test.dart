// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Instrument Console v2 on the Notebooks list:
//  * the rail rides beneath the screen's own app bar with Notebooks lit and
//    inert; the app bar keeps its search / sync / view-toggle actions;
//  * the local New-notebook FAB is replaced by the GLOBAL create key — the
//    create sheet's Notebook entry performs the identical create-and-open;
//  * folder headers render as inset cards without losing their gestures;
//  * the list reserves at least 90px of bottom inset for the FAB.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/notebook_repository.dart';
import 'package:tangent/models/notebook.dart';
import 'package:tangent/screens/dump/dumps_providers.dart';
import 'package:tangent/screens/home/home_screen.dart' show localDbProvider;
import 'package:tangent/screens/notebook/notebook_list_screen.dart';
import 'package:tangent/screens/settings/handwriting_search_section.dart'
    show handwritingSearchEnabledProvider;
import 'package:tangent/theme/tangent_tokens.dart';
import 'package:tangent/widgets/instrument_scaffold.dart';
import 'package:tangent/widgets/top_nav_rail.dart';

import '../support/fake_folders_db.dart';
import '../support/fake_notebook_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeNotebookRepository repository;

  Future<void> mountList(
    WidgetTester tester, {
    List<Notebook> seed = const <Notebook>[],
    FakeFoldersDb? db,
  }) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    repository = FakeNotebookRepository(seed: seed);
    addTearDown(repository.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          notebookRepositoryProvider.overrideWithValue(repository),
          dumpsProvider.overrideWith(
            (_) => Stream<List<DumpRow>>.value(const <DumpRow>[]),
          ),
          foldersProvider.overrideWith(
            (_) => db?.watchFolders() ?? Stream<List<Folder>>.value(const []),
          ),
          if (db != null) localDbProvider.overrideWithValue(db),
          handwritingSearchEnabledProvider.overrideWith((ref) => false),
        ],
        child: const MaterialApp(home: NotebookListScreen()),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  testWidgets(
      'the rail rides beneath the Notebooks app bar and the global create key '
      'replaces the local FAB', (tester) async {
    await mountList(tester);

    final Finder active = find.byKey(railKey(TangentRoot.notebooks));
    expect(active, findsOneWidget);
    expect(
      tester.widget<IconButton>(active).onPressed,
      isNull,
      reason: 'the active destination is lit, not a navigation target',
    );
    expect(
      // Mockup order: app bar first, rail beneath it.
      tester.getTopLeft(find.byType(TopNavRail)).dy,
      greaterThanOrEqualTo(tester.getBottomLeft(find.text('Notebooks')).dy),
    );
    // The GLOBAL create key, and only it.
    expect(find.byKey(InstrumentScaffold.createFabKey), findsOneWidget);
    expect(find.byType(FloatingActionButton), findsOneWidget);
    // The app bar keeps its own actions.
    expect(
      find.byKey(const ValueKey<String>('notebook-view-toggle')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey<String>('sync-button')), findsOneWidget);
    expect(tester.takeException(), isNull);

    await unmount(tester);
  });

  testWidgets('the global create key opens the create sheet', (tester) async {
    await mountList(tester);

    await tester.tap(find.byKey(InstrumentScaffold.createFabKey));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('create-sheet-notebook')), findsOneWidget);
    expect(find.byKey(const Key('create-sheet-recording')), findsOneWidget);
    expect(tester.takeException(), isNull);

    await unmount(tester);
  });

  testWidgets(
      'folder headers are inset cards and long-press still opens the '
      'folder menu', (tester) async {
    final FakeFoldersDb db = FakeFoldersDb()
      ..seedFolder(Folder(id: 'f-1', name: 'Work', createdAt: 1));
    addTearDown(db.dispose);
    await mountList(
      tester,
      seed: <Notebook>[testNotebook(id: 'nb-1', folderId: 'f-1')],
      db: db,
    );

    final Finder header =
        find.byKey(const ValueKey<String>('notebook-section-f-1'));
    expect(header, findsOneWidget);
    final Material card = tester.widget<Material>(
      find.ancestor(of: header, matching: find.byType(Material)).first,
    );
    final RoundedRectangleBorder shape = card.shape! as RoundedRectangleBorder;
    expect(shape.borderRadius, BorderRadius.circular(TangentShapes.panelRadius));
    expect(shape.side.color, TangentColors.edge);
    expect(shape.side.width, TangentShapes.edgeWidth);
    expect(card.color, TangentColors.panel);
    // Geometry: card inset from the edge, rows at full width.
    expect(tester.getTopLeft(header).dx, 10);
    expect(
      tester
          .getTopLeft(find.byKey(const ValueKey<String>('notebook-row-nb-1')))
          .dx,
      0,
    );

    await tester.longPress(header);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('folder-action-rename')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    await unmount(tester);
  });

  testWidgets(
      'the list reserves at least 90px of bottom inset after scrolling to '
      'the end', (tester) async {
    final DateTime base = DateTime.utc(2026, 9, 17, 12);
    await mountList(
      tester,
      seed: <Notebook>[
        for (int i = 0; i < 40; i++)
          testNotebook(
            id: 'nb-$i',
            title: 'Notebook $i',
            updatedAt: base.subtract(Duration(minutes: i)),
          ),
      ],
    );

    await tester.drag(find.byType(ListView), const Offset(0, -8000));
    await tester.pumpAndSettle();

    final double viewportBottom = tester.getRect(find.byType(Scaffold)).bottom;
    final double lastRowBottom = tester
        .getBottomLeft(find.byKey(const ValueKey<String>('notebook-row-nb-39')))
        .dy;
    expect(
      viewportBottom - lastRowBottom,
      greaterThanOrEqualTo(90),
      reason: 'the FAB and system bar must never cover the last row',
    );
    expect(tester.takeException(), isNull);

    await unmount(tester);
  });
}
