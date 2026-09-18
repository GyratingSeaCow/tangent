// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/recording_metadata.dart';
import 'package:tangent/data/storage/storage_contract.dart';

void main() {
  test('orphan recording without metadata gets a valid generated title', () {
    final row = importedDumpRow(
      id: '1789341285253510',
      locator: 'content://recording',
      sizeBytes: 19740,
      modifiedAt: DateTime.utc(2026, 9, 14, 19, 24),
    );
    expect(row.title, isNotEmpty);
    expect(row.title, startsWith('Recording '));
  });

  test('blank metadata title is repaired while other metadata is restored', () {
    final row = importedDumpRow(
      id: 'id-2',
      locator: 'content://recording-2',
      sizeBytes: 42,
      modifiedAt: DateTime.utc(2026, 9, 14),
      metadata: const {
        'title': '',
        'transcript': 'restored transcript',
        'durationSeconds': 9,
        'mode': 'meeting',
      },
    );
    expect(row.title, isNotEmpty);
    expect(row.transcript, 'restored transcript');
    expect(row.durationSeconds, 9);
    expect(row.mode, 'meeting');
  });

  test('sidecar v2 round-trips every durable transcription field', () {
    final started = DateTime.utc(2026, 9, 14, 18, 1);
    final updated = DateTime.utc(2026, 9, 14, 18, 2);
    final completed = DateTime.utc(2026, 9, 14, 18, 3);
    final row = DumpRow(
      id: 'roundtrip',
      createdAt: DateTime.utc(2026, 9, 14, 18),
      updatedAt: updated,
      mode: 'meeting',
      durationSeconds: 42,
      title: 'Durable meeting',
      transcript: 'Raw transcript',
      meetingNotes: 'Meeting notes',
      audioPath: 'content://original',
      audioSizeBytes: 99,
      syncStatus: 'local_only',
      syncAttempts: 0,
      transcriptionStatus: 'completed',
      transcriptionRequestId: 'request-roundtrip',
      transcriptionJobId: 'job-roundtrip',
      transcriptionAttempt: 3,
      transcriptionStartedAt: started,
      transcriptionUpdatedAt: updated,
      transcriptionCompletedAt: completed,
      transcriptionError: 'sidecar_sync_pending: retry',
    );

    final metadata = dumpMetadata(row);
    final restored = importedDumpRow(
      id: row.id,
      locator: 'content://restored',
      sizeBytes: row.audioSizeBytes,
      modifiedAt: updated,
      metadata: metadata,
    );

    expect(metadata['schemaVersion'], 2);
    expect(metadata['transcriptionStatus'], 'completed');
    expect(metadata['transcriptionRequestId'], 'request-roundtrip');
    expect(metadata['transcriptionJobId'], 'job-roundtrip');
    expect(metadata['transcriptionAttempt'], 3);
    expect(metadata['transcriptionStartedAt'], started.toIso8601String());
    expect(metadata['transcriptionUpdatedAt'], updated.toIso8601String());
    expect(metadata['transcriptionCompletedAt'], completed.toIso8601String());
    expect(metadata['transcriptionError'], 'sidecar_sync_pending: retry');
    expect(restored.transcriptionStatus, 'completed');
    expect(restored.transcriptionRequestId, 'request-roundtrip');
    expect(restored.transcriptionJobId, 'job-roundtrip');
    expect(restored.transcriptionAttempt, 3);
    expect(restored.transcriptionStartedAt, started);
    expect(restored.transcriptionUpdatedAt, updated);
    expect(restored.transcriptionCompletedAt, completed);
    expect(restored.transcriptionError, 'sidecar_sync_pending: retry');
  });

  test('schema v1 metadata derives status only from a non-empty transcript',
      () {
    DumpRow restore(String id, String? transcript) => importedDumpRow(
          id: id,
          locator: 'content://$id',
          sizeBytes: 1,
          modifiedAt: DateTime.utc(2026, 9, 14),
          metadata: {
            'schemaVersion': 1,
            'title': id,
            'transcript': transcript,
          },
        );

    expect(restore('done', 'spoken words').transcriptionStatus, 'completed');
    expect(restore('blank', '   ').transcriptionStatus, 'not_transcribed');
    expect(restore('missing', null).transcriptionStatus, 'not_transcribed');
  });

  test('schema v2 blank status derives completed from non-empty transcript',
      () {
    final row = importedDumpRow(
      id: 'v2-blank-status',
      locator: 'content://v2-blank-status',
      sizeBytes: 1,
      modifiedAt: DateTime.utc(2026, 9, 14),
      metadata: const {
        'schemaVersion': 2,
        'title': 'Blank status',
        'transcript': '  recovered transcript  ',
        'transcriptionStatus': '',
      },
    );

    expect(row.transcriptionStatus, 'completed');
  });

  test('schema v2 unknown status derives not transcribed from blank text', () {
    final row = importedDumpRow(
      id: 'v2-unknown-status',
      locator: 'content://v2-unknown-status',
      sizeBytes: 1,
      modifiedAt: DateTime.utc(2026, 9, 14),
      metadata: const {
        'schemaVersion': 2,
        'title': 'Unknown status',
        'transcript': '   ',
        'transcriptionStatus': 'recovering',
      },
    );

    expect(row.transcriptionStatus, 'not_transcribed');
  });

  test('note sidecar with text_note mode and not_applicable status validates',
      () {
    expect(
      () => validateImportedMetadata('note-1', const {
        'schemaVersion': 2,
        'id': 'note-1',
        'title': 'Note 2026-09-17 10-00-00',
        'mode': 'text_note',
        'transcript': 'typed note body',
        'transcriptionStatus': 'not_applicable',
        'durationSeconds': 0,
        'audioSizeBytes': 15,
      }),
      returnsNormally,
    );
  });

  test('sidecar validation still rejects unknown modes and statuses', () {
    Map<String, dynamic> sidecar(Map<String, dynamic> overrides) => {
          'schemaVersion': 2,
          'id': 'bogus-1',
          'title': 'Bogus',
          ...overrides,
        };
    expect(
      () => validateImportedMetadata('bogus-1', sidecar({'mode': 'bogus'})),
      throwsA(isA<StorageFault>()),
    );
    expect(
      () => validateImportedMetadata(
        'bogus-1',
        sidecar({'transcriptionStatus': 'bogus'}),
      ),
      throwsA(isA<StorageFault>()),
    );
  });

  test('sidecar validation rejects incoherent mode/status pairs', () {
    Map<String, dynamic> sidecar(Map<String, dynamic> overrides) => {
          'schemaVersion': 2,
          'id': 'coherence-1',
          'title': 'Coherence',
          ...overrides,
        };
    // Audio mode may not claim the note-only terminal status.
    expect(
      () => validateImportedMetadata(
        'coherence-1',
        sidecar({
          'mode': 'brain_dump',
          'transcriptionStatus': 'not_applicable',
        }),
      ),
      throwsA(isA<StorageFault>()),
    );
    // A note may not claim an audio transcription status.
    expect(
      () => validateImportedMetadata(
        'coherence-1',
        sidecar({'mode': 'text_note', 'transcriptionStatus': 'completed'}),
      ),
      throwsA(isA<StorageFault>()),
    );
    // Coherent pairs stay valid in both directions.
    validateImportedMetadata(
      'coherence-1',
      sidecar({'mode': 'text_note', 'transcriptionStatus': 'not_applicable'}),
    );
    validateImportedMetadata(
      'coherence-1',
      sidecar({'mode': 'meeting', 'transcriptionStatus': 'completed'}),
    );
  });
}
