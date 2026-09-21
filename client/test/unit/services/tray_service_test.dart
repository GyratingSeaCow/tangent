// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/services/tray_service.dart';

/// The tray icon's contract: three items — Open App, Start Recording,
/// Exit — and each click dispatches exactly one action. The platform
/// plugin (tray_manager) is behind a seam; these tests drive the logic
/// that decides what the menu contains and what a click does.
void main() {
  test('menu is exactly Open App / Start Recording / Exit, in order', () {
    expect(
      TrayService.menuItems.map((item) => item.label).toList(),
      ['Open App', 'Start Recording', 'Exit'],
    );
  });

  test('clicks dispatch to the right handlers', () async {
    final calls = <String>[];
    final service = TrayService(
      onOpenApp: () async => calls.add('open'),
      onStartRecording: () async => calls.add('record'),
      onExit: () async => calls.add('exit'),
    );

    await service.handleMenuClick(TrayService.openAppKey);
    await service.handleMenuClick(TrayService.startRecordingKey);
    await service.handleMenuClick(TrayService.exitKey);

    expect(calls, ['open', 'record', 'exit']);
  });

  test('a left-click on the icon opens the app', () async {
    final calls = <String>[];
    final service = TrayService(
      onOpenApp: () async => calls.add('open'),
      onStartRecording: () async => calls.add('record'),
      onExit: () async => calls.add('exit'),
    );

    await service.handleIconClick();
    expect(calls, ['open']);
  });

  test('an unknown menu key is ignored, not a crash', () async {
    final service = TrayService(
      onOpenApp: () async {},
      onStartRecording: () async {},
      onExit: () async {},
    );
    await service.handleMenuClick('bogus');
  });
}
