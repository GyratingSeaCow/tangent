// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/audio_gain.dart';
import 'settings_screen.dart';

/// Microphone gain: a real multiplier applied to captured audio.
///
/// package:record exposes no numeric gain control. Its only knob is a boolean
/// `autoGain` AGC whose own documentation warns that recording volume "may be
/// lowered" — an automatic leveller, not a sensitivity setting. Mapping a
/// percentage slider onto that would show the user a control that does
/// something other than what it says, so Tangent multiplies the raw PCM
/// samples instead.
///
/// That has a consequence this section states on screen rather than hiding:
/// samples are only reachable on package:record's PCM stream path, so an
/// amplified recording is written as WAV instead of Opus — roughly 8x the
/// file size. Unity gain keeps the original Opus path untouched, so the cost
/// is paid only by someone who actually asked for more sensitivity.
class MicGainSection extends ConsumerStatefulWidget {
  const MicGainSection({super.key});

  @override
  ConsumerState<MicGainSection> createState() => _MicGainSectionState();
}

class _MicGainSectionState extends ConsumerState<MicGainSection> {
  late double _gain = ref.read(settingsStoreProvider).micGain;

  /// Above this the microphone's own noise floor is amplified along with the
  /// signal and loud passages start to clip, which transcribes worse rather
  /// than better. Warned about, not forbidden: a very quiet source may still
  /// be worth it, and that is the user's call to make.
  static const double _clipWarningThreshold = 4.0;

  Future<void> _set(double value) async {
    setState(() => _gain = value);
    await ref.read(settingsStoreProvider).setMicGain(value);
  }

  String get _label {
    final String value = _gain.toStringAsFixed(1);
    return _gain == defaultMicGain
        ? '$value'
            'x (normal)'
        : '${value}x';
  }

  String get _formatNote {
    if (usesAmplifiedCapture(_gain)) {
      return 'Recordings will be saved as WAV, which is roughly 8x larger '
          'than compressed Opus files. Only new recordings are affected.';
    }
    // Windows has no system Opus encoder, so capture is WAV there even at
    // normal gain — the note must not promise a format the recorder cannot
    // produce.
    return usesPcmCapture(_gain)
        ? 'Recordings are saved as WAV on Windows. Recordings on your other '
            'devices are unaffected.'
        : 'Recordings stay in the usual compressed Opus format.';
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(
          title: const Text('Microphone gain'),
          subtitle: Text(_label),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Slider(
            value: _gain,
            min: minMicGain,
            max: maxMicGain,
            // 0.5x steps: fine enough to tune a quiet source, coarse enough
            // that the value is reproducible by hand.
            divisions: ((maxMicGain - minMicGain) / 0.5).round(),
            label: '${_gain.toStringAsFixed(1)}x',
            onChanged: (double value) => setState(() => _gain = value),
            onChangeEnd: _set,
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Text(
            'Amplifies the recorded audio for quiet sources. This boosts the '
            'captured signal — it does not change the microphone itself.',
            style: theme.textTheme.bodySmall,
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(_formatNote, style: theme.textTheme.bodySmall),
        ),
        if (_gain >= _clipWarningThreshold)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text(
              'High gain can clip loud audio and amplify background hiss, '
              'which usually transcribes worse. Try a lower setting first.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
      ],
    );
  }
}
