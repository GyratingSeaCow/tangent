// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/models/notebook.dart';
import 'package:tangent/widgets/notebook_ink_canvas.dart';

// The hover cursor: a thin ring follows the pen while it hovers (distance
// > 0, no contact), showing where the nib will land and how wide the mark
// will be — docs/design/pen-vs-finger-input.md section 3.5.
//
// Measured on the Galaxy Tab S10 FE EMR digitizer: ~93 hover events arrive
// as ordinary `PointerHoverEvent`s with kind `stylus` before the nib makes
// contact, and the side button (`buttons == kPrimaryStylusButton`) is
// visible on hover, before contact. No stylus-out-of-range exit event was
// observed in that characterisation, so the ring is cleared by a short
// trailing window rather than an exit handler.
//
// flutter_test drives hover for real: `TestGesture.moveTo` while the
// pointer is UP dispatches a genuine PointerHoverEvent through the
// binding's hit test, exactly like the platform does.

/// The ring's own painter, found inside the mounted canvas. `.single` is
/// deliberate: a second mounted ring painter must throw, not be silently
/// picked.
NotebookHoverRingPainter _ringPainter(WidgetTester tester) => tester
    .widgetList<CustomPaint>(
      find.descendant(
        of: find.byType(NotebookInkCanvas),
        matching: find.byType(CustomPaint),
      ),
    )
    .map((CustomPaint p) => p.painter)
    .whereType<NotebookHoverRingPainter>()
    .single;

HoverRing? _ring(WidgetTester tester) => _ringPainter(tester).ring.value;

Offset _at(WidgetTester tester, Offset local) =>
    tester.getTopLeft(find.byType(NotebookInkCanvas)) + local;

Future<void> _mount(
  WidgetTester tester, {
  double penWidth = 8,
  InkTool tool = InkTool.pen,
  InkColor colour = InkColor.white,
  bool erasing = false,
  bool drawingEnabled = true,
  bool lassoing = false,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 300,
            height: 300,
            child: NotebookInkCanvas(
              strokes: const <InkStroke>[],
              drawingEnabled: drawingEnabled,
              erasing: erasing,
              lassoing: lassoing,
              penWidth: penWidth,
              tool: tool,
              colour: colour,
              onStrokesChanged: (_) {},
            ),
          ),
        ),
      ),
    ),
  );
}

/// A hovering stylus, already registered with the binding the way a real
/// platform registers a pen entering range.
Future<TestGesture> _hoveringStylus(WidgetTester tester) async {
  final TestGesture pen =
      await tester.createGesture(kind: PointerDeviceKind.stylus);
  await pen.addPointer(location: Offset.zero);
  addTearDown(pen.removePointer);
  return pen;
}

void main() {
  group('hover ring follows the pen', () {
    testWidgets('stylus hover shows the ring at the nib with pen radius',
        (tester) async {
      // A NON-default width: a ring hardcoded to the default pen would
      // still fail here.
      await _mount(tester, penWidth: 8);

      final TestGesture pen = await _hoveringStylus(tester);
      await pen.moveTo(_at(tester, const Offset(80, 90)));
      await tester.pump();

      final HoverRing? ring = _ring(tester);
      expect(ring, isNotNull, reason: 'a hovering pen must show the ring');
      expect(ring!.position, const Offset(80, 90));
      expect(
        ring.radius,
        4.0,
        reason: 'the ring is HONEST: pen nib lands width/2 = 8/2 wide',
      );

      // The ring follows: a later hover moves it.
      await pen.moveTo(_at(tester, const Offset(120, 40)));
      await tester.pump();
      expect(_ring(tester)!.position, const Offset(120, 40));
    });

    testWidgets('highlighter hover shows the rendered band half-width',
        (tester) async {
      // NON-default width AND non-default swatch: width 10 renders a band
      // 10 * kHighlighterWidthFactor wide, so the honest ring radius is
      // half that. A ring that reused the pen radius (5) dies here.
      await _mount(
        tester,
        penWidth: 10,
        tool: InkTool.highlighter,
        colour: InkColor.pink,
      );

      final TestGesture pen = await _hoveringStylus(tester);
      await pen.moveTo(_at(tester, const Offset(60, 60)));
      await tester.pump();

      final HoverRing? ring = _ring(tester);
      expect(ring, isNotNull);
      expect(
        ring!.radius,
        10 * kHighlighterWidthFactor / 2,
        reason: 'the ring must show the rendered band, not the nominal nib',
      );
    });

    testWidgets('eraser mode shows the erase-tolerance circle',
        (tester) async {
      // Erase reach is per-stroke (tolerance + that stroke's rendered
      // half-width), which the ring cannot know before the sweep meets ink,
      // so it shows the guaranteed minimum: the tolerance circle around the
      // tip. Width 8 makes pen (4) and highlighter (16) radii both wrong
      // answers here.
      await _mount(tester, penWidth: 8, erasing: true);

      final TestGesture pen = await _hoveringStylus(tester);
      await pen.moveTo(_at(tester, const Offset(70, 70)));
      await tester.pump();

      final HoverRing? ring = _ring(tester);
      expect(ring, isNotNull);
      expect(
        ring!.radius,
        12.0,
        reason: 'the eraser ring is the erase tolerance around the tip',
      );
    });

    testWidgets('the side button held during hover shows the eraser ring',
        (tester) async {
      // Measured on the EMR digitizer: buttons == kPrimaryStylusButton is
      // visible on hover, before contact — the eraser's reach must be
      // legible before committing to a swipe. TestPointer.hover() cannot
      // carry buttons, so the event goes through the binding raw, exactly
      // as the platform delivers it.
      await _mount(tester, penWidth: 8);

      final Offset position = _at(tester, const Offset(90, 90));
      tester.binding.handlePointerEvent(
        PointerHoverEvent(
          kind: PointerDeviceKind.stylus,
          position: position,
          buttons: kPrimaryStylusButton,
        ),
      );
      await tester.pump();

      final HoverRing? ring = _ring(tester);
      expect(ring, isNotNull);
      expect(
        ring!.radius,
        12.0,
        reason: 'a button-held hover previews the erase, not the pen',
      );
    });

    testWidgets('mouse hover shows NO ring', (tester) async {
      // A mouse hovers constantly on a desktop: a permanent ring under
      // every laptop cursor would be noise, so only stylus kinds ring.
      await _mount(tester, penWidth: 8);

      final TestGesture mouse =
          await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(_at(tester, const Offset(80, 90)));
      await tester.pump();

      expect(
        _ring(tester),
        isNull,
        reason: 'only a pen rings; a mouse hovers all day',
      );
    });

    testWidgets('lasso mode never rings — the pen selects, not inks',
        (tester) async {
      // A nib-width ring under a lasso pen would be dishonest about what
      // landing will do. This pins the widget.lassoing early-return, which
      // an earlier sabotage proved was otherwise unobserved.
      await _mount(tester, penWidth: 8, lassoing: true);

      final TestGesture pen = await _hoveringStylus(tester);
      await pen.moveTo(_at(tester, const Offset(80, 90)));
      await tester.pump();

      expect(
        _ring(tester),
        isNull,
        reason: 'a lasso pen selects; no nib ring',
      );
    });

    testWidgets('pen contact hides the ring', (tester) async {
      await _mount(tester, penWidth: 8);

      final TestGesture pen = await _hoveringStylus(tester);
      await pen.moveTo(_at(tester, const Offset(80, 90)));
      await tester.pump();
      expect(_ring(tester), isNotNull);

      // The nib lands: the live stroke preview takes over from the ring.
      await pen.down(_at(tester, const Offset(80, 90)));
      await tester.pump();
      expect(
        _ring(tester),
        isNull,
        reason: 'on contact the live stroke preview replaces the ring',
      );

      await pen.up();
      await tester.pump();
    });

    testWidgets('the ring expires after the hover linger window',
        (tester) async {
      // The measured digitizer delivers no out-of-range exit event, so the
      // ring must die by trailing window — otherwise a pen pulled away
      // leaves a phantom nib on the page forever.
      await _mount(tester, penWidth: 8);

      final TestGesture pen = await _hoveringStylus(tester);
      await pen.moveTo(_at(tester, const Offset(80, 90)));
      await tester.pump();
      expect(_ring(tester), isNotNull);

      await tester.pump(const Duration(milliseconds: 400));
      expect(
        _ring(tester),
        isNull,
        reason: 'no hover event for the linger window drops the ring',
      );
    });

    testWidgets('dispose cancels the linger timer', (tester) async {
      // Unmounting mid-hover with the trailing window armed must cancel it:
      // a leaked timer fails flutter_test and would fire on a dead notifier.
      await _mount(tester, penWidth: 8);

      final TestGesture pen = await _hoveringStylus(tester);
      await pen.moveTo(_at(tester, const Offset(80, 90)));
      await tester.pump();
      expect(_ring(tester), isNotNull);

      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
      // testWidgets itself fails on any timer still pending here.
    });
  });

  group('NotebookHoverRingPainter', () {
    _RecordingCanvas paintRing(HoverRing? ring) {
      final ValueNotifier<HoverRing?> value = ValueNotifier<HoverRing?>(ring);
      addTearDown(value.dispose);
      final _RecordingCanvas canvas = _RecordingCanvas();
      NotebookHoverRingPainter(ring: value)
          .paint(canvas, const Size(300, 300));
      return canvas;
    }

    test('paints one thin stroked translucent circle, never a fill', () {
      final _RecordingCanvas canvas = paintRing(
        const HoverRing(position: Offset(50, 70), radius: 9),
      );

      expect(canvas.circles, hasLength(1));
      final _RecordedCircle circle = canvas.circles.single;
      expect(circle.centre, const Offset(50, 70));
      expect(circle.radius, 9);
      expect(
        circle.paintStyle,
        PaintingStyle.stroke,
        reason: 'a filled ring would obscure the ink beneath it',
      );
      expect(circle.strokeWidth, lessThanOrEqualTo(2));
      // The canvas's own ink colour at low opacity — translucent so the
      // page reads through, and never an invented colour.
      const Color ink = NotebookInkCanvas.inkColor;
      expect(circle.colour.r, closeTo(ink.r, 0.001));
      expect(circle.colour.g, closeTo(ink.g, 0.001));
      expect(circle.colour.b, closeTo(ink.b, 0.001));
      expect(circle.colour.a, lessThan(1.0));
      expect(circle.colour.a, greaterThan(0.0));
    });

    test('paints nothing while no pen is hovering', () {
      expect(paintRing(null).circles, isEmpty);
    });
  });
}

/// Records what the ring painter actually draws. Any unrecorded `draw*`
/// member throws, per this suite's recorder convention: silently swallowed
/// draw calls are exactly how a test watches an empty canvas and passes.
class _RecordingCanvas implements Canvas {
  final List<_RecordedCircle> circles = <_RecordedCircle>[];

  @override
  void drawCircle(Offset c, double radius, Paint paint) => circles.add(
        _RecordedCircle(c, radius, paint.color, paint.style, paint.strokeWidth),
      );

  @override
  dynamic noSuchMethod(Invocation invocation) {
    final String member =
        RegExp(r'"(.*)"').firstMatch('${invocation.memberName}')?.group(1) ??
            '';
    if (member.startsWith('draw')) {
      throw UnimplementedError('unrecorded canvas draw call: $member');
    }
    return null;
  }
}

class _RecordedCircle {
  const _RecordedCircle(
    this.centre,
    this.radius,
    this.colour,
    this.paintStyle,
    this.strokeWidth,
  );
  final Offset centre;
  final double radius;
  final Color colour;
  final PaintingStyle paintStyle;
  final double strokeWidth;
}
