// SPDX-License-Identifier: AGPL-3.0-or-later
/// Local search over handwriting and typed content.
///
/// Handwriting matches come from the ink index mirror — rows the server's OCR
/// produced and sync pulled down (replace-set per notebook). Typed text and
/// checkbox blocks are matched straight from the notebook document, so ONE
/// search box covers everything on the page (spec §3.3).
///
/// Matching is deliberately done in Dart rather than SQL LIKE: phrase queries
/// need each line's words in order (a LIKE hit on one word cannot see its
/// neighbours), and the corpus is one person's handwriting — thousands of
/// words, not millions — so loading a notebook's rows is cheap and keeps the
/// matcher testable as a plain function.
library;

import 'dart:convert';
import 'dart:ui' show Rect;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/local_db.dart';
import '../models/notebook.dart';
import '../screens/home/home_screen.dart' show localDbProvider;

/// App-wide [InkSearch] over the app's own database, the same seam
/// [notebookRepositoryProvider] uses. Tests override [localDbProvider] with
/// an in-memory db and seed index rows directly.
final inkSearchProvider = Provider<InkSearch>(
  (ref) => InkSearch(ref.watch(localDbProvider)),
);

/// One match inside a notebook, in page coordinates.
///
/// [lineId] is the anchor: a segmentation line id for ink, or the BLOCK id
/// for a typed match. [strokeIds] is what the find bar highlights — empty for
/// a typed match, which is highlighted by its block instead. [pageOrderKey]
/// is the match's index in reading order (bbox top, then left), so next/prev
/// in the find bar is a plain increment.
typedef InkMatch = ({
  String lineId,
  String wordText,
  Rect bbox,
  List<String> strokeIds,
  int pageOrderKey,
});

/// One notebook's result in a cross-notebook search.
///
/// [snippet] is the first matched line's words joined in reading order — the
/// context a list row shows under the notebook title.
typedef NotebookMatchSummary = ({
  String notebookId,
  int matchCount,
  String snippet,
});

/// One indexed word, decoded from its mirror row.
class _Word {
  _Word({
    required this.lineId,
    required this.text,
    required this.textLower,
    required this.bbox,
    required this.strokeIds,
  });

  final String lineId;
  final String text;
  final String textLower;
  final Rect bbox;
  final List<String> strokeIds;
}

/// A candidate match before reading-order keys are assigned.
class _Hit {
  _Hit({
    required this.lineId,
    required this.text,
    required this.bbox,
    required this.strokeIds,
  });

  final String lineId;
  final String text;
  final Rect bbox;
  final List<String> strokeIds;
}

/// Searches the local ink index mirror and typed notebook content.
class InkSearch {
  InkSearch(this._db);

  final LocalDb _db;

  /// Which notebooks contain [query], heaviest hitters first.
  ///
  /// Scans the ink index only: this is the library-wide entry point, and the
  /// index is the corpus that exists without opening every notebook document.
  Future<List<NotebookMatchSummary>> searchNotebooks(String query) async {
    final List<String> tokens = _tokens(query);
    if (tokens.isEmpty) return const <NotebookMatchSummary>[];

    final List<InkIndexEntry> rows =
        await _db.select(_db.inkIndexEntries).get();
    final Map<String, List<InkIndexEntry>> byNotebook =
        <String, List<InkIndexEntry>>{};
    for (final InkIndexEntry row in rows) {
      byNotebook.putIfAbsent(row.notebookId, () => <InkIndexEntry>[]).add(row);
    }

    final List<NotebookMatchSummary> summaries = <NotebookMatchSummary>[];
    for (final MapEntry<String, List<InkIndexEntry>> entry
        in byNotebook.entries) {
      final Map<String, List<_Word>> lines = _lines(entry.value);
      final List<_Hit> hits = _matchInk(lines, tokens);
      if (hits.isEmpty) continue;
      hits.sort(_readingOrder);
      final List<_Word> snippetLine = lines[hits.first.lineId] ?? <_Word>[];
      summaries.add(
        (
          notebookId: entry.key,
          matchCount: hits.length,
          snippet: snippetLine
              .map((w) => w.text)
              .where((t) => t.isNotEmpty)
              .join(' '),
        ),
      );
    }
    // Heaviest first: the notebook with the most matches is most likely the
    // one the user is trying to find.
    summaries.sort((a, b) => b.matchCount.compareTo(a.matchCount));
    return summaries;
  }

  /// Every match for [query] inside one notebook, in reading order.
  ///
  /// Covers BOTH kinds of content: indexed handwriting and the document's
  /// typed text/checkbox blocks. Typed matches carry empty [InkMatch.strokeIds]
  /// and the block's position as their bbox.
  Future<List<InkMatch>> searchInNotebook(
    String notebookId,
    String query,
  ) async {
    final List<String> tokens = _tokens(query);
    if (tokens.isEmpty) return const <InkMatch>[];

    final List<InkIndexEntry> rows = await (_db.select(_db.inkIndexEntries)
          ..where((t) => t.notebookId.equals(notebookId)))
        .get();
    final List<_Hit> hits = _matchInk(_lines(rows), tokens);

    // Typed content: the query as one phrase against each block's text. The
    // block text is real text (unlike ink, which is word boxes), so a plain
    // case-insensitive substring is the whole job.
    final NotebookRow? notebook = await _db.getNotebookRow(notebookId);
    if (notebook != null) {
      final String phrase = tokens.join(' ');
      final NotebookDocument doc = NotebookDocument.decode(notebook.docJson);
      for (final NotebookBlock block in doc.blocks) {
        final (String text, double? x, double? y) = switch (block) {
          NotebookTextBlock b => (b.text, b.x, b.y),
          NotebookCheckboxBlock b => (b.text, b.x, b.y),
          _ => ('', null, null),
        };
        if (text.isEmpty || !text.toLowerCase().contains(phrase)) continue;
        hits.add(
          _Hit(
            lineId: block.id,
            text: text,
            // Blocks carry a position but no measured size; a zero-sized rect
            // at the block's corner is still a correct scroll target, and the
            // find bar highlights typed matches by block id, not by rect.
            bbox: Rect.fromLTWH(x ?? 0, y ?? 0, 0, 0),
            strokeIds: const <String>[],
          ),
        );
      }
    }

    hits.sort(_readingOrder);
    return <InkMatch>[
      for (int i = 0; i < hits.length; i++)
        (
          lineId: hits[i].lineId,
          wordText: hits[i].text,
          bbox: hits[i].bbox,
          strokeIds: hits[i].strokeIds,
          pageOrderKey: i,
        ),
    ];
  }

  /// Lowercased query tokens; empty when the query is blank.
  static List<String> _tokens(String query) {
    final String trimmed = query.trim().toLowerCase();
    if (trimmed.isEmpty) return const <String>[];
    return trimmed.split(RegExp(r'\s+'));
  }

  /// Groups mirror rows into lines, each line's words in x-order — the same
  /// order the server assigned recognised text in, so "consecutive words"
  /// here means consecutive as written.
  static Map<String, List<_Word>> _lines(List<InkIndexEntry> rows) {
    final Map<String, List<_Word>> lines = <String, List<_Word>>{};
    for (final InkIndexEntry row in rows) {
      lines.putIfAbsent(row.lineId, () => <_Word>[]).add(
            _Word(
              lineId: row.lineId,
              text: row.wordText,
              textLower: row.wordTextLower,
              bbox: _decodeBbox(row.bboxJson),
              strokeIds: _decodeStrokeIds(row.strokeIdsJson),
            ),
          );
    }
    for (final List<_Word> words in lines.values) {
      words.sort((a, b) => a.bbox.left.compareTo(b.bbox.left));
    }
    return lines;
  }

  /// Runs the token query over segmented lines.
  ///
  /// A single token matches any word containing it. A multi-token query
  /// matches only a run of CONSECUTIVE words within one line — "project
  /// meeting" must not hit a line reading "project kickoff meeting", because
  /// that phrase is not what the user wrote. Each token matches its word by
  /// the same case-insensitive substring rule as a single-token query.
  static List<_Hit> _matchInk(
    Map<String, List<_Word>> lines,
    List<String> tokens,
  ) {
    final List<_Hit> hits = <_Hit>[];
    for (final List<_Word> words in lines.values) {
      for (int start = 0; start + tokens.length <= words.length; start++) {
        bool all = true;
        for (int i = 0; i < tokens.length; i++) {
          if (!words[start + i].textLower.contains(tokens[i])) {
            all = false;
            break;
          }
        }
        if (!all) continue;
        final List<_Word> run = words.sublist(start, start + tokens.length);
        hits.add(
          _Hit(
            lineId: run.first.lineId,
            text: run.map((w) => w.text).join(' '),
            bbox: run.map((w) => w.bbox).reduce((a, b) => a.expandToInclude(b)),
            strokeIds: <String>[for (final _Word w in run) ...w.strokeIds],
          ),
        );
      }
    }
    return hits;
  }

  /// Reading order: top edge first, left edge to break the tie.
  static int _readingOrder(_Hit a, _Hit b) {
    final int byTop = a.bbox.top.compareTo(b.bbox.top);
    if (byTop != 0) return byTop;
    return a.bbox.left.compareTo(b.bbox.left);
  }

  static Rect _decodeBbox(String json) {
    try {
      final Object? decoded = jsonDecode(json);
      if (decoded is List && decoded.length == 4) {
        final List<double> v = decoded
            .map((e) => (e as num?)?.toDouble() ?? 0)
            .toList(growable: false);
        return Rect.fromLTRB(v[0], v[1], v[2], v[3]);
      }
    } on FormatException {
      // Fall through to the zero rect below.
    }
    // A malformed bbox degrades to a zero rect at the origin: the match still
    // lists and still highlights by stroke ids; only scroll-to is off.
    return Rect.zero;
  }

  static List<String> _decodeStrokeIds(String json) {
    try {
      final Object? decoded = jsonDecode(json);
      if (decoded is List) {
        return decoded.whereType<String>().toList(growable: false);
      }
    } on FormatException {
      // Fall through.
    }
    return const <String>[];
  }
}
