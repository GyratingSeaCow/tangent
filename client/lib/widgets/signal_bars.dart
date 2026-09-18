// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/tangent_tokens.dart';

/// The waveform motif, used wherever a recording appears.
///
/// This is the app's signature element: the same bars stand in for a recording
/// in a list row, a notebook card, and a detail header, so audio always looks
/// like audio. It draws a *representative* profile derived from the
/// recording's id — not real sample data — because a list must not decode
/// audio to paint a row.
///
/// Profiles are deterministic: the same id always yields the same shape, so a
/// recording does not appear to change between builds or scroll passes.
class SignalBars extends StatelessWidget {
  const SignalBars({
    super.key,
    required this.seed,
    this.barCount = 24,
    this.height = 16,
    this.live = false,
    this.progress = 0,
    this.color = TangentColors.signal,
  });

  /// Stable identity for this recording — its id works well.
  final String seed;

  /// Number of bars. Zero renders nothing (a text note has no audio).
  final int barCount;

  final double height;

  /// Full strength plus glow. Only ONE element on screen should be live:
  /// a glow per row costs real frame time on a long list.
  final bool live;

  /// 0..1 playback position. Bars before it are drawn at full strength.
  final double progress;

  final Color color;

  @override
  Widget build(BuildContext context) {
    if (barCount <= 0) return const SizedBox.shrink();
    // Bars are a fixed 2px + 1.5px gap, so the widget can size itself. That
    // lets it sit in a Row without Expanded and keeps width finite.
    return SizedBox(
      height: height,
      width: barCount * 3.5,
      child: CustomPaint(
        size: Size.infinite,
        painter: SignalBarsPainter(
          amplitudes: buildProfile(seed, barCount),
          color: color,
          opacity: live ? 1.0 : 0.55,
          live: live,
          glow: live,
          progress: progress,
        ),
      ),
    );
  }

  /// Deterministic pseudo-waveform for [seed].
  ///
  /// A plain hash would produce a spiky mess; speech has runs of loud and
  /// quiet, so neighbouring bars are smoothed toward each other.
  static List<double> buildProfile(String seed, int barCount) {
    var state = 0x811c9dc5;
    for (final unit in seed.codeUnits) {
      state = (state ^ unit) * 0x01000193 & 0x7fffffff;
    }
    final random = math.Random(state);

    final raw = List<double>.generate(barCount, (_) => random.nextDouble());
    return List<double>.generate(barCount, (i) {
      final previous = i == 0 ? raw[i] : raw[i - 1];
      final next = i == barCount - 1 ? raw[i] : raw[i + 1];
      final smoothed = (previous + raw[i] * 2 + next) / 4;
      // Keep a floor so a quiet passage still reads as a bar, not a gap.
      return 0.12 + smoothed * 0.88;
    });
  }
}

class SignalBarsPainter extends CustomPainter {
  const SignalBarsPainter({
    required this.amplitudes,
    required this.color,
    required this.opacity,
    required this.live,
    required this.glow,
    required this.progress,
  });

  final List<double> amplitudes;
  final Color color;
  final double opacity;
  final bool live;
  final bool glow;
  final double progress;

  /// How many bars fall before the playhead.
  int playedBars(int total) => (total * progress.clamp(0.0, 1.0)).round();

  @override
  void paint(Canvas canvas, Size size) {
    // Inside an unbounded parent (a Row without Expanded) width is infinite;
    // flooring that to an int throws. Guard rather than assume a bounded box.
    if (amplitudes.isEmpty || !size.width.isFinite || size.width <= 0) return;

    const barWidth = 2.0;
    const gap = 1.5;
    final slot = barWidth + gap;
    final drawable = math.min(amplitudes.length, (size.width / slot).floor());
    if (drawable <= 0) return;

    final played = playedBars(drawable);
    final paint = Paint()..style = PaintingStyle.fill;

    for (var i = 0; i < drawable; i++) {
      final lit = live || i < played;
      paint
        ..color = color.withValues(alpha: lit ? 1.0 : opacity)
        ..maskFilter = glow
            ? const MaskFilter.blur(BlurStyle.solid, 2.5)
            : null;

      final barHeight = (size.height * amplitudes[i]).clamp(1.0, size.height);
      final left = i * slot;
      final top = size.height - barHeight;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(left, top, barWidth, barHeight),
          const Radius.circular(1),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(SignalBarsPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.live != live ||
        oldDelegate.glow != glow ||
        oldDelegate.opacity != opacity ||
        oldDelegate.color != color ||
        !_sameProfile(oldDelegate.amplitudes, amplitudes);
  }

  bool _sameProfile(List<double> a, List<double> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
