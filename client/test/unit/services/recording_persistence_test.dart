// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/services/recording_persistence.dart';
import 'package:tangent/services/recording_service.dart';
import '../../support/storage_fixture.dart';
import '../../support/scripted_storage_backend.dart';

void main() {
  for (final mode in ['brain_dump', 'meeting']) {
    test(
        mode == 'brain_dump'
            ? 'real filesystem save persists audio sidecar and valid DB row'
            : 'meeting recordings are private local-only from creation',
        () async {
      final h = CatalogHarness();
      addTearDown(h.close);
      await h.bootstrap();
      final reservation = requireOk(await h.catalog.reserveCapture(mode: mode));
      final lease = requireOk(
        await h.mutations.acquire(
          reservation.key.dumpId,
          UseKind.capture,
          expectedIncarnation: reservation.key.incarnation,
        ),
      );
      final staging = File(reservation.stagingPath);
      await staging.writeAsBytes([0x4f, 0x67, 0x67, 0x53, 1], flush: true);
      try {
        final row = await RecordingPersistence(
          db: h.f.db,
          backend: h.backend,
          mutations: h.mutations,
        ).save(
          reservation,
          RecordingResult(
            path: staging.path,
            durationSeconds: 3,
            sizeBytes: 5,
          ),
          now: DateTime.utc(2030),
          lease: lease,
        );
        expect(row.title, isNotEmpty);
        expect(row.audioSizeBytes, 5);
        expect(await h.f.audio('A', row.id).readAsBytes(), hasLength(5));
        expect((await h.f.db.getDump(row.id))?.title, row.title);
        final entries = requireOk(
          await settled(h.backend.listRecordingsAt(reservation.location)),
        );
        expect(entries.single.metadata?['title'], row.title);
        expect(row.syncStatus, mode == 'meeting' ? 'local_only' : 'pending');
        expect(entries.single.metadata?['syncStatus'], row.syncStatus);
        expect(await staging.exists(), isFalse);
      } finally {
        await lease.close();
      }
    });
  }
}
