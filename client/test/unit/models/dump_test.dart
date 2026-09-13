// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/models/dump.dart';
import 'package:tangent/models/dump_mode.dart';
import 'package:tangent/models/sync_status.dart';

void main() {
  group('DumpMode', () {
    test('roundtrips through wire format', () {
      for (final mode in DumpMode.values) {
        expect(DumpMode.fromWire(mode.wireValue), mode);
      }
    });
  });

  group('SyncStatus', () {
    test('roundtrips through wire format', () {
      for (final status in SyncStatus.values) {
        expect(SyncStatus.fromWire(status.wireValue), status);
      }
    });

    test('needsUpload is true except for synced and syncing', () {
      expect(SyncStatus.synced.needsUpload, isFalse);
      expect(SyncStatus.syncing.needsUpload, isFalse);
      expect(SyncStatus.pending.needsUpload, isTrue);
      expect(SyncStatus.failed.needsUpload, isTrue);
      expect(SyncStatus.localOnly.needsUpload, isTrue);
    });
  });

  group('Dump', () {
    test('serializes to JSON with snake_case wire format', () {
      final dump = Dump(
        id: 'test-uuid',
        createdAt: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2026, 1, 1),
        mode: DumpMode.brainDump,
        durationSeconds: 60,
        title: 'Test dump',
        audioPath: '/tmp/audio.opus',
        audioSizeBytes: 1000,
        syncStatus: SyncStatus.localOnly,
      );
      final json = dump.toJson();
      expect(json['id'], 'test-uuid');
      expect(json['mode'], 'brain_dump');
      expect(json['sync_status'], 'local_only');
      expect(json['audio_path'], '/tmp/audio.opus');
      expect(json['audio_size_bytes'], 1000);
    });
  });
}