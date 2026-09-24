# Pen Colours and Highlighter Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the notebook four pen inks and a translucent highlighter tool, both chosen by long-pressing a toolbar button.

**Architecture:** `InkStroke` gains two optional enum fields (`tool`, `colour`) that are omitted from JSON at their defaults so existing notebooks re-encode byte-identical. `NotebookInkPainter.paint` becomes two passes — highlighters first, pens second — which is what guarantees a highlight can never cover handwriting. The canvas learns a third gesture mode alongside pen and eraser; the editor toolbar grows a long-press palette popup but no new buttons.

**Tech Stack:** Flutter (client-only). No server, API, or sync-protocol change. Tests are `flutter test`; the gate is the full suite (currently **1443 passing**) plus `flutter analyze` clean.

**Spec:** `docs/design/2026-09-21-pen-colours-and-highlighter.md`

## Global Constraints

- **Durable format is load-bearing.** A stroke at its defaults MUST NOT emit `tool` or `colour` keys. A legacy page must re-encode byte-identical. This is the expensive failure: writing `"colour":"white"` into every stroke rewrites every notebook on disk at the next save and dumps a spurious diff into sync across devices.
- **Tolerant readers.** An unknown tool reads as pen; an unknown colour reads as that tool's default. Never drop a stroke because a newer build named something this one hasn't heard of. Mirror the existing `PenStyle.fromWire` pattern.
- Pen ink is never lime — `tangent_tokens.dart` reserves lime for "live or selected". Lime IS allowed as a highlighter (user decision, documented in the spec).
- Highlighter strokes ignore `PenStyle` entirely — a felt tip does not taper.
- TDD: every task writes its test first, watches it fail, then implements. Any test encoding a fix gets a sabotage proof (break the fix → watch the test die → restore → watch it pass) per this project's standard.
- Run `flutter test` and `flutter analyze` and see BOTH clean before any commit.
- Commands: `export PATH="$LOCALAPPDATA/flutter/bin:$PATH"` then run from `client/`.

---

### Task 1: Ink tool and colour model

**Files:**
- Modify: `client/lib/models/notebook.dart` (`InkStroke` at line 409, `PenStyle` at 492)
- Test: `client/test/unit/models/notebook_test.dart`

**Interfaces:**
- Consumes: nothing (first task).
- Produces: `enum InkTool { pen, highlighter }` with `.wireValue` and `static InkTool fromWire(Object?)`; `enum InkColor` with `.wireValue`, `.argb` (an `int`), `static InkColor fromWire(Object?, InkTool)`, and `static InkColor defaultFor(InkTool)`; `InkStroke.tool` and `InkStroke.colour` fields; `InkStroke.copyWith` gains `InkTool? tool, InkColor? colour`.

- [ ] **Step 1: Write the failing tests**

Add to `client/test/unit/models/notebook_test.dart`:

```dart
  group('ink tool and colour', () {
    test('a legacy stroke re-encodes byte-identical', () {
      // The expensive regression: a stroke written before this feature must
      // not gain keys, or every notebook on disk rewrites at the next save
      // and floods sync with a spurious diff.
      const String legacy =
          '{"id":"s1","width":3.0,"points":[{"x":1.0,"y":2.0}]}';
      final InkStroke stroke =
          InkStroke.fromJson(jsonDecode(legacy) as Map<String, dynamic>);

      expect(stroke.tool, InkTool.pen);
      expect(stroke.colour, InkColor.white);
      expect(jsonEncode(stroke.toJson()), legacy);
    });

    test('a default pen stroke omits both new keys', () {
      const InkStroke stroke = InkStroke(
        id: 's1',
        width: 3,
        points: <InkPoint>[InkPoint(x: 1, y: 2)],
      );
      final Map<String, dynamic> json = stroke.toJson();
      expect(json.containsKey('tool'), isFalse);
      expect(json.containsKey('colour'), isFalse);
    });

    test('a highlighter stroke round-trips tool and colour', () {
      const InkStroke stroke = InkStroke(
        id: 's2',
        width: 4,
        tool: InkTool.highlighter,
        colour: InkColor.pink,
        points: <InkPoint>[InkPoint(x: 1, y: 2), InkPoint(x: 3, y: 4)],
      );
      final Map<String, dynamic> json = stroke.toJson();
      expect(json['tool'], 'highlighter');
      expect(json['colour'], 'pink');

      final InkStroke back = InkStroke.fromJson(json);
      expect(back.tool, InkTool.highlighter);
      expect(back.colour, InkColor.pink);
    });

    test('a highlighter at ITS default omits colour but keeps tool', () {
      // Yellow is the highlighter's default, so it is not written — but the
      // tool is, or the stroke would read back as a pen.
      const InkStroke stroke = InkStroke(
        id: 's3',
        width: 4,
        tool: InkTool.highlighter,
        colour: InkColor.yellow,
        points: <InkPoint>[InkPoint(x: 1, y: 2)],
      );
      final Map<String, dynamic> json = stroke.toJson();
      expect(json['tool'], 'highlighter');
      expect(json.containsKey('colour'), isFalse);
      expect(InkStroke.fromJson(json).colour, InkColor.yellow);
    });

    test('unknown tool and colour degrade instead of dropping the stroke', () {
      final InkStroke stroke = InkStroke.fromJson(<String, dynamic>{
        'id': 's4',
        'width': 3.0,
        'tool': 'crayon',
        'colour': 'chartreuse',
        'points': <dynamic>[
          <String, dynamic>{'x': 1.0, 'y': 2.0},
        ],
      });
      expect(stroke.tool, InkTool.pen);
      expect(stroke.colour, InkColor.white);
      expect(stroke.points, hasLength(1));
    });

    test('an unknown colour on a highlighter falls back to yellow', () {
      final InkStroke stroke = InkStroke.fromJson(<String, dynamic>{
        'id': 's5',
        'width': 3.0,
        'tool': 'highlighter',
        'colour': 'chartreuse',
        'points': <dynamic>[
          <String, dynamic>{'x': 1.0, 'y': 2.0},
        ],
      });
      expect(stroke.tool, InkTool.highlighter);
      expect(stroke.colour, InkColor.yellow);
    });

    test('tryFromJson carries tool and colour', () {
      final InkStroke? stroke = InkStroke.tryFromJson(<String, dynamic>{
        'id': 's6',
        'width': 3.0,
        'tool': 'highlighter',
        'colour': 'blue',
        'points': <dynamic>[
          <String, dynamic>{'x': 1.0, 'y': 2.0},
        ],
      });
      expect(stroke, isNotNull);
      expect(stroke!.tool, InkTool.highlighter);
      expect(stroke.colour, InkColor.blue);
    });

    test('copyWith preserves tool and colour when not overridden', () {
      const InkStroke stroke = InkStroke(
        id: 's7',
        width: 3,
        tool: InkTool.highlighter,
        colour: InkColor.lime,
        points: <InkPoint>[InkPoint(x: 1, y: 2)],
      );
      final InkStroke moved =
          stroke.copyWith(points: <InkPoint>[const InkPoint(x: 9, y: 9)]);
      expect(moved.tool, InkTool.highlighter);
      expect(moved.colour, InkColor.lime);
    });
  });
```

If `dart:convert` is not already imported in that test file, add `import 'dart:convert';` at the top.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `flutter test test/unit/models/notebook_test.dart --plain-name "ink tool and colour"`
Expected: FAIL to compile — `Undefined name 'InkTool'`.

- [ ] **Step 3: Add the enums**

In `client/lib/models/notebook.dart`, directly after the `PenStyle` enum (which ends around line 509):

```dart
/// Which instrument drew a stroke. Stored per stroke, so a page can mix them.
enum InkTool {
  /// Opaque handwriting. The default: every stroke written before this
  /// feature existed is a pen stroke.
  pen('pen'),

  /// A wide translucent mark, painted beneath every pen stroke so it can
  /// never obscure handwriting.
  highlighter('highlighter');

  const InkTool(this.wireValue);
  final String wireValue;

  /// Unknown or absent tools read as pen: showing a mark as handwriting
  /// beats dropping it because a newer build named an instrument this one
  /// has never heard of.
  static InkTool fromWire(Object? raw) => switch (raw) {
        'highlighter' => InkTool.highlighter,
        _ => InkTool.pen,
      };
}

/// The ink a stroke is drawn in.
///
/// Pen colours are opaque; highlighter colours carry their translucency in
/// the stored alpha, so the value round-trips through JSON unchanged rather
/// than depending on a painter applying an opacity at draw time.
///
/// Pen ink is never lime: `TangentColors.signal` means "live or selected"
/// everywhere else in the app, and opaque lime handwriting would compete
/// with it. Lime IS offered as a highlighter — at 22% alpha as a wide band
/// it reads as a mark, not a selection.
enum InkColor {
  // Pen inks.
  white('white', 0xFFEDF1F3),
  blue('blue', 0xFF5AB4FF),
  red('red', 0xFFFF6B6B),
  amber('amber', 0xFFFFB347),

  // Highlighter marks. Alpha is baked in.
  yellow('yellow', 0x38FFE14D),
  lime('lime', 0x38D4FF47),
  highlightBlue('highlightBlue', 0x425AB4FF),
  pink('pink', 0x3DFF78DC);

  const InkColor(this.wireValue, this.argb);
  final String wireValue;

  /// Packed 32-bit ARGB, ready for `Color(...)`.
  final int argb;

  /// The ink a tool uses when a stroke names no colour.
  static InkColor defaultFor(InkTool tool) => switch (tool) {
        InkTool.pen => InkColor.white,
        InkTool.highlighter => InkColor.yellow,
      };

  /// The swatches offered for a tool, in palette order.
  static List<InkColor> paletteFor(InkTool tool) => switch (tool) {
        InkTool.pen => const <InkColor>[white, blue, red, amber],
        InkTool.highlighter => const <InkColor>[
            yellow,
            lime,
            highlightBlue,
            pink,
          ],
      };

  /// Unknown or absent colours read as the tool's default, so a stroke from
  /// a newer build still draws rather than vanishing.
  static InkColor fromWire(Object? raw, InkTool tool) {
    for (final InkColor colour in paletteFor(tool)) {
      if (colour.wireValue == raw) return colour;
    }
    return defaultFor(tool);
  }
}
```

Note `highlightBlue` exists because the pen's `blue` and the highlighter's blue differ in alpha; they are separate wire values so a highlighter cannot silently inherit an opaque ink.

- [ ] **Step 4: Add the fields to InkStroke**

Replace the constructor, fields, both readers, `copyWith`, `toJson`, `==`, and `hashCode` of `InkStroke` (lines 409–489) so they carry the new state. The changed parts:

```dart
  const InkStroke({
    required this.id,
    required this.width,
    required this.points,
    this.style = PenStyle.ballpoint,
    this.tool = InkTool.pen,
    this.colour = InkColor.white,
  });
```

```dart
  /// Which instrument drew this. Highlighter strokes paint beneath pen ink.
  final InkTool tool;

  /// The ink. Defaults to white, which is also the pen's default, so a
  /// legacy stroke constructs correctly without naming a colour.
  final InkColor colour;
```

In `fromJson`, resolve the tool first because the colour fallback depends on it:

```dart
  factory InkStroke.fromJson(Map<String, dynamic> json) {
    final InkTool tool = InkTool.fromWire(json['tool']);
    return InkStroke(
      id: json['id'] as String? ?? '',
      width: (json['width'] as num?)?.toDouble() ?? kDefaultPenWidth,
      style: PenStyle.fromWire(json['style']),
      tool: tool,
      colour: InkColor.fromWire(json['colour'], tool),
      points: <InkPoint>[
        for (final Object? point
            in (json['points'] as List<dynamic>? ?? const <dynamic>[]))
          if (point is Map<String, dynamic>) InkPoint.fromJson(point),
      ],
    );
  }
```

In `tryFromJson`, after the existing `if (decoded.isEmpty) return null;`:

```dart
    final InkTool tool = InkTool.fromWire(raw['tool']);
    return InkStroke(
      id: id,
      width: width.toDouble(),
      style: PenStyle.fromWire(raw['style']),
      tool: tool,
      colour: InkColor.fromWire(raw['colour'], tool),
      points: decoded,
    );
```

`copyWith` gains both parameters:

```dart
  InkStroke copyWith({
    String? id,
    double? width,
    List<InkPoint>? points,
    InkTool? tool,
    InkColor? colour,
  }) =>
      InkStroke(
        id: id ?? this.id,
        width: width ?? this.width,
        style: style,
        tool: tool ?? this.tool,
        colour: colour ?? this.colour,
        points: points ?? this.points,
      );
```

`toJson` — the load-bearing part. Both keys are conditional, and the colour's default depends on the tool:

```dart
  Map<String, dynamic> toJson() => {
        'id': id,
        'width': width,
        // Written only when set: a legacy file must re-encode byte-comparable,
        // without gaining fields it never had.
        if (style != PenStyle.ballpoint) 'style': style.wireValue,
        if (tool != InkTool.pen) 'tool': tool.wireValue,
        if (colour != InkColor.defaultFor(tool)) 'colour': colour.wireValue,
        'points': points.map((p) => p.toJson()).toList(growable: false),
      };
```

Extend equality and hashing to both fields:

```dart
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is InkStroke &&
          other.id == id &&
          other.width == width &&
          other.style == style &&
          other.tool == tool &&
          other.colour == colour &&
          listEquals(other.points, points);

  @override
  int get hashCode =>
      Object.hash(id, width, style, tool, colour, Object.hashAll(points));
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `flutter test test/unit/models/notebook_test.dart`
Expected: PASS, including the pre-existing tests in that file.

- [ ] **Step 6: Sabotage-prove the byte-identical guarantee**

Temporarily make `toJson` unconditional (`'colour': colour.wireValue,` with no `if`). Run the same file. Expected: FAIL on "a legacy stroke re-encodes byte-identical" and "a default pen stroke omits both new keys". Restore the `if`, re-run, expect PASS. Report both outputs.

- [ ] **Step 7: Commit**

```bash
flutter analyze
flutter test
git add client/lib/models/notebook.dart client/test/unit/models/notebook_test.dart
git commit -m "Ink model: tool and colour, omitted at their defaults"
```

---

### Task 2: Paint highlighters beneath ink

**Files:**
- Modify: `client/lib/widgets/notebook_ink_canvas.dart` (`NotebookInkPainter` at line 976: `buildStrokePaint` 996, `_buildDotPaint` 1004, `_paintStroke` 1009, `_paintFountainStroke` 1068, `paint` 1096)
- Test: `client/test/widget/notebook_ink_canvas_test.dart`

**Interfaces:**
- Consumes: `InkTool`, `InkColor`, `InkStroke.tool`, `InkStroke.colour` from Task 1.
- Produces: `NotebookInkPainter.buildStrokePaint(double width, {required InkStroke stroke})` — the `stroke` argument is REQUIRED (a review round removed the optional form, because an omitted stroke silently produced a white pen; omitting it is now a compile error); `static List<InkStroke> NotebookInkPainter.paintOrder(List<InkStroke> strokes, {InkStroke? active})`; `const double kHighlighterWidthFactor = 4.0` exported from the canvas library.

**Note on testability:** the paint order is exposed as a real, pure function
(`paintOrder`) that `paint` itself calls, NOT as a test-only callback hook.
Production code must not carry hooks that exist solely for tests. Testing the
pure function directly is both cleaner and a stronger assertion.

- [ ] **Step 1: Write the failing tests**

Add to `client/test/widget/notebook_ink_canvas_test.dart`. These assert on the
pure ordering function and on constructed `Paint` objects, so they need no
canvas recording at all:

```dart
  group('highlighter rendering', () {
    test('highlighter strokes paint before pen strokes', () {
      // Insertion order is pen-then-highlighter; paint order must be the
      // reverse, or the highlight would cover the handwriting.
      const InkStroke pen = InkStroke(
        id: 'pen',
        width: 3,
        points: <InkPoint>[InkPoint(x: 0, y: 0), InkPoint(x: 10, y: 10)],
      );
      const InkStroke mark = InkStroke(
        id: 'mark',
        width: 3,
        tool: InkTool.highlighter,
        points: <InkPoint>[InkPoint(x: 0, y: 5), InkPoint(x: 10, y: 5)],
      );

      final List<String> order = NotebookInkPainter.paintOrder(
        const <InkStroke>[pen, mark],
      ).map((InkStroke s) => s.id).toList();

      expect(order, <String>['mark', 'pen']);
    });

    test('insertion order is preserved within a pass', () {
      // A later highlight still covers an earlier one.
      const InkStroke first = InkStroke(
        id: 'first',
        width: 3,
        tool: InkTool.highlighter,
        points: <InkPoint>[InkPoint(x: 0, y: 5)],
      );
      const InkStroke second = InkStroke(
        id: 'second',
        width: 3,
        tool: InkTool.highlighter,
        points: <InkPoint>[InkPoint(x: 1, y: 5)],
      );

      expect(
        NotebookInkPainter.paintOrder(const <InkStroke>[first, second])
            .map((InkStroke s) => s.id),
        <String>['first', 'second'],
      );
    });

    test('the active stroke paints last within its own pass', () {
      // Drawing a highlight over existing ink must show the ink staying on
      // top live, not only after the pen lifts.
      const InkStroke pen = InkStroke(
        id: 'pen',
        width: 3,
        points: <InkPoint>[InkPoint(x: 0, y: 0)],
      );
      const InkStroke mark = InkStroke(
        id: 'mark',
        width: 3,
        tool: InkTool.highlighter,
        points: <InkPoint>[InkPoint(x: 0, y: 5)],
      );
      const InkStroke active = InkStroke(
        id: 'active',
        width: 3,
        tool: InkTool.highlighter,
        points: <InkPoint>[InkPoint(x: 2, y: 5)],
      );

      expect(
        NotebookInkPainter.paintOrder(
          const <InkStroke>[pen, mark],
          active: active,
        ).map((InkStroke s) => s.id),
        <String>['mark', 'active', 'pen'],
      );
    });

    test('a highlighter stroke paints wider than its nominal width', () {
      const InkStroke mark = InkStroke(
        id: 'mark',
        width: 3,
        tool: InkTool.highlighter,
        points: <InkPoint>[InkPoint(x: 0, y: 5), InkPoint(x: 10, y: 5)],
      );
      final Paint paint = const NotebookInkPainter(
        strokes: <InkStroke>[],
        activeStroke: null,
        revision: 1,
      ).buildStrokePaint(mark.width, stroke: mark);

      expect(paint.strokeWidth, 3 * kHighlighterWidthFactor);
      expect(paint.strokeCap, StrokeCap.square);
      expect(paint.strokeJoin, StrokeJoin.bevel);
      expect(paint.color, const Color(0x38FFE14D));
    });

    test('a pen stroke keeps round caps and its own width', () {
      const InkStroke pen = InkStroke(
        id: 'pen',
        width: 3,
        colour: InkColor.red,
        points: <InkPoint>[InkPoint(x: 0, y: 0)],
      );
      final Paint paint = const NotebookInkPainter(
        strokes: <InkStroke>[],
        activeStroke: null,
        revision: 1,
      ).buildStrokePaint(pen.width, stroke: pen);

      expect(paint.strokeWidth, 3);
      expect(paint.strokeCap, StrokeCap.round);
      expect(paint.color, const Color(0xFFFF6B6B));
    });

    test('a highlighter ignores the fountain nib', () {
      // A felt tip does not taper, whatever nib the toolbar has selected.
      // Proven through the paint it builds: a fountain stroke's width comes
      // from pressure, a highlighter's never does.
      const InkStroke mark = InkStroke(
        id: 'mark',
        width: 3,
        style: PenStyle.fountain,
        tool: InkTool.highlighter,
        points: <InkPoint>[
          InkPoint(x: 0, y: 5, p: 0.1),
          InkPoint(x: 10, y: 5, p: 0.9),
        ],
      );
      expect(NotebookInkPainter.usesFountainPath(mark), isFalse);

      const InkStroke pen = InkStroke(
        id: 'pen',
        width: 3,
        style: PenStyle.fountain,
        points: <InkPoint>[
          InkPoint(x: 0, y: 5, p: 0.1),
          InkPoint(x: 10, y: 5, p: 0.9),
        ],
      );
      expect(NotebookInkPainter.usesFountainPath(pen), isTrue);
    });
  });
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `flutter test test/widget/notebook_ink_canvas_test.dart --plain-name "highlighter rendering"`
Expected: FAIL to compile — `The method 'paintOrder' isn't defined for the type 'NotebookInkPainter'`.

- [ ] **Step 3: Add the ordering function and colour-aware paints**

In `NotebookInkPainter`, add the two pure functions the tests drive. These are
real production code — `paint` calls both — not test seams:

```dart
  /// The order strokes are painted in: every highlighter first, then every
  /// pen. This is what guarantees a mark can never cover handwriting,
  /// whatever order they were drawn in. Insertion order is preserved within
  /// each pass, so a later highlight still covers an earlier one, and the
  /// in-progress [active] stroke lands last inside its own pass so drawing
  /// a highlight over existing ink shows the ink staying on top live.
  static List<InkStroke> paintOrder(
    List<InkStroke> strokes, {
    InkStroke? active,
  }) {
    final List<InkStroke> ordered = <InkStroke>[];
    // Explicit, not InkTool.values: declaration order is [pen, highlighter],
    // which is exactly the reverse of what painting needs.
    for (final InkTool pass in const <InkTool>[
      InkTool.highlighter,
      InkTool.pen,
    ]) {
      for (final InkStroke stroke in strokes) {
        if (stroke.tool == pass) ordered.add(stroke);
      }
      if (active != null && active.tool == pass) ordered.add(active);
    }
    return ordered;
  }

  /// Whether a stroke renders through the tapering fountain path. A
  /// highlighter never does: a felt tip does not taper, whatever nib the
  /// toolbar has selected.
  static bool usesFountainPath(InkStroke stroke) =>
      stroke.tool != InkTool.highlighter && stroke.style == PenStyle.fountain;
```

Replace `buildStrokePaint` so it derives everything from the stroke, while keeping its existing one-argument signature working:

```dart
  /// The paint for a stroke. A pen keeps the round nib at its own width; a
  /// highlighter is a wide chisel in translucent ink.
  ///
  /// [stroke] is REQUIRED: an omitted stroke used to fall back to a white
  /// pen, which meant a caller that forgot it silently drew the wrong
  /// colour instead of failing. A review round made it required so the
  /// mistake is a compile error.
  Paint buildStrokePaint(double width, {required InkStroke stroke}) {
    final InkTool tool = stroke.tool;
    final InkColor colour = stroke.colour;
    final bool marker = tool == InkTool.highlighter;
    return Paint()
      ..color = Color(colour.argb)
      ..style = PaintingStyle.stroke
      ..strokeWidth = marker ? width * kHighlighterWidthFactor : width
      // A chisel edge, not a round nib: this is what stops a highlight from
      // reading as merely a fat pen stroke.
      ..strokeCap = marker ? StrokeCap.square : StrokeCap.round
      ..strokeJoin = marker ? StrokeJoin.bevel : StrokeJoin.round
      ..isAntiAlias = true;
  }
```

Add the constant at library level, near `kDefaultPenWidth`'s usage at the top of the file:

```dart
/// How much wider a highlighter is than the pen width the slider gives it.
/// Four is wide enough that a mark is unmistakably a band, while the slider
/// still governs its size.
const double kHighlighterWidthFactor = 4.0;
```

Make `_buildDotPaint` colour-aware (it is used for single-point dots and the fountain fill):

```dart
  Paint _buildDotPaint([InkStroke? stroke]) => Paint()
    ..color = Color((stroke?.colour ?? InkColor.white).argb)
    ..style = PaintingStyle.fill
    ..isAntiAlias = true;
```

In `_paintStroke`, pass the stroke through, gate the fountain branch on the tool, and fire the seam. The changed lines:

```dart
  void _paintStroke(Canvas canvas, InkStroke stroke) {
    if (stroke.points.isEmpty) return;
    final bool marker = stroke.tool == InkTool.highlighter;
    if (stroke.points.length == 1) {
      final double? p = stroke.points.first.p;
      // A highlighter never tapers, so its dot is always the full band.
      final double diameter = usesFountainPath(stroke) && p != null
          ? _fountainWidth(stroke.width, p)
          : (marker ? stroke.width * kHighlighterWidthFactor : stroke.width);
      canvas.drawCircle(
        stroke.points.first.offset,
        diameter / 2,
        _buildDotPaint(stroke),
      );
      return;
    }
    if (usesFountainPath(stroke)) {
      _paintFountainStroke(canvas, stroke);
      return;
    }
    final Path path = Path()
      ..moveTo(stroke.points.first.x, stroke.points.first.y);
    for (final InkPoint point in stroke.points.skip(1)) {
      path.lineTo(point.x, point.y);
    }
    canvas.drawPath(path, buildStrokePaint(stroke.width, stroke: stroke));
  }
```

In `_paintFountainStroke`, colour its fill:

```dart
  void _paintFountainStroke(Canvas canvas, InkStroke stroke) {
    final List<InkPoint> points = stroke.points;
    final Paint fill = _buildDotPaint(stroke);
```

Replace the body of `paint` so it walks the ordered list:

```dart
  void paint(Canvas canvas, Size size) {
    for (final InkStroke stroke in paintOrder(strokes, active: activeStroke)) {
      if (selectedIds.contains(stroke.id)) {
        _paintHalo(canvas, stroke);
      }
      _paintStroke(canvas, stroke);
    }
    final List<Offset>? loop = lassoPath;
    if (loop != null && loop.length > 1) {
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
```

Note the active stroke is no longer painted separately after the loop —
`paintOrder` places it inside its own pass, which is the whole point.

Also widen the halo for highlighters so a selected mark still shows its glow around the full band — in `_paintHalo`, replace the two `stroke.width + 8` occurrences with:

```dart
    final double base = stroke.tool == InkTool.highlighter
        ? stroke.width * kHighlighterWidthFactor
        : stroke.width;
```

then use `base + 8`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `flutter test test/widget/notebook_ink_canvas_test.dart`
Expected: PASS, including the file's pre-existing tests.

- [ ] **Step 5: Sabotage-prove the paint order**

Swap the pass list to `[InkTool.pen, InkTool.highlighter]`. Run the file. Expected: FAIL on "highlighter strokes paint before pen strokes" with `['pen', 'mark']`. Restore, re-run, expect PASS. Report both.

- [ ] **Step 6: Commit**

```bash
flutter analyze
flutter test
git add client/lib/widgets/notebook_ink_canvas.dart client/test/widget/notebook_ink_canvas_test.dart
git commit -m "Ink painter: highlighters paint beneath pen strokes"
```

---

### Task 3: Canvas draws with the selected tool and colour

**Files:**
- Modify: `client/lib/widgets/notebook_ink_canvas.dart` (`penStyle` field at 100, constructor at 120, `_activeStyle` at 177, `_onPointerDown` at ~786, stroke construction at 848, painter construction at 950)
- Test: `client/test/widget/notebook_ink_canvas_test.dart`

**Interfaces:**
- Consumes: Task 1's enums, Task 2's painter.
- Produces: `NotebookInkCanvas.tool` (`InkTool`, default `InkTool.pen`) and `NotebookInkCanvas.colour` (`InkColor`, default `InkColor.white`) constructor parameters.

- [ ] **Step 1: Write the failing test**

```dart
  testWidgets('a stroke is born with the canvas tool and colour',
      (tester) async {
    late List<InkStroke> saved;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: NotebookInkCanvas(
          strokes: const <InkStroke>[],
          drawingEnabled: true,
          tool: InkTool.highlighter,
          colour: InkColor.pink,
          onChanged: (List<InkStroke> s) => saved = s,
        ),
      ),
    ));

    final Offset origin = tester.getCenter(find.byType(NotebookInkCanvas));
    final TestGesture gesture = await tester.startGesture(origin);
    await gesture.moveBy(const Offset(40, 0));
    await gesture.up();
    await tester.pump();

    expect(saved, hasLength(1));
    expect(saved.single.tool, InkTool.highlighter);
    expect(saved.single.colour, InkColor.pink);
  });
```

Match the existing tests in this file for how `NotebookInkCanvas` is mounted and how `onChanged` is named — read one first and copy its harness rather than assuming these parameter names.

- [ ] **Step 2: Run it to verify it fails**

Run: `flutter test test/widget/notebook_ink_canvas_test.dart --plain-name "born with the canvas tool"`
Expected: FAIL — `No named parameter with the name 'tool'`.

- [ ] **Step 3: Thread tool and colour through the canvas**

Add the fields beside `penStyle` (line 100):

```dart
  /// The instrument the next stroke uses.
  final InkTool tool;

  /// The ink the next stroke uses.
  final InkColor colour;
```

Constructor, beside `this.penStyle = PenStyle.ballpoint,`:

```dart
    this.tool = InkTool.pen,
    this.colour = InkColor.white,
```

Latch them at pointer-down beside `_activeStyle`, so changing the toolbar mid-stroke cannot change the stroke already being drawn. Add the state fields near line 177:

```dart
  InkTool _activeTool = InkTool.pen;
  InkColor _activeColour = InkColor.white;
```

In `_onPointerDown`, beside `_activeStyle = widget.penStyle;`:

```dart
      _activeTool = widget.tool;
      _activeColour = widget.colour;
```

Both `InkStroke(...)` constructions (line 848 on lift, line 956 for the live preview) gain:

```dart
      tool: _activeTool,
      colour: _activeColour,
```

- [ ] **Step 4: Run it to verify it passes**

Run: `flutter test test/widget/notebook_ink_canvas_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
flutter analyze
flutter test
git add client/lib/widgets/notebook_ink_canvas.dart client/test/widget/notebook_ink_canvas_test.dart
git commit -m "Ink canvas: strokes take the selected tool and colour"
```

---

### Task 4: Highlighter tool and colour palettes in the toolbar

**Files:**
- Modify: `client/lib/screens/notebook/notebook_editor_screen.dart` (state fields near `_selectedImageId`, `_enterDrawMode` at ~921, toolbar `Row` at ~1077)
- Create: `client/lib/widgets/ink_palette_popup.dart`
- Test: `client/test/widget/notebook_editor_screen_test.dart`

**Interfaces:**
- Consumes: everything above.
- Produces: `showInkPalette({required BuildContext context, required InkTool tool, required InkColor selected, required Offset globalPosition}) → Future<InkColor?>`; editor state `_tool`, `_penColour`, `_highlighterColour`; widget keys `notebook-highlighter`, `notebook-ink-swatch-<wireValue>`.

- [ ] **Step 1: Write the failing tests**

Add to `client/test/widget/notebook_editor_screen_test.dart`:

```dart
  testWidgets('long-pressing the pen opens its palette and picks a colour',
      (tester) async {
    await mountEditor(tester, notebook: seeded());

    await tester.longPress(find.byIcon(Icons.draw));
    await tester.pumpAndSettle();

    // The pen palette, not the highlighter's.
    expect(find.byKey(const ValueKey('notebook-ink-swatch-red')), findsOneWidget);
    expect(find.byKey(const ValueKey('notebook-ink-swatch-pink')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('notebook-ink-swatch-red')));
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<NotebookInkCanvas>(find.byType(NotebookInkCanvas))
          .colour,
      InkColor.red,
    );

    await unmount(tester);
  });

  testWidgets('the highlighter activates draw mode and clears other tools',
      (tester) async {
    await mountEditor(tester, notebook: seeded());

    // From cold, per the toolbar contract: a tool tap enters draw mode.
    await tester.tap(find.byKey(const ValueKey('notebook-highlighter')));
    await tester.pump();

    NotebookInkCanvas canvas() =>
        tester.widget<NotebookInkCanvas>(find.byType(NotebookInkCanvas));
    expect(canvas().drawingEnabled, isTrue);
    expect(canvas().tool, InkTool.highlighter);
    expect(canvas().erasing, isFalse);
    expect(canvas().lassoing, isFalse);

    await unmount(tester);
  });

  testWidgets('each tool remembers its own colour', (tester) async {
    await mountEditor(tester, notebook: seeded());
    NotebookInkCanvas canvas() =>
        tester.widget<NotebookInkCanvas>(find.byType(NotebookInkCanvas));

    await tester.longPress(find.byIcon(Icons.draw));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('notebook-ink-swatch-blue')));
    await tester.pumpAndSettle();
    expect(canvas().colour, InkColor.blue);

    await tester.tap(find.byKey(const ValueKey('notebook-highlighter')));
    await tester.pump();
    expect(canvas().colour, InkColor.yellow, reason: 'highlighter default');

    await tester.longPress(find.byKey(const ValueKey('notebook-highlighter')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('notebook-ink-swatch-pink')));
    await tester.pumpAndSettle();
    expect(canvas().colour, InkColor.pink);

    // Back to the pen: it still has the blue chosen earlier.
    await tester.tap(find.byIcon(Icons.draw));
    await tester.pump();
    expect(canvas().tool, InkTool.pen);
    expect(canvas().colour, InkColor.blue);

    await unmount(tester);
  });

  testWidgets('leaving draw mode resets to the pen', (tester) async {
    await mountEditor(tester, notebook: seeded());
    NotebookInkCanvas canvas() =>
        tester.widget<NotebookInkCanvas>(find.byType(NotebookInkCanvas));

    await tester.tap(find.byKey(const ValueKey('notebook-highlighter')));
    await tester.pump();
    expect(canvas().tool, InkTool.highlighter);

    // A stranded highlighter would make the next stroke a wash of colour
    // when the user expected handwriting — same rule as the eraser.
    await tester.tap(find.byIcon(Icons.draw));
    await tester.pump();
    expect(canvas().tool, InkTool.pen);

    await unmount(tester);
  });
```

`mountEditor`, `seeded()`, and `unmount` already exist in this file — use them as-is.

- [ ] **Step 2: Run them to verify they fail**

Run: `flutter test test/widget/notebook_editor_screen_test.dart --plain-name "palette"`
Expected: FAIL — the `notebook-highlighter` key does not exist.

- [ ] **Step 3: Write the palette popup**

Create `client/lib/widgets/ink_palette_popup.dart`:

```dart
// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';

import '../models/notebook.dart';
import '../theme/tangent_tokens.dart';

/// Shows a tool's ink palette anchored near [globalPosition].
///
/// Returns the chosen colour, or null if the sheet was dismissed without a
/// choice — callers must treat null as "leave the current colour alone",
/// never as a reset.
Future<InkColor?> showInkPalette({
  required BuildContext context,
  required InkTool tool,
  required InkColor selected,
  required Offset globalPosition,
}) {
  final Size screen = MediaQuery.sizeOf(context);
  return showMenu<InkColor>(
    context: context,
    position: RelativeRect.fromLTRB(
      globalPosition.dx,
      globalPosition.dy,
      screen.width - globalPosition.dx,
      screen.height - globalPosition.dy,
    ),
    color: TangentColors.panel,
    items: <PopupMenuEntry<InkColor>>[
      PopupMenuItem<InkColor>(
        enabled: false,
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (final InkColor colour in InkColor.paletteFor(tool))
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: InkSwatch(
                  colour: colour,
                  selected: colour == selected,
                  onTap: () => Navigator.of(context).pop(colour),
                ),
              ),
          ],
        ),
      ),
    ],
  );
}

/// One circular swatch. A highlighter's translucency is shown against the
/// page colour, so the swatch previews the mark rather than the raw value.
class InkSwatch extends StatelessWidget {
  const InkSwatch({
    super.key,
    required this.colour,
    required this.selected,
    required this.onTap,
  });

  final InkColor colour;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        selected: selected,
        label: colour.wireValue,
        child: GestureDetector(
          key: ValueKey<String>('notebook-ink-swatch-${colour.wireValue}'),
          onTap: onTap,
          child: Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: TangentColors.sunken,
              shape: BoxShape.circle,
              border: Border.all(
                color: selected ? TangentColors.signal : TangentColors.edge,
                width: selected ? 2 : 1,
              ),
            ),
            child: Center(
              child: Container(
                width: 18,
                height: 18,
                decoration: BoxDecoration(
                  color: Color(colour.argb),
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ),
        ),
      );
}
```

Check `tangent_tokens.dart` for the exact border token before using it — `TangentColors.edge` (`#2B3034`) is the hairline/border token in this codebase.

- [ ] **Step 4: Wire the editor**

In `notebook_editor_screen.dart`, add state beside `_selectedImageId`:

```dart
  /// The instrument the next stroke uses.
  InkTool _tool = InkTool.pen;

  /// Each tool keeps its own ink for the session, so switching pen →
  /// highlighter → pen returns to the colour you were writing in.
  InkColor _penColour = InkColor.white;
  InkColor _highlighterColour = InkColor.yellow;

  InkColor get _activeColour =>
      _tool == InkTool.highlighter ? _highlighterColour : _penColour;
```

Extend `_enterDrawMode` so the draw-mode reset covers the tool, and add a highlighter button after the eraser. The pen button (`Icons.draw`) and the new highlighter button both gain a long-press:

```dart
                  GestureDetector(
                    onLongPressStart: _notebook == null
                        ? null
                        : (LongPressStartDetails d) => _pickInk(
                              InkTool.pen,
                              d.globalPosition,
                            ),
                    child: IconButton(
                      icon: const Icon(Icons.draw),
                      tooltip: _drawing ? 'Stop drawing' : 'Draw',
                      isSelected: _drawing && _tool == InkTool.pen,
                      color: Color(_penColour.argb),
                      onPressed: _notebook == null
                          ? null
                          : () => setState(() {
                                if (_drawing && _tool == InkTool.pen) {
                                  _drawing = false;
                                  _erasing = false;
                                  _lassoing = false;
                                  _lassoSelection = false;
                                  _tool = InkTool.pen;
                                  return;
                                }
                                _enterDrawMode();
                                _tool = InkTool.pen;
                              }),
                    ),
                  ),
```

The highlighter button, placed immediately after it:

```dart
                  GestureDetector(
                    onLongPressStart: _notebook == null
                        ? null
                        : (LongPressStartDetails d) => _pickInk(
                              InkTool.highlighter,
                              d.globalPosition,
                            ),
                    child: IconButton(
                      key: const ValueKey('notebook-highlighter'),
                      icon: const Icon(Icons.border_color),
                      tooltip: 'Highlighter. Long-press for colours',
                      isSelected: _drawing && _tool == InkTool.highlighter,
                      color: Color(_highlighterColour.argb),
                      onPressed: _notebook == null
                          ? null
                          : () => setState(() {
                                _enterDrawMode();
                                _tool = InkTool.highlighter;
                                // Mutually exclusive gestures, same rule the
                                // eraser and lasso already follow.
                                _erasing = false;
                                _lassoing = false;
                                _lassoSelection = false;
                              }),
                    ),
                  ),
```

Add the picker method beside `_enterDrawMode`:

```dart
  /// Opens a tool's palette and applies the choice. A dismissed sheet
  /// returns null and must leave the current colour alone.
  Future<void> _pickInk(InkTool tool, Offset globalPosition) async {
    final InkColor current =
        tool == InkTool.highlighter ? _highlighterColour : _penColour;
    final InkColor? picked = await showInkPalette(
      context: context,
      tool: tool,
      selected: current,
      globalPosition: globalPosition,
    );
    if (picked == null || !mounted) return;
    setState(() {
      if (tool == InkTool.highlighter) {
        _highlighterColour = picked;
      } else {
        _penColour = picked;
      }
      // Picking a colour selects that tool: the user just said what they
      // want to draw with.
      _enterDrawMode();
      _tool = tool;
    });
  }
```

In the Draw toggle's existing "leaving draw mode" branch, add `_tool = InkTool.pen;` beside the `_erasing = false;` reset.

Pass both to the canvas where it is constructed:

```dart
                        tool: _tool,
                        colour: _activeColour,
```

Import the popup: `import '../../widgets/ink_palette_popup.dart';`

- [ ] **Step 5: Run the tests to verify they pass**

Run: `flutter test test/widget/notebook_editor_screen_test.dart`
Expected: PASS — all 67 pre-existing tests plus the 4 new ones.

- [ ] **Step 6: Sabotage-prove the tool reset**

Remove `_tool = InkTool.pen;` from the leaving-draw-mode branch. Run the file. Expected: FAIL on "leaving draw mode resets to the pen". Restore, re-run, expect PASS. Report both.

- [ ] **Step 7: Commit**

```bash
flutter analyze
flutter test
git add client/lib/screens/notebook/notebook_editor_screen.dart client/lib/widgets/ink_palette_popup.dart client/test/widget/notebook_editor_screen_test.dart
git commit -m "Notebook toolbar: highlighter tool and long-press ink palettes"
```

---

### Task 5: Prove colour and highlighting reach the PDF

**Files:**
- Test: `client/test/unit/services/notebook_pdf_exporter_test.dart`
- Modify (only if the test proves it necessary): `client/lib/services/notebook_pdf_exporter.dart`

**Interfaces:**
- Consumes: everything above.
- Produces: nothing new.

The exporter rasterises the canvas rather than vectorising strokes, so colour and highlighting should reach the PDF for free. **Should is not proof** — the exporter builds its own painter inputs, and this task exists to confirm the claim with a real exported file rather than assuming it.

- [ ] **Step 1: Write the test**

```dart
  test('a page with a highlight and coloured ink exports', () async {
    final NotebookDocument document = NotebookDocument(
      blocks: const <NotebookBlock>[],
      strokes: const <InkStroke>[
        InkStroke(
          id: 'mark',
          width: 3,
          tool: InkTool.highlighter,
          colour: InkColor.lime,
          points: <InkPoint>[InkPoint(x: 10, y: 20), InkPoint(x: 90, y: 20)],
        ),
        InkStroke(
          id: 'pen',
          width: 3,
          colour: InkColor.red,
          points: <InkPoint>[InkPoint(x: 10, y: 20), InkPoint(x: 90, y: 22)],
        ),
      ],
    );

    final Uint8List pdf = await exportNotebookPdf(/* match this file's
        existing call shape — read a neighbouring test first */);

    expect(pdf, isNotEmpty);
    expect(String.fromCharCodes(pdf.take(5)), '%PDF-');
  });
```

Read an existing test in this file first and copy its exact construction of `NotebookDocument` and its exporter call — the names above are indicative, and inventing a signature here would produce a test that cannot compile.

- [ ] **Step 2: Run it**

Run: `flutter test test/unit/services/notebook_pdf_exporter_test.dart`
Expected: PASS, confirming rasterisation carries the new ink. **If it fails**, the exporter constructs a painter that does not pass strokes through — fix it by giving the exporter's painter the same `stroke:` argument added in Task 2, then re-run.

- [ ] **Step 3: Commit**

```bash
flutter analyze
flutter test
git add client/test/unit/services/notebook_pdf_exporter_test.dart client/lib/services/notebook_pdf_exporter.dart
git commit -m "Notebook export: cover coloured ink and highlights"
```

---

### Task 6: Ship it

**Files:** none (verification and delivery only).

- [ ] **Step 1: Full gates**

```bash
cd client
flutter analyze
flutter test
```
Expected: analyze "No issues found!", and **at least 1443 + the new tests** passing. A drop below 1443 means something regressed — find it before continuing.

- [ ] **Step 2: Build the release APK**

```bash
flutter build apk --release
"C:/Users/Jeff/AppData/Local/Android/Sdk/build-tools/34.0.0/apksigner.bat" verify --print-certs build/app/outputs/flutter-apk/app-release.apk
```
Expected: `✓ Built`, and `CN=Tangent` in the certificate. A debug APK will not install over the release-signed builds on either device.

- [ ] **Step 3: Install on both devices**

```bash
export PATH="$LOCALAPPDATA/Android/Sdk/platform-tools:$PATH"
adb connect <fold-tailscale-ip>:5555
for D in <tab-s10fe-serial> <fold-tailscale-ip>:5555; do
  adb -s $D shell dumpsys activity services dev.tangent.tangent | grep -c RecordingService
  adb -s $D install -r build/app/outputs/flutter-apk/app-release.apk
done
```
The RecordingService count must be `0` before installing. Note the Fold's USB serial `<fold-serial>` and the tailnet address are the **same device** — install once.

- [ ] **Step 4: On-device check**

Open a notebook, long-press the pen → pick red → write. Tap the highlighter → drag across the red writing. The handwriting must stay crisp on top of the band. Export the page to PDF and confirm both colours survive.

- [ ] **Step 5: Push**

```bash
git push origin main
gh run list -R GyratingSeaCow/tangent -L 1
```
Poll `gh run view <id>` until completed; report the real conclusion.

---

## Self-Review

**Spec coverage:** Palette → Task 1 enums. Paint order → Task 2. Chisel nib / no taper → Task 2. Data model + byte-identical → Task 1 (sabotage-proven). Tolerant readers → Task 1. Long-press interaction → Task 4. Third-mode rules (exclusivity, cold-tap enters draw mode, reset on exit) → Task 4 (reset sabotage-proven). Per-tool colour memory → Task 4. Colour affordance on icons → Task 4 (`color:` on both IconButtons). PDF risk → Task 5. Out-of-scope items appear in no task, as intended.

**Placeholder scan:** No TBDs. Three places deliberately say "read the neighbouring test first" (Task 3 harness, Task 5 exporter signature, the hairline token name) rather than inventing a signature — that is an instruction to verify, not a gap, and inventing those names would produce code that cannot compile.

**Type consistency:** `InkTool`/`InkColor` spelled identically throughout; `paletteFor`/`defaultFor`/`fromWire` used in Tasks 1, 2, and 4 with the signatures Task 1 defines; `buildStrokePaint(width, {stroke})` defined in Task 2 and used only there; `showInkPalette` defined in Task 4 and used only there. Swatch keys `notebook-ink-swatch-<wireValue>` match the enum wire values used in the Task 4 tests (`red`, `blue`, `pink`).

**One trap flagged for the implementer:** `InkTool.values` is declaration order `[pen, highlighter]` — the reverse of paint order. Task 2 Step 3 calls this out and uses an explicit list.
