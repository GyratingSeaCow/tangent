// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Self-contained handwriting surface for the notebook page.
//
// Design contract: docs/superpowers/specs/2026-09-17-notebooks-design.md
//   * Ink is always WHITE on a BLACK canvas (phase 1 has no colour picker).
//   * Samsung Notes pen types are proprietary and not importable, so the
//     authorised fallback is a single round pen whose width is adjustable from
//     the notebook page's own toolbar via [PenSizeControl].
//   * Strokes are accepted from stylus input, and from touch only while draw
//     mode is active, so finger-scrolling a notebook never paints.
//
// This widget owns no persistence and knows nothing about screens or the
// database. It reports completed strokes upward through `onStrokesChanged`.
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../models/notebook.dart';


/// White-on-black handwriting canvas driven by stylus or (in draw mode) touch.
///
/// Drive imperative actions through a `GlobalKey<NotebookInkCanvasState>`:
///
/// ```dart
/// final key = GlobalKey<NotebookInkCanvasState>();
/// // ...
/// key.currentState?.undoLastStroke();
/// ```
class NotebookInkCanvas extends StatefulWidget {
  /// Ink the canvas starts with. Replacing this list with a different one
  /// (for example when loading another notebook) re-seeds the canvas.
  final List<InkStroke> strokes;

  /// Fired when a stroke completes, is undone, or the canvas is cleared.
  /// Never fired mid-stroke.
  final ValueChanged<List<InkStroke>> onStrokesChanged;

  /// When false the canvas ignores ALL pointer input so the user can scroll
  /// and interact with whatever sits beneath it.
  final bool drawingEnabled;

  /// Width applied to the NEXT stroke started. Existing ink is untouched.
  final double penWidth;

  const NotebookInkCanvas({
    super.key,
    required this.strokes,
    required this.onStrokesChanged,
    required this.drawingEnabled,
    required this.penWidth,
  });

  /// Phase 1 has no colour picker: ink is always white.
  static const Color inkColor = Colors.white;

  /// Phase 1 canvas is always black.
  static const Color backgroundColor = Colors.black;

  static const Key backgroundKey = Key('notebook-ink-canvas-background');

  @override
  State<NotebookInkCanvas> createState() => NotebookInkCanvasState();
}

class NotebookInkCanvasState extends State<NotebookInkCanvas> {
  static const Uuid _uuid = Uuid();

  final List<InkStroke> _strokes = <InkStroke>[];

  /// Points of the stroke currently under the pen, if any.
  List<InkPoint>? _activePoints;

  /// Pen width sampled when the active stroke STARTED.
  double _activeWidth = PenSizeControl.defaultPenWidth;

  /// Pointer owning the active stroke; other pointers are ignored (no
  /// multi-touch scribbling).
  int? _activePointer;

  /// Monotonic counter bumped on every visual change, so the painter can make
  /// an O(1) repaint decision instead of deep-comparing stroke lists.
  int _revision = 0;

  @override
  void initState() {
    super.initState();
    _strokes.addAll(widget.strokes);
  }

  @override
  void didUpdateWidget(covariant NotebookInkCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!listEquals(oldWidget.strokes, widget.strokes)) {
      // A genuinely different document was handed in: re-seed.
      _cancelActiveStroke();
      _strokes
        ..clear()
        ..addAll(widget.strokes);
      _revision++;
    }
  }

  /// Completed strokes, oldest first. Unmodifiable: mutate via the canvas.
  List<InkStroke> get strokes => List<InkStroke>.unmodifiable(_strokes);

  /// True while a stroke is being drawn.
  bool get isDrawing => _activePoints != null;

  /// Removes the most recent stroke. Returns false when there is nothing to
  /// undo (and then does not notify).
  bool undoLastStroke() {
    if (_strokes.isEmpty) return false;
    setState(() {
      _strokes.removeLast();
      _revision++;
    });
    _notify();
    return true;
  }

  /// Removes all ink. Returns false when the canvas was already empty.
  bool clearStrokes() {
    if (_strokes.isEmpty) return false;
    setState(() {
      _strokes.clear();
      _revision++;
    });
    _notify();
    return true;
  }

  void _notify() => widget.onStrokesChanged(strokes);

  /// Stylus input is always honoured while the canvas is active; touch and
  /// mouse only paint when draw mode is on, so finger-scrolling never inks.
  bool _acceptsDevice(PointerDeviceKind kind) {
    switch (kind) {
      case PointerDeviceKind.stylus:
      case PointerDeviceKind.invertedStylus:
        return true;
      case PointerDeviceKind.touch:
      case PointerDeviceKind.mouse:
        return widget.drawingEnabled;
      case PointerDeviceKind.trackpad:
      case PointerDeviceKind.unknown:
        return false;
    }
  }

  void _cancelActiveStroke() {
    _activePoints = null;
    _activePointer = null;
  }

  /// Appends a sample, skipping exact duplicates so a tap stays a single-point
  /// dot and a drag does not double-record its final position.
  bool _appendPoint(List<InkPoint> points, Offset position) {
    final InkPoint point = InkPoint(x: position.dx, y: position.dy);
    if (points.isNotEmpty && points.last == point) return false;
    points.add(point);
    return true;
  }

  void _onPointerDown(PointerDownEvent event) {
    if (!widget.drawingEnabled) return;
    if (!_acceptsDevice(event.kind)) return;
    if (_activePointer != null) return;
    setState(() {
      _activePointer = event.pointer;
      _activeWidth = widget.penWidth;
      _activePoints = <InkPoint>[];
      _appendPoint(_activePoints!, event.localPosition);
      _revision++;
    });
  }

  void _onPointerMove(PointerMoveEvent event) {
    final List<InkPoint>? points = _activePoints;
    if (points == null || event.pointer != _activePointer) return;
    if (!_appendPoint(points, event.localPosition)) return;
    setState(() => _revision++);
  }

  void _onPointerUp(PointerUpEvent event) {
    final List<InkPoint>? points = _activePoints;
    if (points == null || event.pointer != _activePointer) return;
    _appendPoint(points, event.localPosition);
    // A tap with no movement is still ink: it lands as a one-point dot.
    final InkStroke stroke = InkStroke(
      id: _uuid.v4(),
      width: _activeWidth,
      points: List<InkPoint>.unmodifiable(points),
    );
    setState(() {
      _strokes.add(stroke);
      _cancelActiveStroke();
      _revision++;
    });
    _notify();
  }

  void _onPointerCancel(PointerCancelEvent event) {
    if (_activePoints == null || event.pointer != _activePointer) return;
    setState(() {
      _cancelActiveStroke();
      _revision++;
    });
  }

  @override
  Widget build(BuildContext context) {
    final List<InkPoint>? active = _activePoints;
    return Semantics(
      label: 'Handwriting canvas',
      child: RepaintBoundary(
        child: IgnorePointer(
          ignoring: !widget.drawingEnabled,
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: _onPointerDown,
            onPointerMove: _onPointerMove,
            onPointerUp: _onPointerUp,
            onPointerCancel: _onPointerCancel,
            child: ColoredBox(
              key: NotebookInkCanvas.backgroundKey,
              color: NotebookInkCanvas.backgroundColor,
              child: CustomPaint(
                painter: NotebookInkPainter(
                  strokes: _strokes,
                  activeStroke: active == null
                      ? null
                      : InkStroke(
                          id: '_active',
                          width: _activeWidth,
                          points: active,
                        ),
                  revision: _revision,
                ),
                child: const SizedBox.expand(),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Paints committed ink plus the stroke currently under the pen.
class NotebookInkPainter extends CustomPainter {
  final List<InkStroke> strokes;
  final InkStroke? activeStroke;

  /// Bumped by the canvas on every visual change; see [shouldRepaint].
  final int revision;

  const NotebookInkPainter({
    required this.strokes,
    required this.activeStroke,
    required this.revision,
  });

  /// The "round pen": round caps and round joins at the stroke's own width.
  Paint buildStrokePaint(double width) => Paint()
    ..color = NotebookInkCanvas.inkColor
    ..style = PaintingStyle.stroke
    ..strokeWidth = width
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..isAntiAlias = true;

  Paint _buildDotPaint() => Paint()
    ..color = NotebookInkCanvas.inkColor
    ..style = PaintingStyle.fill
    ..isAntiAlias = true;

  void _paintStroke(Canvas canvas, InkStroke stroke) {
    if (stroke.points.isEmpty) return;
    if (stroke.points.length == 1) {
      // Single tap: a round dot of the pen's own diameter.
      canvas.drawCircle(
        stroke.points.first.offset,
        stroke.width / 2,
        _buildDotPaint(),
      );
      return;
    }
    final Path path = Path()
      ..moveTo(stroke.points.first.x, stroke.points.first.y);
    for (final InkPoint point in stroke.points.skip(1)) {
      path.lineTo(point.x, point.y);
    }
    canvas.drawPath(path, buildStrokePaint(stroke.width));
  }

  @override
  void paint(Canvas canvas, Size size) {
    for (final InkStroke stroke in strokes) {
      _paintStroke(canvas, stroke);
    }
    final InkStroke? active = activeStroke;
    if (active != null) _paintStroke(canvas, active);
  }

  @override
  bool shouldRepaint(covariant NotebookInkPainter oldDelegate) =>
      oldDelegate.revision != revision ||
      !identical(oldDelegate.strokes, strokes) ||
      !identical(oldDelegate.activeStroke, activeStroke);
}

/// Pen-size slider with a live round preview dot, for the notebook page's own
/// top toolbar. Pure presentation: it holds no state and never self-updates.
class PenSizeControl extends StatelessWidget {
  final double value;
  final ValueChanged<double> onChanged;

  const PenSizeControl({
    super.key,
    required this.value,
    required this.onChanged,
  });

  static const double minPenWidth = 1;
  static const double maxPenWidth = 24;
  static const double defaultPenWidth = 3;

  static const Key previewDotKey = Key('pen-size-control-preview-dot');
  static const Key sliderKey = Key('pen-size-control-slider');

  @override
  Widget build(BuildContext context) {
    final double clamped = value.clamp(minPenWidth, maxPenWidth);
    return Semantics(
      container: true,
      label: 'Pen size',
      value: '${clamped.toStringAsFixed(1)} pixels',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          SizedBox(
            width: maxPenWidth,
            height: maxPenWidth,
            child: Center(
              child: SizedBox(
                key: previewDotKey,
                width: clamped,
                height: clamped,
                child: const DecoratedBox(
                  decoration: BoxDecoration(
                    color: NotebookInkCanvas.inkColor,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Slider(
              key: sliderKey,
              min: minPenWidth,
              max: maxPenWidth,
              value: clamped,
              label: clamped.toStringAsFixed(1),
              onChanged: onChanged,
            ),
          ),
        ],
      ),
    );
  }
}