// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Back exits SELECTION, not the SCREEN (Jeff, 2026-09-23):
//
//   "after you long press on a notebook or dump, the back button needs to
//    simply exit out of the selection mode rather than going back a page.
//    Same thing with the navigation bar at the bottom of the screen"
//
// Both list screens enter multi-select on long-press. While selection is
// active, EVERY back gesture — the app-bar arrow, the system/gesture back,
// the bottom navigation bar's back — must cancel selection and stay on the
// page. Only a second back leaves the screen. The system back and the
// nav-bar back both arrive through the same pop machinery
// (handlePopRoute), so driving it covers the whole family.
//
// Each screen is pushed onto a host route, as in the real app — a
// same-route `home:` mount would make canPop false and hide the bug.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/screens/dump/dumps_list_screen.dart';
import 'package:tangent/screens/dump/dumps_providers.dart';
import 'package:tangent/screens/notebook/notebook_list_screen.dart';

import '../support/fake_notebook_repository.dart';
import 'package:tangent/data/notebook_repository.dart';
import 'package:tangent/models/notebook.dart';
import 'package:tangent/services/notebook_persistence.dart';

class _HostedApp extends StatelessWidget {
  const _HostedApp({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Builder(
        builder: (BuildContext context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute<void>(builder: (_) => child),
              ),
              child: const Text('open list'),
            ),
          ),
        ),
      ),
    );
  }
}

DumpRow _dumpRow(String id) => DumpRow(
      id: id,
      createdAt: DateTime.utc(2026, 9, 17),
      updatedAt: DateTime.utc(2026, 9, 17),
      mode: 'brain_dump',
      durationSeconds: 9,
      title: 'Dump $id',
      transcript: null,
      audioPath: 'content://tangent/$id.opus',
      audioSizeBytes: 3,
      syncStatus: 'pending',
      syncAttempts: 0,
      transcriptionStatus: 'not_transcribed',
      transcriptionAttempt: 0,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> open(WidgetTester tester) async {
    await tester.tap(find.text('open list'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 400));
  }

  group('dumps list', () {
    Future<void> mount(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            deletionEligibilityProvider.overrideWith(
              (_) => Stream<Map<String, Eligibility>>.value(
                const <String, Eligibility>{},
              ),
            ),
            dumpsProvider.overrideWith(
              (_) => Stream<List<DumpRow>>.value(<DumpRow>[_dumpRow('d1')]),
            ),
          ],
          child: const _HostedApp(child: DumpsListScreen()),
        ),
      );
      await open(tester);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 1));
      });
    }

    testWidgets('back cancels selection and stays on the page',
        (WidgetTester tester) async {
      await mount(tester);
      await tester.longPress(find.byKey(const ValueKey('dump-row-d1')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('selection-cancel')),
        findsOneWidget,
        reason: 'long-press must enter selection',
      );

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('selection-cancel')),
        findsNothing,
        reason: 'the first back exits selection mode',
      );
      expect(
        find.byKey(const ValueKey('dump-row-d1')),
        findsOneWidget,
        reason: 'the first back must NOT leave the dumps list',
      );

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(
        find.text('open list'),
        findsOneWidget,
        reason: 'the second back, with no selection active, leaves the page',
      );
    });
  });

  group('notebook list', () {
    late FakeNotebookRepository repository;

    Future<void> mount(WidgetTester tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final Notebook notebook = Notebook(
        id: 'nb-sel',
        title: 'Selectable',
        createdAt: DateTime.utc(2026, 9, 23),
        updatedAt: DateTime.utc(2026, 9, 23),
        document: const NotebookDocument.empty(),
        ink: const NotebookInk.empty(),
      );
      repository = FakeNotebookRepository(seed: <Notebook>[notebook]);
      addTearDown(repository.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            notebookRepositoryProvider.overrideWithValue(repository),
            notebookPersistenceProvider.overrideWithValue(
              _ForwardingPersistence(repository),
            ),
            foldersProvider.overrideWith(
              (_) => Stream<List<Folder>>.value(const <Folder>[]),
            ),
            dumpsProvider.overrideWith(
              (_) => Stream<List<DumpRow>>.value(const <DumpRow>[]),
            ),
          ],
          child: _HostedApp(
            child: const NotebookListScreen(),
          ),
        ),
      );
      await open(tester);
      // The folders stream needs one more settle than the dumps mount.
      await tester.pumpAndSettle();
      // Remember the row key for the test body.
      _rowKey = ValueKey<String>('notebook-row-${notebook.id}');
    }

    testWidgets('back cancels selection and stays on the page',
        (WidgetTester tester) async {
      await mount(tester);
      await tester.longPress(find.byKey(_rowKey));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('notebook-selection-cancel')),
        findsOneWidget,
        reason: 'long-press must enter selection',
      );

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey<String>('notebook-selection-cancel')),
        findsNothing,
        reason: 'the first back exits selection mode',
      );
      expect(
        find.byKey(_rowKey),
        findsOneWidget,
        reason: 'the first back must NOT leave the notebooks list',
      );

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(
        find.text('open list'),
        findsOneWidget,
        reason: 'the second back, with no selection active, leaves the page',
      );
    });
  });
}

late ValueKey<String> _rowKey;

/// Saves go straight to the repository; durable publication needs a
/// storage backend no widget test has.
class _ForwardingPersistence implements NotebookPersistence {
  _ForwardingPersistence(this._repository);

  final NotebookRepository _repository;

  @override
  Future<Notebook> saveNotebook(Notebook notebook) async {
    await _repository.saveNotebook(notebook);
    return notebook;
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
