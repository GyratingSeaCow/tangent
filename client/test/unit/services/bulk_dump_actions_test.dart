// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Bulk actions over a selection of recordings.
//
// The rules under test are eligibility and honesty:
//
//  * "Download all audio" touches only rows whose audio is on the server and
//    not on this device. Everything else is SKIPPED, not failed — a bulk
//    action over a mixed selection is normal, not an error.
//  * "Transcribe all" touches only rows that hold local audio and are not
//    already transcribed. Bulk must never silently overwrite a transcript:
//    the per-row flow asks before overwriting, and a bulk loop cannot ask.
//  * One row's failure must not stop the rest, and the summary must count
//    what actually happened — the snackbar is the only receipt the user gets.
import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/services/bulk_dump_actions.dart';

import '../../support/dump_view_fixture.dart';

DumpRow local(String id) => viewRow(id);

DumpRow remote(String id) => viewRow(id).copyWith(
      audioPath: '',
      audioSizeBytes: 0,
      remoteOnly: const Value<bool?>(true),
      audioOnServer: const Value<bool?>(true),
    );

DumpRow transcribed(String id) => viewRow(id)
    .copyWith(transcriptionStatus: 'completed', transcript: const Value('hi'));

DumpRow textNote(String id) =>
    viewRow(id).copyWith(mode: 'text_note', audioPath: '');

void main() {
  group('bulk download', () {
    test('downloads only remote rows; skips local ones; counts both',
        () async {
      final List<String> downloaded = <String>[];
      final BulkActionSummary summary = await runBulkDownload(
        rows: <DumpRow>[remote('r1'), local('l1'), remote('r2')],
        download: (String id) async {
          downloaded.add(id);
          return true;
        },
      );
      expect(downloaded, <String>['r1', 'r2']);
      expect(summary.succeeded, 2);
      expect(summary.skipped, 1);
      expect(summary.failed, 0);
    });

    test('one failure does not stop the rest', () async {
      final List<String> attempted = <String>[];
      final BulkActionSummary summary = await runBulkDownload(
        rows: <DumpRow>[remote('r1'), remote('r2'), remote('r3')],
        download: (String id) async {
          attempted.add(id);
          if (id == 'r2') throw StateError('boom');
          return true;
        },
      );
      expect(attempted, <String>['r1', 'r2', 'r3']);
      expect(summary.succeeded, 2);
      expect(summary.failed, 1);
    });

    test('a refused download (Fail outcome) counts as failed, not success',
        () async {
      final BulkActionSummary summary = await runBulkDownload(
        rows: <DumpRow>[remote('r1')],
        download: (String id) async => false,
      );
      expect(summary.succeeded, 0);
      expect(summary.failed, 1);
    });

    test('a download that hangs is timed out and the run continues',
        () async {
      final List<String> attempted = <String>[];
      final BulkActionSummary summary = await runBulkDownload(
        rows: <DumpRow>[remote('r1'), remote('r2')],
        perItemTimeout: const Duration(milliseconds: 50),
        download: (String id) async {
          attempted.add(id);
          if (id == 'r1') {
            // Simulates a fetch against an unreachable server with no
            // transport timeout: it never completes. The bulk loop must
            // cut it loose or one dead row freezes the whole selection.
            await Completer<void>().future;
          }
          return true;
        },
      );
      expect(attempted, <String>['r1', 'r2']);
      expect(summary.failed, 1, reason: 'the hung row');
      expect(summary.succeeded, 1, reason: 'the run continued past it');
    });
  });

  group('bulk transcribe', () {
    test(
        'transcribes only untranscribed local audio; '
        'never overwrites, never uploads what is not here', () async {
      final List<String> sent = <String>[];
      final BulkActionSummary summary = await runBulkTranscribe(
        rows: <DumpRow>[
          local('a'), // eligible
          transcribed('b'), // has a transcript: bulk must not overwrite
          remote('c'), // no local audio: nothing to upload
          textNote('d'), // text notes have no audio at all
          local('e'), // eligible
        ],
        transcribe: (String id) async => sent.add(id),
      );
      expect(sent, <String>['a', 'e']);
      expect(summary.succeeded, 2);
      expect(summary.skipped, 3);
      expect(summary.failed, 0);
    });

    test('a failed transcription request is counted and does not stop others',
        () async {
      final List<String> sent = <String>[];
      final BulkActionSummary summary = await runBulkTranscribe(
        rows: <DumpRow>[local('a'), local('b'), local('c')],
        transcribe: (String id) async {
          sent.add(id);
          if (id == 'b') throw StateError('server down');
        },
      );
      expect(sent, <String>['a', 'b', 'c']);
      expect(summary.succeeded, 2);
      expect(summary.failed, 1);
    });

    test('a failed prior transcription is retried, not skipped', () async {
      final List<String> sent = <String>[];
      await runBulkTranscribe(
        rows: <DumpRow>[
          viewRow('f').copyWith(transcriptionStatus: 'failed'),
        ],
        transcribe: (String id) async => sent.add(id),
      );
      expect(
        sent,
        <String>['f'],
        reason: 'failed is exactly the state bulk retry exists for',
      );
    });
  });

  group('summary line', () {
    test('reads as a human receipt', () {
      const BulkActionSummary s =
          (succeeded: 2, skipped: 1, failed: 1, noun: 'download');
      expect(describeBulkSummary(s), '2 downloads done · 1 skipped · 1 failed');
      const BulkActionSummary one =
          (succeeded: 1, skipped: 0, failed: 0, noun: 'download');
      expect(describeBulkSummary(one), '1 download done');
      const BulkActionSummary none =
          (succeeded: 0, skipped: 3, failed: 0, noun: 'transcription');
      expect(describeBulkSummary(none), 'Nothing to do · 3 skipped');
    });
  });
}
