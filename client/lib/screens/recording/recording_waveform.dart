// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'waveform_state.dart';

class RecordingWaveform extends StatelessWidget {
  final List<double> samples;
  final Color color;

  const RecordingWaveform({
    super.key,
    required this.samples,
    required this.color,
  });

  @override
  Widget build(BuildContext context) => Semantics(
        label: 'Live microphone waveform',
        image: true,
        child: RepaintBoundary(
          child: SizedBox(
            height: 72,
            width: double.infinity,
            child: CustomPaint(
              painter: RecordingWaveformPainter(samples: samples, color: color),
            ),
          ),
        ),
      );
}

/// Focused consumer so amplitude changes repaint only the waveform subtree.
class RecordingWaveformConsumer extends ConsumerStatefulWidget {
  final Color color;

  const RecordingWaveformConsumer({super.key, required this.color});

  @override
  ConsumerState<RecordingWaveformConsumer> createState() =>
      _RecordingWaveformConsumerState();
}

class _RecordingWaveformConsumerState
    extends ConsumerState<RecordingWaveformConsumer> {
  late List<double> _displayed;
  List<double>? _pending;
  Timer? _reducedMotionTimer;

  @override
  void initState() {
    super.initState();
    _displayed = ref.read(waveformProvider);
  }

  @override
  void dispose() {
    _reducedMotionTimer?.cancel();
    super.dispose();
  }

  void _accept(List<double> next, bool reducedMotion) {
    if (!reducedMotion) {
      _reducedMotionTimer?.cancel();
      _reducedMotionTimer = null;
      _pending = null;
      if (mounted) setState(() => _displayed = next);
      return;
    }
    _pending = next;
    _reducedMotionTimer ??= Timer(const Duration(milliseconds: 250), () {
      _reducedMotionTimer = null;
      final pending = _pending;
      _pending = null;
      if (mounted && pending != null) setState(() => _displayed = pending);
    });
  }

  @override
  Widget build(BuildContext context) {
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    ref.listen<List<double>>(waveformProvider, (_, next) {
      _accept(next, reducedMotion);
    });
    return RecordingWaveform(samples: _displayed, color: widget.color);
  }
}

class RecordingWaveformPainter extends CustomPainter {
  final List<double> samples;
  final Color color;

  const RecordingWaveformPainter({
    required this.samples,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final centerY = size.height / 2;
    final centerPaint = Paint()
      ..color = color.withValues(alpha: 0.25)
      ..strokeWidth = 1
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
        Offset(0, centerY), Offset(size.width, centerY), centerPaint,);
    if (samples.isEmpty) return;

    final waveformPaint = Paint()
      ..color = color
      ..strokeWidth = math.max(1.5, size.width / samples.length * 0.42)
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true;
    final step = samples.length <= 1 ? 0.0 : size.width / (samples.length - 1);
    final maxHalfHeight = size.height * 0.46;
    for (var index = 0; index < samples.length; index++) {
      final x = index * step;
      final halfHeight = samples[index].clamp(0.0, 1.0) * maxHalfHeight;
      canvas.drawLine(
        Offset(x, centerY - halfHeight),
        Offset(x, centerY + halfHeight),
        waveformPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant RecordingWaveformPainter oldDelegate) =>
      oldDelegate.samples != samples || oldDelegate.color != color;
}
