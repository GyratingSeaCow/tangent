// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:json_annotation/json_annotation.dart';

/// Brain Dump (default) or Meeting (secretary mode).
enum DumpMode {
  @JsonValue('brain_dump')
  brainDump,
  @JsonValue('meeting')
  meeting;

  /// Wire format used by the Tangent server API.
  String get wireValue => switch (this) {
        DumpMode.brainDump => 'brain_dump',
        DumpMode.meeting => 'meeting',
      };

  static DumpMode fromWire(String value) {
    return values.firstWhere(
      (m) => m.wireValue == value,
      orElse: () => throw ArgumentError('Unknown DumpMode: $value'),
    );
  }
}