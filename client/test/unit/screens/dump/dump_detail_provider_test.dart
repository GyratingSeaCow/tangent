// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import '../../../support/bound_row_fixture.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/models/transcription_status.dart';
import 'package:tangent/screens/dump/dump_detail_screen.dart';
import 'package:tangent/screens/home/home_screen.dart';

void main() {
  test('dump detail provider emits external durable status changes', () async {
    final db = LocalDb.forTesting(NativeDatabase.memory());
    final now = DateTime.utc(2026, 9, 14);
    final binding = await seedFileFixtureRow(
      db,
      DumpRow(
        id: 'watched-provider',
        createdAt: now,
        updatedAt: now,
        mode: 'brain_dump',
        durationSeconds: 4,
        title: 'Watched provider',
        audioPath: '/watched-provider.opus',
        audioSizeBytes: 3,
        syncStatus: 'pending',
        syncAttempts: 0,
        transcriptionStatus: 'not_transcribed',
        transcriptionAttempt: 0,
      ),
    );
    final container = ProviderContainer(
      overrides: [localDbProvider.overrideWithValue(db)],
    );
    final running = Completer<DumpRow>();
    final subscription = container.listen<AsyncValue<DumpRow?>>(
      dumpByIdProvider('watched-provider'),
      (_, next) {
        final row = next.valueOrNull;
        if (row?.transcriptionStatus == 'running' && !running.isCompleted) {
          running.complete(row);
        }
      },
    );

    try {
      final initial =
          await container.read(dumpByIdProvider('watched-provider').future);
      expect(initial!.transcriptionStatus, 'not_transcribed');

      final attempt = await db.beginTranscriptionAttempt(
        'watched-provider',
        storageKey: binding.key,
        requestId: 'request-watched-provider',
        now: now.add(const Duration(seconds: 1)),
      );
      final updated = await db.updateTranscriptionStatus(
        'watched-provider',
        storageKey: binding.key,
        attempt: attempt.transcriptionAttempt,
        requestId: 'request-watched-provider',
        status: TranscriptionStatus.running,
        now: now.add(const Duration(seconds: 2)),
        jobId: 'job-watched-provider',
      );
      expect(updated, isTrue);

      final emitted = await running.future.timeout(const Duration(seconds: 2));
      expect(emitted.transcriptionRequestId, 'request-watched-provider');
      expect(emitted.transcriptionJobId, 'job-watched-provider');
    } finally {
      subscription.close();
      container.dispose();
      await db.close();
    }
  });

  test('detail row provider auto-disposes after its last listener closes',
      () async {
    final db = LocalDb.forTesting(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [localDbProvider.overrideWithValue(db)],
    );
    final provider = dumpByIdProvider('auto-dispose-provider');
    final subscription = container.listen(provider, (_, __) {});

    try {
      await container.read(provider.future);
      expect(container.exists(provider), isTrue);

      subscription.close();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(container.exists(provider), isFalse);
    } finally {
      container.dispose();
      await db.close();
    }
  });
}
