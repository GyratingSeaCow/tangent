// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/models/dump.dart';
import 'package:tangent/models/dump_mode.dart';
import 'package:tangent/models/sync_status.dart';
import 'package:tangent/widgets/notebook_dump_card.dart';

Dump _dump({
  String id = 'd1',
  String title = 'Morning ideas',
  DumpMode mode = DumpMode.brainDump,
  int durationSeconds = 95,
}) {
  final at = DateTime(2026, 9, 17, 10, 30);
  return Dump(
    id: id,
    createdAt: at,
    updatedAt: at,
    mode: mode,
    durationSeconds: durationSeconds,
    title: title,
    audioPath: '/audio/$id.m4a',
    audioSizeBytes: 2048,
    syncStatus: SyncStatus.localOnly,
  );
}

/// Pumps a card inside a Stack canvas, keeping [position] in local state so
/// successive drag deltas accumulate exactly as they would on the notebook.
Future<Offset Function()> _pumpCard(
  WidgetTester tester, {
  required Dump? dump,
  Offset start = const Offset(20, 30),
  VoidCallback? onTap,
  VoidCallback? onRemove,
}) async {
  var position = start;
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) => Stack(
            children: [
              NotebookDumpCard(
                dump: dump,
                position: position,
                onPositionChanged: (next) => setState(() => position = next),
                onTap: onTap,
                onRemove: onRemove,
              ),
            ],
          ),
        ),
      ),
    ),
  );
  return () => position;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a real finger tap opens the card even though it jitters',
      (tester) async {
    // Jeff: "the recordings in notebooks, when you tap on them, it no longer
    // links into the recording so you can review it".
    //
    // tester.tap() moves EXACTLY zero pixels, so it never produced a
    // PointerMoveEvent and the eager recognizer stayed out of the way. A real
    // finger always slides a pixel or two, which the recognizer was claiming
    // as a drag -- swallowing the tap. This reproduces the human gesture.
    var opened = 0;
    await _pumpCard(tester, dump: _dump(), onTap: () => opened++);

    final TestGesture gesture =
        await tester.startGesture(tester.getCenter(find.text('Morning ideas')));
    // Well under kTouchSlop (18px): a human tap, not a drag.
    await gesture.moveBy(const Offset(1.5, 1.5));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(
      opened,
      1,
      reason: 'a tap that wobbles a pixel must still open the recording',
    );
  });

  testWidgets('a real finger tap still presses the remove button',
      (tester) async {
    // Jeff: "The X on the boxes aren't working".
    var removed = 0;
    await _pumpCard(tester, dump: _dump(), onRemove: () => removed++);

    final TestGesture gesture =
        await tester.startGesture(tester.getCenter(find.byIcon(Icons.close)));
    await gesture.moveBy(const Offset(1.5, 1.5));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(
      removed,
      1,
      reason: 'a slightly-wobbly tap on X must still remove the card',
    );
  });

  testWidgets('a SLOW drag still moves the card', (tester) async {
    // Jeff: "when you add in a dump or text note etc. into the notebooks, it
    // can no longer be dragged and put somewhere else on the screen".
    //
    // Device evidence, same card and same path, only speed changed:
    //   fast 120ms swipe -> card moves
    //   slow 900ms swipe -> card does not move at all
    // A slow finger delivers 1-2px move events. The touch-slop check added to
    // fix stolen taps measured each event in isolation, so no single event
    // ever exceeded the slop and the card never claimed the gesture. The
    // distance must accumulate from where the pointer went DOWN.
    final position = await _pumpCard(tester, dump: _dump());

    final TestGesture gesture =
        await tester.startGesture(tester.getCenter(find.text('Morning ideas')));
    for (int i = 0; i < 40; i++) {
      await gesture.moveBy(const Offset(1.5, 1.5));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();

    expect(
      position(),
      isNot(const Offset(20, 30)),
      reason: 'a slow drag is still a drag: 40 x 1.5px = 60px of travel',
    );
  });

  testWidgets('a deliberate drag is still a drag, not a tap', (tester) async {
    // The fix must not go too far the other way: past the slop it is a drag.
    var opened = 0;
    final position = await _pumpCard(
      tester,
      dump: _dump(),
      onTap: () => opened++,
    );

    final TestGesture gesture =
        await tester.startGesture(tester.getCenter(find.text('Morning ideas')));
    await gesture.moveBy(const Offset(60, 40));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(opened, 0, reason: 'a real drag must not open the card');
    expect(
      position(),
      isNot(const Offset(20, 30)),
      reason: 'a real drag must still move the card',
    );
  });

  testWidgets('renders the dump title, mode icon and duration',
      (tester) async {
    await _pumpCard(tester, dump: _dump());
    expect(find.text('Morning ideas'), findsOneWidget);
    expect(find.text('1m 35s'), findsOneWidget);
    expect(find.byIcon(Icons.mic), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('uses the meeting icon for meeting dumps', (tester) async {
    await _pumpCard(
      tester,
      dump: _dump(title: 'Standup', mode: DumpMode.meeting, durationSeconds: 42),
    );
    expect(find.byIcon(Icons.groups), findsOneWidget);
    expect(find.text('42s'), findsOneWidget);
  });

  testWidgets('uses the notes icon and hides duration for text notes',
      (tester) async {
    await _pumpCard(
      tester,
      dump: _dump(title: 'Grocery list', mode: DumpMode.textNote,
          durationSeconds: 0,),
    );
    expect(find.byIcon(Icons.notes), findsOneWidget);
    expect(find.text('0s'), findsNothing);
  });

  testWidgets('null dump renders a disabled "Recording unavailable" '
      'placeholder without throwing', (tester) async {
    var tapped = false;
    await _pumpCard(tester, dump: null, onTap: () => tapped = true);
    expect(find.text('Recording unavailable'), findsOneWidget);
    expect(tester.takeException(), isNull);
    // The placeholder is inert: tapping it must not open anything.
    await tester.tap(find.byType(NotebookDumpCard));
    await tester.pump();
    expect(tapped, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the card is positioned at its offset within the canvas',
      (tester) async {
    await _pumpCard(tester, dump: _dump(), start: const Offset(20, 30));
    final topLeft = tester.getTopLeft(find.byType(NotebookDumpCard));
    expect(topLeft.dx, closeTo(20, 0.5));
    expect(topLeft.dy, closeTo(30, 0.5));
  });

  testWidgets('dragging the card reports the updated offset', (tester) async {
    final position = await _pumpCard(
      tester,
      dump: _dump(),
      start: const Offset(20, 30),
    );
    await tester.drag(find.byType(NotebookDumpCard), const Offset(40, 25));
    await tester.pumpAndSettle();
    expect(position().dx, closeTo(60, 0.5));
    expect(position().dy, closeTo(55, 0.5));
    // ...and the card actually moved on the canvas.
    final topLeft = tester.getTopLeft(find.byType(NotebookDumpCard));
    expect(topLeft.dx, closeTo(60, 0.5));
    expect(topLeft.dy, closeTo(55, 0.5));
  });

  testWidgets('multi-step drag accumulates even when the parent never '
      'rebuilds mid-gesture', (tester) async {
    // A parent that stores the position but does NOT rebuild the card until
    // the gesture ends (a realistic notebook that saves on drag end). The card
    // must track its own drag anchor rather than reading the stale prop back.
    final reported = <Offset>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              NotebookDumpCard(
                dump: _dump(),
                position: const Offset(10, 10),
                onPositionChanged: reported.add,
              ),
            ],
          ),
        ),
      ),
    );
    final gesture = await tester
        .startGesture(tester.getCenter(find.byType(NotebookDumpCard)));
    await gesture.moveBy(const Offset(30, 0));
    await gesture.moveBy(const Offset(30, 0));
    await gesture.moveBy(const Offset(0, 20));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(reported.last, const Offset(70, 30));
  });

  testWidgets('a missing-dump placeholder can still be dragged',
      (tester) async {
    final position = await _pumpCard(tester, dump: null);
    await tester.drag(find.byType(NotebookDumpCard), const Offset(15, -10));
    await tester.pumpAndSettle();
    expect(position(), const Offset(35, 20));
  });

  testWidgets('onRemove fires when the remove button is tapped',
      (tester) async {
    var removed = 0;
    await _pumpCard(tester, dump: _dump(), onRemove: () => removed++);
    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    expect(removed, 1);
  });

  testWidgets('no remove affordance when onRemove is null', (tester) async {
    await _pumpCard(tester, dump: _dump());
    expect(find.byIcon(Icons.close), findsNothing);
  });

  testWidgets('onTap fires when the card body is tapped', (tester) async {
    var taps = 0;
    await _pumpCard(tester, dump: _dump(), onTap: () => taps++);
    await tester.tap(find.text('Morning ideas'));
    await tester.pump();
    expect(taps, 1);
  });

  testWidgets('stays compact and rounded', (tester) async {
    await _pumpCard(tester, dump: _dump(title: 'A very long recording title '
        'that should not stretch the floating card across the canvas',),);
    final size = tester.getSize(find.byType(NotebookDumpCard));
    expect(size.width, lessThanOrEqualTo(NotebookDumpCard.maxCardWidth + 0.5));
    expect(size.height, lessThan(160));
    final card = tester.widget<Material>(
      find.descendant(
        of: find.byType(NotebookDumpCard),
        matching: find.byType(Material),
      ).first,
    );
    expect(card.elevation, greaterThan(0));
    expect(card.shape, isA<RoundedRectangleBorder>());
  });
}
