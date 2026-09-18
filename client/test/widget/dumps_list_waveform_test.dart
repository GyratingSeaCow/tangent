// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/screens/dump/dumps_providers.dart';
import 'package:tangent/screens/dump/dumps_list_screen.dart';
import 'package:tangent/widgets/signal_bars.dart';

/// Blackout: a recording row carries the waveform motif so audio always looks
/// like audio. A text note has no audio and must not fake one.

DumpRow _row(
  String id,
  String title, {
  String mode = 'brain_dump',
  int duration = 9,
}) =>
    DumpRow(
      id: id,
      createdAt: DateTime.utc(2026, 9, 18),
      updatedAt: DateTime.utc(2026, 9, 18),
      mode: mode,
      durationSeconds: duration,
      title: title,
      transcript: null,
      audioPath: mode == 'text_note'
          ? 'content://tangent/$id.md'
          : 'content://tangent/$id.opus',
      audioSizeBytes: 3,
      syncStatus: 'pending',
      syncAttempts: 0,
      transcriptionStatus:
          mode == 'text_note' ? 'not_applicable' : 'not_transcribed',
      transcriptionAttempt: 0,
    );

Future<void> _mount(WidgetTester tester, List<DumpRow> rows) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        deletionEligibilityProvider.overrideWith(
          (_) => Stream.value(const <String, Eligibility>{}),
        ),
        dumpsProvider.overrideWith((_) => Stream.value(rows)),
      ],
      child: const MaterialApp(home: DumpsListScreen()),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });
}

void main() {
  testWidgets('an audio dump row shows its signal bars', (tester) async {
    await _mount(tester, [_row('a1', 'Standup')]);

    expect(find.byKey(const ValueKey('dump-waveform-a1')), findsOneWidget);
  });

  testWidgets('a text note row shows no waveform', (tester) async {
    await _mount(tester, [_row('n1', 'Idea', mode: 'text_note', duration: 0)]);

    expect(find.byKey(const ValueKey('dump-waveform-n1')), findsNothing);
  });

  testWidgets('each recording keeps its own stable profile', (tester) async {
    await _mount(tester, [_row('a1', 'One'), _row('a2', 'Two')]);

    final first = tester.widget<SignalBars>(
      find.byKey(const ValueKey('dump-waveform-a1')),
    );
    final second = tester.widget<SignalBars>(
      find.byKey(const ValueKey('dump-waveform-a2')),
    );

    expect(first.seed, 'a1');
    expect(second.seed, 'a2');
    expect(
      SignalBars.buildProfile(first.seed, 12),
      isNot(SignalBars.buildProfile(second.seed, 12)),
    );
  });

  testWidgets('idle rows never glow, so a long list stays cheap', (
    tester,
  ) async {
    await _mount(tester, [
      _row('a1', 'One'),
      _row('a2', 'Two'),
      _row('a3', 'Three'),
    ]);

    final bars = tester.widgetList<SignalBars>(find.byType(SignalBars));
    expect(bars, isNotEmpty);
    for (final widget in bars) {
      expect(widget.live, isFalse);
    }
  });
}
