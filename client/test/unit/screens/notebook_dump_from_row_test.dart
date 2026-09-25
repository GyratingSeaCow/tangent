// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/models/dump.dart';
import 'package:tangent/screens/notebook/notebook_editor_screen.dart'
    show dumpFromRow;

/// The notebook reads dumps through [dumpFromRow]. Summary import needs the
/// server-owned summary columns to survive that hop: a row carrying a
/// summary that maps to a Dump without one is exactly the severed seam that
/// would make the Summary shape fall back to "(no summary yet)" forever.
DumpRow _row({
  String? summary,
  String? summaryModel,
  int? summarizedAt,
}) =>
    DumpRow(
      id: 'd1',
      createdAt: DateTime.utc(2026, 9, 24, 8),
      updatedAt: DateTime.utc(2026, 9, 24, 8),
      mode: 'meeting',
      durationSeconds: 95,
      title: 'Standup',
      transcript: 'we talked',
      audioPath: '/audio/d1.opus',
      audioSizeBytes: 2048,
      syncStatus: 'synced',
      syncAttempts: 0,
      transcriptionStatus: 'transcribed',
      transcriptionAttempt: 0,
      summary: summary,
      summaryModel: summaryModel,
      summarizedAt: summarizedAt,
    );

void main() {
  test('dumpFromRow carries summary, summaryModel and summarizedAt', () {
    final Dump dump = dumpFromRow(
      _row(
        summary: '## Summary\n- we talked',
        summaryModel: 'Qwen3-4B-Instruct-2507-Q4_K_M',
        summarizedAt: 1790000000,
      ),
    );

    expect(dump.summary, '## Summary\n- we talked');
    expect(dump.summaryModel, 'Qwen3-4B-Instruct-2507-Q4_K_M');
    expect(
      dump.summarizedAt,
      DateTime.fromMillisecondsSinceEpoch(1790000000 * 1000, isUtc: true),
      reason: 'the row stores unix seconds; the model exposes a DateTime',
    );
  });

  test('dumpFromRow maps an unsummarized row to nulls, not blanks', () {
    final Dump dump = dumpFromRow(_row());

    expect(dump.summary, isNull);
    expect(dump.summaryModel, isNull);
    expect(dump.summarizedAt, isNull);
  });
}
