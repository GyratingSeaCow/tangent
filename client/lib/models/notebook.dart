// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart' show immutable, listEquals;

import 'notebook_ruling.dart';
import 'text_stamp.dart';

/// Typed view of one notebook row, its document and its ink layer.
///
/// Notebooks are stored as a single row with two JSON payloads (phase 1 of the
/// notebooks design): atomic document saves, no relational block explosion.
/// The list-facing surface of a notebook: what a row can show without
/// decoding a single stroke. [Notebook] carries it as part of the full
/// model; the repository's header stream carries it alone.
abstract interface class NotebookHeader {
  String get id;
  String get title;
  DateTime get updatedAt;
  String? get folderId;
  bool get pinned;
  String? get passwordHash;
  bool get passwordProtected;
}

class Notebook implements NotebookHeader {
  const Notebook({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    required this.document,
    required this.ink,
    this.folderId,
    this.pinned = false,
    this.ruling = NotebookRuling.medium,
    this.lastPenStyle,
    this.passwordHash,
    this.passwordSalt,
    this.passwordIterations,
    this.passwordHashPrev,
    this.passwordMetadataPresent = true,
  });

  @override
  final String id;
  @override
  final String title;
  final DateTime createdAt;
  @override
  final DateTime updatedAt;
  final NotebookDocument document;
  final NotebookInk ink;

  /// Which folder this notebook is filed in, or null when unfiled.
  ///
  /// Filing is metadata: moving a notebook between folders never moves its
  /// published file, so a reorganise cannot half-fail across storage.
  @override
  final String? folderId;

  /// Whether this notebook leads its current folder on the list screen.
  @override
  final bool pinned;

  /// How the page is ruled.
  ///
  /// New notebooks default to college ruled. Notebooks that predate this
  /// feature store null, and the repository reads null as [
  /// NotebookRuling.blank] — an existing page must not silently gain lines it
  /// was never given.
  final NotebookRuling ruling;

  /// The nib this notebook was last written with, or null when it has
  /// never recorded one (every notebook written before pen memory).
  ///
  /// Per-notebook on purpose: the user writes personal notebooks in
  /// fountain and others in ballpoint, and each must reopen with ITS pen
  /// rather than a global default. Null reads as the fountain default.
  final PenStyle? lastPenStyle;

  /// PBKDF2 password verifier metadata. The plaintext password is never kept.
  @override
  final String? passwordHash;
  final String? passwordSalt;
  final int? passwordIterations;

  /// Causal proof for the latest verifier transition. While unprotected this
  /// is the cleared hash tombstone; while protected it is the predecessor that
  /// authorized the install/rotation. It is a verifier, never plaintext.
  final String? passwordHashPrev;

  /// False only for a decoded legacy durable file that predates verifier
  /// fields. Present metadata is still subject to causal proof validation.
  final bool passwordMetadataPresent;
  @override
  bool get passwordProtected => passwordHash != null;

  Notebook copyWith({
    String? title,
    DateTime? updatedAt,
    NotebookDocument? document,
    NotebookInk? ink,
    NotebookRuling? ruling,
    PenStyle? lastPenStyle,
  }) => Notebook(
    id: id,
    title: title ?? this.title,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    document: document ?? this.document,
    ink: ink ?? this.ink,
    folderId: folderId,
    pinned: pinned,
    ruling: ruling ?? this.ruling,
    lastPenStyle: lastPenStyle ?? this.lastPenStyle,
    passwordHash: passwordHash,
    passwordSalt: passwordSalt,
    passwordIterations: passwordIterations,
    passwordHashPrev: passwordHashPrev,
    passwordMetadataPresent: passwordMetadataPresent,
  );
}

/// Default title for a freshly created notebook: `Notebook <yyyy-MM-dd HH-mm-ss>`.
///
/// Colons are illegal in filenames on several platforms, so the time uses
/// hyphens; the title is user-editable afterwards.
String defaultNotebookTitle(DateTime when) {
  String two(int value) => value.toString().padLeft(2, '0');
  final date =
      '${when.year.toString().padLeft(4, '0')}-'
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
        final x = raw['x'];
        final y = raw['y'];
        // x/y are absent in notebooks written before blocks were movable.
        // Null means "not placed yet"; the editor lays those out in order.
        if ((x != null && x is! num) || (y != null && y is! num)) {
          return NotebookUnknownBlock(raw);
        }
        return NotebookTextBlock(
          id: id,
          text: text,
          x: (x as num?)?.toDouble(),
          y: (y as num?)?.toDouble(),
          stamps: _decodeStamps(raw['stamps']),
        );
      case 'checkbox':
        final text = raw['text'];
        final checked = raw['checked'] ?? false;
        if (text is! String || checked is! bool) {
          return NotebookUnknownBlock(raw);
        }
        final cx = raw['x'];
        final cy = raw['y'];
        if ((cx != null && cx is! num) || (cy != null && cy is! num)) {
          return NotebookUnknownBlock(raw);
        }
        return NotebookCheckboxBlock(
          id: id,
          text: text,
          checked: checked,
          x: (cx as num?)?.toDouble(),
          y: (cy as num?)?.toDouble(),
        );
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
      case 'image':
        final data = raw['data'];
        final mime = raw['mime'];
        final x = raw['x'];
        final y = raw['y'];
        final width = raw['width'];
        final height = raw['height'];
        if (data is! String ||
            mime is! String ||
            x is! num ||
            y is! num ||
            width is! num ||
            height is! num) {
          return NotebookUnknownBlock(raw);
        }
        return NotebookImageBlock(
          id: id,
          data: data,
          mime: mime,
          x: x.toDouble(),
          y: y.toDouble(),
          width: width.toDouble(),
          height: height.toDouble(),
        );
      case 'pdfPage':
        final documentId = raw['documentId'];
        final importGroupId = raw['importGroupId'];
        final pageNumber = raw['pageNumber'];
        final pageCount = raw['pageCount'];
        final data = raw['data'];
        final x = raw['x'];
        final y = raw['y'];
        final width = raw['width'];
        final height = raw['height'];
        if (documentId is! String ||
            documentId.isEmpty ||
            (importGroupId != null &&
                (importGroupId is! String || importGroupId.isEmpty)) ||
            pageNumber is! int ||
            pageNumber < 1 ||
            pageCount is! int ||
            pageCount < pageNumber ||
            (data != null && data is! String) ||
            x is! num ||
            y is! num ||
            width is! num ||
            width <= 0 ||
            height is! num ||
            height <= 0) {
          return NotebookUnknownBlock(raw);
        }
        return NotebookPdfPageBlock(
          id: id,
          documentId: documentId,
          importGroupId: importGroupId as String?,
          pageNumber: pageNumber,
          pageCount: pageCount,
          data: data as String?,
          x: x.toDouble(),
          y: y.toDouble(),
          width: width.toDouble(),
          height: height.toDouble(),
        );
      case 'table':
        final rows = raw['rows'];
        final columns = raw['columns'];
        final x = raw['x'];
        final y = raw['y'];
        if (rows is! int ||
            columns is! int ||
            rows < 1 ||
            rows > kNotebookTableMaxDimension ||
            columns < 1 ||
            columns > kNotebookTableMaxDimension ||
            x is! num ||
            y is! num) {
          return NotebookUnknownBlock(raw);
        }
        final Map<int, String>? cells = _decodeTableCells(
          raw['cells'],
          rows: rows,
          columns: columns,
        );
        if (cells == null) return NotebookUnknownBlock(raw);
        return NotebookTableBlock(
          id: id,
          rows: rows,
          columns: columns,
          x: x.toDouble(),
          y: y.toDouble(),
          cells: cells,
        );
      default:
        return NotebookUnknownBlock(raw);
    }
  }
}

/// Largest supported row or column count for one notebook table.
const int kNotebookTableMaxDimension = 100;

/// Fixed cell geometry in canonical notebook-page pixels.
const double kNotebookTableCellWidth = 120;
const double kNotebookTableCellHeight = 44;

/// Large tables scroll inside a bounded viewport instead of widening the page.
const double kNotebookTableMaxViewportWidth = 600;
const double kNotebookTableMaxViewportHeight = 352;

Map<int, String>? _decodeTableCells(
  Object? raw, {
  required int rows,
  required int columns,
}) {
  // Empty cells are the default and are omitted from the wire format. This
  // keeps a new 100x100 table small instead of writing 10,000 empty strings.
  if (raw == null) return <int, String>{};
  if (raw is! List) return null;
  final Map<int, String> cells = <int, String>{};
  for (final Object? entry in raw) {
    if (entry is! Map<String, dynamic>) return null;
    final Object? row = entry['r'];
    final Object? column = entry['c'];
    final Object? text = entry['text'];
    if (row is! int ||
        column is! int ||
        text is! String ||
        row < 0 ||
        row >= rows ||
        column < 0 ||
        column >= columns) {
      return null;
    }
    if (text.isNotEmpty) cells[row * columns + column] = text;
  }
  return cells;
}

/// Tolerant `stamps` reader: a missing, mistyped, or partly garbage list
/// degrades to whatever entries are well-formed — never to an unknown
/// block. Losing a tappable time is recoverable; losing the text is not.
List<TextStamp> _decodeStamps(Object? raw) {
  if (raw is! List) return const <TextStamp>[];
  return List<TextStamp>.unmodifiable(<TextStamp>[
    for (final Object? entry in raw)
      if (TextStamp.tryFromJson(entry) case final TextStamp stamp) stamp,
  ]);
}

/// Free typed text.
class NotebookTextBlock extends NotebookBlock {
  const NotebookTextBlock({
    required this.id,
    required this.text,
    this.x,
    this.y,
    this.stamps = const <TextStamp>[],
  });

  @override
  final String id;
  final String text;

  /// Logical pixels from the page's top-left, or null when never moved.
  ///
  /// Null blocks are laid out in order by the editor, so notebooks written
  /// before blocks were movable open exactly as they did.
  final double? x;
  final double? y;

  /// Live `[mm:ss]` ranges inside [text] (v1.20.0). Empty for ordinary
  /// typed blocks. Callers that change [text] must pass reconciled stamps
  /// (see `reconcileStamps`); [copyWith] does not re-map them itself.
  final List<TextStamp> stamps;

  NotebookTextBlock copyWith({
    String? text,
    double? x,
    double? y,
    List<TextStamp>? stamps,
  }) => NotebookTextBlock(
    id: id,
    text: text ?? this.text,
    x: x ?? this.x,
    y: y ?? this.y,
    stamps: stamps ?? this.stamps,
  );

  @override
  Map<String, dynamic> toJson() => {
    'kind': 'text',
    'id': id,
    'text': text,
    if (x != null) 'x': x,
    if (y != null) 'y': y,
    // Written only when present: an unstamped block re-encodes
    // byte-identical to what every earlier build wrote.
    if (stamps.isNotEmpty)
      'stamps': stamps.map((s) => s.toJson()).toList(growable: false),
  };
}

/// A checkable line item.
class NotebookCheckboxBlock extends NotebookBlock {
  const NotebookCheckboxBlock({
    required this.id,
    required this.text,
    this.checked = false,
    this.x,
    this.y,
  });

  @override
  final String id;
  final String text;
  final bool checked;

  /// Logical pixels from the page's top-left, or null when never moved.
  final double? x;
  final double? y;

  NotebookCheckboxBlock copyWith({
    String? text,
    bool? checked,
    double? x,
    double? y,
  }) => NotebookCheckboxBlock(
    id: id,
    text: text ?? this.text,
    checked: checked ?? this.checked,
    x: x ?? this.x,
    y: y ?? this.y,
  );

  @override
  Map<String, dynamic> toJson() => {
    'kind': 'checkbox',
    'id': id,
    'text': text,
    'checked': checked,
    if (x != null) 'x': x,
    if (y != null) 'y': y,
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

/// An imported picture, floating on the page like a dump card.
///
/// The image bytes live INSIDE the document as base64 [data]: the notebook
/// file stays one self-contained durable JSON object (no sidecar to lose),
/// and sync carries the picture with the page. [width]/[height] are the
/// rendered size in canonical page pixels; resizing rewrites them and never
/// touches the bytes.
class NotebookImageBlock extends NotebookBlock {
  const NotebookImageBlock({
    required this.id,
    required this.data,
    required this.mime,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  @override
  final String id;

  /// Base64-encoded image bytes, exactly as imported.
  final String data;

  /// The picked file's MIME type (image/jpeg, image/png, ...).
  final String mime;

  /// Logical pixels from the canvas top-left, canonical page space.
  final double x;
  final double y;

  /// Rendered size in canonical page pixels. Aspect ratio is the importer's
  /// concern; the model stores whatever the editor committed.
  final double width;
  final double height;

  NotebookImageBlock copyWith({
    double? x,
    double? y,
    double? width,
    double? height,
  }) => NotebookImageBlock(
    id: id,
    data: data,
    mime: mime,
    x: x ?? this.x,
    y: y ?? this.y,
    width: width ?? this.width,
    height: height ?? this.height,
  );

  @override
  Map<String, dynamic> toJson() => {
    'kind': 'image',
    'id': id,
    'data': data,
    'mime': mime,
    'x': x,
    'y': y,
    'width': width,
    'height': height,
  };
}

/// One imported PDF page positioned on the notebook canvas.
///
/// A PDF import creates one block per source page so pages can be laid out,
/// rendered, and exported independently. The source PDF bytes are stored once,
/// on the first page block, as base64 [data]; sibling pages resolve them by
/// [documentId]. This keeps the durable notebook self-contained for sync
/// without multiplying a large PDF by its page count.
const Object _notebookPdfUnchanged = Object();

class NotebookPdfPageBlock extends NotebookBlock {
  const NotebookPdfPageBlock({
    required this.id,
    required this.documentId,
    required this.pageNumber,
    required this.pageCount,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    this.importGroupId,
    this.data,
  }) : assert(pageNumber >= 1),
       assert(pageCount >= pageNumber),
       assert(width > 0),
       assert(height > 0);

  @override
  final String id;

  /// Stable SHA-256 of the source bytes, shared by all pages in one import.
  final String documentId;

  /// Identifies one picker/import action. Null means a pre-grouping document.
  final String? importGroupId;
  final int pageNumber;
  final int pageCount;

  /// Base64 source bytes. Present on exactly one block per imported document.
  final String? data;

  final double x;
  final double y;
  final double width;
  final double height;

  NotebookPdfPageBlock copyWith({
    double? x,
    double? y,
    double? width,
    double? height,
    Object? data = _notebookPdfUnchanged,
    Object? importGroupId = _notebookPdfUnchanged,
  }) => NotebookPdfPageBlock(
    id: id,
    documentId: documentId,
    importGroupId: identical(importGroupId, _notebookPdfUnchanged)
        ? this.importGroupId
        : importGroupId as String?,
    pageNumber: pageNumber,
    pageCount: pageCount,
    data: identical(data, _notebookPdfUnchanged) ? this.data : data as String?,
    x: x ?? this.x,
    y: y ?? this.y,
    width: width ?? this.width,
    height: height ?? this.height,
  );

  @override
  Map<String, dynamic> toJson() => <String, dynamic>{
    'kind': 'pdfPage',
    'id': id,
    'documentId': documentId,
    if (importGroupId != null) 'importGroupId': importGroupId,
    'pageNumber': pageNumber,
    'pageCount': pageCount,
    if (data != null) 'data': data,
    'x': x,
    'y': y,
    'width': width,
    'height': height,
  };
}

/// An editable grid positioned on the notebook page.
///
/// Cell contents are stored sparsely by row-major index. Empty cells do not
/// consume document JSON, which matters at the supported 100x100 maximum.
/// The editor paints only the visible grid window and mounts at most one
/// TextField for the cell currently being edited.
class NotebookTableBlock extends NotebookBlock {
  const NotebookTableBlock({
    required this.id,
    required this.rows,
    required this.columns,
    required this.x,
    required this.y,
    this.cells = const <int, String>{},
  }) : assert(rows >= 1 && rows <= kNotebookTableMaxDimension),
       assert(columns >= 1 && columns <= kNotebookTableMaxDimension);

  @override
  final String id;
  final int rows;
  final int columns;
  final double x;
  final double y;

  /// Non-empty cell values keyed by `row * columns + column`.
  final Map<int, String> cells;

  double get contentWidth => columns * kNotebookTableCellWidth;
  double get contentHeight => rows * kNotebookTableCellHeight;
  double get viewportWidth => contentWidth < kNotebookTableMaxViewportWidth
      ? contentWidth
      : kNotebookTableMaxViewportWidth;
  double get viewportHeight => contentHeight < kNotebookTableMaxViewportHeight
      ? contentHeight
      : kNotebookTableMaxViewportHeight;

  String cellAt(int row, int column) {
    assert(row >= 0 && row < rows);
    assert(column >= 0 && column < columns);
    return cells[row * columns + column] ?? '';
  }

  NotebookTableBlock copyWith({
    double? x,
    double? y,
    Map<int, String>? cells,
  }) => NotebookTableBlock(
    id: id,
    rows: rows,
    columns: columns,
    x: x ?? this.x,
    y: y ?? this.y,
    cells: cells ?? this.cells,
  );

  NotebookTableBlock copyWithCell(int row, int column, String text) {
    assert(row >= 0 && row < rows);
    assert(column >= 0 && column < columns);
    final int index = row * columns + column;
    final Map<int, String> changed = <int, String>{...cells};
    if (text.isEmpty) {
      changed.remove(index);
    } else {
      changed[index] = text;
    }
    return copyWith(cells: changed);
  }

  @override
  Map<String, dynamic> toJson() {
    final List<MapEntry<int, String>> ordered =
        cells.entries
            .where((MapEntry<int, String> entry) => entry.value.isNotEmpty)
            .toList(growable: false)
          ..sort(
            (MapEntry<int, String> a, MapEntry<int, String> b) =>
                a.key.compareTo(b.key),
          );
    return <String, dynamic>{
      'kind': 'table',
      'id': id,
      'rows': rows,
      'columns': columns,
      'x': x,
      'y': y,
      if (ordered.isNotEmpty)
        'cells': <Map<String, dynamic>>[
          for (final MapEntry<int, String> entry in ordered)
            <String, dynamic>{
              'r': entry.key ~/ columns,
              'c': entry.key % columns,
              'text': entry.value,
            },
        ],
    };
  }
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

  /// The document as a JSON-encodable map. [encode] is this, stringified;
  /// callers embedding the document in a larger payload use this directly
  /// instead of paying an encode→decode round trip.
  Map<String, dynamic> toJson() => {
    'blocks': blocks.map((block) => block.toJson()).toList(growable: false),
  };

  String encode() => jsonEncode(toJson());

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
    this.style = PenStyle.ballpoint,
    this.tool = InkTool.pen,
    this.colour = InkColor.white,
  }) : assert(
         // The colour must belong to the tool's own palette. A highlighter
         // carrying an opaque pen ink would round-trip to a *different*
         // colour — `InkColor.fromWire` is palette-scoped, so it reads back
         // as yellow — and a 0xFF band would blot out the handwriting it is
         // painted beneath.
         //
         // Spelled out rather than `InkColor.paletteFor(tool).contains(...)`
         // because a method invocation is not a constant expression and
         // would make every `const InkStroke` a compile error. Keep this in
         // step with `paletteFor`; `ink palette`/`an ink outside the tool
         // palette cannot be constructed` fail loudly if it drifts.
         tool == InkTool.pen
             ? (colour == InkColor.white ||
                   colour == InkColor.blue ||
                   colour == InkColor.red ||
                   colour == InkColor.amber)
             : (colour == InkColor.yellow ||
                   colour == InkColor.lime ||
                   colour == InkColor.highlightBlue ||
                   colour == InkColor.pink),
         'colour must be one of InkColor.paletteFor(tool)',
       );

  final String id;
  final double width;
  final List<InkPoint> points;

  /// How this stroke renders. Ballpoint is the original flat stroke; fountain
  /// tapers with the pressure recorded in each point.
  final PenStyle style;

  /// Which instrument drew this. Highlighter strokes paint beneath pen ink.
  final InkTool tool;

  /// The ink. Defaults to white, which is also the pen's default, so a
  /// legacy stroke constructs correctly without naming a colour.
  final InkColor colour;

  /// Tolerant reader: missing fields fall back to defaults.
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
    final InkTool tool = InkTool.fromWire(raw['tool']);
    return InkStroke(
      id: id,
      width: width.toDouble(),
      style: PenStyle.fromWire(raw['style']),
      tool: tool,
      colour: InkColor.fromWire(raw['colour'], tool),
      points: decoded,
    );
  }

  InkStroke copyWith({
    String? id,
    double? width,
    List<InkPoint>? points,
    InkTool? tool,
    InkColor? colour,
  }) => InkStroke(
    id: id ?? this.id,
    width: width ?? this.width,
    style: style,
    tool: tool ?? this.tool,
    // A tool switch that names no colour adopts the new tool's default.
    // Carrying the old tool's ink across would violate the palette
    // invariant the constructor asserts.
    colour:
        colour ??
        (tool != null && tool != this.tool
            ? InkColor.defaultFor(tool)
            : this.colour),
    points: points ?? this.points,
  );

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

  @override
  String toString() =>
      'InkStroke($id, w=$width, ${tool.wireValue}, '
      '${colour.wireValue}, ${points.length}pts)';
}

/// How a stroke is rendered. Stored per stroke, so a page can mix pens.
enum PenStyle {
  /// The original uniform-width round stroke.
  ballpoint('ballpoint'),

  /// Width tapers with pen pressure, like Samsung Notes' fountain pen.
  fountain('fountain');

  const PenStyle(this.wireValue);
  final String wireValue;

  /// Unknown or absent styles read as ballpoint: showing the user's ink at
  /// the wrong width beats dropping it because a newer build named a pen
  /// this one has never heard of.
  static PenStyle fromWire(Object? raw) => switch (raw) {
    'fountain' => PenStyle.fountain,
    _ => PenStyle.ballpoint,
  };
}

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
  white('white', 0xFFF2EFE6),
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
    InkTool.highlighter => const <InkColor>[yellow, lime, highlightBlue, pink],
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

/// One sampled point of a stroke, in canvas logical pixels.
@immutable
class InkPoint {
  const InkPoint({required this.x, required this.y, this.p});

  final double x;
  final double y;

  /// Pen pressure 0–1 at this sample, null for legacy points and touch input.
  /// Null renders at the stroke's flat width.
  final double? p;

  /// Tolerant reader: missing/!num coordinates fall back to the origin.
  factory InkPoint.fromJson(Map<String, dynamic> json) => InkPoint(
    x: (json['x'] as num?)?.toDouble() ?? 0,
    y: (json['y'] as num?)?.toDouble() ?? 0,
    p: (json['p'] is num) ? (json['p'] as num).toDouble() : null,
  );

  /// Strict reader used when decoding storage.
  static InkPoint? tryFromJson(Map<String, dynamic> raw) {
    final x = raw['x'];
    final y = raw['y'];
    if (x is! num || y is! num) return null;
    final Object? p = raw['p'];
    return InkPoint(
      x: x.toDouble(),
      y: y.toDouble(),
      // A malformed pressure degrades that one sample to flat, never the file.
      p: p is num ? p.toDouble() : null,
    );
  }

  Offset get offset => Offset(x, y);

  Map<String, dynamic> toJson() => {
    'x': x,
    'y': y,
    // Written only when present, so legacy files re-encode unchanged.
    if (p != null) 'p': p,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is InkPoint && other.x == x && other.y == y && other.p == p;

  @override
  int get hashCode => Object.hash(x, y, p);

  @override
  String toString() => 'InkPoint($x, $y${p == null ? '' : ', p=$p'})';
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

  /// The ink as a JSON-encodable map; same contract as
  /// [NotebookDocument.toJson].
  Map<String, dynamic> toJson() => {
    'strokes': strokes.map((s) => s.toJson()).toList(growable: false),
  };

  String encode() => jsonEncode(toJson());

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
