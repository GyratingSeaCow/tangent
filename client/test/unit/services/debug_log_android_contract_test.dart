// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android export uses a private FileProvider with URI read grants', () {
    final String manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    final String paths = File(
      'android/app/src/main/res/xml/debug_log_paths.xml',
    ).readAsStringSync();

    expect(manifest, contains('androidx.core.content.FileProvider'));
    expect(manifest, contains('android:exported="false"'));
    expect(manifest, contains('android:grantUriPermissions="true"'));
    expect(manifest, isNot(contains('MANAGE_EXTERNAL_STORAGE')));
    expect(manifest, isNot(contains('WRITE_EXTERNAL_STORAGE')));
    expect(paths, contains('<cache-path'));
    expect(paths, contains('path="debug_logs/"'));
  });

  test('native channel exposes attachment, mailto, and plain-share methods', () {
    final String activity = File(
      'android/app/src/main/kotlin/dev/tangent/tangent/MainActivity.kt',
    ).readAsStringSync();
    final String intents = File(
      'android/app/src/main/kotlin/dev/tangent/tangent/DebugLogExportIntents.kt',
    ).readAsStringSync();

    for (final String method in <String>[
      'sendAttachedEmail',
      'openMailto',
      'shareFile',
    ]) {
      expect(activity, contains('"$method"'));
    }
    expect(intents, contains('FileProvider.getUriForFile'));
    expect(intents, contains('Intent.EXTRA_STREAM'));
    expect(intents, contains('Intent.EXTRA_EMAIL'));
    expect(intents, contains('Intent.FLAG_GRANT_READ_URI_PERMISSION'));
    expect(intents, isNot(contains('Uri.fromFile')));
  });
}
