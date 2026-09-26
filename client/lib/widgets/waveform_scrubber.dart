// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Waveform strip for Listen mode (spec §3.6). Draws the server-computed
// RMS peaks, a playhead that follows playback, and turns taps/drags into
// seeks. Pure presentation: peaks and position come in, seek targets go
// out. Empty peaks draw a flat baseline so the scrubber still works on
// legacy recordings that were backfilled without them.
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

class WaveformScrubber extends StatefulWidget {
  const WaveformScrubber({
    super.key,
    required this.peaks,
    required this.position,
    required this.duration,
    required this.onSeek,
    this.enabled = true,
    this.onDisabledTap,
    this.height = 56,
  });

  /// 0–1 RMS buckets, any count (600 from the server).
  final List<double> peaks;
  final ValueListenable<Duration> position;

  /// Total length; a zero duration disables seeking.
  final Duration duration;
  final void Function(Duration target) onSeek;

  /// False when audio is not local: the strip still draws, taps go to
  /// [onDisabledTap] (the download affordance) instead of seeking.
  final bool enabled;
  final VoidCallback? onDisabledTap;
  final double height;

  @override
  State<WaveformScrubber> createState() => WaveformScrubberState();
}

class WaveformScrubberState extends State<WaveformScrubber> {
  /// Exposed for tests: 0–1 position of the playhead.
  double get playheadFraction {
    final total = widget.duration.inMilliseconds;
    if (total <= 0) return 0;
    return (widget.position.value.inMilliseconds / total).clamp(0.0, 1.0);
  }

  bool get _seekable => widget.enabled && widget.duration > Duration.zero;

  void _seekToDx(double dx, double width) {
    if (!_seekable || width <= 0) return;
    final fraction = (dx / width).clamp(0.0, 1.0);
    widget.onSeek(
      Duration(
        milliseconds: (widget.duration.inMilliseconds * fraction).round(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          // Seek on the DOWN of the drag recogniser, not a tap recogniser:
          // a tap that turns into a drag is cancelled by the gesture arena,
          // so the initial touch point would otherwise be lost.
          onHorizontalDragDown:
              _seekable ? (d) => _seekToDx(d.localPosition.dx, width) : null,
          onTap: _seekable ? null : widget.onDisabledTap,
          onHorizontalDragUpdate:
              _seekable ? (d) => _seekToDx(d.localPosition.dx, width) : null,
          child: SizedBox(
            height: widget.height,
            width: double.infinity,
            child: ValueListenableBuilder<Duration>(
              valueListenable: widget.position,
              builder: (context, _, __) => CustomPaint(
                painter: _WaveformPainter(
                  peaks: widget.peaks,
                  playhead: playheadFraction,
                  played: scheme.primary,
                  unplayed: widget.enabled
                      ? scheme.primary.withValues(alpha: 0.35)
                      : scheme.outlineVariant,
                  playheadColor: scheme.primary,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _WaveformPainter extends CustomPainter {
  _WaveformPainter({
    required this.peaks,
    required this.playhead,
    required this.played,
    required this.unplayed,
    required this.playheadColor,
  });

  final List<double> peaks;
  final double playhead;
  final Color played;
  final Color unplayed;
  final Color playheadColor;

  @override
  void paint(Canvas canvas, Size size) {
    final mid = size.height / 2;
    final playedPaint = Paint()..color = played;
    final unplayedPaint = Paint()..color = unplayed;
    if (peaks.isEmpty) {
      // Flat baseline: still a scrubber, just no shape to show.
      canvas.drawRect(
        Rect.fromLTWH(0, mid - 1, size.width, 2),
        unplayedPaint,
      );
    } else {
      // One bar per peak when there is room; otherwise bucket peaks into
      // the available pixel columns taking the max, so narrow strips do
      // not alias into noise.
      final columns = size.width.floor().clamp(1, peaks.length);
      final per = peaks.length / columns;
      final barW = size.width / columns;
      for (var c = 0; c < columns; c++) {
        final from = (c * per).floor();
        final to = ((c + 1) * per).ceil().clamp(from + 1, peaks.length);
        var v = 0.0;
        for (var i = from; i < to; i++) {
          if (peaks[i] > v) v = peaks[i];
        }
        final h = (v * (size.height - 4)).clamp(2.0, size.height);
        final x = c * barW;
        final paint = (x + barW / 2) / size.width <= playhead
            ? playedPaint
            : unplayedPaint;
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(x + barW * 0.15, mid - h / 2, barW * 0.7, h),
            const Radius.circular(1),
          ),
          paint,
        );
      }
    }
    final px = playhead * size.width;
    canvas.drawRect(
      Rect.fromLTWH(px - 1, 0, 2, size.height),
      Paint()..color = playheadColor,
    );
  }

  @override
  bool shouldRepaint(_WaveformPainter old) =>
      old.playhead != playhead ||
      !identical(old.peaks, peaks) ||
      old.played != played ||
      old.unplayed != unplayed;
}
