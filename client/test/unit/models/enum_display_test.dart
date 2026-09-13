// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/models/dump_mode.dart';
import 'package:tangent/models/sync_status.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DumpMode display', () {
    test('brainDump displayName', () {
      expect(DumpMode.brainDump.displayName, 'Brain Dump');
    });
    test('meeting displayName', () {
      expect(DumpMode.meeting.displayName, 'Meeting');
    });
    test('wire roundtrip', () {
      expect(DumpMode.fromWire('brain_dump'), DumpMode.brainDump);
      expect(DumpMode.fromWire('meeting'), DumpMode.meeting);
      expect(DumpMode.brainDump.wireValue, 'brain_dump');
    });
  });

  group('SyncStatus display', () {
    test('all statuses have display names', () {
      for (final s in SyncStatus.values) {
        expect(s.displayName, isNotEmpty);
      }
    });
    test('wire roundtrip', () {
      for (final s in SyncStatus.values) {
        expect(SyncStatus.fromWire(s.wireValue), s);
      }
    });
    test('needsUpload is false for synced and syncing', () {
      expect(SyncStatus.synced.needsUpload, isFalse);
      expect(SyncStatus.syncing.needsUpload, isFalse);
      expect(SyncStatus.pending.needsUpload, isTrue);
      expect(SyncStatus.failed.needsUpload, isTrue);
      expect(SyncStatus.localOnly.needsUpload, isTrue);
    });
  });
}