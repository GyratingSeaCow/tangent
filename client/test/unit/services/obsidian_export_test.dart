// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/notebook_repository.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/models/dump_mode.dart';
import 'package:tangent/models/notebook.dart';
import 'package:tangent/services/obsidian_export.dart';

class _AvailableCatalog extends Fake implements StorageCatalog {
  @override
  Stream<DefaultFolderState> watchDefault() => Stream.value((
    location: const (
      id: 'test-location',
      directory: (
        kind: 'path',
        path: '/test',
        treeUri: '',
        authority: '',
        documentId: '',
      ),
      label: 'Test',
    ),
    revision: 1,
    available: true,
    canChooseDefault: true,
    problem: null,
  ));
}

class _RejectUnexpectedPublish extends Fake implements StorageBackend {
  @override
  IoOperation<Outcome<DurableDocument>> publishDocument(
    StorageLocation location,
    String directoryName,
    String name,
    String content,
    String publicationId,
  ) => throw StateError('locked notebook content reached the storage backend');
}

/// Obsidian export (2026-09-23): every dump and notebook becomes a
/// markdown file a vault can index. The rules pinned here:
///  * YAML frontmatter carries the Tangent identity and dates, so a
///    re-export can be recognised and files sort correctly in Obsidian
///  * filenames are vault-safe (no characters Obsidian or SAF reject)
///    and unique within one export run
///  * notebook blocks export in reading order (top to bottom); checkboxes
///    become task-list items; ink degrades to an honest note, never
///    silently vanishes
void main() {
  group('dump markdown', () {
    test('carries frontmatter, title, and transcript', () {
      final md = dumpMarkdown(
        id: 'dump-1',
        title: 'Groceries idea',
        createdAt: DateTime.utc(2026, 9, 23, 14, 30),
        mode: DumpMode.brainDump,
        durationSeconds: 95,
        transcript: 'Buy oat milk and batteries.',
      );

      expect(md, startsWith('---\n'));
      expect(md, contains('tangent-id: dump-1'));
      expect(md, contains('created: 2026-09-23T14:30:00.000Z'));
      expect(md, contains('type: brain-dump'));
      expect(md, contains('duration: 0:01:35'));
      expect(md, contains('# Groceries idea'));
      expect(md, contains('Buy oat milk and batteries.'));
    });

    test('a dump with no transcript says so instead of exporting nothing', () {
      final md = dumpMarkdown(
        id: 'dump-2',
        title: 'Untranscribed',
        createdAt: DateTime.utc(2026, 9, 23),
        mode: DumpMode.brainDump,
        durationSeconds: 10,
        transcript: null,
      );

      expect(md, contains('*Not transcribed yet.*'));
    });
  });

  group('notebook markdown', () {
    Notebook notebook(
      List<NotebookBlock> blocks, {
      List<InkStroke> strokes = const [],
    }) {
      return Notebook(
        id: 'nb-1',
        title: 'Plans',
        createdAt: DateTime.utc(2026, 9, 1),
        updatedAt: DateTime.utc(2026, 9, 23),
        document: NotebookDocument(blocks),
        ink: NotebookInk(strokes),
      );
    }

    test('text and checkboxes export in reading order', () {
      final md = notebookMarkdown(
        notebook(const [
          NotebookCheckboxBlock(
            id: 'b2',
            text: 'Call plumber',
            checked: true,
            x: 0,
            y: 200,
          ),
          NotebookTextBlock(id: 'b1', text: 'Kitchen refit', x: 0, y: 10),
          NotebookCheckboxBlock(
            id: 'b3',
            text: 'Order tiles',
            checked: false,
            x: 0,
            y: 300,
          ),
        ]),
      );

      expect(md, contains('tangent-id: nb-1'));
      final kitchen = md.indexOf('Kitchen refit');
      final plumber = md.indexOf('- [x] Call plumber');
      final tiles = md.indexOf('- [ ] Order tiles');
      expect(kitchen, lessThan(plumber), reason: 'y=10 must precede y=200');
      expect(plumber, lessThan(tiles));
    });

    test('ink degrades to an honest note, never vanishes silently', () {
      final md = notebookMarkdown(
        notebook(
          const [NotebookTextBlock(id: 'b1', text: 'Sketch page', x: 0, y: 0)],
          strokes: [
            InkStroke(
              id: 's1',
              width: 2,
              points: const [InkPoint(x: 1, y: 2), InkPoint(x: 3, y: 4)],
            ),
          ],
        ),
      );

      expect(
        md,
        contains('handwritten ink'),
        reason: 'the reader must know the page has ink the export cannot carry',
      );
    });

    test('PDF pages degrade to an honest omission note', () {
      final String md = notebookMarkdown(
        notebook(const <NotebookBlock>[
          NotebookPdfPageBlock(
            id: 'pdf-1',
            documentId: 'doc',
            pageNumber: 1,
            pageCount: 2,
            data: 'cGRm',
            x: 16,
            y: 20,
            width: 688,
            height: 900,
          ),
          NotebookPdfPageBlock(
            id: 'pdf-2',
            documentId: 'doc',
            pageNumber: 2,
            pageCount: 2,
            x: 16,
            y: 944,
            width: 688,
            height: 900,
          ),
        ]),
      );

      expect(md, contains('2 imported PDF pages not included'));
    });
  });

  group('vault-safe filenames', () {
    test('strips characters Obsidian and SAF reject', () {
      expect(
        vaultFileName(
          'What: about "quotes"/slashes?',
          DateTime.utc(2026, 9, 23),
        ),
        '2026-09-23 What about quotesslashes.md',
      );
    });

    test('an empty title falls back to the date alone', () {
      expect(
        vaultFileName('###', DateTime.utc(2026, 9, 23)),
        '2026-09-23 Untitled.md',
      );
    });

    test('duplicate names within a run get counters', () {
      final taken = <String>{};
      final a = uniqueVaultName('2026-09-23 Note.md', taken);
      final b = uniqueVaultName('2026-09-23 Note.md', taken);
      final c = uniqueVaultName('2026-09-23 Note.md', taken);

      expect(a, '2026-09-23 Note.md');
      expect(b, '2026-09-23 Note 2.md');
      expect(c, '2026-09-23 Note 3.md');
    });
  });

  test(
    'bulk export rejects a protected notebook until it is unlocked',
    () async {
      final LocalDb db = LocalDb.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final NotebookRepository notebooks = NotebookRepository(db: db);
      final int at = DateTime.utc(2026, 9, 23).millisecondsSinceEpoch;
      await db.applyRemoteNotebook(
        id: 'private',
        title: 'Private',
        docJson: '{"blocks":[{"kind":"text","id":"b1","text":"secret"}]}',
        inkJson: '{"strokes":[]}',
        createdAt: at,
        updatedAt: at,
        passwordHash: 'hash',
        passwordSalt: 'salt',
        passwordIterations: 210000,
        seq: 1,
      );
      final ObsidianExporter exporter = ObsidianExporter(
        db: db,
        notebooks: notebooks,
        backend: _RejectUnexpectedPublish(),
        catalog: _AvailableCatalog(),
        isNotebookUnlocked: (_, _) => false,
      );

      final ExportSummary summary = await exporter.run(
        onProgress: (_, _, _) {},
      );

      expect(summary.exported, 0);
      expect(summary.failed, hasLength(1));
      expect(summary.failed.single.reason, contains('Unlock this notebook'));
    },
  );

  group('anyDumpHasWordTimings (L4 switch gate)', () {
    Future<LocalDb> dbWith(List<(String, String?)> dumps) async {
      final LocalDb db = LocalDb.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final DateTime t = DateTime.utc(2026, 9, 28);
      for (final (id, timings) in dumps) {
        await db.applyRemoteDump(
          id: id,
          mode: 'brain_dump',
          title: id,
          transcript: 'hello',
          meetingNotes: null,
          durationSeconds: 3,
          audioOnServer: true,
          createdAt: t,
          updatedAt: t,
          seq: 1,
          transcriptTimings: timings,
        );
      }
      return db;
    }

    const segmentOnly =
        '{"segments":[{"start":0,"end":1,"text":"hello","words":[]}]}';
    const withWords =
        '{"segments":[{"start":0,"end":1,"text":"hello",'
        '"words":[{"w":"hello","s":0,"e":1}]}]}';

    test('false with no recordings', () async {
      expect(await anyDumpHasWordTimings(await dbWith([])), isFalse);
    });

    test('false when every recording is segment-only or untimed', () async {
      final db = await dbWith([('a', null), ('b', segmentOnly)]);
      expect(await anyDumpHasWordTimings(db), isFalse);
    });

    test('true once any recording carries word timings', () async {
      final db = await dbWith([
        ('a', null),
        ('b', segmentOnly),
        ('c', withWords),
      ]);
      expect(await anyDumpHasWordTimings(db), isTrue);
    });
  });
}
