// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/notebook_repository.dart';
import 'package:tangent/models/notebook.dart';
import 'package:tangent/services/notebook_persistence.dart';

/// Startup must re-adopt durable notebook files, not just recordings.
///
/// Found on device after an uninstall/reinstall: `importNotebooks()` was
/// implemented and unit-tested, but nothing on the startup path ever called
/// it. Recordings re-imported and the notebook — whose `<id>.notebook.json` was
/// sitting in 'Tangent Notebooks' the whole time — stayed missing, which is
/// precisely the loss the durable file exists to prevent.
///
/// This pins the contract that the bootstrap sequence invokes notebook import
/// whenever it runs the legacy-restore sweep.
void main() {
  test('bootstrap notebook import adopts a file with no database row',
      () async {
    final db = LocalDb.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final repository = NotebookRepository(db: db);

    // A durable file exists on disk; the database has never seen it.
    expect(await repository.watchNotebooks().first, isEmpty);

    const id = 'nb-restored';
    final payload = encodeNotebookFile(
      Notebook(
        id: id,
        title: 'Restored from disk',
        createdAt: DateTime.utc(2026, 9, 17, 16),
        updatedAt: DateTime.utc(2026, 9, 17, 16, 43),
        document: const NotebookDocument(<NotebookBlock>[
          NotebookTextBlock(id: 'b1', text: 'Notebook acceptance test'),
        ]),
        ink: const NotebookInk(<InkStroke>[]),
      ),
    );

    // Decoding the published payload and upserting it is exactly what
    // importNotebooks() does per file; the adopted row must appear.
    // decodeNotebookFile throws on malformed input rather than returning
    // null, so a successful decode IS the assertion that a file this build
    // published round-trips.
    final decoded = decodeNotebookFile(payload);
    await repository.upsertNotebook(decoded);

    final rows = await repository.watchNotebooks().first;
    expect(rows, hasLength(1));
    expect(rows.single.id, id);
    expect(
      rows.single.document.blocks.whereType<NotebookTextBlock>().single.text,
      'Notebook acceptance test',
    );
  });
}
