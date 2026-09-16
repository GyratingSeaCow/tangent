// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/manual_transcript_publication.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/data/storage/recording_access.dart';
import 'package:tangent/data/storage/recording_mutation_coordinator.dart';
import '../../support/storage_fixture.dart';
import '../../support/scripted_storage_backend.dart';

final class _SettlingMetadata extends ScriptedStorageBackend {
  final resultDelivered = Completer<void>();
  final release = Completer<void>();
  final writes = <BoundRecording>[];
  @override
  IoOperation<Outcome<void>> writeMetadata(
    BoundRecording binding,
    Map<String, dynamic> metadata,
    String operationId,
  ) {
    writes.add(binding);
    final actual = super.writeMetadata(binding, metadata, operationId);
    if (writes.length != 1) return actual;
    final result = actual.result.then((value) {
      resultDelivered.complete();
      return value;
    });
    return GatedIo(
      operationId,
      result,
      Future.wait([actual.settled, release.future]).then((_) {}),
    );
  }
}

void main() {
  for (final nullable in [false, true]) {
    test(
        'manual pinned FIFO waits actual settlement and late acknowledgement is a no-op (nullable=$nullable)',
        () async {
      final f = StorageFixture.create();
      final backend = _SettlingMetadata();
      final mutations = DefaultRecordingMutationCoordinator(db: f.db);
      final access = BoundRecordingAccess(
        db: f.db,
        backend: backend,
        mutations: mutations,
      );
      addTearDown(() async {
        if (!backend.release.isCompleted) backend.release.complete();
        await backend.drain();
        await mutations.drain();
        await f.close();
      });
      final a = await f.seed('fixture-manual-bound', status: 'completed');
      await f.metadata('B', a.key.dumpId).writeAsString('unrelated B');
      if (nullable) {
        await f.db.customStatement(
          "UPDATE dumps SET transcription_request_id=NULL, transcription_status='failed', transcription_error='original failure' WHERE id=?",
          [a.key.dumpId],
        );
      }
      await mutations.restoreFences(unsettled: await backend.unsettledUses());
      final before = (await f.db.getDump(a.key.dumpId))!;
      final revision = await f.db.updateDumpTranscript(
        a.key.dumpId,
        storageKey: a.key,
        expectedTranscript: before.transcript!,
        expectedTranscriptionAttempt: before.transcriptionAttempt,
        expectedTranscriptionRequestId: before.transcriptionRequestId,
        transcript: 'manual synthetic words',
        now: DateTime.utc(2031),
      );
      Future<bool> publish() => publishManualTranscriptSidecar(
            db: f.db,
            access: access,
            storageKey: a.key,
            revision: revision,
            now: () => DateTime.utc(2032),
          );
      var finished = false;
      final first = publish().then((value) {
        finished = true;
        return value;
      });
      await backend.resultDelivered.future;
      final second = publish();
      expect(finished, isFalse);
      expect(
        await mutations.acquire(a.key.dumpId, UseKind.deletion),
        isA<Fail<UseLease>>(),
      );
      backend.release.complete();
      expect(await first, isTrue);
      expect(await second, isTrue);
      // A caller whose DB-result acknowledgement was delayed arrives after repair.
      expect(await publish(), isTrue);
      expect(backend.writes, [a]);
      final current = (await f.db.getDump(a.key.dumpId))!;
      expect(
        current.transcriptionError,
        nullable ? 'original failure' : isNull,
      );
      expect(current.transcriptionRequestId, before.transcriptionRequestId);
      expect(current.meetingNotes, before.meetingNotes);
      expect(current.transcript, 'manual synthetic words');
      final json =
          jsonDecode(await f.metadata('A', a.key.dumpId).readAsString()) as Map;
      expect(json['transcript'], current.transcript);
      expect(json['transcriptionError'], current.transcriptionError);
      expect(await f.metadata('B', a.key.dumpId).readAsString(), 'unrelated B');
      expect(await f.audio('A', a.key.dumpId).readAsBytes(), [1, 2, 3]);
    });
  }
}
