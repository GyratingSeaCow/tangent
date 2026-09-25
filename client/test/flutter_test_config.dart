// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Runs around EVERY test in this suite (flutter_test's per-directory
// config hook).
//
// The capture-format decision branches on the HOST platform
// (`Platform.isWindows` — no system Opus encoder there, so capture stages
// WAV). Left unpinned, the same test would assert different staging
// extensions depending on which OS runs it, and the suite's Windows bench
// runs would diverge from CI's ubuntu runs. Tests therefore run with the
// non-Windows default; the Windows branch is exercised explicitly by
// windows_capture_format_test.dart via the same override.
import 'dart:async';

import 'package:tangent/services/audio_gain.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  debugIsWindowsCaptureOverride = false;
  await testMain();
}
