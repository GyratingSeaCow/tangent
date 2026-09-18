// Guards the work the stop path is allowed to do.
//
// T8: stopping a recording took 10.4s on device. The persistence path proved
// the receipt it had just written by calling listRecordingsAt, which on SAF
// enumerates and parses EVERY recording in the folder — two directory lookups,
// a stat and a metadata read per entry. With 56 recordings that single
// verification cost 4.4s of a 5.9s stop.
//
// These tests drive the REAL RecordingPersistence.save() and count backend
// calls, so a regression that reintroduces a whole-folder scan on the stop
// path fails here rather than on Jeff's phone.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/services/recording_persistence.dart';
import 'package:tangent/services/recording_service.dart';

import '../../support/scripted_storage_backend.dart';
import '../../support/storage_fixture.dart';

void main() {
  /// Runs one real save() and returns the harness so the caller can assert on
  /// what the backend was asked to do.
  Future<CatalogHarness> saveOnce({required bool singleEntryReads}) async {
    final h = CatalogHarness();
    addTearDown(h.close);
    await h.bootstrap();
    h.backend.singleEntryReads = singleEntryReads;
    final r = requireOk(await h.catalog.reserveCapture(mode: 'text_note'));
    final bytes = utf8.encode('stop path budget');
    await File(r.stagingPath).writeAsBytes(bytes, flush: true);
    final lease = requireOk(
      await h.mutations.acquire(
        r.key.dumpId,
        UseKind.capture,
        expectedIncarnation: r.key.incarnation,
      ),
    );
    h.backend.listed.clear();
    try {
      await h.mutations.serialize(
        r.key,
        () => RecordingPersistence(
          db: h.f.db,
          backend: h.backend,
          mutations: h.mutations,
        ).save(
          r,
          RecordingResult(
            path: r.stagingPath,
            durationSeconds: 0,
            sizeBytes: bytes.length,
          ),
          now: DateTime.utc(2030, 1, 2, 3, 4, 5),
          lease: lease,
        ),
      );
    } finally {
      await lease.close();
    }
    return h;
  }

  test(
    'save proves its receipt without enumerating the folder when the backend '
    'can read one entry',
    () async {
      final h = await saveOnce(singleEntryReads: true);

      expect(
        h.backend.singleReadCalls,
        1,
        reason: 'the receipt is proved by reading exactly that one entry',
      );
      expect(
        h.backend.listed,
        isEmpty,
        reason: 'no whole-folder enumeration may happen on the stop path',
      );
    },
  );

  test(
    'save still proves its receipt by listing when the backend cannot read a '
    'single entry',
    () async {
      final h = await saveOnce(singleEntryReads: false);

      expect(
        h.backend.singleReadCalls,
        0,
        reason: 'the fast path must not be used when the backend opts out',
      );
      expect(
        h.backend.listed,
        isNotEmpty,
        reason: 'the listing fallback still proves the receipt',
      );
    },
  );
}
