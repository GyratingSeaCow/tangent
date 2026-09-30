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
import 'package:tangent/screens/home/home_screen.dart' show localDbProvider;
import 'package:tangent/services/ask_client.dart';

class _Db extends Mock implements LocalDb {}

class _Dump extends Mock implements DumpRow {}

Widget _app({
  required List<AskHistoryMessage> history,
  LocalDb? db,
  AskVoiceQuestion? voice,
  AskOpenDestination? openDestination,
}) =>
    ProviderScope(
      overrides: <Override>[
        askHistoryProvider.overrideWith((ref) => Stream.value(history)),
        localDbProvider.overrideWithValue(db ?? _Db()),
      ],
      child: MaterialApp(
        home: AskScreen(
          voiceQuestion: voice ?? () async => null,
          openDestination: openDestination,
        ),
      ),
    );

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
    final chip = find.byKey(const Key('ask-source-a-17-dump-dump-42'));
    expect(
      find.descendant(of: chip, matching: find.text('Recording 0:42')),
      findsOneWidget,
    );
    final cards = tester.widgetList<Card>(find.byType(Card)).toList();
    expect((cards[0].key as Key).toString(), contains('u-17'));
    expect((cards[1].key as Key).toString(), contains('a-17'));
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
    await tester.tap(find.byKey(const Key('ask-source-a-miss-dump-gone-73')));
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
    final chip = find.byKey(const Key('ask-source-a-route-dump-dump-42'));
    await tester.tap(chip);
    await tester.pump();
    final screen = opened! as DumpDetailScreen;
    expect(screen.dumpId, 'dump-42');
    expect(screen.initialSeekSeconds, 42.5);
  });

  testWidgets('mic transcription auto-submits and exposes pending state',
      (tester) async {
    final completer = Completer<String?>();
    await tester
        .pumpWidget(_app(history: const [], voice: () => completer.future));
    await tester.pump();
    await tester.tap(find.byKey(const Key('ask-mic')));
    completer.complete('Where is project Zephyr?');
    await tester.pump();
    expect(find.byKey(const Key('ask-pending')), findsOneWidget);
  });
}
