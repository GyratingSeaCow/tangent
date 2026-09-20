// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Self-contained handwriting surface for the notebook page.
//
// Design contract: docs/superpowers/specs/2026-09-17-notebooks-design.md
//   * Ink is always WHITE on a BLACK canvas (phase 1 has no colour picker).
//   * Samsung Notes pen types are proprietary and not importable, so the
//     authorised fallback is a single round pen whose width is adjustable from
//     the notebook page's own toolbar via [PenSizeControl].
//   * A PEN always writes, wherever it touches the page and with no mode
//     toggle first -- requiring a toggle is the largest friction there is in a
//     handwriting app on an active-pen device. Touch and mouse paint only
//     while draw mode is active, so finger-scrolling a notebook never paints
//     and the draw-mode button remains the backup for writing with a finger.
//
// This widget owns no persistence and knows nothing about screens or the
// database. It reports completed strokes upward through `onStrokesChanged`.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../theme/tangent_tokens.dart';
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

  /// When true, pointer input removes whole strokes instead of drawing.
  ///
  /// Strokes are the stored unit (they round-trip through the durable notebook
  /// file), so erasing removes entire strokes rather than clearing pixels —
  /// the file format is unchanged either way.
  final bool erasing;

  /// When true, pointer input selects instead of drawing: a drawn loop
  /// selects every stroke inside it, a drag begun inside the selection moves
  /// all of it together, and [NotebookInkCanvasState.deleteSelection] removes
  /// it. Wins over [erasing] when both are set.
  final bool lassoing;

  /// Fired when the lasso selection becomes non-empty (true) or empty
  /// (false). The editor uses it to enable its delete action.
  final ValueChanged<bool>? onSelectionChanged;

  /// Fired when a lasso loop completes, with the loop's polygon in canvas
  /// coordinates. The host tests its own content (text blocks, recording
  /// cards) against the polygon — [NotebookInkCanvasState.pointInLoop] is
  /// the same ray-cast the strokes use — and returns how many of its items
  /// the loop caught. A non-zero return keeps the selection alive even when
  /// no INK was circled, so a blocks-only lasso still arms delete/drag.
  final int Function(List<Offset> loop)? onLassoLoop;

  /// Asked on a lasso-mode pointer-down whether [position] falls inside the
  /// host's selected content, so a drag can begin from a selected block just
  /// as it can from selected ink.
  final bool Function(Offset position)? hitsExternalSelection;

  /// Fired for each movement step of a selection drag, in canvas
  /// coordinates. The host applies the same delta to its selected blocks so
  /// ink and blocks travel together.
  final ValueChanged<Offset>? onSelectionDragStep;

  /// Whether this canvas paints its own opaque backdrop.
  ///
  /// False when it is layered over a page that already painted one: the ink
  /// then composites directly, with no colour filter and no giant saveLayer.
  final bool opaqueBackground;

  /// Width applied to the NEXT stroke started. Existing ink is untouched.
  final double penWidth;

  /// Style applied to the NEXT stroke started. Fountain strokes record the
  /// pen's per-point pressure and render tapered; ballpoint stays the
  /// original flat stroke (and records no pressure, keeping legacy files
  /// byte-comparable).
  final PenStyle penStyle;

  /// Reports pen presence: true when a stylus is in contact (and through a
  /// short trailing window after it lifts), false once the window lapses.
  /// The editor uses it to hold the page still under a resting palm.
  final ValueChanged<bool>? onStylusPresence;

  const NotebookInkCanvas({
    super.key,
    required this.strokes,
    required this.onStrokesChanged,
    required this.drawingEnabled,
    this.erasing = false,
    this.lassoing = false,
    this.onSelectionChanged,
    this.onLassoLoop,
    this.hitsExternalSelection,
    this.onSelectionDragStep,
    this.opaqueBackground = true,
    required this.penWidth,
    this.penStyle = PenStyle.ballpoint,
    this.onStylusPresence,
  });

  /// Handwriting. White, never the lime signal colour: lime ink competes
  /// with the transcript and tires the eye over a page of notes.
  static const Color inkColor = TangentColors.ink;

  /// The page. The deepest chassis tone rather than pure black, so the page
  /// sits in the same material as the bars and docks around it.
  static const Color backgroundColor = TangentColors.sunken;

  static const Key backgroundKey = Key('notebook-ink-canvas-background');

  @override
  State<NotebookInkCanvas> createState() => NotebookInkCanvasState();
}

class NotebookInkCanvasState extends State<NotebookInkCanvas> {
  static const Uuid _uuid = Uuid();

  final List<InkStroke> _strokes = <InkStroke>[];

  /// The ink as it stood before the current (or most recent) eraser gesture.
  /// Null when the last action was drawing, so undo falls through to removing
  /// the last stroke.
  List<InkStroke>? _eraseUndoSnapshot;

  /// True while the CURRENT gesture is erasing (toggle or side button).
  bool _erasingGesture = false;

  /// Last position touched by the active eraser gesture, so each move erases
  /// along the path travelled since the previous sample.
  Offset? _lastErasePosition;

  /// Points of the stroke currently under the pen, if any.
  List<InkPoint>? _activePoints;

  /// Pen width sampled when the active stroke STARTED.
  double _activeWidth = PenSizeControl.defaultPenWidth;

  /// Pen style sampled when the active stroke STARTED.
  PenStyle _activeStyle = PenStyle.ballpoint;

  /// Pointer owning the active stroke; other pointers are ignored (no
  /// multi-touch scribbling).
  int? _activePointer;

  /// Palm rejection: true from a stylus contact until [_stylusWindow] after
  /// the last stylus event. While set, touch neither draws nor erases here,
  /// and the editor is told to hold the page still. Only ever set by a real
  /// stylus event, so a device with no pen never suppresses touch.
  bool _stylusPresent = false;
  Timer? _stylusWindowTimer;

  /// How long after the pen lifts before a finger is trusted again. Covers
  /// the gap between strokes when the nib lifts briefly mid-word.
  static const Duration _stylusWindow = Duration(milliseconds: 500);

  // ---- Lasso selection ----

  /// Ids of the currently selected strokes. Non-empty only in lasso mode.
  final Set<String> _selected = <String>{};

  /// The loop being drawn by the active lasso gesture, in canvas space.
  List<Offset>? _lassoPath;

  /// Origin of the active selection drag, when the gesture began inside the
  /// selection instead of drawing a new loop.
  Offset? _dragStart;

  /// Cumulative translation applied by the active drag, for live preview.
  Offset _dragDelta = Offset.zero;

  /// Ink as it stood before the active drag, so the move commits as a single
  /// undoable action and a cancelled drag restores exactly.
  List<InkStroke>? _dragUndoSnapshot;

  /// Number of strokes currently selected.
  int get selectedCount => _selected.length;

  /// How many of the HOST's items (blocks, cards) the last loop caught, per
  /// its [NotebookInkCanvas.onLassoLoop] return. The selection is "live"
  /// while either ink or external items are held.
  int _externalSelected = 0;

  bool get _selectionLive => _selected.isNotEmpty || _externalSelected > 0;

  /// The stroke-selection ray-cast, exposed so the host can test its own
  /// content against the reported loop with identical geometry.
  static bool pointInLoop(Offset p, List<Offset> loop) =>
      _pointInLoop(p, loop);

  /// Drops the whole selection (ink and external). The host calls this after
  /// consuming a selection — e.g. deleting its selected blocks.
  void clearSelection() {
    if (!_selectionLive) return;
    setState(() {
      // Zeroing the external count first would make _setSelection see the
      // selection as already dead and swallow the notification.
      _selected.clear();
      _externalSelected = 0;
      widget.onSelectionChanged?.call(false);
      _revision++;
    });
  }

  void _setSelection(Iterable<String> ids) {
    final bool wasLive = _selectionLive;
    _selected
      ..clear()
      ..addAll(ids);
    if (wasLive != _selectionLive) {
      widget.onSelectionChanged?.call(_selectionLive);
    }
  }

  /// Deletes every selected stroke as ONE undoable action. Returns false
  /// when nothing was selected.
  bool deleteSelection() {
    if (_selected.isEmpty) {
      // Blocks-only selection: the ink canvas has nothing to remove, but the
      // selection state still ends here (the host deletes its own blocks).
      if (_externalSelected > 0) clearSelection();
      return false;
    }
    // Reuses the eraser's snapshot slot: undo restores the whole deletion,
    // exactly like undoing an eraser sweep.
    _eraseUndoSnapshot = List<InkStroke>.of(_strokes);
    setState(() {
      _strokes.removeWhere((InkStroke s) => _selected.contains(s.id));
      _externalSelected = 0;
      _setSelection(const <String>[]);
      _revision++;
    });
    _notify();
    return true;
  }

  void _markStylusPresent() {
    _stylusWindowTimer?.cancel();
    _stylusWindowTimer = Timer(_stylusWindow, () {
      _stylusPresent = false;
      widget.onStylusPresence?.call(false);
    });
    if (!_stylusPresent) {
      _stylusPresent = true;
      widget.onStylusPresence?.call(true);
    }
  }

  @override
  void dispose() {
    _stylusWindowTimer?.cancel();
    super.dispose();
  }

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
    if (oldWidget.lassoing && !widget.lassoing) {
      // Leaving lasso mode drops the selection: a stale, invisible selection
      // would make the next delete tap destroy off-screen ink.
      _lassoPath = null;
      _dragStart = null;
      _dragUndoSnapshot = null;
      // Order matters: _setSelection's liveness comparison must still see
      // the external half, or a blocks-only selection dies silently.
      _setSelection(const <String>[]);
      if (_externalSelected > 0) {
        _externalSelected = 0;
        widget.onSelectionChanged?.call(false);
      }
      _revision++;
    }
    if (!listEquals(oldWidget.strokes, widget.strokes)) {
      // Our own edit echoing back through the parent is NOT a new document.
      // The editor is stateful: onStrokesChanged sets its state and rebuilds
      // this canvas with the list we just produced. Treating that as a fresh
      // document cancelled the in-flight gesture, so on device the eraser
      // stopped dead after its first line and a pen stroke could be cut short
      // mid-draw.
      if (_isOwnEcho(widget.strokes)) {
        return;
      }
      // A genuinely different document was handed in: re-seed.
      _cancelActiveStroke();
      _strokes
        ..clear()
        ..addAll(widget.strokes);
      _revision++;
    }
  }

  /// True when [incoming] is the list this canvas itself just published.
  ///
  /// Compared by identity of the strokes, not the list object: the parent
  /// copies the list before storing it, so the container differs while the
  /// strokes are the very same instances.
  bool _isOwnEcho(List<InkStroke> incoming) {
    if (incoming.length != _strokes.length) return false;
    for (int i = 0; i < incoming.length; i++) {
      if (!identical(incoming[i], _strokes[i])) return false;
    }
    return true;
  }

  /// Completed strokes, oldest first. Unmodifiable: mutate via the canvas.
  List<InkStroke> get strokes => List<InkStroke>.unmodifiable(_strokes);

  /// True while a stroke is being drawn.
  bool get isDrawing => _activePoints != null;

  /// Removes the most recent stroke. Returns false when there is nothing to
  /// undo (and then does not notify).
  bool undoLastStroke() {
    // An eraser gesture is undone as one action, restoring every stroke it
    // removed. Without this an accidental wipe would be unrecoverable.
    final List<InkStroke>? snapshot = _eraseUndoSnapshot;
    if (snapshot != null) {
      setState(() {
        _strokes
          ..clear()
          ..addAll(snapshot);
        _eraseUndoSnapshot = null;
        _revision++;
      });
      _notify();
      return true;
    }
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

  /// True when this pointer should erase rather than draw.
  ///
  /// Either the eraser toggle is on, or the pen's side button is held. The
  /// button is measured to be present on the down event, every move and the
  /// up, so it is read per-event and needs no latching.
  ///
  /// Flip-to-erase is deliberately absent: flipping the pen on the target EMR
  /// digitizer never produced `PointerDeviceKind.invertedStylus`, so a branch
  /// on that value would be dead code.
  bool _isErasing(PointerEvent event) {
    if (widget.erasing) return true;
    final bool isPen = event.kind == PointerDeviceKind.stylus ||
        event.kind == PointerDeviceKind.invertedStylus;
    return isPen && (event.buttons & kPrimaryStylusButton) != 0;
  }

  void _cancelActiveStroke() {
    _activePoints = null;
    _activePointer = null;
  }

  /// Appends a sample, skipping exact duplicates so a tap stays a single-point
  /// dot and a drag does not double-record its final position.
  ///
  /// Pressure is recorded only for fountain strokes from a pressure-reporting
  /// device: a ballpoint stroke must re-encode byte-identical to the legacy
  /// shape, and a touch pointer reports a constant 1.0 that means nothing.
  bool _appendPoint(
    List<InkPoint> points,
    Offset position, {
    PointerEvent? event,
  }) {
    double? p;
    if (event != null &&
        _activeStyle == PenStyle.fountain &&
        event.kind == PointerDeviceKind.stylus &&
        event.pressureMax > event.pressureMin) {
      p = ((event.pressure - event.pressureMin) /
              (event.pressureMax - event.pressureMin))
          .clamp(0.0, 1.0);
    }
    final InkPoint point = InkPoint(x: position.dx, y: position.dy, p: p);
    if (points.isNotEmpty && points.last == point) return false;
    points.add(point);
    return true;
  }

  /// Extra reach around a stroke, in logical pixels.
  ///
  /// Exact-pixel hit testing on a 3px line is unusable with a fingertip and
  /// fiddly even with a stylus, so the band is generous — but not so wide that
  /// neighbouring lines are erased by accident.
  static const double _eraseTolerance = 12;

  /// True when [p] lies inside the closed polygon [loop] (ray casting).
  /// The loop is implicitly closed: last vertex connects back to the first.
  static bool _pointInLoop(Offset p, List<Offset> loop) {
    bool inside = false;
    for (int i = 0, j = loop.length - 1; i < loop.length; j = i++) {
      final Offset a = loop[i];
      final Offset b = loop[j];
      if ((a.dy > p.dy) != (b.dy > p.dy) &&
          p.dx < (b.dx - a.dx) * (p.dy - a.dy) / (b.dy - a.dy) + a.dx) {
        inside = !inside;
      }
    }
    return inside;
  }

  /// A stroke is "circled" when the MAJORITY of its points fall inside the
  /// loop. All-points would drop a word whose descender pokes out of a hasty
  /// circle; any-point would grab neighbours the loop barely clips. Majority
  /// matches what the hand meant.
  static bool _strokeInLoop(InkStroke s, List<Offset> loop) {
    if (s.points.isEmpty) return false;
    int inside = 0;
    for (final InkPoint p in s.points) {
      if (_pointInLoop(Offset(p.x, p.y), loop)) inside++;
    }
    return inside * 2 > s.points.length;
  }

  /// True when the gesture at [position] should DRAG the current selection:
  /// it starts inside any selected stroke's bounding box (padded by the
  /// erase tolerance, so grabbing thin ink is forgiving).
  bool _hitsSelection(Offset position) {
    for (final InkStroke s in _strokes) {
      if (!_selected.contains(s.id)) continue;
      double minX = double.infinity, minY = double.infinity;
      double maxX = -double.infinity, maxY = -double.infinity;
      for (final InkPoint p in s.points) {
        if (p.x < minX) minX = p.x;
        if (p.y < minY) minY = p.y;
        if (p.x > maxX) maxX = p.x;
        if (p.y > maxY) maxY = p.y;
      }
      final Rect box = Rect.fromLTRB(minX, minY, maxX, maxY)
          .inflate(_eraseTolerance + s.width);
      if (box.contains(position)) return true;
    }
    return false;
  }

  void _lassoDown(PointerDownEvent event) {
    final bool hitsExternal = _externalSelected > 0 &&
        (widget.hitsExternalSelection?.call(event.localPosition) ?? false);
    if (_selectionLive &&
        (hitsExternal ||
            (_selected.isNotEmpty && _hitsSelection(event.localPosition)))) {
      // Grabbed the selection: this gesture moves it (ink and blocks alike).
      _dragStart = event.localPosition;
      _dragDelta = Offset.zero;
      _dragUndoSnapshot = List<InkStroke>.of(_strokes);
      _activePointer = event.pointer;
      return;
    }
    // Anywhere else begins a fresh loop (and implicitly drops the old
    // selection on release).
    _activePointer = event.pointer;
    setState(() {
      _lassoPath = <Offset>[event.localPosition];
      _revision++;
    });
  }

  void _lassoMove(PointerMoveEvent event) {
    if (event.pointer != _activePointer) return;
    final Offset? dragStart = _dragStart;
    if (dragStart != null) {
      // Live-move the selected strokes by the delta since the last event.
      final Offset step = event.localPosition - dragStart - _dragDelta;
      _dragDelta = event.localPosition - dragStart;
      // Selected blocks ride along: the host applies this same step to its
      // own selected items.
      widget.onSelectionDragStep?.call(step);
      setState(() {
        for (int i = 0; i < _strokes.length; i++) {
          final InkStroke s = _strokes[i];
          if (!_selected.contains(s.id)) continue;
          _strokes[i] = s.copyWith(
            points: <InkPoint>[
              for (final InkPoint p in s.points)
                InkPoint(x: p.x + step.dx, y: p.y + step.dy, p: p.p),
            ],
          );
        }
        _revision++;
      });
      return;
    }
    final List<Offset>? path = _lassoPath;
    if (path == null) return;
    if (path.isEmpty || (event.localPosition - path.last).distance > 2) {
      setState(() {
        path.add(event.localPosition);
        _revision++;
      });
    }
  }

  void _lassoUp(PointerUpEvent event) {
    if (event.pointer != _activePointer) return;
    _activePointer = null;
    if (_dragStart != null) {
      // Commit the move: one undo restores the pre-drag ink. A drag that
      // went nowhere leaves no undo entry and no notify.
      final bool moved = _dragDelta != Offset.zero;
      _dragStart = null;
      _dragDelta = Offset.zero;
      final List<InkStroke>? snapshot = _dragUndoSnapshot;
      _dragUndoSnapshot = null;
      if (moved) {
        _eraseUndoSnapshot = snapshot;
        _notify();
      }
      return;
    }
    final List<Offset>? path = _lassoPath;
    if (path == null) return;
    setState(() {
      _lassoPath = null;
      // A loop needs area; a stray tap (too few points) selects nothing.
      if (path.length < 3) {
        _externalSelected = 0;
        _setSelection(const <String>[]);
      } else {
        // Liveness is captured BEFORE either half mutates: _setSelection
        // compares against it to decide whether to fire, so setting the
        // external count first would swallow the became-live transition of
        // a blocks-only catch.
        final bool wasLive = _selectionLive;
        _externalSelected = widget.onLassoLoop?.call(path) ?? 0;
        _selected
          ..clear()
          ..addAll(<String>[
            for (final InkStroke s in _strokes)
              if (_strokeInLoop(s, path)) s.id,
          ]);
        if (wasLive != _selectionLive) {
          widget.onSelectionChanged?.call(_selectionLive);
        }
      }
      _revision++;
    });
  }

  /// Distance from [p] to the segment a-b. Strokes are polylines, so hit
  /// testing measures against segments, not just the recorded vertices: a long
  /// straight line has few points and a midpoint tap must still register.
  static double _distanceToSegment(Offset p, Offset a, Offset b) {
    final Offset ab = b - a;
    final double lengthSquared = ab.dx * ab.dx + ab.dy * ab.dy;
    if (lengthSquared == 0) return (p - a).distance;
    double t = ((p - a).dx * ab.dx + (p - a).dy * ab.dy) / lengthSquared;
    t = t.clamp(0.0, 1.0);
    return (p - (a + ab * t)).distance;
  }

  /// True when any part of stroke [s] lies within reach of the segment a-b.
  bool _strokeHitSegment(InkStroke s, Offset a, Offset b) {
    final List<InkPoint> points = s.points;
    if (points.isEmpty) return false;
    final double reach = _eraseTolerance + s.width / 2;
    if (points.length == 1) {
      return _distanceToSegment(Offset(points.first.x, points.first.y), a, b) <=
          reach;
    }
    for (int i = 0; i < points.length - 1; i++) {
      final Offset p1 = Offset(points[i].x, points[i].y);
      final Offset p2 = Offset(points[i + 1].x, points[i + 1].y);
      // Segment-to-segment proximity, approximated by the four endpoint-to-
      // segment distances. Exact for the crossing case that matters here: if
      // the segments intersect, at least one endpoint distance is zero.
      final double closest = [
        _distanceToSegment(p1, a, b),
        _distanceToSegment(p2, a, b),
        _distanceToSegment(a, p1, p2),
        _distanceToSegment(b, p1, p2),
      ].reduce((double x, double y) => x < y ? x : y);
      if (closest <= reach) return true;
    }
    return false;
  }

  /// Removes every stroke touched between [from] and [to]. Returns true when
  /// ink was removed.
  ///
  /// A drag is erased along its travelled path rather than at sampled points:
  /// a quick sweep reports widely spaced positions, and point-sampling would
  /// skip straight over lines lying between two samples.
  bool _eraseAlong(Offset from, Offset to) {
    final int before = _strokes.length;
    _strokes.removeWhere((InkStroke s) => _strokeHitSegment(s, from, to));
    return _strokes.length != before;
  }

  /// Removes every stroke under [position]. Returns true when ink was removed.
  bool _eraseAt(Offset position) => _eraseAlong(position, position);

  void _onPointerDown(PointerDownEvent event) {
    // No `drawingEnabled` check here: _acceptsDevice owns that decision, and
    // it is per-kind. A blanket early return above this line is what made the
    // stylus branch below dead code while its doc comment still advertised
    // "stylus input is always honoured".
    final bool isStylus = event.kind == PointerDeviceKind.stylus ||
        event.kind == PointerDeviceKind.invertedStylus;
    if (isStylus) _markStylusPresent();
    // Palm rejection: while the pen is present (in contact, or within the
    // trailing window after lifting), a touch contact is a resting hand,
    // not intent — even in draw mode. Lasso mode is exempt: a selection
    // gesture cannot scribble, and eating the touch here made finger
    // lassos silently dead for half a second after every pen stroke.
    if (!isStylus &&
        event.kind == PointerDeviceKind.touch &&
        _stylusPresent &&
        !widget.lassoing) {
      return;
    }
    if (!_acceptsDevice(event.kind)) return;
    if (_activePointer != null) return;
    if (widget.lassoing) {
      _lassoDown(event);
      return;
    }
    if (_isErasing(event)) {
      _erasingGesture = true;
      // One eraser gesture is one user action, so the pre-gesture ink is
      // snapshotted once and restored by a single undo.
      _eraseUndoSnapshot = List<InkStroke>.of(_strokes);
      _activePointer = event.pointer;
      _lastErasePosition = event.localPosition;
      final bool removed = _eraseAt(event.localPosition);
      setState(() => _revision++);
      if (removed) _notify();
      return;
    }
    setState(() {
      _activePointer = event.pointer;
      _activeWidth = widget.penWidth;
      _activeStyle = widget.penStyle;
      _activePoints = <InkPoint>[];
      _appendPoint(_activePoints!, event.localPosition, event: event);
      _revision++;
    });
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (event.kind == PointerDeviceKind.stylus ||
        event.kind == PointerDeviceKind.invertedStylus) {
      // Keep the palm window alive for the whole contact, not just the down:
      // a long written line would otherwise let the window lapse mid-stroke.
      _markStylusPresent();
    }
    if (widget.lassoing) {
      _lassoMove(event);
      return;
    }
    if (_erasingGesture || widget.erasing) {
      if (event.pointer != _activePointer) return;
      final Offset from = _lastErasePosition ?? event.localPosition;
      _lastErasePosition = event.localPosition;
      final bool removed = _eraseAlong(from, event.localPosition);
      if (!removed) return;
      setState(() => _revision++);
      _notify();
      return;
    }
    final List<InkPoint>? points = _activePoints;
    if (points == null || event.pointer != _activePointer) return;
    if (!_appendPoint(points, event.localPosition, event: event)) return;
    setState(() => _revision++);
  }

  void _onPointerUp(PointerUpEvent event) {
    if (widget.lassoing) {
      _lassoUp(event);
      return;
    }
    if (_erasingGesture || widget.erasing) {
      _erasingGesture = false;
      if (event.pointer != _activePointer) return;
      final Offset from = _lastErasePosition ?? event.localPosition;
      final bool removed = _eraseAlong(from, event.localPosition);
      _lastErasePosition = null;
      _activePointer = null;
      setState(() => _revision++);
      if (removed) _notify();
      return;
    }
    final List<InkPoint>? points = _activePoints;
    if (points == null || event.pointer != _activePointer) return;
    _appendPoint(points, event.localPosition, event: event);
    // A tap with no movement is still ink: it lands as a one-point dot.
    final InkStroke stroke = InkStroke(
      id: _uuid.v4(),
      width: _activeWidth,
      style: _activeStyle,
      points: List<InkPoint>.unmodifiable(points),
    );
    setState(() {
      _strokes.add(stroke);
      // Drawing supersedes the erase: undo now removes this new stroke.
      _eraseUndoSnapshot = null;
      _cancelActiveStroke();
      _revision++;
    });
    _notify();
  }

  void _onPointerCancel(PointerCancelEvent event) {
    if (event.pointer != _activePointer) return;
    setState(() {
      // A cancelled gesture must release EVERY mode's claim on the pointer,
      // not just the pen's. Leaving _activePointer latched after a cancelled
      // lasso gesture made every later lasso attempt a silent no-op.
      _cancelActiveStroke();
      _lassoPath = null;
      // A cancelled drag restores the pre-drag ink exactly.
      final List<InkStroke>? snapshot = _dragUndoSnapshot;
      if (_dragStart != null && snapshot != null) {
        _strokes
          ..clear()
          ..addAll(snapshot);
      }
      _dragStart = null;
      _dragDelta = Offset.zero;
      _dragUndoSnapshot = null;
      _revision++;
    });
  }

  @override
  Widget build(BuildContext context) {
    final List<InkPoint>? active = _activePoints;
    return Semantics(
      label: 'Handwriting canvas',
      child: RepaintBoundary(
        // IgnorePointer cannot express "pen only" -- it drops every pointer
        // kind alike, which is why reaching the canvas used to require draw
        // mode. Instead the layer is translucent to hit testing when draw mode
        // is off, so a FINGER falls through to the blocks and the page scroll
        // underneath, while a stylus is claimed eagerly by the recognizer
        // below and never reaches them.
        child: RawGestureDetector(
          behavior: widget.drawingEnabled
              ? HitTestBehavior.opaque
              : HitTestBehavior.translucent,
          gestures: <Type, GestureRecognizerFactory>{
            // Claims the gesture arena for stylus pointers the moment one
            // lands, so a pen stroke inks instead of being interpreted as a
            // page scroll or a drag of whatever block lies beneath it. Scoped
            // to stylus kinds: touch is left entirely alone so the widgets
            // below keep their taps and drags.
            EagerGestureRecognizer:
                GestureRecognizerFactoryWithHandlers<EagerGestureRecognizer>(
              () => EagerGestureRecognizer(
                supportedDevices: const <PointerDeviceKind>{
                  PointerDeviceKind.stylus,
                  PointerDeviceKind.invertedStylus,
                },
              ),
              (EagerGestureRecognizer instance) {},
            ),
          },
          child: Listener(
            // Translucent lets the hit continue to the widgets BEHIND this
            // layer after the Listener has seen it, which is what keeps a
            // finger working on the blocks below; opaque claims it outright
            // for the canvas while draw mode is on.
            behavior: widget.drawingEnabled
                ? HitTestBehavior.opaque
                : HitTestBehavior.translucent,
            onPointerDown: _onPointerDown,
            onPointerMove: _onPointerMove,
            onPointerUp: _onPointerUp,
            onPointerCancel: _onPointerCancel,
            // The painted surface takes no hits of its own. A ColoredBox plus
            // an expanded child is hit-testable even when fully transparent,
            // and it was absorbing the finger taps that must reach the blocks
            // below; the Listener above still sees every event first.
            child: IgnorePointer(
              child: ColoredBox(
                key: NotebookInkCanvas.backgroundKey,
                // Transparent when the page already paints the backdrop, so the
                // caller does not have to punch the black back out with a
                // colour filter. On a canvas the size of the notebook page that
                // filter is a saveLayer tens of megapixels wide, and when the
                // GPU declines it the black stays opaque and hides the page.
                color: widget.opaqueBackground
                    ? NotebookInkCanvas.backgroundColor
                    : const Color(0x00000000),
                child: CustomPaint(
                  painter: NotebookInkPainter(
                    strokes: _strokes,
                    selectedIds: _selected,
                    lassoPath: _lassoPath,
                    activeStroke: active == null
                        ? null
                        : InkStroke(
                            id: '_active',
                            width: _activeWidth,
                            style: _activeStyle,
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
      ),
    );
  }
}

/// Paints committed ink plus the stroke currently under the pen.
class NotebookInkPainter extends CustomPainter {
  final List<InkStroke> strokes;
  final InkStroke? activeStroke;

  /// Ids drawn with the selection glow, plus the in-progress lasso loop.
  final Set<String> selectedIds;
  final List<Offset>? lassoPath;

  /// Bumped by the canvas on every visual change; see [shouldRepaint].
  final int revision;

  const NotebookInkPainter({
    required this.strokes,
    required this.activeStroke,
    required this.revision,
    this.selectedIds = const <String>{},
    this.lassoPath,
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
      // Single tap: a round dot of the pen's own diameter (scaled by the
      // point's pressure for a fountain stroke).
      final double? p = stroke.points.first.p;
      final double diameter = stroke.style == PenStyle.fountain && p != null
          ? _fountainWidth(stroke.width, p)
          : stroke.width;
      canvas.drawCircle(
        stroke.points.first.offset,
        diameter / 2,
        _buildDotPaint(),
      );
      return;
    }
    if (stroke.style == PenStyle.fountain) {
      _paintFountainStroke(canvas, stroke);
      return;
    }
    final Path path = Path()
      ..moveTo(stroke.points.first.x, stroke.points.first.y);
    for (final InkPoint point in stroke.points.skip(1)) {
      path.lineTo(point.x, point.y);
    }
    canvas.drawPath(path, buildStrokePaint(stroke.width));
  }

  /// A fountain nib never quite vanishes: zero pressure still leaves a hair
  /// line, full pressure swells to 1.6x the chosen size. The floor keeps a
  /// fast light stroke visible; the ceiling keeps a heavy hand from blotting.
  ///
  /// Pressure passes through a gamma of 0.4 before scaling width: hardware
  /// verification showed the linear curve demanded roughly twice a natural
  /// writing pressure to reach full width, so the curve is bent to put
  /// normal-hand pressure (~a quarter of the sensor range) at the pen's
  /// nominal width. Stored points keep the RAW sensor value — only the
  /// rendering bends — so re-tuning this never rewrites ink.
  static double _fountainWidth(double base, double pressure) =>
      base * (0.35 + 1.25 * math.pow(pressure.clamp(0.0, 1.0), 0.4));

  /// The chisel edge: an italic nib held at 30 degrees from horizontal
  /// (hardware-tuned — Jeff asked for a stronger italic than round caps
  /// gave). Every mark is this edge swept along the stroke, so direction
  /// matters: a stroke perpendicular to the edge comes out full width, one
  /// parallel to it nearly disappears — the classic calligraphy look.
  ///
  /// Screen y grows downward, so -sin gives the conventional up-to-the-right
  /// slant of a right-handed nib.
  static final Offset _nibEdge = Offset(
    math.cos(30 * math.pi / 180),
    -math.sin(30 * math.pi / 180),
  );

  /// Italic rendering: each segment becomes a filled parallelogram — the nib
  /// edge at `a` swept to the nib edge at `b`. Adjacent segments share their
  /// edge exactly, so consecutive quads tile into a smooth ribbon with no
  /// seams. Points without pressure (legacy files) sweep at the flat width,
  /// so a mixed stroke degrades gracefully.
  void _paintFountainStroke(Canvas canvas, InkStroke stroke) {
    final List<InkPoint> points = stroke.points;
    final Paint fill = _buildDotPaint();
    for (int i = 0; i < points.length - 1; i++) {
      final InkPoint a = points[i];
      final InkPoint b = points[i + 1];
      final double? pa = a.p;
      final double? pb = b.p;
      final double width = pa == null && pb == null
          ? stroke.width
          : _fountainWidth(stroke.width, ((pa ?? pb)! + (pb ?? pa)!) / 2);
      final Offset half = _nibEdge * (width / 2);
      final Path quad = Path()
        ..moveTo(a.x + half.dx, a.y + half.dy)
        ..lineTo(b.x + half.dx, b.y + half.dy)
        ..lineTo(b.x - half.dx, b.y - half.dy)
        ..lineTo(a.x - half.dx, a.y - half.dy)
        ..close();
      canvas.drawPath(quad, fill);
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    for (final InkStroke stroke in strokes) {
      // Selected ink glows: a soft lime halo behind the stroke, so the
      // selection reads through any ink colour without obscuring it.
      if (selectedIds.contains(stroke.id)) {
        _paintHalo(canvas, stroke);
      }
      _paintStroke(canvas, stroke);
    }
    final InkStroke? active = activeStroke;
    if (active != null) _paintStroke(canvas, active);
    final List<Offset>? loop = lassoPath;
    if (loop != null && loop.length > 1) {
      // The marquee: a dashed-feel thin line in the signal colour.
      final Path path = Path()..moveTo(loop.first.dx, loop.first.dy);
      for (final Offset p in loop.skip(1)) {
        path.lineTo(p.dx, p.dy);
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = TangentColors.signal.withValues(alpha: 0.9)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..isAntiAlias = true,
      );
    }
  }

  /// The selection glow: the stroke redrawn wider and translucent beneath
  /// itself. Reuses the stroke's own geometry so fountain and ballpoint
  /// both halo correctly.
  void _paintHalo(Canvas canvas, InkStroke stroke) {
    if (stroke.points.isEmpty) return;
    final Paint halo = Paint()
      ..color = TangentColors.signal.withValues(alpha: 0.35)
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke.width + 8
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;
    if (stroke.points.length == 1) {
      canvas.drawCircle(
        stroke.points.first.offset,
        (stroke.width + 8) / 2,
        halo..style = PaintingStyle.fill,
      );
      return;
    }
    final Path path = Path()
      ..moveTo(stroke.points.first.x, stroke.points.first.y);
    for (final InkPoint point in stroke.points.skip(1)) {
      path.lineTo(point.x, point.y);
    }
    canvas.drawPath(path, halo);
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
