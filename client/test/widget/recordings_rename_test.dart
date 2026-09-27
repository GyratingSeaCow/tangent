// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/screens/dump/dumps_list_screen.dart';
import 'package:tangent/screens/dump/dumps_providers.dart';
import 'package:tangent/widgets/signal_bars.dart';

/// v1.22.0 R1/M1: the list surface is titled "Recordings" (display strings
/// only — identifiers, SQL, and wire values keep the dump name), and while
/// meeting CAPTURE is gone, EXISTING meeting-mode rows must keep rendering
/// exactly as before (regression pin).

DumpRow _row(
  String id,
  String title, {
  String mode = 'brain_dump',
  int duration = 65,
}) =>
    DumpRow(
      id: id,
      createdAt: DateTime.utc(2026, 9, 17),
      updatedAt: DateTime.utc(2026, 9, 17),
      mode: mode,
      durationSeconds: duration,
      title: title,
      audioPath: 'content://tangent/$id.opus',
      audioSizeBytes: 3,
      syncStatus: 'pending',
      syncAttempts: 0,
      transcriptionStatus: 'not_transcribed',
      transcriptionAttempt: 0,
    );

List<Override> _overrides(List<DumpRow> rows) => [
      deletionEligibilityProvider.overrideWith(
        (_) => Stream.value(const <String, Eligibility>{}),
      ),
      dumpsProvider.overrideWith((_) => Stream.value(rows)),
    ];

Future<void> _mount(WidgetTester tester, List<DumpRow> rows) async {
  tester.view.physicalSize = const Size(1080, 2340);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: _overrides(rows),
      child: const MaterialApp(home: DumpsListScreen()),
    ),
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('list is titled Recordings and search hints Search recordings…',
      (tester) async {
    await _mount(tester, const <DumpRow>[]);

    expect(find.text('Recordings'), findsOneWidget);
    expect(find.text('Dumps'), findsNothing,
        reason: 'R1: every user-visible dump string reads recording now',);

    await tester.tap(find.byIcon(Icons.search));
    await tester.pump();
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.decoration?.hintText, 'Search recordings…');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'regression pin: an EXISTING meeting-mode row still renders its '
      'meeting affordances after capture removal', (tester) async {
    await _mount(tester, [_row('m1', 'Sprint review', mode: 'meeting')]);

    // The row renders as a normal audio recording: title, waveform motif,
    // duration subtitle — nothing about the stored mode changed.
    expect(find.byKey(const ValueKey('dump-row-m1')), findsOneWidget);
    expect(find.text('Sprint review'), findsOneWidget);
    expect(find.byKey(const ValueKey('dump-waveform-m1')), findsOneWidget);
    expect(find.byType(SignalBars), findsOneWidget);
    expect(find.textContaining('1m 5s'), findsOneWidget);

    // The Meeting FILTER survives (viewing existing meeting recordings is
    // untouched); only creation went away.
    await tester.tap(find.byKey(const ValueKey('mode-filter-menu')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('mode-filter-meeting')),
      findsOneWidget,
      reason: 'M1 removes capture, not the ability to see meeting rows',
    );
    await tester.tap(find.byKey(const ValueKey('mode-filter-meeting')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const ValueKey('dump-row-m1')), findsOneWidget,
        reason: 'the meeting filter still lists existing meeting rows',);
    expect(tester.takeException(), isNull);
  });
}
