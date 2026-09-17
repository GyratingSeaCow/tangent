// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/services/recording_persistence.dart';
import '../../support/storage_fixture.dart';
import 'recording_staging_validation_test.dart' show SymlinkedStagingHarness;

/// Reproduces the on-device F2 failure "Staging cleanup source is not owned":
/// after the F1 fix, save() publishes and commits the capture correctly, but
/// cleanupCommitted() still compares the staged file's resolveSymbolicLinks()
/// result against the LITERAL reservation path. When the staging directory is
/// handed out through a symlinked alias (Android /data/user/0 vs /data/data),
/// that comparison faults after every successful save — the user sees
/// "Recording failed" for a recording that saved, the staged file is never
/// deleted, and the committed reservation row is never removed.
///
/// The host publish path cannot reach cleanupCommitted under an aliased
/// staging directory (its own reparse-point ancestor hardening rejects
/// earlier), so this test drives cleanupCommitted directly against a
/// committed reservation — exactly the state the device DB showed.
void main() {
  final links = () {
    try {
      final probe = Directory.systemTemp.createTempSync('tangent-linkprobe-');
      try {
        Link(p.join(probe.path, 'l')).createSync(probe.path);
        return true;
      } finally {
        probe.deleteSync(recursive: true);
      }
    } on FileSystemException {
      return false; // Windows without developer mode cannot create symlinks.
    }
  }();

  test(
      'cleanupCommitted deletes aliased staged audio and the committed '
      'reservation without faulting', () async {
    if (!links) {
      markTestSkipped('symlinks unavailable on this host');
      return;
    }
    final h = SymlinkedStagingHarness();
    addTearDown(h.close);
    await h.bootstrap();
    final r = requireOk(await h.catalog.reserveCapture(mode: 'brain_dump'));
    expect(p.dirname(r.stagingPath), h.linkedStagingDir);
    final audio = [0x4f, 0x67, 0x67, 0x53, 1];
    await File(r.stagingPath).writeAsBytes(audio, flush: true);

    // Committed capture state, as save() persists it just before cleanup:
    // dump row + binding + reservation row in state 'committed'.
    final now = DateTime.utc(2030, 1, 2, 3, 4, 5);
    final binding = (
      key: r.key,
      location: r.location,
      audio: (kind: 'file', value: p.join(h.f.directory('A'), '${r.key.dumpId}.opus')),
      metadataName: '${r.key.dumpId}.meta.json'
    );
    await h.f.db.into(h.f.db.dumps).insert(DumpRow(
          id: r.key.dumpId,
          createdAt: now,
          updatedAt: now,
          mode: 'brain_dump',
          durationSeconds: 3,
          title: 'fixture cleanup',
          transcript: null,
          meetingNotes: null,
          audioPath: binding.audio.value,
          audioSizeBytes: audio.length,
          syncStatus: 'local_only',
          syncAttempts: 0,
          transcriptionStatus: 'not_transcribed',
          transcriptionAttempt: 0,
          transcriptionRequestId: null,
          transcriptionJobId: null,
          transcriptionError: null,
        ),);
    await h.f.db.bindRecording(binding);
    await h.f.db.customStatement(
      'UPDATE capture_reservations SET state=? WHERE reservation_id=?',
      ['committed', r.id],
    );

    final persistence = RecordingPersistence(
      db: h.f.db,
      backend: h.backend,
      mutations: h.mutations,
    );
    // The F2 defect: this faulted ProblemCode.invalid with
    // 'Staging cleanup source is not owned' because the staged file's
    // resolved path (real directory) never equals the literal aliased
    // reservation path. The corrected cleanup accepts the aliased owned
    // directory while still rejecting foreign/symlinked entries.
    await persistence.cleanupCommitted(r, binding);

    expect(
      await File(r.stagingPath).exists(),
      isFalse,
      reason: 'committed staging audio must be deleted by cleanup',
    );
    final retained = await h.f.db.customSelect(
      'SELECT reservation_id FROM capture_reservations '
      'WHERE reservation_id = ?',
      variables: [Variable(r.id)],
    ).get();
    expect(
      retained,
      isEmpty,
      reason: 'committed reservation row must be removed after cleanup',
    );
  });

  test('cleanup still rejects a staging entry that is itself a symlink',
      () async {
    if (!links) {
      markTestSkipped('symlinks unavailable on this host');
      return;
    }
    final h = SymlinkedStagingHarness();
    addTearDown(h.close);
    await h.bootstrap();
    final r = requireOk(await h.catalog.reserveCapture(mode: 'brain_dump'));
    final foreign = File(p.join(h.f.root.path, 'foreign.opus'));
    await foreign.writeAsBytes([1, 2, 3], flush: true);
    Link(r.stagingPath).createSync(foreign.path);
    final now = DateTime.utc(2030, 1, 2, 3, 4, 5);
    final binding = (
      key: r.key,
      location: r.location,
      audio: (kind: 'file', value: p.join(h.f.directory('A'), '${r.key.dumpId}.opus')),
      metadataName: '${r.key.dumpId}.meta.json'
    );
    await h.f.db.into(h.f.db.dumps).insert(DumpRow(
          id: r.key.dumpId,
          createdAt: now,
          updatedAt: now,
          mode: 'brain_dump',
          durationSeconds: 3,
          title: 'fixture symlink reject',
          transcript: null,
          meetingNotes: null,
          audioPath: binding.audio.value,
          audioSizeBytes: 3,
          syncStatus: 'local_only',
          syncAttempts: 0,
          transcriptionStatus: 'not_transcribed',
          transcriptionAttempt: 0,
          transcriptionRequestId: null,
          transcriptionJobId: null,
          transcriptionError: null,
        ),);
    await h.f.db.bindRecording(binding);
    await h.f.db.customStatement(
      'UPDATE capture_reservations SET state=? WHERE reservation_id=?',
      ['committed', r.id],
    );
    final persistence = RecordingPersistence(
      db: h.f.db,
      backend: h.backend,
      mutations: h.mutations,
    );
    await expectLater(
      persistence.cleanupCommitted(r, binding),
      throwsA(
        isA<StorageFault>()
            .having((e) => e.problem.code, 'code', ProblemCode.invalid)
            .having(
              (e) => e.problem.message,
              'message',
              'Staging cleanup source is not owned',
            ),
      ),
    );
    expect(
      await foreign.readAsBytes(),
      [1, 2, 3],
      reason: 'the foreign target must not be deleted',
    );
    expect(
      Link(r.stagingPath).existsSync(),
      isTrue,
      reason: 'the rejected symlink entry is left for diagnosis',
    );
  });
}
