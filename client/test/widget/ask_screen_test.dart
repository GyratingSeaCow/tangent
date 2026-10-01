// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:tangent/data/ask_history_repository.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/screens/ask/ask_screen.dart';
import 'package:tangent/screens/dump/dump_detail_screen.dart';
import 'package:tangent/screens/home/home_providers.dart'
    show documentSyncEngineProvider;
import 'package:tangent/screens/home/home_screen.dart' show localDbProvider;
import 'package:tangent/services/ask_client.dart';
import 'package:tangent/services/document_sync_engine.dart';
import 'package:tangent/models/api_exception.dart';
import 'package:tangent/screens/recording/recording_controller.dart';

class _Db extends Mock implements LocalDb {}

/// Default stubs for the local-only visited-citation bookkeeping, which every
/// Ask render and every citation tap touches. Without these mocktail throws a
/// MissingStub from inside `_openSource`, BEFORE navigation runs, so unrelated
/// tests fail with a misleading "no destination opened".
///
/// [visits] lets a test declare which citations are already opened. `_app`
/// applies the empty default only when a test has not stubbed the stream
/// itself, so a per-test `when(...)` is never silently overwritten.
void _stubVisits(_Db db, {Set<String> visits = const <String>{}}) {
  when(() => db.watchAskSourceVisits())
      .thenAnswer((_) => Stream<Set<String>>.value(visits));
  when(
    () => db.markAskSourceVisited(
      messageId: any(named: 'messageId'),
      sourceIndex: any(named: 'sourceIndex'),
    ),
  ).thenAnswer((_) async {});
}

class _Dump extends Mock implements DumpRow {}

class _AskClient extends Mock implements AskClient {}

class _SyncEngine extends Mock implements DocumentSyncEngine {}

class _VoiceRecorder implements AskVoiceRecorderPort {
  _VoiceRecorder(this.row);
  final DumpRow row;
  @override
  RecordingState state = RecordingState.recording;
  @override
  Future<void> start() async => state = RecordingState.recording;
  @override
  Future<DumpRow?> stop() async {
    state = RecordingState.idle;
    return row;
  }
}

Widget _app({
  required List<AskHistoryMessage> history,
  LocalDb? db,
  AskVoiceQuestion? voice,
  AskOpenDestination? openDestination,
}) {
  final LocalDb resolved = db ?? _Db();
  if (resolved is _Db) {
    // Only supply the default when the test has not stubbed the stream, so a
    // per-test `when(() => db.watchAskSourceVisits())` survives.
    try {
      resolved.watchAskSourceVisits();
    } catch (_) {
      _stubVisits(resolved);
    }
  }
  return ProviderScope(
    overrides: <Override>[
      askHistoryProvider.overrideWith((ref) => Stream.value(history)),
      localDbProvider.overrideWithValue(resolved),
    ],
    child: MaterialApp(
      home: AskScreen(
        voiceQuestion: voice ?? () async => null,
        openDestination: openDestination,
      ),
    ),
  );
}

void main() {
  testWidgets('renders ordered user and assistant history with scoped citation',
      (tester) async {
    final messages = <AskHistoryMessage>[
      AskHistoryMessage(
        id: 'u-17',
        role: 'user',
        text: 'When was lunch?',
        sources: const [],
        createdAt: DateTime.utc(2026, 9, 30, 12),
      ),
      AskHistoryMessage(
        id: 'a-17',
        role: 'assistant',
        text: 'Lunch was at 12:45.',
        sources: const <AskSource>[
          AskSource(
            entityType: 'dump',
            entityId: 'dump-42',
            snippet: 'lunch starts',
            seekSeconds: 42.5,
          ),
        ],
        createdAt: DateTime.utc(2026, 9, 30, 12),
      ),
    ];
    await tester.pumpWidget(_app(history: messages));
    await tester.pump();
    expect(find.text('When was lunch?'), findsOneWidget);
    expect(find.text('Lunch was at 12:45.'), findsOneWidget);
    final chip = find.byKey(const Key('ask-source-a-17-0-dump-dump-42'));
    expect(
      find.descendant(of: chip, matching: find.text('Recording 0:42')),
      findsOneWidget,
    );
    // Visual order: the question sits ABOVE its answer (the list is built
    // newest-first under reverse: true, so assert positions, not build order).
    final double userY = tester
        .getTopLeft(find.byKey(const ValueKey<String>('ask-message-u-17')))
        .dy;
    final double answerY = tester
        .getTopLeft(find.byKey(const ValueKey<String>('ask-message-a-17')))
        .dy;
    expect(userY, lessThan(answerY));
  });

  testWidgets('opens on the NEWEST message of a multi-screen history',
      (tester) async {
    final List<AskHistoryMessage> messages = <AskHistoryMessage>[
      for (int i = 0; i < 40; i++)
        AskHistoryMessage(
          id: 'm-$i',
          role: i.isEven ? 'user' : 'assistant',
          text: 'Message number $i',
          sources: const [],
          createdAt: DateTime.utc(2026, 9, 29, 8).add(Duration(minutes: i)),
        ),
    ];
    await tester.pumpWidget(_app(history: messages));
    await tester.pump();
    // No scrolling at all: the latest answer is on screen, the oldest is not.
    expect(find.text('Message number 39'), findsOneWidget);
    expect(find.text('Message number 38'), findsOneWidget);
    expect(find.text('Message number 0'), findsNothing);
    final Rect view =
        tester.getRect(find.byKey(const ValueKey<String>('ask-history')));
    final Rect newest = tester.getRect(find.text('Message number 39'));
    expect(view.contains(newest.topLeft) && view.contains(newest.bottomRight),
        isTrue,);
    expect(tester.takeException(), isNull);
  });

  testWidgets('citations stack one per line in a single left-aligned column',
      (tester) async {
    tester.view.physicalSize = const Size(1248, 1972);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);
    final message = AskHistoryMessage(
      id: 'a-col',
      role: 'assistant',
      text: "I couldn't find that in your notes",
      sources: const <AskSource>[
        AskSource(
          entityType: 'todo',
          entityId: 'todo-1',
          snippet: 'todo',
          seekSeconds: null,
        ),
        AskSource(
          entityType: 'dump',
          entityId: 'dump-1',
          snippet: 'a',
          seekSeconds: 34,
        ),
        AskSource(
          entityType: 'dump',
          entityId: 'dump-2',
          snippet: 'b',
          seekSeconds: 116,
        ),
        AskSource(
          entityType: 'dump',
          entityId: 'dump-3',
          snippet: 'c',
          seekSeconds: 39,
        ),
      ],
      createdAt: DateTime.utc(2026, 9, 30),
    );
    await tester.pumpWidget(_app(history: <AskHistoryMessage>[message]));
    await tester.pump();

    final List<Rect> rects = <Rect>[
      tester.getRect(find.byKey(const Key('ask-source-a-col-0-todo-todo-1'))),
      tester.getRect(find.byKey(const Key('ask-source-a-col-1-dump-dump-1'))),
      tester.getRect(find.byKey(const Key('ask-source-a-col-2-dump-dump-2'))),
      tester.getRect(find.byKey(const Key('ask-source-a-col-3-dump-dump-3'))),
    ];

    // Every citation starts at the same left edge: one readable column.
    for (final Rect rect in rects) {
      expect(rect.left, moreOrLessEquals(rects.first.left, epsilon: 0.5));
    }
    // Each citation sits strictly BELOW the previous one -- never side by side.
    for (int i = 1; i < rects.length; i++) {
      expect(
        rects[i].top,
        greaterThanOrEqualTo(rects[i - 1].bottom - 0.5),
        reason: 'citation $i shares a row with ${i - 1}; layout reflowed',
      );
    }
    // Rows span the bubble so the whole line is a tap target, not a pill.
    expect(rects.first.width, greaterThan(200));
    // No chip cloud remains.
    expect(find.byType(ActionChip), findsNothing);
  });

  testWidgets('visited citation dims and shows a check; unvisited does not',
      (tester) async {
    final db = _Db();
    // Source 1 has been opened before; source 0 has not.
    _stubVisits(db, visits: const <String>{'a-v#1'});
    final message = AskHistoryMessage(
      id: 'a-v',
      role: 'assistant',
      text: 'Two sources',
      sources: const <AskSource>[
        AskSource(
          entityType: 'dump',
          entityId: 'd-0',
          snippet: 'unvisited',
          seekSeconds: 10,
        ),
        AskSource(
          entityType: 'dump',
          entityId: 'd-1',
          snippet: 'visited',
          seekSeconds: 20,
        ),
      ],
      createdAt: DateTime.utc(2026, 9, 30),
    );
    await tester
        .pumpWidget(_app(history: <AskHistoryMessage>[message], db: db));
    await tester.pump();

    final Finder unvisited = find.byKey(const Key('ask-source-a-v-0-dump-d-0'));
    final Finder visited = find.byKey(const Key('ask-source-a-v-1-dump-d-1'));

    // The visited row swaps its leading icon for a filled check.
    expect(
      find.descendant(of: visited, matching: find.byIcon(Icons.check_circle)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: unvisited, matching: find.byIcon(Icons.check_circle)),
      findsNothing,
    );
    expect(
      find.descendant(of: unvisited, matching: find.byIcon(Icons.mic)),
      findsOneWidget,
    );

    // ...and dims, so the distinction survives a monochrome/colourblind read.
    double opacityOf(Finder row) => tester
        .widgetList<Opacity>(
          find.descendant(of: row, matching: find.byType(Opacity)),
        )
        .first
        .opacity;
    expect(opacityOf(visited), lessThan(opacityOf(unvisited)));
    expect(opacityOf(unvisited), 1.0);
  });

  testWidgets('opening a citation records the visit', (tester) async {
    final db = _Db();
    _stubVisits(db);
    when(() => db.getDumpRow('d-9')).thenAnswer((_) async => null);
    final message = AskHistoryMessage(
      id: 'a-mark',
      role: 'assistant',
      text: 'One source',
      sources: const <AskSource>[
        AskSource(
          entityType: 'dump',
          entityId: 'd-9',
          snippet: 'tapped',
          seekSeconds: 5,
        ),
      ],
      createdAt: DateTime.utc(2026, 9, 30),
    );
    await tester
        .pumpWidget(_app(history: <AskHistoryMessage>[message], db: db));
    await tester.pump();
    await tester.tap(find.byKey(const Key('ask-source-a-mark-0-dump-d-9')));
    await tester.pump();
    verify(
      () => db.markAskSourceVisited(messageId: 'a-mark', sourceIndex: 0),
    ).called(1);
  });

  testWidgets('missing citation remains visible and reports honest miss',
      (tester) async {
    final db = _Db();
    when(() => db.getDumpRow('gone-73')).thenAnswer((_) async => null);
    final message = AskHistoryMessage(
      id: 'a-miss',
      role: 'assistant',
      text: 'Old answer',
      sources: const <AskSource>[
        AskSource(
          entityType: 'dump',
          entityId: 'gone-73',
          snippet: 'deleted passage',
          seekSeconds: 42.5,
        ),
      ],
      createdAt: DateTime.utc(2026, 9, 30),
    );
    await tester
        .pumpWidget(_app(history: <AskHistoryMessage>[message], db: db));
    await tester.pump();
    await tester.tap(find.byKey(const Key('ask-source-a-miss-0-dump-gone-73')));
    await tester.pump();
    expect(
      find.text('Source no longer exists: deleted passage'),
      findsOneWidget,
    );
  });

  testWidgets('scoped dump citation passes the observed 42.5 second seek',
      (tester) async {
    final db = _Db();
    final dump = _Dump();
    when(() => dump.id).thenReturn('dump-42');
    when(() => dump.audioPath).thenReturn('C:/recordings/lunch.m4a');
    when(() => dump.durationSeconds).thenReturn(173);
    when(() => db.getDumpRow('dump-42')).thenAnswer((_) async => dump);
    Widget? opened;
    final message = AskHistoryMessage(
      id: 'a-route',
      role: 'assistant',
      text: 'Lunch citation',
      sources: const <AskSource>[
        AskSource(
          entityType: 'dump',
          entityId: 'dump-42',
          snippet: 'lunch begins',
          seekSeconds: 42.5,
        ),
      ],
      createdAt: DateTime.utc(2026, 9, 30),
    );
    await tester.pumpWidget(
      _app(
        history: <AskHistoryMessage>[message],
        db: db,
        openDestination: (destination) async => opened = destination,
      ),
    );
    await tester.pump();
    final chip = find.byKey(const Key('ask-source-a-route-0-dump-dump-42'));
    await tester.tap(chip);
    await tester.pump();
    final screen = opened! as DumpDetailScreen;
    expect(screen.dumpId, 'dump-42');
    expect(screen.initialSeekSeconds, 42.5);
  });

  testWidgets('mic transcription auto-submits and exposes pending state',
      (tester) async {
    final ask = _AskClient();
    final engine = _SyncEngine();
    final response = Completer<AskResponse>();
    when(() => ask.ask('Where is project Zephyr?'))
        .thenAnswer((_) => response.future);
    when(() => engine.syncNow()).thenAnswer(
      (_) async => const SyncReport(outcome: SyncOutcome.success),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          askHistoryProvider.overrideWith((ref) => Stream.value(const [])),
          localDbProvider.overrideWithValue(_Db()),
          askClientProvider.overrideWith((ref) async => ask),
          documentSyncEngineProvider.overrideWithValue(engine),
        ],
        child: MaterialApp(
          home:
              AskScreen(voiceQuestion: () async => 'Where is project Zephyr?'),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('ask-mic')));
    await tester.pump();
    expect(find.byKey(const Key('ask-pending')), findsOneWidget);
    verify(() => ask.ask('Where is project Zephyr?')).called(1);
    response.complete(const AskResponse(answer: 'On desk', sources: []));
    await tester.pumpAndSettle();
  });

  testWidgets('successful ask triggers a sync pull; failed ask does not',
      (tester) async {
    final ask = _AskClient();
    final engine = _SyncEngine();
    when(() => ask.ask('Where did we leave the Zephyr build?')).thenAnswer(
      (_) async => const AskResponse(answer: 'On the bench PC', sources: []),
    );
    var syncCalls = 0;
    when(() => engine.syncNow()).thenAnswer((_) async {
      syncCalls++;
      return syncCalls == 1
          ? const SyncReport(outcome: SyncOutcome.alreadyRunning)
          : const SyncReport(outcome: SyncOutcome.success, pulled: 2);
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          askHistoryProvider.overrideWith(
            (ref) => Stream.value(const <AskHistoryMessage>[]),
          ),
          localDbProvider.overrideWithValue(_Db()),
          askClientProvider.overrideWith((ref) async => ask),
          documentSyncEngineProvider.overrideWithValue(engine),
        ],
        child: MaterialApp(home: AskScreen(voiceQuestion: () async => null)),
      ),
    );
    await tester.pump();
    await tester.enterText(
      find.byKey(const Key('ask-question')),
      'Where did we leave the Zephyr build?',
    );
    await tester.tap(find.byKey(const Key('ask-send')));
    await tester.pumpAndSettle();
    // The server-authored history rows only arrive via the pull: a successful
    // ask that skips syncNow leaves the answer invisible until next resume.
    verify(() => engine.syncNow()).called(2);

    // Failure path: the pull must NOT run when the ask itself failed.
    final failingAsk = _AskClient();
    final idleEngine = _SyncEngine();
    when(() => failingAsk.ask(any())).thenThrow(Exception('unreachable'));
    when(() => idleEngine.syncNow()).thenAnswer(
      (_) async => const SyncReport(outcome: SyncOutcome.success),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          askHistoryProvider.overrideWith(
            (ref) => Stream.value(const <AskHistoryMessage>[]),
          ),
          localDbProvider.overrideWithValue(_Db()),
          askClientProvider.overrideWith((ref) async => failingAsk),
          documentSyncEngineProvider.overrideWithValue(idleEngine),
        ],
        child: MaterialApp(home: AskScreen(voiceQuestion: () async => null)),
      ),
    );
    await tester.pump();
    await tester.enterText(
      find.byKey(const Key('ask-question')),
      'Anything at all?',
    );
    await tester.tap(find.byKey(const Key('ask-send')));
    await tester.pumpAndSettle();
    expect(find.text('Server unreachable. Try again.'), findsOneWidget);
    verifyNever(() => idleEngine.syncNow());
  });

  testWidgets('409 renders install guidance rather than unreachable',
      (tester) async {
    final ask = _AskClient();
    final engine = _SyncEngine();
    when(() => ask.ask(any())).thenThrow(
      const ApiException(
        statusCode: 409,
        code: 'http_error',
        message: 'Summarizer environment is not installed',
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          askHistoryProvider.overrideWith((ref) => Stream.value(const [])),
          localDbProvider.overrideWithValue(_Db()),
          askClientProvider.overrideWith((ref) async => ask),
          documentSyncEngineProvider.overrideWithValue(engine),
        ],
        child: MaterialApp(home: AskScreen(voiceQuestion: () async => null)),
      ),
    );
    await tester.pump();
    await tester.enterText(find.byKey(const Key('ask-question')), 'Use AI?');
    await tester.tap(find.byKey(const Key('ask-send')));
    await tester.pumpAndSettle();
    expect(find.text('Install AI summaries in Settings first'), findsOneWidget);
    expect(find.text('Server unreachable. Try again.'), findsNothing);
    verifyNever(() => engine.syncNow());
  });

  testWidgets('same recording can render and open two independent seeks',
      (tester) async {
    final db = _Db();
    final dump = _Dump();
    when(() => dump.id).thenReturn('dump-1');
    when(() => dump.audioPath).thenReturn('C:/recordings/two.m4a');
    when(() => dump.durationSeconds).thenReturn(90);
    when(() => db.getDumpRow('dump-1')).thenAnswer((_) async => dump);
    final opened = <DumpDetailScreen>[];
    final message = AskHistoryMessage(
      id: 'multi',
      role: 'assistant',
      text: 'Two moments',
      sources: const [
        AskSource(
          entityType: 'dump',
          entityId: 'dump-1',
          snippet: 'first',
          seekSeconds: 1.0,
        ),
        AskSource(
          entityType: 'dump',
          entityId: 'dump-1',
          snippet: 'second',
          seekSeconds: 20.0,
        ),
      ],
      createdAt: DateTime.utc(2026, 9, 30),
    );
    await tester.pumpWidget(
      _app(
        history: [message],
        db: db,
        openDestination: (widget) async =>
            opened.add(widget as DumpDetailScreen),
      ),
    );
    await tester.pump();
    final first = find.byKey(const Key('ask-source-multi-0-dump-dump-1'));
    final second = find.byKey(const Key('ask-source-multi-1-dump-dump-1'));
    expect(
      find.descendant(of: first, matching: find.text('Recording 0:01')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: second, matching: find.text('Recording 0:20')),
      findsOneWidget,
    );
    await tester.tap(first);
    await tester.pump();
    await tester.tap(second);
    await tester.pump();
    expect(opened.map((screen) => screen.initialSeekSeconds), [1.0, 20.0]);
  });

  for (final fixture in <({int seconds, bool discarded, String transcript})>[
    (seconds: 24, discarded: true, transcript: 'Short Zephyr voice question'),
    (seconds: 26, discarded: false, transcript: 'Long Juniper voice question'),
  ]) {
    testWidgets('real mic branch ${fixture.seconds}s retention path',
        (tester) async {
      final row = _Dump();
      when(() => row.id).thenReturn('voice-${fixture.seconds}');
      when(() => row.durationSeconds).thenReturn(fixture.seconds);
      when(() => row.audioPath)
          .thenReturn('content://media/external/audio/ask-probe');
      final recorder = _VoiceRecorder(row);
      final ask = _AskClient();
      final engine = _SyncEngine();
      final transcribed = <String>[];
      final discarded = <String>[];
      when(() => ask.ask(fixture.transcript)).thenAnswer(
        (_) async => const AskResponse(answer: 'answer', sources: []),
      );
      when(() => engine.syncNow()).thenAnswer(
        (_) async => const SyncReport(outcome: SyncOutcome.success),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            askHistoryProvider.overrideWith((ref) => Stream.value(const [])),
            localDbProvider.overrideWithValue(_Db()),
            askClientProvider.overrideWith((ref) async => ask),
            documentSyncEngineProvider.overrideWithValue(engine),
            askVoiceRecorderProvider.overrideWithValue(recorder),
            askVoiceTranscribeProvider.overrideWithValue((captured) async {
              transcribed.add(captured.id);
              return fixture.transcript;
            }),
            askVoiceDiscardProvider.overrideWithValue((captured) async {
              expect(
                captured.audioPath,
                'content://media/external/audio/ask-probe',
              );
              discarded.add(captured.id);
            }),
          ],
          child: const MaterialApp(home: AskScreen()),
        ),
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('ask-mic')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      expect(transcribed, <String>['voice-${fixture.seconds}']);
      verify(() => ask.ask(fixture.transcript)).called(1);
      expect(
        discarded,
        fixture.discarded ? <String>['voice-${fixture.seconds}'] : isEmpty,
      );
      expect(find.byKey(const Key('ask-pending')), findsNothing);
      expect(
        tester.widget<IconButton>(find.byKey(const Key('ask-mic'))).onPressed,
        isNotNull,
      );
      expect(
        tester.widget<IconButton>(find.byKey(const Key('ask-send'))).onPressed,
        isNotNull,
      );
    });
  }

  testWidgets('real mic 409 renders summaries installation guidance',
      (tester) async {
    final row = _Dump();
    when(() => row.id).thenReturn('voice-409');
    when(() => row.durationSeconds).thenReturn(26);
    final ask = _AskClient();
    when(() => ask.ask('Voice asks for unavailable summaries')).thenThrow(
      const ApiException(
        statusCode: 409,
        code: 'summarizer_missing',
        message: 'summarizer missing',
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          askHistoryProvider.overrideWith((ref) => Stream.value(const [])),
          localDbProvider.overrideWithValue(_Db()),
          askClientProvider.overrideWith((ref) async => ask),
          askVoiceRecorderProvider.overrideWithValue(_VoiceRecorder(row)),
          askVoiceTranscribeProvider.overrideWithValue(
            (_) async => 'Voice asks for unavailable summaries',
          ),
        ],
        child: const MaterialApp(home: AskScreen()),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('ask-mic')));
    await tester.pump();
    expect(
      find.text('Install AI summaries in Settings first'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('ask-pending')), findsNothing);
  });

  testWidgets('mic icon rebuilds when the real recorder adapter state changes',
      (tester) async {
    // Uses the REAL askVoiceRecorderProvider adapter (no overrideWithValue)
    // over a fake state machine, pinning that the provider subscribes to
    // recordingControllerProvider: without that watch the icon freezes on
    // its first-build state and never shows the stop affordance.
    final controller = _MutableRecordingController(RecordingState.idle);
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          askHistoryProvider.overrideWith((ref) => Stream.value(const [])),
          localDbProvider.overrideWithValue(_Db()),
          recordingControllerProvider.overrideWith((ref) => controller),
        ],
        child: const MaterialApp(home: AskScreen()),
      ),
    );
    await tester.pump();
    expect(find.byIcon(Icons.stop), findsNothing);
    controller.set(RecordingState.recording);
    await tester.pump();
    expect(
      find.descendant(
        of: find.byKey(const Key('ask-mic')),
        matching: find.byIcon(Icons.stop),
      ),
      findsOneWidget,
    );
  });
}

/// Fake state machine for the REAL adapter path: state can be driven by the
/// test without standing up the recorder's seven collaborators.
class _MutableRecordingController extends StateNotifier<RecordingState>
    implements RecordingController {
  _MutableRecordingController(super.initial);

  void set(RecordingState next) => state = next;

  @override
  bool get isRecording => state == RecordingState.recording;

  @override
  int get elapsedSeconds => 0;

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
