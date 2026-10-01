// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/ask_history_repository.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/notebook_repository.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/data/storage/storage_providers.dart';
import 'package:tangent/data/todo_repository.dart';
import 'package:tangent/models/api_exception.dart';
import 'package:tangent/models/notebook.dart';
import 'package:tangent/screens/ask/ask_screen.dart';
import 'package:tangent/screens/ask/ask_source_actions.dart';
import 'package:tangent/screens/home/home_screen.dart' show localDbProvider;
import 'package:tangent/services/ask_client.dart';
import 'package:tangent/services/notebook_persistence.dart';
import 'package:tangent/widgets/item_action_sheet.dart';

import '../support/dump_selection_fixture.dart'
    show CountingDeletion, itemFor, targetFor;

/// Durable-publication fake: delegates to the real repository so content
/// round-trips through the database, and records what was published.
class _Persistence implements NotebookPersistence {
  _Persistence(this.repo);
  final NotebookRepository repo;
  final List<String> deleted = <String>[];

  @override
  Future<Notebook> saveNotebook(Notebook notebook) async {
    await repo.saveNotebook(notebook);
    return notebook;
  }

  @override
  Future<ComponentResult> deleteNotebook(String id) async {
    deleted.add(id);
    await repo.deleteNotebook(id);
    return (state: ComponentState.removed, problem: null);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late LocalDb db;
  late NotebookRepository notebooks;
  late TodoRepository todos;
  late CountingDeletion deletion;
  late _Persistence persistence;
  late List<String> log;
  int? serverStatus;

  setUp(() {
    db = LocalDb.forTesting(NativeDatabase.memory());
    notebooks = NotebookRepository(db: db);
    todos = TodoRepository(db: db);
    deletion = CountingDeletion();
    persistence = _Persistence(notebooks);
    log = <String>[];
    serverStatus = null;
  });

  Future<void> insertDump(
    String id,
    String title, {
    bool pinned = false,
    String syncStatus = 'synced',
    int? syncedSeq,
    int syncAttempts = 0,
  }) =>
      db.into(db.dumps).insert(
            DumpsCompanion.insert(
              id: id,
              createdAt: DateTime.utc(2026, 9, 29, 9),
              updatedAt: DateTime.utc(2026, 9, 29, 9),
              mode: 'brain_dump',
              durationSeconds: 61,
              title: title,
              audioPath: 'content://media/external/audio/$id',
              audioSizeBytes: 2048,
              syncStatus: syncStatus,
              syncedSeq: Value(syncedSeq),
              syncAttempts: Value(syncAttempts),
              pinned: Value(pinned),
            ),
          );

  AskHistoryMessage answer(List<AskSource> sources) => AskHistoryMessage(
        id: 'a-7',
        role: 'assistant',
        text: 'Here is what I found.',
        sources: sources,
        createdAt: DateTime.utc(2026, 9, 30, 9),
      );

  Future<void> mount(WidgetTester tester, List<AskSource> sources) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          askHistoryProvider.overrideWith(
            (ref) => Stream<List<AskHistoryMessage>>.value(
              <AskHistoryMessage>[answer(sources)],
            ),
          ),
          localDbProvider.overrideWithValue(db),
          notebookRepositoryProvider.overrideWithValue(notebooks),
          todoRepositoryProvider.overrideWithValue(todos),
          notebookPersistenceProvider.overrideWithValue(persistence),
          localDeletionServiceProvider.overrideWithValue(deletion),
          askSourceServerDeleteProvider.overrideWithValue((String id) async {
            // Records the previews run before it and whether the deletion
            // lease was held at the time.
            log.add(
              'server-delete:$id:previews=${deletion.previews.length}'
              ':leased=${deletion.inLease}',
            );
            if (serverStatus != null) {
              throw ApiException(
                statusCode: serverStatus!,
                code: 'not_found',
                message: 'Dump not found',
              );
            }
          }),
        ],
        child: MaterialApp(
          home: AskScreen(voiceQuestion: () async => null),
        ),
      ),
    );
    await pumpFrames(tester);
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
    await db.close();
  }

  Finder chip(int index, String type, String id) =>
      find.byKey(ValueKey<String>('ask-source-a-7-$index-$type-$id'));

  Future<void> longPress(WidgetTester tester, Finder target) async {
    await tester.longPress(target);
    await pumpFrames(tester);
  }

  Future<void> choose(WidgetTester tester, ItemAction action) async {
    await tester.tap(find.byKey(ItemActionSheet.keyFor(action)));
    await pumpFrames(tester);
  }

  testWidgets('long-press sheet offers per-entity actions for every type',
      (tester) async {
    await insertDump('d-1', 'Harbor walk');
    final Notebook nb = await notebooks.createNotebook(title: 'Field notes');
    final TodoRow todo = await todos.add('Buy rope');
    await mount(tester, <AskSource>[
      const AskSource(entityType: 'dump', entityId: 'd-1', snippet: 'harbor'),
      const AskSource(entityType: 'summary', entityId: 'd-1', snippet: 'sum'),
      AskSource(entityType: 'notebook', entityId: nb.id, snippet: 'field'),
      AskSource(entityType: 'todo', entityId: todo.id, snippet: 'rope'),
    ]);

    final Map<(int, String, String), bool> expectDelete =
        <(int, String, String), bool>{
      (0, 'dump', 'd-1'): true,
      (1, 'summary', 'd-1'): false,
      (2, 'notebook', nb.id): true,
      (3, 'todo', todo.id): true,
    };
    for (final MapEntry<(int, String, String), bool> e
        in expectDelete.entries) {
      await longPress(tester, chip(e.key.$1, e.key.$2, e.key.$3));
      for (final ItemAction a in <ItemAction>[
        ItemAction.rename,
        ItemAction.move,
        ItemAction.pin,
      ]) {
        expect(
          find.byKey(ItemActionSheet.keyFor(a)),
          findsOneWidget,
          reason: '${e.key.$2} offers $a',
        );
      }
      expect(
        find.byKey(ItemActionSheet.keyFor(ItemAction.delete)),
        e.value ? findsOneWidget : findsNothing,
        reason: '${e.key.$2} delete offered = ${e.value}',
      );
      await tester.tapAt(const Offset(10, 10));
      await pumpFrames(tester);
    }
    await unmount(tester);
  });

  testWidgets('pin round-trips to the origin flag and flips every chip',
      (tester) async {
    final TodoRow todo = await todos.add('Call harbor master');
    await insertDump('d-2', 'Dock notes');
    await mount(tester, <AskSource>[
      const AskSource(
        entityType: 'dump',
        entityId: 'd-2',
        snippet: 'a',
        seekSeconds: 3,
      ),
      const AskSource(
        entityType: 'dump',
        entityId: 'd-2',
        snippet: 'b',
        seekSeconds: 40,
      ),
      AskSource(entityType: 'todo', entityId: todo.id, snippet: 'call'),
    ]);

    await longPress(tester, chip(0, 'dump', 'd-2'));
    await choose(tester, ItemAction.pin);
    // The SAME column Recordings reads for its pinned group.
    expect((await tester.runAsync(() => db.getDumpRow('d-2')))!.pinned, isTrue);
    // Both chips citing d-2 now show the pin.
    expect(
      find.byKey(const ValueKey<String>('ask-source-pinned')),
      findsNWidgets(2),
    );
    // Label flips to Unpin from current state.
    await longPress(tester, chip(1, 'dump', 'd-2'));
    expect(
      find.byKey(ItemActionSheet.keyFor(ItemAction.unpin)),
      findsOneWidget,
    );
    await choose(tester, ItemAction.unpin);
    expect(
      (await tester.runAsync(() => db.getDumpRow('d-2')))!.pinned,
      isFalse,
    );

    await longPress(tester, chip(2, 'todo', todo.id));
    await choose(tester, ItemAction.pin);
    final TodoRow pinnedTodo =
        (await tester.runAsync(() => todos.watchTodos().first))!
            .firstWhere((t) => t.id == todo.id);
    expect(pinnedTodo.pinned, isTrue);
    await unmount(tester);
  });

  testWidgets('rename saves the FULL notebook: content survives',
      (tester) async {
    final Notebook created = await notebooks.createNotebook(title: 'Old');
    await notebooks.saveNotebook(
      created.copyWith(
        document: const NotebookDocument(<NotebookBlock>[
          NotebookTextBlock(id: 'b1', text: 'Tide table lives here'),
        ]),
      ),
    );
    await mount(tester, <AskSource>[
      AskSource(entityType: 'notebook', entityId: created.id, snippet: 's'),
    ]);

    await longPress(tester, chip(0, 'notebook', created.id));
    await choose(tester, ItemAction.rename);
    await tester.enterText(
      find.byKey(const ValueKey<String>('ask-source-rename-field')),
      'Tides',
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('ask-source-rename-save')),
    );
    await pumpFrames(tester);

    final Notebook? after = await tester
        .runAsync<Notebook?>(() => notebooks.getNotebook(created.id));
    expect(after!.title, 'Tides');
    expect(
      (after.document.blocks.single as NotebookTextBlock).text,
      'Tide table lives here',
    );
    // Chip shows the live title.
    expect(find.textContaining('Tides'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('move uses the folder picker; dismissing moves nothing',
      (tester) async {
    await insertDump('d-3', 'Boat list');
    final String folder = await db.createFolder(name: 'Sailing');
    await mount(tester, <AskSource>[
      const AskSource(entityType: 'dump', entityId: 'd-3', snippet: 'boat'),
    ]);
    await longPress(tester, chip(0, 'dump', 'd-3'));
    await choose(tester, ItemAction.move);
    await tester.tapAt(const Offset(10, 10));
    await pumpFrames(tester);
    expect(
      (await tester.runAsync(() => db.getDumpRow('d-3')))!.folderId,
      isNull,
    );

    await longPress(tester, chip(0, 'dump', 'd-3'));
    await choose(tester, ItemAction.move);
    await tester.tap(find.text('Sailing'));
    await pumpFrames(tester);
    expect(
      (await tester.runAsync(() => db.getDumpRow('d-3')))!.folderId,
      folder,
    );
    await unmount(tester);
  });

  testWidgets(
      'delete recording: eligibility, then server tombstone, then '
      'LocalDeletionService; stale chip degrades to a snackbar',
      (tester) async {
    await insertDump('d-4', 'Engine noise');
    deletion.result = (
      replayed: false,
      items: <DeletionItemResult>[itemFor('d-4', DeleteState.deleted)],
    );
    await mount(tester, <AskSource>[
      const AskSource(entityType: 'dump', entityId: 'd-4', snippet: 'x'),
    ]);
    await longPress(tester, chip(0, 'dump', 'd-4'));
    await choose(tester, ItemAction.delete);
    expect(log, isEmpty, reason: 'confirmation first');
    await tester.tap(
      find.byKey(const ValueKey<String>('ask-source-delete-confirm')),
    );
    await pumpFrames(tester);
    // Previewed for the sheet AND re-checked by the provider, both BEFORE
    // the server delete.
    expect(log, <String>['server-delete:d-4:previews=2:leased=true']);
    expect(deletion.previews, <Set<String>>[
      <String>{'d-4'},
      <String>{'d-4'},
    ]);
    expect(deletion.deletes.single.targets.single.id, 'd-4');

    // The fake service does not remove the row; simulate it, then the
    // stale chip must degrade gracefully.
    await tester.runAsync(
      () => (db.delete(db.dumps)..where((t) => t.id.equals('d-4'))).go(),
    );
    await pumpFrames(tester);
    await longPress(tester, chip(0, 'dump', 'd-4'));
    expect(find.text('Source no longer exists: x'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await unmount(tester);
  });

  testWidgets('skipped local deletion surfaces an error, never success',
      (tester) async {
    await insertDump('d-5', 'Busy one');
    deletion.result = (
      replayed: false,
      items: <DeletionItemResult>[itemFor('d-5', DeleteState.skipped)],
    );
    await mount(tester, <AskSource>[
      const AskSource(entityType: 'dump', entityId: 'd-5', snippet: 'y'),
    ]);
    await longPress(tester, chip(0, 'dump', 'd-5'));
    await choose(tester, ItemAction.delete);
    await tester.tap(
      find.byKey(const ValueKey<String>('ask-source-delete-confirm')),
    );
    await pumpFrames(tester);
    expect(find.textContaining('Could not delete'), findsOneWidget);
    await unmount(tester);
  });

  Future<void> deleteVia404(WidgetTester tester, String id) async {
    serverStatus = 404;
    deletion.result = (
      replayed: false,
      items: <DeletionItemResult>[itemFor(id, DeleteState.deleted)],
    );
    await mount(tester, <AskSource>[
      AskSource(entityType: 'dump', entityId: id, snippet: 'z'),
    ]);
    await longPress(tester, chip(0, 'dump', id));
    await choose(tester, ItemAction.delete);
    await tester.tap(
      find.byKey(const ValueKey<String>('ask-source-delete-confirm')),
    );
    await pumpFrames(tester);
  }

  testWidgets('synced recording + server 404: nothing deleted locally, error',
      (tester) async {
    await insertDump('d-404s', 'Synced one', syncedSeq: 41);
    await deleteVia404(tester, 'd-404s');
    expect(log, <String>['server-delete:d-404s:previews=2:leased=true']);
    expect(deletion.deleted, isEmpty);
    expect(find.textContaining('Could not delete'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets(
      'upload attempted but unconfirmed + server 404: keeps local copy, error',
      (tester) async {
    await insertDump(
      'd-404a',
      'Timed-out upload',
      syncStatus: 'failed',
      syncAttempts: 1,
    );
    await deleteVia404(tester, 'd-404a');
    expect(log, <String>['server-delete:d-404a:previews=2:leased=true']);
    expect(deletion.deleted, isEmpty);
    expect(find.textContaining('Could not delete'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('local-only recording + server 404: local delete proceeds',
      (tester) async {
    await insertDump('d-404l', 'Never uploaded', syncStatus: 'local_only');
    await deleteVia404(tester, 'd-404l');
    expect(log, <String>['server-delete:d-404l:previews=2:leased=true']);
    expect(deletion.deletes.single.targets.single.id, 'd-404l');
    expect(find.textContaining('Could not delete'), findsNothing);
    await unmount(tester);
  });

  testWidgets('pending capture with zero upload attempts + 404 proceeds',
      (tester) async {
    await insertDump('d-404p', 'Fresh capture', syncStatus: 'pending');
    await deleteVia404(tester, 'd-404p');
    expect(deletion.deletes.single.targets.single.id, 'd-404p');
    expect(find.textContaining('Could not delete'), findsNothing);
    await unmount(tester);
  });

  testWidgets('ineligible recording: Delete greyed with reason, no server call',
      (tester) async {
    await insertDump('d-busy', 'Transcribing');
    deletion.previewTargets = <DeleteTarget>[
      (
        id: 'd-busy',
        title: 'Transcribing',
        eligibility: Eligibility.nonterminal,
        retryTicketId: null,
        binding: targetFor('d-busy').binding,
      ),
    ];
    await mount(tester, <AskSource>[
      const AskSource(entityType: 'dump', entityId: 'd-busy', snippet: 'b'),
    ]);
    await longPress(tester, chip(0, 'dump', 'd-busy'));
    expect(find.text('Transcription in progress'), findsOneWidget);
    await tester.tap(find.byKey(ItemActionSheet.keyFor(ItemAction.delete)));
    await pumpFrames(tester);
    expect(
      find.byKey(const ValueKey<String>('ask-source-delete-confirm')),
      findsNothing,
    );
    expect(log, isEmpty);
    expect(deletion.deletes, isEmpty);
    await unmount(tester);
  });

  testWidgets('provider refuses an ineligible row BEFORE any server delete',
      (tester) async {
    final List<String> serverCalls = <String>[];
    deletion.previewTargets = <DeleteTarget>[
      (
        id: 'd-busy2',
        title: 'Busy',
        eligibility: Eligibility.busy,
        retryTicketId: null,
        binding: targetFor('d-busy2').binding,
      ),
    ];
    final ProviderContainer c = ProviderContainer(
      overrides: <Override>[
        localDbProvider.overrideWithValue(db),
        localDeletionServiceProvider.overrideWithValue(deletion),
        askSourceServerDeleteProvider
            .overrideWithValue((String id) async => serverCalls.add(id)),
      ],
    );
    Object? caught;
    await tester.runAsync(() async {
      await insertDump('d-busy2', 'Busy');
      try {
        await c.read(askSourceDeleteDumpProvider)('d-busy2');
      } catch (error) {
        caught = error;
      }
    });
    expect(caught, isA<StorageFault>());
    expect(serverCalls, isEmpty);
    expect(deletion.deletes, isEmpty);
    c.dispose();
    await tester.runAsync(db.close);
  });

  testWidgets(
      'TOCTOU: eligible at preview, busy by the time of the lease → '
      'no server delete, nothing deleted', (tester) async {
    final List<String> serverCalls = <String>[];
    // Preview says eligible; the recording becomes busy before deletion
    // can take its lease (e.g. sync or playback started in between).
    deletion.leaseBusy.add('d-race');
    final ProviderContainer c = ProviderContainer(
      overrides: <Override>[
        localDbProvider.overrideWithValue(db),
        localDeletionServiceProvider.overrideWithValue(deletion),
        askSourceServerDeleteProvider
            .overrideWithValue((String id) async => serverCalls.add(id)),
      ],
    );
    Object? caught;
    await tester.runAsync(() async {
      await insertDump('d-race', 'Raced');
      try {
        await c.read(askSourceDeleteDumpProvider)('d-race');
      } catch (error) {
        caught = error;
      }
    });
    expect(caught, isA<StorageFault>());
    expect(serverCalls, isEmpty, reason: 'no tombstone without the lease');
    expect(deletion.deleted, isEmpty);
    c.dispose();
    await tester.runAsync(db.close);
  });

  testWidgets('server failure inside the lease surfaces the server error',
      (tester) async {
    final ProviderContainer c = ProviderContainer(
      overrides: <Override>[
        localDbProvider.overrideWithValue(db),
        localDeletionServiceProvider.overrideWithValue(deletion),
        askSourceServerDeleteProvider.overrideWithValue(
          (String id) async => throw const ApiException(
            statusCode: 500,
            code: 'server_error',
            message: 'boom',
          ),
        ),
      ],
    );
    Object? caught;
    await tester.runAsync(() async {
      await insertDump('d-500', 'Server fails');
      try {
        await c.read(askSourceDeleteDumpProvider)('d-500');
      } catch (error) {
        caught = error;
      }
    });
    expect(caught, isA<ApiException>());
    expect((caught! as ApiException).statusCode, 500);
    expect(deletion.deleted, isEmpty);
    c.dispose();
    await tester.runAsync(db.close);
  });
}

/// Drift completes on real async; interleave real delays with frames so
/// repository writes and their watch streams land between pumps.
Future<void> pumpFrames(WidgetTester tester) async {
  for (int i = 0; i < 4; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 150));
  }
}
