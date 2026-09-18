// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Microphone gain applied to raw PCM, and the WAV container that carries it.
//
// `package:record` exposes no numeric gain -- only a boolean `autoGain` whose
// own documentation warns it may LOWER the level. A percentage slider mapped
// onto that boolean would be a control that lies, so the gain is applied to
// the samples themselves.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/services/audio_gain.dart';

/// Builds a little-endian PCM16 buffer from signed sample values.
Uint8List pcm(List<int> samples) {
  final ByteData data = ByteData(samples.length * 2);
  for (int i = 0; i < samples.length; i++) {
    data.setInt16(i * 2, samples[i], Endian.little);
  }
  return data.buffer.asUint8List();
}

/// Reads a little-endian PCM16 buffer back into signed sample values.
List<int> samplesOf(Uint8List bytes) {
  final ByteData data = ByteData.sublistView(bytes);
  return <int>[
    for (int i = 0; i + 1 < bytes.length; i += 2)
      data.getInt16(i, Endian.little),
  ];
}

void main() {
  group('applyGain', () {
    test('gain of 1.0 returns the samples untouched', () {
      final Uint8List input = pcm(<int>[0, 1000, -1000, 32767, -32768]);

      final Uint8List out = applyGain(input, 1.0);

      expect(
        out,
        orderedEquals(input),
        reason: 'unity gain must be byte-identical, so the default path can '
            'never degrade audio',
      );
    });

    test('gain of 2.0 doubles each sample', () {
      final Uint8List out = applyGain(pcm(<int>[100, -250, 0]), 2.0);

      expect(samplesOf(out), <int>[200, -500, 0]);
    });

    test('gain of 0.5 halves each sample', () {
      final Uint8List out = applyGain(pcm(<int>[100, -250]), 0.5);

      expect(samplesOf(out), <int>[50, -125]);
    });

    test('a loud sample SATURATES instead of wrapping', () {
      // The single most important property here. Integer overflow wraps a
      // near-maximum positive sample to a large NEGATIVE one, which is heard
      // as violent crackling -- far worse than the clipping it replaces.
      final Uint8List out = applyGain(pcm(<int>[20000, -20000]), 4.0);

      expect(
        samplesOf(out),
        <int>[32767, -32768],
        reason: 'amplified peaks must clamp to the rail, never wrap sign',
      );
    });

    test('every sample of a loud buffer stays in range', () {
      final Uint8List out = applyGain(
        pcm(<int>[30000, -30000, 32767, -32768, 1, -1]),
        8.0,
      );

      for (final int s in samplesOf(out)) {
        expect(s, inInclusiveRange(-32768, 32767));
      }
    });

    test('a trailing odd byte is preserved rather than corrupting the frame',
        () {
      // A stream chunk can split a 2-byte sample. Dropping the stray byte
      // shifts every following sample by one and turns the rest of the
      // recording into noise.
      final Uint8List input = Uint8List.fromList(<int>[...pcm(<int>[100]), 7]);

      final Uint8List out = applyGain(input, 2.0);

      expect(out.length, input.length, reason: 'no byte may be lost');
      expect(out.last, 7, reason: 'the partial sample is passed through');
      expect(samplesOf(out).first, 200);
    });

    test('an empty buffer is handled', () {
      expect(applyGain(Uint8List(0), 4.0), isEmpty);
    });
  });

  group('peakLevel', () {
    test('silence reads zero', () {
      expect(peakLevel(pcm(<int>[0, 0, 0])), 0.0);
    });

    test('a full-scale sample reads 1.0', () {
      expect(peakLevel(pcm(<int>[32767])), closeTo(1.0, 0.001));
    });

    test('a negative peak counts too', () {
      // Asymmetric clipping is real: -32768 is louder than +32767.
      expect(peakLevel(pcm(<int>[-32768, 100])), closeTo(1.0, 0.001));
    });

    test('half scale reads about 0.5', () {
      expect(peakLevel(pcm(<int>[16384])), closeTo(0.5, 0.01));
    });
  });

  group('wavHeader', () {
    test('declares RIFF/WAVE with the PCM format', () {
      final Uint8List header = wavHeader(
        sampleRate: 16000,
        numChannels: 1,
        dataBytes: 32000,
      );

      expect(header.length, 44, reason: 'canonical PCM WAV header size');
      expect(String.fromCharCodes(header.sublist(0, 4)), 'RIFF');
      expect(String.fromCharCodes(header.sublist(8, 12)), 'WAVE');
      expect(String.fromCharCodes(header.sublist(36, 40)), 'data');
    });

    test('carries the real sample rate and byte rate', () {
      final ByteData h = ByteData.sublistView(
        wavHeader(sampleRate: 16000, numChannels: 1, dataBytes: 32000),
      );

      expect(h.getUint16(22, Endian.little), 1, reason: 'mono');
      expect(h.getUint32(24, Endian.little), 16000, reason: 'sample rate');
      expect(
        h.getUint32(28, Endian.little),
        32000,
        reason: 'byte rate = rate * channels * 2; a wrong value plays at the '
            'wrong speed',
      );
      expect(h.getUint16(34, Endian.little), 16, reason: 'bits per sample');
    });

    test('sizes both length fields from the payload', () {
      final ByteData h = ByteData.sublistView(
        wavHeader(sampleRate: 16000, numChannels: 1, dataBytes: 32000),
      );

      expect(
        h.getUint32(4, Endian.little),
        36 + 32000,
        reason: 'RIFF size covers everything after the first 8 bytes',
      );
      expect(h.getUint32(40, Endian.little), 32000, reason: 'data chunk size');
    });
  });
}
