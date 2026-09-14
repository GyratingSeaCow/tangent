// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_riverpod/flutter_riverpod.dart';

const waveformSampleCount = 72;
const waveformSmoothingFactor = 0.35;

double normalizeDbfs(double dbfs) => (dbfs.clamp(-60.0, 0.0) + 60.0) / 60.0;

class WaveformNotifier extends StateNotifier<List<double>> {
  WaveformNotifier() : super(List<double>.filled(waveformSampleCount, 0));

  void addDbfs(double dbfs) {
    final normalized = normalizeDbfs(dbfs);
    final smoothed =
        state.last + (normalized - state.last) * waveformSmoothingFactor;
    _append(smoothed);
  }

  void addNormalized(double sample) => _append(sample.clamp(0.0, 1.0));

  void _append(double sample) {
    state = List<double>.unmodifiable([...state.skip(1), sample]);
  }

  void clear() {
    state = List<double>.filled(waveformSampleCount, 0);
  }
}

final waveformProvider =
    StateNotifierProvider<WaveformNotifier, List<double>>((ref) {
  return WaveformNotifier();
});
