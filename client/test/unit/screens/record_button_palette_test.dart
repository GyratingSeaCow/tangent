// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/screens/home/record_button_palette.dart';
import 'package:tangent/theme/tangent_tokens.dart';

/// Blackout reserves red for capture and destruction. The record key is the
/// app's one red control, so it must be red whether or not capture is running
/// — the icon and the timer say which. Spotted on the device: an idle record
/// button painted lime, which made lime mean both "live/selected" and
/// "record".
void main() {
  test('the record key is red when idle', () {
    expect(
      recordButtonColor(isNoteMode: false, isRecording: false),
      TangentColors.record,
    );
  });

  test('the record key stays red while capturing', () {
    expect(
      recordButtonColor(isNoteMode: false, isRecording: true),
      TangentColors.record,
    );
  });

  test('the record key is never the signal colour', () {
    for (final recording in const [true, false]) {
      expect(
        recordButtonColor(isNoteMode: false, isRecording: recording),
        isNot(TangentColors.signal),
        reason: 'red must mean capture, and only capture',
      );
    }
  });

  test('note mode writes rather than records, so it takes the signal', () {
    expect(
      recordButtonColor(isNoteMode: true, isRecording: false),
      TangentColors.signal,
    );
  });
}
