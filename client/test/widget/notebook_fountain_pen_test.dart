// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The fountain pen and palm rejection.
//
// Fountain strokes taper with the pen's own pressure, which the EMR digitizer
// reports finely (180 distinct values measured on the Tab S10 FE). Palm
// rejection exists because resting a hand while writing produces touch
// contacts that would otherwise scroll the page or ink through draw mode.
//
// TestPointer cannot carry pressure, so these tests dispatch raw
// PointerEvents through the binding — the same route the platform uses.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/models/notebook.dart';
import 'package:tangent/widgets/notebook_ink_canvas.dart';

void main() {
  Future<void> mount(
    WidgetTester tester, {
    required List<InkStroke> captured,
    PenStyle penStyle = PenStyle.ballpoint,
    bool drawingEnabled = false,
    ValueChanged<bool>? onStylusPresence,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NotebookInkCanvas(
            strokes: const <InkStroke>[],
            drawingEnabled: drawingEnabled,
            erasing: false,
            penWidth: 4,
            penStyle: penStyle,
            opaqueBackground: false,
            onStylusPresence: onStylusPresence,
            onStrokesChanged: (List<InkStroke> s) {
              captured
                ..clear()
                ..addAll(s);
            },
          ),
        ),
      ),
    );
  }

  /// Drives a stylus stroke with real pressure values through the binding.
  Future<void> stylusStroke(
    WidgetTester tester,
    List<(Offset, double)> samples, {
    int pointer = 7,
  }) async {
    final (Offset first, double firstP) = samples.first;
    tester.binding.handlePointerEvent(
      PointerDownEvent(
        pointer: pointer,
        kind: PointerDeviceKind.stylus,
        position: first,
        pressure: firstP,
        pressureMin: 0,
        pressureMax: 1,
      ),
    );
    await tester.pump();
    for (final (Offset position, double p) in samples.skip(1)) {
      tester.binding.handlePointerEvent(
        PointerMoveEvent(
          pointer: pointer,
          kind: PointerDeviceKind.stylus,
          position: position,
          pressure: p,
          pressureMin: 0,
          pressureMax: 1,
        ),
      );
      await tester.pump();
    }
    final (Offset last, double lastP) = samples.last;
    tester.binding.handlePointerEvent(
      PointerUpEvent(
        pointer: pointer,
        kind: PointerDeviceKind.stylus,
        position: last,
        pressure: lastP,
        pressureMin: 0,
        pressureMax: 1,
      ),
    );
    await tester.pump();
  }

  testWidgets('a stylus stroke records per-point pressure',
      (WidgetTester tester) async {
    final List<InkStroke> captured = <InkStroke>[];
    await mount(tester, captured: captured, penStyle: PenStyle.fountain);

    await stylusStroke(tester, <(Offset, double)>[
      (const Offset(100, 100), 0.2),
      (const Offset(140, 120), 0.6),
      (const Offset(180, 140), 0.9),
    ]);

    expect(captured, hasLength(1));
    expect(captured.single.style, PenStyle.fountain);
    final List<double?> pressures =
        captured.single.points.map((p) => p.p).toList();
    expect(pressures, contains(closeTo(0.2, 0.001)));
    expect(pressures, contains(closeTo(0.9, 0.001)));
  });

  testWidgets('a ballpoint stroke stays flat on the wire',
      (WidgetTester tester) async {
    // Ballpoint is the legacy stroke: whatever the digitizer reports, the
    // stored stroke must re-encode without pressure so old and new files
    // stay byte-comparable.
    final List<InkStroke> captured = <InkStroke>[];
    await mount(tester, captured: captured);

    await stylusStroke(tester, <(Offset, double)>[
      (const Offset(100, 100), 0.2),
      (const Offset(140, 120), 0.7),
    ]);

    expect(captured, hasLength(1));
    expect(captured.single.style, PenStyle.ballpoint);
    expect(
      captured.single.points.every((p) => p.p == null),
      isTrue,
      reason: 'legacy stroke shape must not gain fields',
    );
  });

  testWidgets('touch does not ink while the pen is in contact',
      (WidgetTester tester) async {
    // The palm: a touch landing while the stylus is down must not draw even
    // though draw mode is on.
    final List<InkStroke> captured = <InkStroke>[];
    await mount(tester, captured: captured, drawingEnabled: true);

    // Stylus lands and stays down.
    tester.binding.handlePointerEvent(
      const PointerDownEvent(
        pointer: 7,
        kind: PointerDeviceKind.stylus,
        position: Offset(100, 100),
        pressure: 0.4,
        pressureMin: 0,
        pressureMax: 1,
      ),
    );
    await tester.pump();

    // A palm-shaped touch arrives elsewhere.
    final TestGesture palm = await tester.createGesture(
      kind: PointerDeviceKind.touch,
      pointer: 9,
    );
    await palm.down(const Offset(300, 400));
    await tester.pump();
    await palm.moveTo(const Offset(320, 460));
    await tester.pump();
    await palm.up();
    await tester.pump();

    // Finish the pen stroke.
    tester.binding.handlePointerEvent(
      const PointerUpEvent(
        pointer: 7,
        kind: PointerDeviceKind.stylus,
        position: Offset(150, 150),
        pressure: 0.4,
        pressureMin: 0,
        pressureMax: 1,
      ),
    );
    await tester.pump();

    expect(
      captured,
      hasLength(1),
      reason: 'only the pen stroke lands; the palm must not ink',
    );
  });

  testWidgets('touch inks again once the pen has been away for the window',
      (WidgetTester tester) async {
    final List<InkStroke> captured = <InkStroke>[];
    await mount(tester, captured: captured, drawingEnabled: true);

    await stylusStroke(tester, <(Offset, double)>[
      (const Offset(100, 100), 0.4),
      (const Offset(120, 120), 0.4),
    ]);
    expect(captured, hasLength(1));

    // Inside the trailing window: still suppressed.
    final TestGesture early = await tester.createGesture(
      kind: PointerDeviceKind.touch,
      pointer: 11,
    );
    await early.down(const Offset(250, 250));
    await tester.pump();
    await early.up();
    await tester.pump();
    expect(
      captured,
      hasLength(1),
      reason: 'the gap between strokes keeps touch suppressed',
    );

    // Beyond the window: finger drawing works again (draw mode is on).
    await tester.pump(const Duration(milliseconds: 700));
    final TestGesture late = await tester.createGesture(
      kind: PointerDeviceKind.touch,
      pointer: 12,
    );
    await late.down(const Offset(260, 260));
    await tester.pump();
    await late.up();
    await tester.pump();
    expect(
      captured,
      hasLength(2),
      reason: 'touch recovers after the pen leaves',
    );
  });

  testWidgets('stylus presence is reported so the page can hold still',
      (WidgetTester tester) async {
    final List<bool> presence = <bool>[];
    await mount(
      tester,
      captured: <InkStroke>[],
      onStylusPresence: presence.add,
    );

    await stylusStroke(tester, <(Offset, double)>[
      (const Offset(100, 100), 0.4),
      (const Offset(120, 120), 0.4),
    ]);
    expect(presence, isNotEmpty);
    expect(presence.first, isTrue);

    await tester.pump(const Duration(milliseconds: 700));
    expect(
      presence.last,
      isFalse,
      reason: 'presence must clear after the trailing window',
    );
  });

  testWidgets('a phone with no pen never suppresses touch',
      (WidgetTester tester) async {
    // No stylus event has ever arrived: finger drawing in draw mode works
    // exactly as before.
    final List<InkStroke> captured = <InkStroke>[];
    await mount(tester, captured: captured, drawingEnabled: true);

    final TestGesture finger = await tester.createGesture(
      kind: PointerDeviceKind.touch,
      pointer: 13,
    );
    await finger.down(const Offset(100, 100));
    await tester.pump();
    await finger.moveTo(const Offset(140, 140));
    await tester.pump();
    await finger.up();
    await tester.pump();

    expect(captured, hasLength(1));
  });
}
