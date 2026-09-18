// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Microphone gain for raw PCM16 capture, and the WAV container that carries
// the amplified samples to disk.
//
// Why this exists: `package:record` offers no numeric gain control. Its only
// related knob is `autoGain: bool`, whose own documentation warns that
// "recording volume may be lowered by using this" -- it is an AGC, not a
// sensitivity control, and it fights quiet sources rather than lifting them.
// Mapping a percentage slider onto that boolean would be a setting that
// stores a preference while the system does something else.
//
// So gain is applied to the samples. The recorder is asked for PCM16 through
// `startStream`, each chunk is multiplied here, and the result is written with
// a WAV header. The server already accepts `.wav` alongside `.opus`.
import 'dart:math' as math;
import 'dart:typed_data';

/// Smallest and largest gain the UI may request.
///
/// Unity is the default and is byte-identical to the previous behaviour. The
/// ceiling is 8x (+18 dB): beyond that, microphone self-noise dominates and
/// the result is louder hiss rather than a more audible voice.
const double minMicGain = 0.5;
const double maxMicGain = 8.0;
const double defaultMicGain = 1.0;

/// PCM16 rails. -32768 is one louder than +32767; clamping must respect both.
const int _pcmMin = -32768;
const int _pcmMax = 32767;

/// Multiplies every 16-bit sample in [bytes] by [gain], saturating at the
/// rails.
///
/// Saturating matters more than the multiplication: a near-maximum sample
/// scaled past 32767 WRAPS to a large negative value under integer
/// arithmetic, which is heard as violent crackling -- far worse than the
/// clipping it would replace.
///
/// A trailing odd byte (a stream chunk that split a sample in half) is passed
/// through untouched. Dropping it would shift every subsequent sample by one
/// byte and turn the rest of the recording into noise.
Uint8List applyGain(Uint8List bytes, double gain) {
  if (gain == 1.0 || bytes.isEmpty) return bytes;

  final Uint8List out = Uint8List(bytes.length);
  final ByteData src = ByteData.sublistView(bytes);
  final ByteData dst = ByteData.sublistView(out);

  final int wholeSamples = bytes.length ~/ 2;
  for (int i = 0; i < wholeSamples; i++) {
    final int offset = i * 2;
    final int scaled = (src.getInt16(offset, Endian.little) * gain).round();
    dst.setInt16(
      offset,
      scaled < _pcmMin
          ? _pcmMin
          : scaled > _pcmMax
              ? _pcmMax
              : scaled,
      Endian.little,
    );
  }

  // Preserve any half sample at the tail.
  if (bytes.length.isOdd) out[bytes.length - 1] = bytes[bytes.length - 1];

  return out;
}

/// Loudest sample in [bytes] as a 0.0-1.0 fraction of full scale.
///
/// Drives the live meter in Settings so the gain can be set against real
/// input instead of guesswork, and so clipping is visible before a recording
/// is made rather than discovered afterwards.
double peakLevel(Uint8List bytes) {
  final ByteData data = ByteData.sublistView(bytes);
  final int wholeSamples = bytes.length ~/ 2;
  int peak = 0;
  for (int i = 0; i < wholeSamples; i++) {
    final int sample = data.getInt16(i * 2, Endian.little).abs();
    if (sample > peak) peak = sample;
  }
  // Divide by 32768: |-32768| is one greater than the positive rail, so this
  // keeps a full-scale negative peak at exactly 1.0 rather than above it.
  return math.min(1.0, peak / 32768.0);
}

/// Canonical 44-byte PCM WAV header for [dataBytes] of payload.
///
/// The stream path yields headerless PCM, so the file needs this prefix or
/// nothing will play it. Both length fields are patched again when the
/// recording stops and the true payload size is known.
Uint8List wavHeader({
  required int sampleRate,
  required int numChannels,
  required int dataBytes,
}) {
  const int bitsPerSample = 16;
  final int byteRate = sampleRate * numChannels * bitsPerSample ~/ 8;
  final int blockAlign = numChannels * bitsPerSample ~/ 8;

  final ByteData header = ByteData(44);
  void ascii(int offset, String tag) {
    for (int i = 0; i < tag.length; i++) {
      header.setUint8(offset + i, tag.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  header.setUint32(4, 36 + dataBytes, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  header.setUint32(16, 16, Endian.little); // PCM fmt chunk size
  header.setUint16(20, 1, Endian.little); // format = PCM
  header.setUint16(22, numChannels, Endian.little);
  header.setUint32(24, sampleRate, Endian.little);
  header.setUint32(28, byteRate, Endian.little);
  header.setUint16(32, blockAlign, Endian.little);
  header.setUint16(34, bitsPerSample, Endian.little);
  ascii(36, 'data');
  header.setUint32(40, dataBytes, Endian.little);

  return header.buffer.asUint8List();
}
