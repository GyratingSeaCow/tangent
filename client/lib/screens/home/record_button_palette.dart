// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';

import '../../theme/tangent_tokens.dart';

/// Colour for the big circular control on the home screen.
///
/// Blackout reserves red for capture and destruction, so the record key is red
/// whether or not capture is running — the icon (mic vs stop) and the running
/// timer say which. Note mode is not a capture, so it takes the signal colour
/// instead.
///
/// Pulled out of the widget so the rule is testable on its own: this is the
/// one place in the app allowed to decide what the record key looks like.
Color recordButtonColor({
  required bool isNoteMode,
  required bool isRecording,
}) {
  if (isNoteMode) return TangentColors.signal;
  return TangentColors.record;
}

/// Icon colour that sits on [recordButtonColor].
Color recordButtonIconColor({required bool isNoteMode}) {
  return isNoteMode ? TangentColors.sunken : TangentColors.text;
}
