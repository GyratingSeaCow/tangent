// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The unpaired-client default URL: the "10.0.2.2 on desktop" bug.
//
// 10.0.2.2 is the ANDROID EMULATOR's alias for the dev machine's loopback.
// On a real desktop it is a routable-nowhere address: a Linux/Windows client
// that has never paired pointed every request at it and sat there timing
// out — the deferred minor from the v1.7.0 E2E arc (next-iteration.md §1.1).
// The default must be platform-aware: emulator alias on Android, real
// loopback (with the documented docker port, 8765) everywhere else.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/services/server_defaults.dart';

void main() {
  test('Android default stays the emulator loopback alias', () {
    expect(
      defaultServerBaseUrl(isAndroidOverride: true),
      'http://10.0.2.2:8000',
    );
  });

  test('desktop default is a real loopback on the documented docker port',
      () {
    expect(
      defaultServerBaseUrl(isAndroidOverride: false),
      'http://localhost:8765',
    );
  });

  test('the host default resolves without an override (this test host is '
      'a desktop)', () {
    // Guards the unparameterized call path actually used by production
    // sites. The suite runs on desktop, so the loopback default applies.
    expect(defaultServerBaseUrl(), 'http://localhost:8765');
  });

  test('no production site hard-codes the emulator alias outside the '
      'helper', () {
    // Regression guard for the actual bug: four call sites each carried
    // their own `url ?? 'http://10.0.2.2:8000'`. Any new literal outside
    // server_defaults.dart reintroduces the desktop black hole.
    final List<String> offenders = <String>[];
    final Directory lib = Directory('lib');
    for (final FileSystemEntity f in lib.listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      final String normalized = f.path.replaceAll('\\', '/');
      if (normalized.endsWith('services/server_defaults.dart')) continue;
      if (f.readAsStringSync().contains('10.0.2.2')) {
        offenders.add(normalized);
      }
    }
    expect(
      offenders,
      isEmpty,
      reason: 'hard-coded emulator alias outside server_defaults.dart: '
          '$offenders',
    );
  });
}
