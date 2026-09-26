// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/widgets/waveform_scrubber.dart';

Future<void> _pump(
  WidgetTester tester, {
  required List<double> peaks,
  required ValueNotifier<Duration> position,
  required Duration duration,
  required void Function(Duration) onSeek,
  bool enabled = true,
  VoidCallback? onDisabledTap,
}) =>
    tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 300,
              child: WaveformScrubber(
                peaks: peaks,
                position: position,
                duration: duration,
                onSeek: onSeek,
                enabled: enabled,
                onDisabledTap: onDisabledTap,
              ),
            ),
          ),
        ),
      ),
    );

void main() {
  final peaks = List<double>.generate(600, (i) => (i % 10) / 10);

  testWidgets('tap at 50% seeks to half the duration', (tester) async {
    final seeks = <Duration>[];
    await _pump(
      tester,
      peaks: peaks,
      position: ValueNotifier(Duration.zero),
      duration: const Duration(seconds: 20),
      onSeek: seeks.add,
    );
    final box = tester.getRect(find.byType(WaveformScrubber));
    await tester.tapAt(Offset(box.left + box.width / 2, box.center.dy));
    expect(seeks, [const Duration(seconds: 10)]);
  });

  testWidgets('dragging seeks continuously and clamps at the edges',
      (tester) async {
    final seeks = <Duration>[];
    await _pump(
      tester,
      peaks: peaks,
      position: ValueNotifier(Duration.zero),
      duration: const Duration(seconds: 10),
      onSeek: seeks.add,
    );
    final box = tester.getRect(find.byType(WaveformScrubber));
    final gesture = await tester.startGesture(
      Offset(box.left + box.width * 0.25, box.center.dy),
    );
    await gesture.moveTo(Offset(box.left + box.width * 0.75, box.center.dy));
    await gesture.moveTo(Offset(box.right + 50, box.center.dy));
    await gesture.up();
    expect(seeks.first, const Duration(milliseconds: 2500));
    expect(seeks, contains(const Duration(milliseconds: 7500)));
    expect(seeks.last, const Duration(seconds: 10), reason: 'clamped');
  });

  testWidgets('disabled: no seeks, disabled tap callback fires',
      (tester) async {
    final seeks = <Duration>[];
    var disabledTaps = 0;
    await _pump(
      tester,
      peaks: peaks,
      position: ValueNotifier(Duration.zero),
      duration: const Duration(seconds: 10),
      onSeek: seeks.add,
      enabled: false,
      onDisabledTap: () => disabledTaps++,
    );
    await tester.tap(find.byType(WaveformScrubber));
    expect(seeks, isEmpty);
    expect(disabledTaps, 1);
  });

  testWidgets('empty peaks render a flat strip (no crash, still seekable)',
      (tester) async {
    final seeks = <Duration>[];
    await _pump(
      tester,
      peaks: const [],
      position: ValueNotifier(Duration.zero),
      duration: const Duration(seconds: 4),
      onSeek: seeks.add,
    );
    final box = tester.getRect(find.byType(WaveformScrubber));
    await tester.tapAt(Offset(box.left + box.width / 4, box.center.dy));
    expect(seeks, [const Duration(seconds: 1)]);
  });

  testWidgets('playhead fraction follows the position', (tester) async {
    final position = ValueNotifier(Duration.zero);
    await _pump(
      tester,
      peaks: peaks,
      position: position,
      duration: const Duration(seconds: 10),
      onSeek: (_) {},
    );
    WaveformScrubberState state() =>
        tester.state(find.byType(WaveformScrubber));
    expect(state().playheadFraction, 0.0);
    position.value = const Duration(seconds: 2, milliseconds: 500);
    await tester.pump();
    expect(state().playheadFraction, closeTo(0.25, 1e-9));
    position.value = const Duration(seconds: 99);
    await tester.pump();
    expect(state().playheadFraction, 1.0, reason: 'clamped');
  });
}
