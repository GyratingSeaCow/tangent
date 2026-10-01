// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Instrument Console v2 on the Ask screen:
//  * the rail rides beneath the screen's own app bar with Ask lit and inert;
//  * NO create FAB — the compose row (question field, mic, send) owns the
//    bottom of the screen, and a FAB over the send button would be a
//    mis-tap trap;
//  * the compose row and its actions survive the restyle untouched.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/ask_history_repository.dart';
import 'package:tangent/screens/ask/ask_screen.dart';
import 'package:tangent/screens/ask/ask_source_actions.dart';
import 'package:tangent/services/ask_client.dart' show AskSource;
import 'package:tangent/widgets/top_nav_rail.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> mountAsk(
    WidgetTester tester, {
    List<AskHistoryMessage> history = const <AskHistoryMessage>[],
  }) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          askHistoryProvider.overrideWith((ref) => Stream.value(history)),
          askSourceVisitsProvider.overrideWith(
            (ref) => Stream.value(const <String>{}),
          ),
          askSourceEntitiesProvider.overrideWith(
            (ref) => Stream.value(const <String, AskSourceEntity>{}),
          ),
        ],
        child: MaterialApp(
          home: AskScreen(voiceQuestion: () async => null),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  testWidgets('the rail rides beneath the Ask app bar, lit and inert',
      (tester) async {
    await mountAsk(tester);

    final Finder active = find.byKey(railKey(TangentRoot.ask));
    expect(active, findsOneWidget);
    expect(
      tester.widget<IconButton>(active).onPressed,
      isNull,
      reason: 'the active destination is lit, not a navigation target',
    );
    expect(
      // Mockup order: app bar first, rail beneath it.
      tester.getTopLeft(find.byType(TopNavRail)).dy,
      greaterThanOrEqualTo(tester.getBottomLeft(find.text('Ask')).dy),
    );
    expect(tester.takeException(), isNull);

    await unmount(tester);
  });

  testWidgets('no FAB covers the compose row — the input owns the bottom',
      (tester) async {
    await mountAsk(tester);

    expect(
      find.byType(FloatingActionButton),
      findsNothing,
      reason: 'a create key over the send button would be a mis-tap trap',
    );
    // The compose row keeps its three controls.
    expect(find.byKey(const Key('ask-question')), findsOneWidget);
    expect(find.byKey(const Key('ask-mic')), findsOneWidget);
    expect(find.byKey(const Key('ask-send')), findsOneWidget);
    expect(tester.takeException(), isNull);

    await unmount(tester);
  });

  testWidgets('history still renders under the rail', (tester) async {
    await mountAsk(
      tester,
      history: <AskHistoryMessage>[
        AskHistoryMessage(
          id: 'u-1',
          role: 'user',
          text: 'When was lunch?',
          sources: const <AskSource>[],
          createdAt: DateTime.utc(2026, 9, 30, 12),
        ),
        AskHistoryMessage(
          id: 'a-1',
          role: 'assistant',
          text: 'Lunch was at 12:45.',
          sources: const <AskSource>[],
          createdAt: DateTime.utc(2026, 9, 30, 12, 1),
        ),
      ],
    );

    expect(find.text('When was lunch?'), findsOneWidget);
    expect(find.text('Lunch was at 12:45.'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await unmount(tester);
  });
}
