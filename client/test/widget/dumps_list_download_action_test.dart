// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The download-audio action on the recordings list.
//
// A synced recording arrives carrying metadata and a transcript but no audio.
// The action that fetches it must appear ONLY on those rows: offering it on a
// recording this device already holds would be a control that does nothing,
// and hiding it on a row that genuinely needs it strands the audio on the
// server with no way to ask for it.
//
// These tests exist because a service with no call sites passes every unit
// test while doing nothing at runtime — the default outcome for work split
// across layers, and the reason the menu wiring gets its own proof.
import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/screens/dump/dumps_providers.dart';
import 'package:tangent/widgets/item_action_sheet.dart';

import '../support/dump_selection_fixture.dart';
import '../support/dump_view_fixture.dart';

/// A recording whose audio is on the server but not on this device.
DumpRow remoteRow(String id) => viewRow(id).copyWith(
      audioPath: '',
      audioSizeBytes: 0,
      syncStatus: 'synced',
      remoteOnly: const Value<bool?>(true),
      audioOnServer: const Value<bool?>(true),
    );

void main() {
  group('dumpNeedsAudioDownload', () {
    test('needs both halves: server has it AND this device does not', () {
      expect(dumpNeedsAudioDownload(remoteRow('a')), isTrue);

      expect(
        dumpNeedsAudioDownload(viewRow('b')),
        isFalse,
        reason: 'a local recording has nothing to fetch',
      );

      expect(
        dumpNeedsAudioDownload(
          viewRow('c').copyWith(audioOnServer: const Value<bool?>(true)),
        ),
        isFalse,
        reason: 'audio already on this device must not offer a download',
      );

      expect(
        dumpNeedsAudioDownload(
          viewRow('d').copyWith(
            audioPath: '',
            remoteOnly: const Value<bool?>(true),
          ),
        ),
        isFalse,
        reason: 'the server has no audio, so there is nothing to fetch',
      );
    });

    test('a row predating the sync columns reads as not downloadable', () {
      // Both columns are nullable: null means "before this feature existed",
      // which must degrade to the old behaviour rather than offering a fetch
      // that would 404.
      expect(dumpNeedsAudioDownload(viewRow('legacy')), isFalse);
    });
  });

  testWidgets('a remote-only recording offers Download audio',
      (WidgetTester tester) async {
    final ProviderContainer container =
        await mountSelection(tester, CountingDeletion());
    container.read(presentedFixture.notifier).state = AsyncData(
      (
        scopeKey: 'all',
        generation: 2,
        settled: true,
        rows: <DumpRow>[remoteRow('fixture-a'), viewRow('fixture-b')],
        limit: null,
      ),
    );
    await pumpSelection(tester);

    await tester.tap(find.byKey(const ValueKey('dump-more-fixture-a')));
    await pumpSelection(tester);

    expect(
      find.byKey(ItemActionSheet.keyFor(ItemAction.download)),
      findsOneWidget,
      reason: 'the server holds audio this device does not',
    );
  });

  testWidgets('a recording that already has its audio offers no download',
      (WidgetTester tester) async {
    await mountSelection(tester, CountingDeletion());

    // fixture-a is an ordinary local recording.
    await tester.tap(find.byKey(const ValueKey('dump-more-fixture-a')));
    await pumpSelection(tester);

    expect(
      find.byKey(ItemActionSheet.keyFor(ItemAction.download)),
      findsNothing,
      reason: 'a control that cannot do anything must not be shown',
    );
    expect(
      find.byKey(ItemActionSheet.keyFor(ItemAction.rename)),
      findsOneWidget,
      reason: 'the rest of the menu is unchanged',
    );
  });

  testWidgets('download does not disturb the existing menu contract',
      (WidgetTester tester) async {
    final ProviderContainer container =
        await mountSelection(tester, CountingDeletion());
    container.read(presentedFixture.notifier).state = AsyncData(
      (
        scopeKey: 'all',
        generation: 2,
        settled: true,
        rows: <DumpRow>[remoteRow('fixture-a'), viewRow('fixture-b')],
        limit: null,
      ),
    );
    await pumpSelection(tester);

    // Long-press must STILL be multi-select, not the sheet. 28 tests encode
    // that contract and the new action must not have touched it.
    await tester.longPress(find.byKey(const ValueKey('dump-row-fixture-a')));
    await pumpSelection(tester);

    expect(
      find.byKey(ItemActionSheet.keyFor(ItemAction.download)),
      findsNothing,
      reason: 'long-press is the bulk-delete entry point, not the menu',
    );
    expect(
      find.byKey(const ValueKey('dump-select-fixture-a')),
      findsOneWidget,
      reason: 'long-press must still enter selection mode',
    );
  });
}
