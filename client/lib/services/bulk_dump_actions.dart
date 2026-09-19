// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Bulk actions over a selection of recordings: download-all and
// transcribe-all. Pure orchestration — eligibility, sequencing, counting —
// with the actual work injected, so the rules are testable without storage.
import 'dart:async';

import '../data/local_db.dart';

/// One row's failure in a bulk run: which row and the reason shown to the
/// user. The reason is the storage layer's own wording where available.
typedef BulkFailure = ({String id, String reason});

/// Receipt for one bulk run. [noun] names the unit for the summary line.
/// [failures] carries each failed row's id and reason — the count alone
/// cannot tell a Wi-Fi gate from a dead server from a fenced identity, and
/// the receipt is the only diagnostic surface the user gets.
typedef BulkActionSummary = ({
  int succeeded,
  int skipped,
  int failed,
  String noun,
  List<BulkFailure> failures,
});

/// True when this row's audio can be fetched from the server: the server
/// holds it and this device does not.
bool bulkDownloadEligible(DumpRow row) =>
    row.audioOnServer == true && row.remoteOnly == true;

/// True when this row can be transcribed FROM THIS DEVICE without asking
/// anything: local audio to upload, no transcript worth protecting.
///
/// Excluded deliberately:
///  * completed rows — the per-row flow confirms before overwriting; a bulk
///    loop cannot ask, so it must not overwrite.
///  * remote-only rows — transcription uploads local bytes; there are none.
///  * text notes — no audio exists in any location.
///  * in-progress rows — the queue already owns them.
bool bulkTranscribeEligible(DumpRow row) {
  if (row.mode == 'text_note') return false;
  if (row.audioPath.isEmpty) return false;
  final String status = row.transcriptionStatus;
  return status == 'not_transcribed' || status == 'failed';
}

/// Downloads audio for every eligible row in [rows], one at a time.
///
/// Sequential on purpose: each download publishes into the same storage
/// tree and the server is a single small box — a burst of parallel fetches
/// wins nothing and turns one failure mode into several. [download] returns
/// null on success or the user-facing failure reason (a refusal — Wi-Fi
/// gate, absent audio — is a reason string, not a throw), so the receipt
/// can name WHY each row failed rather than only counting.
Future<BulkActionSummary> runBulkDownload({
  required List<DumpRow> rows,
  required Future<String?> Function(String dumpId) download,
  Duration perItemTimeout = const Duration(minutes: 2),
}) async {
  int succeeded = 0, skipped = 0;
  final List<BulkFailure> failures = <BulkFailure>[];
  for (final DumpRow row in rows) {
    if (!bulkDownloadEligible(row)) {
      skipped++;
      continue;
    }
    try {
      // A hard per-row deadline: one wedged fetch (dead route, no transport
      // timeout) must cost ONE failed row, never freeze the whole run with
      // the toolbar disabled behind it. TimeoutException is caught below
      // rather than via onTimeout: the callback's future may be reified
      // narrower than Future<String?> (a test closure returning only null),
      // and a mismatched onTimeout callback throws a TypeError at runtime.
      final String? reason = await download(row.id).timeout(perItemTimeout);
      reason == null
          ? succeeded++
          : failures.add((id: row.id, reason: reason));
    } on TimeoutException {
      failures.add(
        (
          id: row.id,
          reason: 'Timed out after ${perItemTimeout.inMinutes} min',
        ),
      );
    } catch (e) {
      // One row's failure is that row's news; the rest still get their turn.
      failures.add((id: row.id, reason: '$e'));
    }
  }
  return (
    succeeded: succeeded,
    skipped: skipped,
    failed: failures.length,
    noun: 'download',
    failures: failures,
  );
}

/// Requests transcription for every eligible row in [rows].
///
/// [transcribe] hands the id to ServerTranscriptionService.transcribeDump,
/// which queues and dedupes internally — this loop only decides WHO gets
/// queued and reports what happened.
Future<BulkActionSummary> runBulkTranscribe({
  required List<DumpRow> rows,
  required Future<void> Function(String dumpId) transcribe,
  Duration perItemTimeout = const Duration(minutes: 2),
}) async {
  int succeeded = 0, skipped = 0;
  final List<BulkFailure> failures = <BulkFailure>[];
  for (final DumpRow row in rows) {
    if (!bulkTranscribeEligible(row)) {
      skipped++;
      continue;
    }
    try {
      await transcribe(row.id).timeout(perItemTimeout);
      succeeded++;
    } catch (e) {
      failures.add((id: row.id, reason: '$e'));
    }
  }
  return (
    succeeded: succeeded,
    skipped: skipped,
    failed: failures.length,
    noun: 'transcription',
    failures: failures,
  );
}

/// One line the snackbar shows — the only receipt the user gets.
String describeBulkSummary(BulkActionSummary s) {
  final List<String> parts = <String>[
    if (s.succeeded > 0)
      '${s.succeeded} ${s.noun}${s.succeeded == 1 ? '' : 's'} done'
    else
      'Nothing to do',
    if (s.skipped > 0) '${s.skipped} skipped',
    if (s.failed > 0) '${s.failed} failed',
  ];
  return parts.join(' · ');
}
