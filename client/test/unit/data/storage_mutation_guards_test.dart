// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/models/sync_status.dart';
import 'package:tangent/models/transcription_status.dart';
import '../../support/storage_fixture.dart';

void main() {
  test(
      'matching storage key retains late attempt CAS and title-derived notes CAS',
      () async {
    final f = StorageFixture.create();
    addTearDown(f.close);
    final a = await f.seed('fixture-late-cas');
    final first = await f.db.beginTranscriptionAttempt(
      a.key.dumpId,
      storageKey: a.key,
      requestId: 'fixture-request-first',
      now: DateTime.utc(2031),
    );
    expect(
      await f.db.completeTranscriptionAttempt(
        a.key.dumpId,
        storageKey: a.key,
        attempt: first.transcriptionAttempt,
        requestId: first.transcriptionRequestId!,
        transcript: 'first words',
        meetingNotes: 'first notes',
        now: DateTime.utc(2031),
      ),
      isTrue,
    );
    final second = await f.db.beginTranscriptionAttempt(
      a.key.dumpId,
      storageKey: a.key,
      requestId: 'fixture-request-second',
      now: DateTime.utc(2032),
    );
    expect(
      await f.db.updateTranscriptionStatus(
        a.key.dumpId,
        storageKey: a.key,
        attempt: first.transcriptionAttempt,
        requestId: first.transcriptionRequestId!,
        status: TranscriptionStatus.failed,
        now: DateTime.utc(2033),
      ),
      isFalse,
    );
    expect(
      await f.db.completeTranscriptionAttempt(
        a.key.dumpId,
        storageKey: a.key,
        attempt: first.transcriptionAttempt,
        requestId: first.transcriptionRequestId!,
        transcript: 'stale words',
        meetingNotes: 'stale notes',
        now: DateTime.utc(2033),
      ),
      isFalse,
    );
    expect(await f.db.getDump(a.key.dumpId), second);
    final renamed = await f.db.updateDumpTitle(
      a.key.dumpId,
      storageKey: a.key,
      title: 'new title',
      now: DateTime.utc(2033),
    );
    await expectLater(
      f.db.updateDumpMeetingNotes(
        a.key.dumpId,
        storageKey: a.key,
        expectedTitle: second.title,
        expectedTranscript: second.transcript!,
        expectedTranscriptionAttempt: second.transcriptionAttempt,
        expectedTranscriptionRequestId: second.transcriptionRequestId,
        meetingNotes: 'stale derived notes',
        now: DateTime.utc(2034),
      ),
      throwsStateError,
    );
    expect(await f.db.getDump(a.key.dumpId), renamed);
  });
  for (final state in ['wrong incarnation', 'wrong ID', 'fenced', 'retired']) {
    for (final operation in [
      'title',
      'notes',
      'manual',
      'begin',
      'status',
      'complete',
      'sidecar',
      'sync',
    ]) {
      test('$operation rejects $state without changing semantic row', () async {
        final f = StorageFixture.create();
        addTearDown(f.close);
        final a = await f.seed('fixture-guard', status: 'completed');
        final row = (await f.db.getDump(a.key.dumpId))!;
        if (state == 'fenced' || state == 'retired') {
          final ticket = requireOk(
            await f.db.claimLocalDeletion(
              'fixture-claim',
              (
                id: a.key.dumpId,
                binding: a,
                title: row.title,
                eligibility: Eligibility.eligible,
                retryTicketId: null,
              ),
            ),
          );
          if (state == 'retired') {
            for (final component in RecordingComponent.values) {
              await f.db.recordDeletionComponent(
                ticket.id,
                component,
                (state: ComponentState.absent, problem: null),
              );
            }
            await f.db.finishLocalDeletion(ticket.id);
            await f.reopen();
          }
        }
        final key = state == 'wrong incarnation'
            ? (dumpId: a.key.dumpId, incarnation: 'fixture-foreign')
            : state == 'wrong ID'
                ? (dumpId: 'fixture-other', incarnation: a.key.incarnation)
                : a.key;
        final now = DateTime.utc(2031);
        Future<void> mutate() async {
          await switch (operation) {
            'title' => f.db.updateDumpTitle(
                row.id,
                storageKey: key,
                title: 'forbidden',
                now: now,
              ),
            'notes' => f.db.updateDumpMeetingNotes(
                row.id,
                storageKey: key,
                expectedTitle: row.title,
                expectedTranscript: row.transcript!,
                expectedTranscriptionAttempt: row.transcriptionAttempt,
                expectedTranscriptionRequestId: row.transcriptionRequestId,
                meetingNotes: 'forbidden',
                now: now,
              ),
            'manual' => f.db.updateDumpTranscript(
                row.id,
                storageKey: key,
                expectedTranscript: row.transcript!,
                expectedTranscriptionAttempt: row.transcriptionAttempt,
                expectedTranscriptionRequestId: row.transcriptionRequestId,
                transcript: 'forbidden',
                now: now,
              ),
            'begin' => f.db.beginTranscriptionAttempt(
                row.id,
                storageKey: key,
                requestId: 'fixture-new',
                now: now,
              ),
            'status' => f.db.updateTranscriptionStatus(
                row.id,
                storageKey: key,
                attempt: row.transcriptionAttempt,
                requestId: row.transcriptionRequestId!,
                status: TranscriptionStatus.failed,
                now: now,
              ),
            'complete' => f.db.completeTranscriptionAttempt(
                row.id,
                storageKey: key,
                attempt: row.transcriptionAttempt,
                requestId: row.transcriptionRequestId!,
                transcript: 'forbidden',
                meetingNotes: 'forbidden',
                now: now,
              ),
            'sidecar' => f.db.updateTranscriptionSidecarError(
                row.id,
                storageKey: key,
                attempt: row.transcriptionAttempt,
                requestId: row.transcriptionRequestId,
                error: 'forbidden',
                now: now,
              ),
            'sync' =>
              f.db.updateSyncStatus(row.id, SyncStatus.synced, storageKey: key),
            _ => throw StateError(operation),
          };
        }

        await expectLater(mutate(), throwsA(isA<StorageFault>()));
        expect(await f.db.getDump(row.id), state == 'retired' ? isNull : row);
        expect(await f.audio('A', row.id).readAsBytes(), [1, 2, 3]);
      });
    }
  }
}
