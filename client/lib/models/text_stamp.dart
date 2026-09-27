// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Live timestamp ranges inside a notebook text block (v1.20.0, spec §C).
// Lives in the model layer so `notebook.dart` carries it without pulling
// the transcript renderer (and its DB row types) into the document model.

/// A live timestamp inside a text block: the `[mm:ss]` characters at
/// [offset]..[offset]+[length] in the block text play [dumpId] from
/// [seconds]. Import-time facts; never edited afterwards.
class TextStamp {
  const TextStamp({
    required this.offset,
    required this.length,
    required this.seconds,
    required this.dumpId,
  });

  /// Character index of the opening `[` in the block text.
  final int offset;

  /// Characters covered, `[` through `]` inclusive.
  final int length;

  /// Seek position in the recording.
  final double seconds;

  /// The recording this stamp plays.
  final String dumpId;

  /// Wire form `{'o','l','s','d'}` — short keys because a long transcript
  /// carries hundreds of these inside one document blob.
  Map<String, dynamic> toJson() => <String, dynamic>{
        'o': offset,
        'l': length,
        's': seconds,
        'd': dumpId,
      };

  /// Strict reader: null for anything mistyped so a garbage entry is
  /// dropped by the block parser rather than rendered as a broken span.
  static TextStamp? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? o = raw['o'];
    final Object? l = raw['l'];
    final Object? s = raw['s'];
    final Object? d = raw['d'];
    if (o is! int || l is! int || s is! num || d is! String) return null;
    if (o < 0 || l <= 0) return null;
    return TextStamp(offset: o, length: l, seconds: s.toDouble(), dumpId: d);
  }

  /// Throwing reader for callers that already validated the shape.
  factory TextStamp.fromJson(Map<String, dynamic> json) {
    final TextStamp? stamp = tryFromJson(json);
    if (stamp == null) {
      throw FormatException('Malformed TextStamp: $json');
    }
    return stamp;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TextStamp &&
          other.offset == offset &&
          other.length == length &&
          other.seconds == seconds &&
          other.dumpId == dumpId;

  @override
  int get hashCode => Object.hash(offset, length, seconds, dumpId);

  @override
  String toString() => 'TextStamp(o=$offset, l=$length, s=$seconds, d=$dumpId)';
}
