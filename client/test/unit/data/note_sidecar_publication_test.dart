// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/manual_transcript_publication.dart';
import 'package:tangent/data/storage/recording_access.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/services/note_persistence.dart';

import '../../support/scripted_storage_backend.dart';

/// Task 9 prerequisite (Task 2b): a text note's manual body edit must complete
/// the full sidecar-republication lifecycle. Three gates historically only
/// admitted completed/failed and would strand a not_applicable note with a
/// permanently stuck 'sidecar_sync_pending:' marker (which also blocks
/// deletion): publishManualTranscriptSidecar's status allow-list,
/// updateTranscriptionSidecarError's isIn gate, and the durable-recovery
/// query's marker branch.
void main() {
  test('note body edit publishes the sidecar and clears the pending marker',
      () async {
    final h = CatalogHarness();
    addTearDown(h.close);
    await h.bootstrap();
    final notes = NotePersistence(
      db: h.f.db,
      backend: h.backend,
      mutations: h.mutations,
      catalog: h.catalog,
    );
    final row = await notes.saveNote(
      text: 'first body',
      now: DateTime.utc(2030, 1, 2, 3, 4, 5),
    );
    expect(row.transcriptionStatus, 'not_applicable');

    final lease = switch (await h.mutations.acquire(row.id, UseKind.edit)) {
      Ok<UseLease>(:final value) => value,
      Fail<UseLease>(:final problem) => fail('acquire failed: $problem'),
    };
    addTearDown(lease.close);
    final access = BoundRecordingAccess(
      db: h.f.db,
      backend: h.backend,
      mutations: h.mutations,
    );

    final revision = await h.f.db.updateDumpTranscript(
      row.id,
      storageKey: lease.key,
      expectedTranscript: row.transcript!,
      expectedTranscriptionAttempt: row.transcriptionAttempt,
      expectedTranscriptionRequestId: row.transcriptionRequestId,
      transcript: 'edited body',
      now: DateTime.utc(2031),
    );
    expect(
      revision.transcriptionError,
      startsWith('sidecar_sync_pending: manual_edit:'),
      reason: 'Task 2 gate must admit not_applicable and set the marker',
    );

    final published = await publishManualTranscriptSidecar(
      db: h.f.db,
      access: access,
      storageKey: lease.key,
      revision: revision,
      now: () => DateTime.utc(2032),
    );
    expect(
      published,
      isTrue,
      reason: 'publication gate must admit not_applicable notes',
    );

    final settled = await h.f.db.getDump(row.id);
    expect(settled!.transcript, 'edited body');
    expect(
      settled.transcriptionError,
      isNull,
      reason: 'acknowledgement gate must clear the marker for notes',
    );
    expect(
      settled.transcriptionStatus,
      'not_applicable',
      reason: 'status must remain terminal not_applicable',
    );
  });

  test('durable recovery query surfaces a note with a stuck pending marker',
      () async {
    final h = CatalogHarness();
    addTearDown(h.close);
    await h.bootstrap();
    final notes = NotePersistence(
      db: h.f.db,
      backend: h.backend,
      mutations: h.mutations,
      catalog: h.catalog,
    );
    final row = await notes.saveNote(
      text: 'body needing recovery',
      now: DateTime.utc(2030, 2, 3, 4, 5, 6),
    );

    final lease = switch (await h.mutations.acquire(row.id, UseKind.edit)) {
      Ok<UseLease>(:final value) => value,
      Fail<UseLease>(:final problem) => fail('acquire failed: $problem'),
    };
    await h.f.db.updateDumpTranscript(
      row.id,
      storageKey: lease.key,
      expectedTranscript: row.transcript!,
      expectedTranscriptionAttempt: row.transcriptionAttempt,
      expectedTranscriptionRequestId: row.transcriptionRequestId,
      transcript: 'unpublished edit',
      now: DateTime.utc(2031),
    );
    await lease.close();

    final pending = await h.f.db.dumpsNeedingTranscriptionRecovery();
    expect(
      pending.map((d) => d.id),
      contains(row.id),
      reason: 'recovery must see not_applicable rows with pending markers',
    );
  });
}
