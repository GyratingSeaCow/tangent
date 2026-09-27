// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Dump → notebook import service (v1.20.0, spec §A). Drives the REAL
// NotebookPersistence over a real LocalDb + scripted storage backend: the
// import must land blocks in order with the editor's layout positions, save
// the row, mark it dirty for sync, and publish the durable file.

import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/notebook_repository.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/models/notebook.dart';
import 'package:tangent/models/speaker_names.dart';
import 'package:tangent/services/notebook_import.dart';
import 'package:tangent/services/notebook_persistence.dart';
import 'package:tangent/services/transcript_page_text.dart';
import 'package:tangent/services/transcript_timings.dart';

import '../../support/scripted_storage_backend.dart';

DumpRow dumpRow({
  required String id,
  String title = 'Standup',
  String? transcript,
  String? summary,
  String? speakerNames,
}) =>
    DumpRow(
      id: id,
      createdAt: DateTime.utc(2026, 9, 27, 9),
      updatedAt: DateTime.utc(2026, 9, 27, 9),
      mode: 'meeting',
      durationSeconds: 95,
      title: title,
      transcript: transcript,
      audioPath: '',
      audioSizeBytes: 0,
      syncStatus: 'local',
      syncAttempts: 0,
      transcriptionStatus: 'completed',
      transcriptionAttempt: 0,
      summary: summary,
      speakerNames: speakerNames,
    );

final TranscriptTimings twoTurns = TranscriptTimings.parse(
  '{"segments":['
  '{"start":0,"end":1,"speaker":"Speaker 1","text":"Morning"},'
  '{"start":5.9,"end":7,"speaker":"Speaker 2","text":"Morning to you"}]}',
)!;

void main() {
  late CatalogHarness h;
  late NotebookRepository repository;
  late NotebookPersistence persistence;
  int ids = 0;

  setUp(() async {
    h = CatalogHarness();
    addTearDown(h.close);
    await h.bootstrap();
    ids = 0;
    repository = NotebookRepository(
      db: h.f.db,
      idFactory: () => 'nb-${h.counter++}',
      now: () => DateTime.utc(2030, 5, 6, 7, 8, 9),
    );
    persistence = NotebookPersistence(
      repository: repository,
      backend: h.backend,
      catalog: h.catalog,
    );
  });

  String nextId() => 'blk-${ids++}';

  Future<NotebookImportResult> run({
    required String notebookId,
    required List<DumpRow> dumps,
    required ImportShape shape,
    bool includeAudioCard = false,
    Map<String, TranscriptTimings> timings = const {},
  }) =>
      importDumpsIntoNotebook(
        persistence: persistence,
        notebookId: notebookId,
        dumps: dumps,
        shape: shape,
        includeAudioCard: includeAudioCard,
        timingsFor: (String id) async => timings[id],
        speakerNamesFor: (DumpRow d) => SpeakerNames.decode(d.speakerNames),
        idFactory: nextId,
      );

  Future<List<NotebookBlock>> blocksOf(String id) async =>
      (await repository.getNotebook(id))!.document.blocks;

  group('layoutImportedBlocks', () {
    test('stacks incoming blocks below existing content and ink, in order', () {
      final placed = layoutImportedBlocks(
        existing: const <NotebookBlock>[
          NotebookTextBlock(id: 'old', text: 'placed low', x: 16, y: 600),
        ],
        strokes: const <InkStroke>[
          InkStroke(
            id: 's',
            width: 3,
            points: <InkPoint>[
              InkPoint(x: 100, y: 700),
              InkPoint(x: 1, y: 740),
            ],
          ),
        ],
        incoming: <NotebookBlock>[
          const NotebookDumpCardBlock(id: 'c', dumpId: 'd', x: 0, y: 0),
          NotebookTextBlock(id: 't', text: 'x' * 100),
          const NotebookTextBlock(id: 'u', text: 'short'),
        ],
      );
      expect(placed.map((b) => b.id), ['c', 't', 'u']);
      final card = placed[0] as NotebookDumpCardBlock;
      final long = placed[1] as NotebookTextBlock;
      final short = placed[2] as NotebookTextBlock;
      // Ink bottom (740) wins over the block (600 + 90): the card lands
      // below the handwriting, never over it.
      expect(card.y, 740 + kNotebookImportSpacing);
      expect(card.x, kNotebookImportX);
      expect(long.y, card.y + kNotebookImportCardSpacing);
      // 100 chars / 40 per line → 3 lines × 24 + the import gap.
      expect(short.y, long.y! + kNotebookImportSpacing + 3 * 24.0);
      expect(long.x, kNotebookImportX);
      expect(short.x, kNotebookImportX);
    });

    test('an empty page starts at the page inset', () {
      final placed = layoutImportedBlocks(
        existing: const <NotebookBlock>[],
        strokes: const <InkStroke>[],
        incoming: const <NotebookBlock>[NotebookTextBlock(id: 't', text: 'a')],
      );
      expect((placed.single as NotebookTextBlock).y, kNotebookImportSpacing);
    });

    test('never-moved existing blocks count at their flow slots', () {
      final bottom = notebookContentBottom(
        const <NotebookBlock>[
          NotebookTextBlock(id: 'a', text: 'a'),
          NotebookTextBlock(id: 'b', text: 'b'),
        ],
        const <InkStroke>[],
      );
      expect(
        bottom,
        kNotebookPagePadding +
            kNotebookUnplacedBlockSpacing +
            kNotebookImportBlockHeight,
      );
    });
  });

  group('importDumpsIntoNotebook', () {
    test(
        'Text shape inserts the rendered transcript with its stamps and '
        'saves through persistence (row dirty, file published)', () async {
      final created = await persistence.createNotebook(title: 'Scratch');
      await h.f.db.update(h.f.db.notebooks).write(
            const NotebooksCompanion(syncDirty: Value<bool>(false)),
          );
      final result = await run(
        notebookId: created.id,
        dumps: [
          dumpRow(
            id: 'd1',
            transcript: '## Speaker 1\n\nMorning\n\n## Speaker 2\n\n'
                'Morning to you',
            speakerNames: '{"Speaker 1":"Jeff"}',
          ),
        ],
        shape: ImportShape.text,
        timings: {'d1': twoTurns},
      );
      expect(result.notebookId, created.id);
      expect(result.newBlockIds, ['blk-0']);

      final blocks = await blocksOf(created.id);
      expect(blocks, hasLength(1));
      final text = blocks.single as NotebookTextBlock;
      expect(
        text.text,
        '[00:00] Jeff: Morning\n\n[00:05] Speaker 2: Morning to you',
      );
      expect(text.stamps, const [
        TextStamp(offset: 0, length: 7, seconds: 0, dumpId: 'd1'),
        TextStamp(offset: 23, length: 7, seconds: 5.9, dumpId: 'd1'),
      ]);
      expect(text.x, kNotebookImportX);
      expect(text.y, kNotebookImportSpacing);

      final row = await (h.f.db.select(h.f.db.notebooks)
            ..where((n) => n.id.equals(created.id)))
          .getSingle();
      expect(row.syncDirty, isTrue, reason: 'an import is unsynced work');
      final file = File(
        p.join(
          h.f.directory('A'),
          notebookSubdirectoryName,
          notebookFileName(created.id),
        ),
      );
      expect(await file.exists(), isTrue, reason: 'durable copy published');
      expect(await file.readAsString(), contains('"stamps"'));
    });

    test('includeAudioCard puts a card before each dump\'s text', () async {
      final created = await persistence.createNotebook(title: 'Scratch');
      final result = await run(
        notebookId: created.id,
        dumps: [
          dumpRow(id: 'd1', title: 'One', transcript: 'first'),
          dumpRow(id: 'd2', title: 'Two', transcript: 'second'),
        ],
        shape: ImportShape.text,
        includeAudioCard: true,
      );
      final blocks = await blocksOf(created.id);
      expect(
        blocks.map((b) => b.runtimeType),
        [
          NotebookDumpCardBlock,
          NotebookTextBlock,
          NotebookDumpCardBlock,
          NotebookTextBlock,
        ],
      );
      expect((blocks[0] as NotebookDumpCardBlock).dumpId, 'd1');
      expect((blocks[1] as NotebookTextBlock).text, 'first');
      expect((blocks[2] as NotebookDumpCardBlock).dumpId, 'd2');
      expect((blocks[3] as NotebookTextBlock).text, 'second');
      expect(result.newBlockIds, blocks.map((b) => b.id));
      // Stacked downward, never overlapping.
      double last = -1;
      for (final block in blocks) {
        final y = switch (block) {
          NotebookDumpCardBlock d => d.y,
          NotebookTextBlock t => t.y!,
          _ => throw StateError('unexpected $block'),
        };
        expect(y, greaterThan(last));
        last = y;
      }
    });

    test('includeAudioCard off: Text shape is text only', () async {
      final created = await persistence.createNotebook(title: 'Scratch');
      await run(
        notebookId: created.id,
        dumps: [dumpRow(id: 'd1', transcript: 'first')],
        shape: ImportShape.text,
      );
      final blocks = await blocksOf(created.id);
      expect(blocks.map((b) => b.runtimeType), [NotebookTextBlock]);
    });

    test('Audio shape is the card alone, whatever the switch says', () async {
      final created = await persistence.createNotebook(title: 'Scratch');
      await run(
        notebookId: created.id,
        dumps: [dumpRow(id: 'd1', transcript: 'first')],
        shape: ImportShape.audio,
        includeAudioCard: false,
      );
      final blocks = await blocksOf(created.id);
      expect(blocks.map((b) => b.runtimeType), [NotebookDumpCardBlock]);
      expect((blocks.single as NotebookDumpCardBlock).dumpId, 'd1');
    });

    test('both: card, summary, then rendered transcript, summary above',
        () async {
      final created = await persistence.createNotebook(title: 'Scratch');
      await run(
        notebookId: created.id,
        dumps: [
          dumpRow(
            id: 'd1',
            transcript: 'we talked about shipping on friday',
            summary: '## Summary\n- ship on Friday',
          ),
        ],
        shape: ImportShape.both,
        includeAudioCard: true,
        timings: {
          'd1': TranscriptTimings.parse(
            '[{"start":3,"end":4,"speaker":null,'
            '"text":"we talked about shipping on friday"}]',
          )!,
        },
      );
      final blocks = await blocksOf(created.id);
      expect(blocks, hasLength(3));
      expect(blocks[0], isA<NotebookDumpCardBlock>());
      final summary = blocks[1] as NotebookTextBlock;
      final transcript = blocks[2] as NotebookTextBlock;
      expect(summary.text, 'Summary\n- ship on Friday');
      expect(summary.stamps, isEmpty);
      expect(transcript.text, '[00:03] we talked about shipping on friday');
      expect(transcript.stamps.single.offset, 0);
      expect(summary.y!, lessThan(transcript.y!));
    });

    test('Summary shape is unchanged: flattened markdown, no card', () async {
      final created = await persistence.createNotebook(title: 'Scratch');
      await run(
        notebookId: created.id,
        dumps: [dumpRow(id: 'd1', summary: '## Summary\n- ship on Friday')],
        shape: ImportShape.summary,
        includeAudioCard: true,
      );
      final blocks = await blocksOf(created.id);
      expect(blocks.map((b) => b.runtimeType), [NotebookTextBlock]);
      expect(
        (blocks.single as NotebookTextBlock).text,
        'Summary\n- ship on Friday',
      );
    });

    test('honest fallbacks for a dump with no transcript / no summary',
        () async {
      final created = await persistence.createNotebook(title: 'Scratch');
      await run(
        notebookId: created.id,
        dumps: [dumpRow(id: 'd1', title: 'Standup', transcript: '  ')],
        shape: ImportShape.both,
      );
      final texts = (await blocksOf(created.id)).cast<NotebookTextBlock>();
      expect(texts.map((t) => t.text), [
        '(no summary yet for "Standup")',
        '(no transcript for "Standup")',
      ]);
      expect(texts.map((t) => t.stamps), everyElement(isEmpty));
    });

    test('no timings: transcript lands without stamps, never a fake time',
        () async {
      final created = await persistence.createNotebook(title: 'Scratch');
      await run(
        notebookId: created.id,
        dumps: [
          dumpRow(
            id: 'd1',
            transcript: '## Speaker 1\n\nMorning',
            speakerNames: '{"Speaker 1":"Jeff"}',
          ),
        ],
        shape: ImportShape.text,
      );
      final text = (await blocksOf(created.id)).single as NotebookTextBlock;
      expect(text.text, 'Jeff: Morning');
      expect(text.stamps, isEmpty);
    });

    test('appends below existing content instead of replacing it', () async {
      final created = await persistence.createNotebook(title: 'Scratch');
      await persistence.saveNotebook(
        created.copyWith(
          document: const NotebookDocument([
            NotebookTextBlock(id: 'old', text: 'keep me', x: 16, y: 600),
          ]),
        ),
      );
      await run(
        notebookId: created.id,
        dumps: [dumpRow(id: 'd1', transcript: 'new')],
        shape: ImportShape.text,
      );
      final blocks = await blocksOf(created.id);
      expect(blocks.map((b) => b.id), ['old', 'blk-0']);
      expect(
        (blocks[1] as NotebookTextBlock).y,
        600 + kNotebookImportBlockHeight + kNotebookImportSpacing,
      );
    });

    test('an unknown notebook faults as absent; empty dumps is a no-op',
        () async {
      await expectLater(
        run(
          notebookId: 'nope',
          dumps: [dumpRow(id: 'd1')],
          shape: ImportShape.text,
        ),
        throwsA(
          isA<StorageFault>()
              .having((f) => f.problem.code, 'code', ProblemCode.absent),
        ),
      );
      final created = await persistence.createNotebook(title: 'Scratch');
      final result =
          await run(notebookId: created.id, dumps: [], shape: ImportShape.text);
      expect(result.newBlockIds, isEmpty);
      expect(await blocksOf(created.id), isEmpty);
    });
  });
}
