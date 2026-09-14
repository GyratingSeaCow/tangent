// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/screens/recording/waveform_state.dart';

void main() {
  test('normalization clamps dBFS to zero through one', () {
    expect(normalizeDbfs(-80), 0);
    expect(normalizeDbfs(-60), 0);
    expect(normalizeDbfs(-30), closeTo(0.5, 0.0001));
    expect(normalizeDbfs(0), 1);
    expect(normalizeDbfs(6), 1);
  });

  test('new samples enter on right and history remains 72 values', () {
    final notifier = WaveformNotifier();
    for (var index = 0; index < 80; index++) {
      notifier.addNormalized(index / 80);
    }
    expect(notifier.state, hasLength(72));
    expect(notifier.state.last, closeTo(79 / 80, 0.0001));
    expect(notifier.state.first, closeTo(8 / 80, 0.0001));
  });

  test('dBFS insertion applies smoothing and clear restores silence', () {
    final notifier = WaveformNotifier();
    notifier.addDbfs(0);
    expect(notifier.state.last, greaterThan(0));
    expect(notifier.state.last, lessThan(1));
    notifier.clear();
    expect(notifier.state, hasLength(72));
    expect(notifier.state, everyElement(0));
  });
}
