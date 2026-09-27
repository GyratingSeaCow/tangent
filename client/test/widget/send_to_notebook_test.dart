// SPDX-License-Identifier: AGPL-3.0-or-later
//
// "Send to notebook…" (transcript-to-notebook spec §A): the recordings list
// ⋮ and the multi-select toolbar hand dumps to the notebook picker, then the
// shared shape sheet, then the import service — WITHOUT opening the editor —
// and a snackbar offers to Open the page. The service itself is unit-tested;
// here the provider is overridden to record what the UI asked for.
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/notebook_repository.dart';
import 'package:tangent/data/settings_store.dart';
import 'package:tangent/models/notebook.dart';
import 'package:tangent/screens/dump/dumps_providers.dart';
import 'package:tangent/screens/home/home_screen.dart' show localDbProvider;
import 'package:tangent/screens/notebook/import_shape_sheet.dart';
import 'package:tangent/screens/notebook/notebook_editor_screen.dart';
import 'package:tangent/screens/notebook/send_to_notebook.dart';
import 'package:tangent/screens/settings/ai_summaries_section.dart'
    show summariesEnabledProvider;
import 'package:tangent/screens/settings/settings_screen.dart'
    show settingsStoreProvider;
import 'package:tangent/services/notebook_import.dart';
import 'package:tangent/services/notebook_persistence.dart';
import 'package:tangent/widgets/item_action_sheet.dart';
import 'package:tangent/widgets/notebook_picker_sheet.dart';

import '../support/dump_selection_fixture.dart';
import '../support/dump_view_fixture.dart';
import '../support/fake_notebook_repository.dart';

/// One recorded import request.
typedef ImportCall = ({
  String notebookId,
  int dumpCount,
  ImportShape shape,
  bool includeAudioCard,
});

DumpRow _transcribedRow(String id, {String title = 'Sprint planning'}) =>
    viewRow(id).copyWith(
      title: title,
      transcript: const Value<String?>('[00:00] Alice: hello everyone'),
      transcriptionStatus: 'completed',
    );

/// Save-only persistence so the editor pushed by Open can mount without the
/// storage pipeline (it never saves in these tests).
class _NoopPersistence implements NotebookPersistence {
  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final Finder sendTile =
      find.byKey(ItemActionSheet.keyFor(ItemAction.sendToNotebook));
  final Finder picker = find.byKey(const ValueKey('notebook-picker'));
  final Finder pickerNew = find.byKey(const ValueKey('notebook-picker-new'));
  final Finder doneBar = find.byKey(const ValueKey('send-to-notebook-done'));
  final Finder openAction = find.byKey(const ValueKey('send-to-notebook-open'));

  late FakeNotebookRepository repository;
  late List<ImportCall> calls;
  late SettingsStore settings;

  List<Override> sendOverrides() => <Override>[
        notebookRepositoryProvider.overrideWithValue(repository),
        notebookPersistenceProvider.overrideWithValue(_NoopPersistence()),
        settingsStoreProvider.overrideWithValue(settings),
        summariesEnabledProvider.overrideWith((_) => false),
        dumpsProvider.overrideWith(
          (_) => Stream<List<DumpRow>>.value(const <DumpRow>[]),
        ),
        notebookImportProvider.overrideWithValue(({
          required String notebookId,
          required List<DumpRow> dumps,
          required ImportShape shape,
          required bool includeAudioCard,
        }) async {
          calls.add(
            (
              notebookId: notebookId,
              dumpCount: dumps.length,
              shape: shape,
              includeAudioCard: includeAudioCard,
            ),
          );
          return (
            notebookId: notebookId,
            newBlockIds: <String>['new-block-1'],
          );
        }),
      ];

  setUp(() {
    repository = FakeNotebookRepository();
    calls = <ImportCall>[];
    settings = SettingsStore();
  });
  tearDown(() => repository.dispose());

  Future<ProviderContainer> mountRows(
    WidgetTester tester,
    List<DumpRow> rows,
  ) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final LocalDb db = LocalDb.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final ProviderContainer container = await mountSelection(
      tester,
      CountingDeletion(),
      extraOverrides: <Override>[
        localDbProvider.overrideWithValue(db),
        ...sendOverrides(),
      ],
    );
    container.read(presentedFixture.notifier).state = AsyncData(
      (
        scopeKey: 'all',
        generation: 2,
        settled: true,
        rows: rows,
        limit: null,
      ),
    );
    await pumpSelection(tester);
    return container;
  }

  Future<void> openSheet(WidgetTester tester, String id) async {
    await tester.tap(find.byKey(ValueKey('dump-more-$id')));
    await pumpSelection(tester);
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  group('recordings list', () {
    testWidgets(
        '⋮ → Send to notebook → New notebook → Text: import recorded, '
        'snackbar with Open, Open pushes the editor', (tester) async {
      await mountRows(tester, <DumpRow>[_transcribedRow('fixture-a')]);

      await openSheet(tester, 'fixture-a');
      expect(sendTile, findsOneWidget);
      expect(
        find.descendant(of: sendTile, matching: find.text('Send to notebook…')),
        findsOneWidget,
      );
      await tester.tap(sendTile);
      await settle(tester);

      expect(picker, findsOneWidget, reason: 'the notebook picker opens');
      expect(pickerNew, findsOneWidget);
      await tester.tap(pickerNew);
      await settle(tester);
      expect(repository.createCalls, 1);
      expect(
        repository.snapshot.single.title,
        'Sprint planning',
        reason: 'New notebook is titled after the recording',
      );

      // The shape sheet is next; Text with the audio bubble left on.
      expect(find.byKey(const ValueKey('import-as-text')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('import-as-text')));
      await settle(tester);

      expect(calls, hasLength(1));
      expect(calls.single.notebookId, repository.snapshot.single.id);
      expect(calls.single.dumpCount, 1);
      expect(calls.single.shape, ImportShape.text);
      expect(calls.single.includeAudioCard, isTrue);
      expect(
        find.byType(NotebookEditorScreen),
        findsNothing,
        reason: 'insertion happens without opening the editor',
      );
      expect(doneBar, findsOneWidget);
      expect(find.text('Added to Sprint planning'), findsOneWidget);

      await tester.tap(openAction);
      await settle(tester);
      final NotebookEditorScreen editor = tester.widget<NotebookEditorScreen>(
        find.byType(NotebookEditorScreen),
      );
      expect(editor.notebookId, repository.snapshot.single.id);
      expect(editor.scrollToBlockId, 'new-block-1');
    });

    testWidgets('picking an existing notebook sends there; search filters',
        (tester) async {
      repository = FakeNotebookRepository(
        seed: <Notebook>[
          testNotebook(id: 'nb-old', title: 'Groceries'),
          testNotebook(id: 'nb-new', title: 'Sprint retro'),
        ],
      );
      await mountRows(tester, <DumpRow>[_transcribedRow('fixture-a')]);

      await openSheet(tester, 'fixture-a');
      await tester.tap(sendTile);
      await settle(tester);
      expect(find.byKey(const ValueKey('notebook-picker-nb-old')), findsOne);
      expect(find.byKey(const ValueKey('notebook-picker-nb-new')), findsOne);

      await tester.enterText(
        find.byKey(const ValueKey('notebook-picker-search')),
        'retro',
      );
      await tester.pump();
      expect(
        find.byKey(const ValueKey('notebook-picker-nb-old')),
        findsNothing,
        reason: 'search filters by title',
      );
      expect(find.byKey(const ValueKey('notebook-picker-nb-new')), findsOne);

      await tester.tap(find.byKey(const ValueKey('notebook-picker-nb-new')));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('import-as-card')));
      await settle(tester);

      expect(repository.createCalls, 0);
      expect(calls.single.notebookId, 'nb-new');
      expect(calls.single.shape, ImportShape.audio);
      expect(find.text('Added to Sprint retro'), findsOneWidget);
    });

    testWidgets('a recording with nothing to send gets no such tile',
        (tester) async {
      await mountRows(tester, <DumpRow>[viewRow('fixture-a')]);
      await openSheet(tester, 'fixture-a');
      expect(
        find.byKey(ItemActionSheet.keyFor(ItemAction.rename)),
        findsOneWidget,
        reason: 'the sheet itself opened',
      );
      expect(sendTile, findsNothing, reason: 'absent, not disabled');
    });

    testWidgets('multi-select sends every selected recording in one call',
        (tester) async {
      await mountRows(tester, <DumpRow>[
        _transcribedRow('fixture-a'),
        _transcribedRow('fixture-b', title: 'Second'),
        _transcribedRow('fixture-c', title: 'Third'),
      ]);

      await tester.longPress(find.byKey(const ValueKey('dump-row-fixture-a')));
      await pumpSelection(tester);
      await tester.tap(find.byKey(const ValueKey('dump-row-fixture-b')));
      await pumpSelection(tester);
      await tester.tap(find.byKey(const ValueKey('dump-row-fixture-c')));
      await pumpSelection(tester);

      final Finder toolbarButton =
          find.byKey(const ValueKey('selection-send-to-notebook'));
      expect(toolbarButton, findsOneWidget);
      await tester.tap(toolbarButton);
      await settle(tester);

      expect(picker, findsOneWidget);
      expect(
        find.text('Titled "3 recordings"'),
        findsOneWidget,
        reason: 'a batch suggests a batch title',
      );
      await tester.tap(pickerNew);
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('import-as-text')));
      await settle(tester);

      expect(calls, hasLength(1));
      expect(calls.single.dumpCount, 3);
      expect(calls.single.shape, ImportShape.text);
      expect(doneBar, findsOneWidget);
    });
  });

  group('shape sheet', () {
    Future<Future<ImportShapeChoice?> Function()> mountSheet(
      WidgetTester tester, {
      required bool offerSummary,
      bool remembered = false,
    }) async {
      Future<ImportShapeChoice?>? result;
      final Widget app = ProviderScope(
        overrides: <Override>[
          settingsStoreProvider.overrideWithValue(settings),
        ],
        child: MaterialApp(
          home: Consumer(
            builder: (BuildContext context, WidgetRef ref, _) => Scaffold(
              body: ElevatedButton(
                onPressed: () {
                  result = remembered
                      ? askImportShapeRemembered(
                          context,
                          ref,
                          offerSummary: offerSummary,
                        )
                      : askImportShape(
                          context,
                          offerSummary: offerSummary,
                          initialIncludeAudioCard: true,
                        );
                },
                child: const Text('ask'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpWidget(app);
      return () => result!;
    }

    Future<void> open(WidgetTester tester) async {
      await tester.pump();
      await tester.tap(find.text('ask'));
      await settle(tester);
    }

    final Finder switchTile =
        find.byKey(const ValueKey('import-include-audio'));

    testWidgets('the switch is offered for the text shapes only',
        (tester) async {
      await mountSheet(tester, offerSummary: true);
      await open(tester);
      expect(switchTile, findsOneWidget);
      expect(find.byKey(const ValueKey('import-as-summary')), findsOneWidget);
      expect(find.byKey(const ValueKey('import-as-both')), findsOneWidget);
      // The Audio bubble row lives above the divider that separates it from
      // the text shapes and their switch: the switch is NOT part of it.
      final double dividerY = tester.getTopLeft(find.byType(Divider).first).dy;
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('import-as-card'))).dy,
        lessThan(dividerY),
      );
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('import-as-text'))).dy,
        greaterThan(dividerY),
      );
      expect(tester.getTopLeft(switchTile).dy, greaterThan(dividerY));
    });

    testWidgets('Audio bubble always reports includeAudioCard true',
        (tester) async {
      final Future<ImportShapeChoice?> Function() result =
          await mountSheet(tester, offerSummary: false);
      await open(tester);
      await tester.tap(switchTile);
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('import-as-card')));
      await settle(tester);
      final ImportShapeChoice? choice = await result();
      expect(choice?.shape, ImportShape.audio);
      expect(choice?.includeAudioCard, isTrue);
    });

    for (final (String key, ImportShape shape) in <(String, ImportShape)>[
      ('import-as-text', ImportShape.text),
      ('import-as-summary', ImportShape.summary),
      ('import-as-both', ImportShape.both),
    ]) {
      testWidgets('$key carries the switch state', (tester) async {
        final Future<ImportShapeChoice?> Function() result =
            await mountSheet(tester, offerSummary: true);
        await open(tester);
        expect(tester.widget<SwitchListTile>(switchTile).value, isTrue);
        await tester.tap(switchTile);
        await tester.pump();
        expect(tester.widget<SwitchListTile>(switchTile).value, isFalse);
        await tester.tap(find.byKey(ValueKey(key)));
        await settle(tester);
        final ImportShapeChoice? choice = await result();
        expect(choice?.shape, shape);
        expect(choice?.includeAudioCard, isFalse);
      });
    }

    testWidgets('the remembered variant seeds from and writes to SettingsStore',
        (tester) async {
      expect(settings.notebookImportAudioCard, isTrue, reason: 'default on');
      final Future<ImportShapeChoice?> Function() result =
          await mountSheet(tester, offerSummary: false, remembered: true);
      await open(tester);
      await tester.tap(switchTile);
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('import-as-text')));
      await settle(tester);
      expect((await result())?.includeAudioCard, isFalse);
      expect(settings.notebookImportAudioCard, isFalse, reason: 'persisted');

      // Next time the sheet opens it starts from the stored answer.
      await open(tester);
      expect(tester.widget<SwitchListTile>(switchTile).value, isFalse);
      await tester.tap(find.byKey(const ValueKey('import-as-card')));
      await settle(tester);
      expect(
        settings.notebookImportAudioCard,
        isFalse,
        reason: 'the Audio bubble choice never rewrites the text preference',
      );
    });
  });

  group('notebook picker', () {
    testWidgets('lists newest-edited first and New creates with the title',
        (tester) async {
      repository = FakeNotebookRepository(
        seed: <Notebook>[
          testNotebook(id: 'nb-old', title: 'Older'),
          testNotebook(id: 'nb-new', title: 'Newer').copyWith(
            updatedAt: DateTime.utc(2027),
          ),
        ],
      );
      Future<String?>? picked;
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            notebookRepositoryProvider.overrideWithValue(repository),
          ],
          child: MaterialApp(
            home: Consumer(
              builder: (BuildContext context, WidgetRef ref, _) => Scaffold(
                body: ElevatedButton(
                  onPressed: () => picked = showNotebookPickerSheet(
                    context,
                    ref: ref,
                    suggestedTitle: 'From a recording',
                  ),
                  child: const Text('pick'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('pick'));
      await settle(tester);
      expect(
        tester
            .getTopLeft(find.byKey(const ValueKey('notebook-picker-nb-new')))
            .dy,
        lessThan(
          tester
              .getTopLeft(find.byKey(const ValueKey('notebook-picker-nb-old')))
              .dy,
        ),
      );
      await tester.tap(find.byKey(const ValueKey('notebook-picker-new')));
      await settle(tester);
      final String? id = await picked;
      expect(repository.createCalls, 1);
      expect(id, isNotNull);
      expect((await repository.getNotebook(id!))?.title, 'From a recording');
    });
  });
}
