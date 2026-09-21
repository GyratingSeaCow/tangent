// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/services/close_to_tray.dart';

/// Desktop close behavior: the X button hides the window to the tray
/// instead of quitting — Discord-style. Quitting belongs to the tray's
/// Exit item alone. The window plumbing is injected so tests drive the
/// decision logic without a real window.
void main() {
  test('a close request hides the window and never quits', () async {
    final calls = <String>[];
    final handler = CloseToTray(
      hideWindow: () async => calls.add('hide'),
      quitApp: () async => calls.add('quit'),
    );

    await handler.onCloseRequested();

    expect(calls, ['hide'], reason: 'X must hide, not kill the app');
  });

  test('an explicit exit quits for real, bypassing close-to-tray', () async {
    final calls = <String>[];
    final handler = CloseToTray(
      hideWindow: () async => calls.add('hide'),
      quitApp: () async => calls.add('quit'),
    );

    await handler.exitForReal();

    expect(
      calls,
      ['quit'],
      reason: 'tray Exit is the one true quit and must not be swallowed',
    );
  });
}
