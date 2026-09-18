// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/theme/tangent_tokens.dart';
import 'package:tangent/widgets/signal_bars.dart';

Future<void> _pump(WidgetTester tester, Widget child) {
  return tester.pumpWidget(
    MaterialApp(home: Scaffold(body: Center(child: child))),
  );
}

/// The framework wraps widgets in its own CustomPaints, so target OURS by
/// finding the CustomPaint that is a descendant of the SignalBars widget.
SignalBarsPainter _painter(WidgetTester tester) {
  final paint = tester.widget<CustomPaint>(
    find.descendant(
      of: find.byType(SignalBars),
      matching: find.byType(CustomPaint),
    ).first,
  );
  return paint.painter! as SignalBarsPainter;
}

void main() {
  group('SignalBars', () {
    testWidgets('renders a deterministic bar profile from a seed', (
      tester,
    ) async {
      await _pump(tester, const SignalBars(seed: 'abc', barCount: 12));
      final first = _painter(tester);

      await _pump(tester, const SignalBars(seed: 'abc', barCount: 12));
      final again = _painter(tester);

      expect(first.amplitudes, hasLength(12));
      expect(
        first.amplitudes,
        again.amplitudes,
        reason: 'the same recording must not shuffle its bars between builds',
      );
    });

    testWidgets('different seeds give different profiles', (tester) async {
      await _pump(tester, const SignalBars(seed: 'one', barCount: 16));
      final a = _painter(tester).amplitudes;

      await _pump(tester, const SignalBars(seed: 'two', barCount: 16));
      final b = _painter(tester).amplitudes;

      expect(a, isNot(b));
    });

    testWidgets('amplitudes stay within the drawable range', (tester) async {
      await _pump(tester, const SignalBars(seed: 'range-check', barCount: 40));
      final painter = _painter(tester);
      for (final a in painter.amplitudes) {
        expect(a, inInclusiveRange(0.12, 1.0));
      }
    });

    testWidgets('idle bars are dimmed and carry no glow', (tester) async {
      await _pump(tester, const SignalBars(seed: 'x'));
      final painter = _painter(tester);
      expect(painter.live, isFalse);
      expect(painter.opacity, lessThan(1.0));
      expect(
        painter.glow,
        isFalse,
        reason: 'a glow on every row costs frame time on a long list',
      );
    });

    testWidgets('the live row is full strength and glows', (tester) async {
      await _pump(tester, const SignalBars(seed: 'x', live: true));
      final painter = _painter(tester);
      expect(painter.live, isTrue);
      expect(painter.opacity, 1.0);
      expect(painter.glow, isTrue);
      expect(painter.color, TangentColors.signal);
    });

    testWidgets('progress splits played from unplayed bars', (tester) async {
      await _pump(
        tester,
        const SignalBars(seed: 'x', barCount: 10, progress: 0.5),
      );
      final painter = _painter(tester);
      expect(painter.progress, 0.5);
      expect(painter.playedBars(10), 5);
    });

    testWidgets('a text note has no audio, so it renders nothing', (
      tester,
    ) async {
      await _pump(tester, const SignalBars(seed: 'x', barCount: 0));
      expect(
        find.descendant(
          of: find.byType(SignalBars),
          matching: find.byType(CustomPaint),
        ),
        findsNothing,
      );
    });

    test('repaints only when something visible changed', () {
      const a = SignalBarsPainter(
        amplitudes: [0.5, 0.6],
        color: TangentColors.signal,
        opacity: 0.55,
        live: false,
        glow: false,
        progress: 0,
      );
      const same = SignalBarsPainter(
        amplitudes: [0.5, 0.6],
        color: TangentColors.signal,
        opacity: 0.55,
        live: false,
        glow: false,
        progress: 0,
      );
      const moved = SignalBarsPainter(
        amplitudes: [0.5, 0.6],
        color: TangentColors.signal,
        opacity: 0.55,
        live: false,
        glow: false,
        progress: 0.4,
      );
      expect(a.shouldRepaint(same), isFalse);
      expect(a.shouldRepaint(moved), isTrue);
    });
  });
}
