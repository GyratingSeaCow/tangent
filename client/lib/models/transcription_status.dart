// SPDX-License-Identifier: AGPL-3.0-or-later

/// Durable state of the latest transcription attempt for a dump.
enum TranscriptionStatus {
  notTranscribed('not_transcribed'),
  uploading('uploading'),
  queued('queued'),
  running('running'),
  completed('completed'),
  failed('failed');

  const TranscriptionStatus(this.wireValue);

  final String wireValue;

  bool get isInProgress =>
      this == uploading || this == queued || this == running;

  bool get isTerminal => this == completed || this == failed;

  static TranscriptionStatus fromWire(String value) =>
      values.firstWhere((status) => status.wireValue == value);
}
