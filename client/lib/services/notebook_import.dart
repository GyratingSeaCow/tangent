// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Dump → notebook import service (v1.20.0,
// docs/design/2026-09-27-transcript-to-notebook.md §A).
//
// ONE code path for landing recordings on a page. The editor's *Import
// meetings* flow and the recording-side *Send to notebook…* action both
// build their blocks with [importBlocksForDump], place them with
// [layoutImportedBlocks], and — when no editor is open — persist through
// [importDumpsIntoNotebook]. The layout formula used to live inside the
// editor's setState; it is pure here so it unit-tests without a widget.

import 'dart:math' as math;

import 'package:uuid/uuid.dart';

import '../data/local_db.dart';
import '../data/storage/storage_contract.dart';
import '../models/notebook.dart';
import '../models/speaker_names.dart';
import 'notebook_persistence.dart';
import 'summary_page_text.dart';
import 'transcript_page_text.dart';
import 'transcript_timings.dart';

/// How a picked dump lands on the page.
///
/// [summary] and [both] exist only while AI summaries are in play; the
/// shape sheet never lists them otherwise.
enum ImportShape { audio, text, summary, both }

/// What an import produced: the page it landed on and the ids of every
/// block it added, in page order (first id = first new block, which the
/// snackbar's *Open* action scrolls to).
typedef NotebookImportResult = ({
  String notebookId,
  List<String> newBlockIds,
});

// ── page geometry ─────────────────────────────────────────────────────
//
// Shared with the editor, which aliases these for its own flow layout so
// the service and the screen can never disagree about where content ends.

/// Inset of the page's content from its top-left corner.
const double kNotebookPagePadding = 12;

/// Vertical step between blocks that have never been moved.
const double kNotebookUnplacedBlockSpacing = 72;

/// Vertical gap between the current content bottom and an imported item.
const double kNotebookImportSpacing = 24;

/// Nominal height reserved for a block when computing the content bottom.
const double kNotebookImportBlockHeight = 90;

/// Spacing between consecutive imported audio cards.
const double kNotebookImportCardSpacing = 104;

/// Left edge every imported block lands on (the typed column's inset).
const double kNotebookImportX = kNotebookPagePadding + 4;

/// The lowest edge of everything on the page: placed blocks (plus a nominal
/// footprint height), flow-laid blocks at their computed slots, and every
/// ink point. Ink MUST count — without it cards land over handwriting.
double notebookContentBottom(
  List<NotebookBlock> blocks,
  List<InkStroke> strokes,
) {
  double lowest = 0;
  double flowY = kNotebookPagePadding;
  for (final NotebookBlock block in blocks) {
    switch (block) {
      case NotebookTextBlock t:
        lowest = math.max(lowest, (t.y ?? flowY) + kNotebookImportBlockHeight);
        if (t.y == null) flowY += kNotebookUnplacedBlockSpacing;
      case NotebookCheckboxBlock c:
        lowest = math.max(lowest, (c.y ?? flowY) + kNotebookImportBlockHeight);
        if (c.y == null) flowY += kNotebookUnplacedBlockSpacing;
      case NotebookDumpCardBlock d:
        lowest = math.max(lowest, d.y + kNotebookImportBlockHeight);
      case NotebookImageBlock i:
        lowest = math.max(lowest, i.y + i.height);
      case NotebookBlock():
        break;
    }
  }
  for (final InkStroke stroke in strokes) {
    for (final InkPoint point in stroke.points) {
      lowest = math.max(lowest, point.y);
    }
  }
  return lowest;
}

/// Vertical room a text box of [text] needs before the next item: the
/// import gap plus a line-count estimate, so consecutive imports of long
/// transcripts do not overlap each other.
double importedTextAdvance(String text) =>
    kNotebookImportSpacing + (text.length / 40).ceil() * 24.0;

/// Content-aware placement: every [incoming] block is positioned in order,
/// starting below the lowest existing content (blocks AND ink) and
/// stacking downward — never on top of what is already there. Returns the
/// positioned copies of [incoming] only; the caller appends them.
///
/// Text and checkbox blocks advance by [importedTextAdvance]; cards and
/// images by their own spacing. Unknown blocks pass through unpositioned.
List<NotebookBlock> layoutImportedBlocks({
  required List<NotebookBlock> existing,
  required List<InkStroke> strokes,
  required List<NotebookBlock> incoming,
}) {
  double insertY =
      notebookContentBottom(existing, strokes) + kNotebookImportSpacing;
  final List<NotebookBlock> placed = <NotebookBlock>[];
  for (final NotebookBlock block in incoming) {
    switch (block) {
      case NotebookTextBlock t:
        placed.add(t.copyWith(x: kNotebookImportX, y: insertY));
        insertY += importedTextAdvance(t.text);
      case NotebookCheckboxBlock c:
        placed.add(c.copyWith(x: kNotebookImportX, y: insertY));
        insertY += importedTextAdvance(c.text);
      case NotebookDumpCardBlock d:
        placed.add(d.copyWith(x: kNotebookImportX, y: insertY));
        insertY += kNotebookImportCardSpacing;
      case NotebookImageBlock i:
        placed.add(i.copyWith(x: kNotebookImportX, y: insertY));
        insertY += i.height + kNotebookImportSpacing;
      case NotebookBlock():
        placed.add(block);
    }
  }
  return placed;
}

// ── block content ─────────────────────────────────────────────────────

/// The transcript as page text. Honest fallback: an empty text box would
/// read as a broken import, so a missing transcript says so in the box.
TranscriptPageText transcriptImportText({
  required DumpRow dump,
  required TranscriptTimings? timings,
  required SpeakerNames speakerNames,
}) {
  final TranscriptPageText rendered = transcriptPageText(
    dump: dump,
    timings: timings,
    speakerNames: speakerNames,
  );
  if (!rendered.isEmpty) return rendered;
  return TranscriptPageText(
    text: '(no transcript for "${dump.title}")',
    stamps: const <TextStamp>[],
  );
}

/// The AI summary as page text (markdown headings flattened for the plain
/// block editor). Mirrors the transcript's fallback: a dump the server has
/// not summarized yet says so rather than landing an empty box.
String summaryImportText(DumpRow dump) {
  final String normalised = summaryToPageText(dump.summary ?? '');
  return normalised.isEmpty
      ? '(no summary yet for "${dump.title}")'
      : normalised;
}

/// The blocks ONE dump contributes for [shape], unpositioned and in page
/// order. [includeAudioCard] prepends an audio bubble to the Text and
/// Transcript + summary shapes (spec §C — the common case for tappable
/// stamps); the Audio shape is the card alone and Summary is unchanged.
List<NotebookBlock> importBlocksForDump({
  required DumpRow dump,
  required ImportShape shape,
  required bool includeAudioCard,
  required TranscriptTimings? timings,
  required SpeakerNames speakerNames,
  required String Function() newId,
}) {
  NotebookDumpCardBlock card() =>
      NotebookDumpCardBlock(id: newId(), dumpId: dump.id, x: 0, y: 0);
  NotebookTextBlock transcript() {
    final TranscriptPageText page = transcriptImportText(
      dump: dump,
      timings: timings,
      speakerNames: speakerNames,
    );
    return NotebookTextBlock(id: newId(), text: page.text, stamps: page.stamps);
  }

  NotebookTextBlock summary() =>
      NotebookTextBlock(id: newId(), text: summaryImportText(dump));

  return switch (shape) {
    ImportShape.audio => <NotebookBlock>[card()],
    ImportShape.text => <NotebookBlock>[
        if (includeAudioCard) card(),
        transcript(),
      ],
    ImportShape.summary => <NotebookBlock>[summary()],
    // Summary first, transcript beneath it: the whole record lands in one
    // import, each half honest on its own.
    ImportShape.both => <NotebookBlock>[
        if (includeAudioCard) card(),
        summary(),
        transcript(),
      ],
  };
}

// ── the headless import ───────────────────────────────────────────────

/// Lands [dumps] on notebook [notebookId] without opening the editor:
/// loads the notebook through [persistence], appends the blocks
/// [importBlocksForDump] produces (placed by [layoutImportedBlocks]), and
/// saves through [persistence] — which writes the row, marks it dirty for
/// sync, and publishes the durable file, exactly as the editor's Save does.
///
/// [timingsFor] and [speakerNamesFor] are injected so the caller decides
/// where timings come from (the row's column today). Throws
/// [StorageFault] with [ProblemCode.absent] when the notebook does not
/// exist; an empty [dumps] list is a no-op that still returns the id.
Future<NotebookImportResult> importDumpsIntoNotebook({
  required NotebookPersistence persistence,
  required String notebookId,
  required List<DumpRow> dumps,
  required ImportShape shape,
  required bool includeAudioCard,
  required Future<TranscriptTimings?> Function(String dumpId) timingsFor,
  required SpeakerNames Function(DumpRow) speakerNamesFor,
  String Function()? idFactory,
}) async {
  final Notebook? notebook = await persistence.getNotebook(notebookId);
  if (notebook == null) {
    throw StorageFault(
      (code: ProblemCode.absent, message: 'Notebook $notebookId not found'),
    );
  }
  if (dumps.isEmpty) {
    return (notebookId: notebookId, newBlockIds: const <String>[]);
  }
  final String Function() newId = idFactory ?? const Uuid().v4;
  final List<NotebookBlock> incoming = <NotebookBlock>[];
  for (final DumpRow dump in dumps) {
    incoming.addAll(
      importBlocksForDump(
        dump: dump,
        shape: shape,
        includeAudioCard: includeAudioCard,
        timings: await timingsFor(dump.id),
        speakerNames: speakerNamesFor(dump),
        newId: newId,
      ),
    );
  }
  final List<NotebookBlock> placed = layoutImportedBlocks(
    existing: notebook.document.blocks,
    strokes: notebook.ink.strokes,
    incoming: incoming,
  );
  await persistence.saveNotebook(
    notebook.copyWith(
      document: NotebookDocument(
        <NotebookBlock>[...notebook.document.blocks, ...placed],
      ),
    ),
  );
  return (
    notebookId: notebookId,
    newBlockIds: <String>[for (final NotebookBlock b in placed) b.id],
  );
}
