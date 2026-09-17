// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:json_annotation/json_annotation.dart';

/// Brain Dump (default), Meeting (secretary mode), or Text Note (typed).
enum DumpMode {
  @JsonValue('brain_dump')
  brainDump,
  @JsonValue('meeting')
  meeting,
  @JsonValue('text_note')
  textNote;

  /// Wire format used by the Tangent server API.
  String get wireValue => switch (this) {
        DumpMode.brainDump => 'brain_dump',
        DumpMode.meeting => 'meeting',
        DumpMode.textNote => 'text_note',
      };

  static DumpMode fromWire(String value) {
    return values.firstWhere(
      (m) => m.wireValue == value,
      orElse: () => throw ArgumentError('Unknown DumpMode: $value'),
    );
  }

  String get displayName => switch (this) {
        DumpMode.brainDump => 'Brain Dump',
        DumpMode.meeting => 'Meeting',
        DumpMode.textNote => 'Text Note',
      };
}