// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart' show immutable, listEquals;

/// Typed view of one notebook row, its document and its ink layer.
///
/// Notebooks are stored as a single row with two JSON payloads (phase 1 of the
/// notebooks design): atomic document saves, no relational block explosion.
class Notebook {
  const Notebook({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    required this.document,
    required this.ink,
  });

  final String id;
  final String title;
  final DateTime createdAt;
  final DateTime updatedAt;
  final NotebookDocument document;
  final NotebookInk ink;

  Notebook copyWith({
    String? title,
    DateTime? updatedAt,
    NotebookDocument? document,
    NotebookInk? ink,
  }) =>
      Notebook(
        id: id,
        title: title ?? this.title,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        document: document ?? this.document,
        ink: ink ?? this.ink,
      );
}

/// Default title for a freshly created notebook: `Notebook <yyyy-MM-dd HH-mm-ss>`.
///
/// Colons are illegal in filenames on several platforms, so the time uses
/// hyphens; the title is user-editable afterwards.
String defaultNotebookTitle(DateTime when) {
  String two(int value) => value.toString().padLeft(2, '0');
  final date = '${when.year.toString().padLeft(4, '0')}-'
      '${two(when.month)}-${two(when.day)}';
  final time = '${two(when.hour)}-${two(when.minute)}-${two(when.second)}';
  return 'Notebook $date $time';
}

/// One entry in a notebook's ordered block list.
///
/// Every block round trips through [toJson]; a block whose `kind` this build
/// does not understand is carried verbatim by [NotebookUnknownBlock] so that a
/// newer build's data survives an older build opening and saving the notebook.
sealed class NotebookBlock {
  const NotebookBlock();

  String get id;

  Map<String, dynamic> toJson();

  /// Decodes one block, falling back to verbatim preservation.
  ///
  /// A known `kind` whose payload is malformed is also preserved verbatim
  /// rather than dropped or coerced: losing user data is worse than showing a
  /// block this build cannot render.
  static NotebookBlock fromJson(Map<String, dynamic> raw) {
    final id = raw['id'];
    if (id is! String) return NotebookUnknownBlock(raw);
    switch (raw['kind']) {
      case 'text':
        final text = raw['text'];
        if (text is! String) return NotebookUnknownBlock(raw);
        return NotebookTextBlock(id: id, text: text);
      case 'checkbox':
        final text = raw['text'];
        final checked = raw['checked'] ?? false;
        if (text is! String || checked is! bool) {
          return NotebookUnknownBlock(raw);
        }
        return NotebookCheckboxBlock(id: id, text: text, checked: checked);
      case 'dumpCard':
        final dumpId = raw['dumpId'];
        final x = raw['x'];
        final y = raw['y'];
        if (dumpId is! String || x is! num || y is! num) {
          return NotebookUnknownBlock(raw);
        }
        return NotebookDumpCardBlock(
          id: id,
          dumpId: dumpId,
          x: x.toDouble(),
          y: y.toDouble(),
        );
      default:
        return NotebookUnknownBlock(raw);
    }
  }
}

/// Free typed text.
class NotebookTextBlock extends NotebookBlock {
  const NotebookTextBlock({required this.id, required this.text});

  @override
  final String id;
  final String text;

  NotebookTextBlock copyWith({String? text}) =>
      NotebookTextBlock(id: id, text: text ?? this.text);

  @override
  Map<String, dynamic> toJson() => {'kind': 'text', 'id': id, 'text': text};
}

/// A checkable line item.
class NotebookCheckboxBlock extends NotebookBlock {
  const NotebookCheckboxBlock({
    required this.id,
    required this.text,
    this.checked = false,
  });

  @override
  final String id;
  final String text;
  final bool checked;

  NotebookCheckboxBlock copyWith({String? text, bool? checked}) =>
      NotebookCheckboxBlock(
        id: id,
        text: text ?? this.text,
        checked: checked ?? this.checked,
      );

  @override
  Map<String, dynamic> toJson() => {
        'kind': 'checkbox',
        'id': id,
        'text': text,
        'checked': checked,
      };
}

/// A floating, draggable reference to an existing recording.
///
/// The notebook never owns or mutates the dump; a missing [dumpId] renders as a
/// disabled placeholder and is never silently dropped.
class NotebookDumpCardBlock extends NotebookBlock {
  const NotebookDumpCardBlock({
    required this.id,
    required this.dumpId,
    required this.x,
    required this.y,
  });

  @override
  final String id;
  final String dumpId;

  /// Logical pixels from the canvas top-left.
  final double x;
  final double y;

  NotebookDumpCardBlock copyWith({double? x, double? y}) =>
      NotebookDumpCardBlock(
        id: id,
        dumpId: dumpId,
        x: x ?? this.x,
        y: y ?? this.y,
      );

  @override
  Map<String, dynamic> toJson() => {
        'kind': 'dumpCard',
        'id': id,
        'dumpId': dumpId,
        'x': x,
        'y': y,
      };
}

/// A block this build cannot interpret, retained byte-for-byte.
class NotebookUnknownBlock extends NotebookBlock {
  NotebookUnknownBlock(Map<String, dynamic> raw)
      : raw = Map<String, dynamic>.unmodifiable(raw);

  /// The original JSON map, returned unchanged on save.
  final Map<String, dynamic> raw;

  @override
  String get id => raw['id'] is String ? raw['id']! as String : '';

  @override
  Map<String, dynamic> toJson() => raw;
}

/// The ordered block list persisted in `notebooks.doc_json`.
class NotebookDocument {
  const NotebookDocument(this.blocks);

  const NotebookDocument.empty() : blocks = const <NotebookBlock>[];

  final List<NotebookBlock> blocks;

  /// Never throws: unreadable storage degrades to an empty document so that a
  /// corrupt row cannot brick the notebook list.
  static NotebookDocument decode(String? source) {
    final blocks = _decodeList(source, 'blocks');
    if (blocks == null) return const NotebookDocument.empty();
    return NotebookDocument(
      blocks
          .whereType<Map<String, dynamic>>()
          .map(NotebookBlock.fromJson)
          .toList(growable: false),
    );
  }

  String encode() => jsonEncode({
        'blocks': blocks.map((block) => block.toJson()).toList(growable: false),
      });

  NotebookDocument copyWith({List<NotebookBlock>? blocks}) =>
      NotebookDocument(blocks ?? this.blocks);
}

/// Default pen width, shared by the model layer and the toolbar control.
const double kDefaultPenWidth = 3;

/// A single ink stroke: white on black in phase 1, width captured at draw time.
@immutable
class InkStroke {
  const InkStroke({
    required this.id,
    required this.width,
    required this.points,
  });

  final String id;
  final double width;
  final List<InkPoint> points;

  /// Tolerant reader: missing fields fall back to defaults.
  factory InkStroke.fromJson(Map<String, dynamic> json) => InkStroke(
        id: json['id'] as String? ?? '',
        width: (json['width'] as num?)?.toDouble() ?? kDefaultPenWidth,
        points: <InkPoint>[
          for (final Object? point
              in (json['points'] as List<dynamic>? ?? const <dynamic>[]))
            if (point is Map<String, dynamic>) InkPoint.fromJson(point),
        ],
      );

  /// Strict reader used when decoding storage: unusable rows become null so
  /// they can be dropped instead of materialising an empty stroke.
  static InkStroke? tryFromJson(Map<String, dynamic> raw) {
    final id = raw['id'];
    final width = raw['width'];
    final points = raw['points'];
    if (id is! String || width is! num || points is! List) return null;
    final decoded = points
        .whereType<Map<String, dynamic>>()
        .map(InkPoint.tryFromJson)
        .whereType<InkPoint>()
        .toList(growable: false);
    if (decoded.isEmpty) return null;
    return InkStroke(id: id, width: width.toDouble(), points: decoded);
  }

  InkStroke copyWith({String? id, double? width, List<InkPoint>? points}) =>
      InkStroke(
        id: id ?? this.id,
        width: width ?? this.width,
        points: points ?? this.points,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'width': width,
        'points': points.map((p) => p.toJson()).toList(growable: false),
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is InkStroke &&
          other.id == id &&
          other.width == width &&
          listEquals(other.points, points);

  @override
  int get hashCode => Object.hash(id, width, Object.hashAll(points));

  @override
  String toString() => 'InkStroke($id, w=$width, ${points.length}pts)';
}

/// One sampled point of a stroke, in canvas logical pixels.
@immutable
class InkPoint {
  const InkPoint({required this.x, required this.y});

  final double x;
  final double y;

  /// Tolerant reader: missing/!num coordinates fall back to the origin.
  factory InkPoint.fromJson(Map<String, dynamic> json) => InkPoint(
        x: (json['x'] as num?)?.toDouble() ?? 0,
        y: (json['y'] as num?)?.toDouble() ?? 0,
      );

  /// Strict reader used when decoding storage.
  static InkPoint? tryFromJson(Map<String, dynamic> raw) {
    final x = raw['x'];
    final y = raw['y'];
    if (x is! num || y is! num) return null;
    return InkPoint(x: x.toDouble(), y: y.toDouble());
  }

  Offset get offset => Offset(x, y);

  Map<String, dynamic> toJson() => {'x': x, 'y': y};

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is InkPoint && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);

  @override
  String toString() => 'InkPoint($x, $y)';
}

/// The stroke list persisted in `notebooks.ink_json`.
class NotebookInk {
  const NotebookInk(this.strokes);

  const NotebookInk.empty() : strokes = const <InkStroke>[];

  final List<InkStroke> strokes;

  /// Never throws: unreadable storage degrades to no strokes.
  static NotebookInk decode(String? source) {
    final strokes = _decodeList(source, 'strokes');
    if (strokes == null) return const NotebookInk.empty();
    return NotebookInk(
      strokes
          .whereType<Map<String, dynamic>>()
          .map(InkStroke.tryFromJson)
          .whereType<InkStroke>()
          .toList(growable: false),
    );
  }

  String encode() => jsonEncode({
        'strokes': strokes.map((s) => s.toJson()).toList(growable: false),
      });

  NotebookInk copyWith({List<InkStroke>? strokes}) =>
      NotebookInk(strokes ?? this.strokes);
}

/// Shared tolerant reader for the `{"<key>": [...]}` envelope.
List<dynamic>? _decodeList(String? source, String key) {
  if (source == null || source.trim().isEmpty) return null;
  Object? decoded;
  try {
    decoded = jsonDecode(source);
  } on FormatException {
    return null;
  }
  if (decoded is! Map<String, dynamic>) return null;
  final list = decoded[key];
  return list is List ? list : null;
}
