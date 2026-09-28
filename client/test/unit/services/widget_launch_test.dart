// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Contract for the home-screen widget deep link (Jeff, 2026-09-23:
// "click it and go directly into the Notebook you selected").
//
// Two paths, both pinned here:
//   cold start  — takeLaunchNotebook returns the id once, then null
//   warm arrive — an openNotebook call from native lands on the stream

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tangent/services/widget_launch.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel(widgetLaunchChannelName);

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('initialNotebook returns the cold-start id', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      expect(call.method, 'takeLaunchNotebook');
      return 'nb-widget-1';
    });

    final WidgetLaunch launch = WidgetLaunch(channel: channel);
    expect(await launch.initialNotebook(), 'nb-widget-1');
    launch.dispose();
  });

  test('initialNotebook maps null and empty to null (normal launch)',
      () async {
    for (final Object? raw in <Object?>[null, '']) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        channel,
        (MethodCall call) async => raw,
      );
      final WidgetLaunch launch = WidgetLaunch(channel: channel);
      expect(
        await launch.initialNotebook(),
        isNull,
        reason: 'raw=$raw must read as "no widget launch"',
      );
      launch.dispose();
    }
  });

  test('no native channel reads as a normal launch, not an error', () async {
    // Desktop builds and widget tests have no launch channel at all.
    final WidgetLaunch launch = WidgetLaunch(channel: channel);
    expect(await launch.initialNotebook(), isNull);
    launch.dispose();
  });

  test('a warm openNotebook call from native lands on the stream', () async {
    final WidgetLaunch launch = WidgetLaunch(channel: channel);
    final Future<String> first = launch.opens.first;

    // Simulate the native side invoking the Dart handler.
    final ByteData message = const StandardMethodCodec()
        .encodeMethodCall(const MethodCall('openNotebook', 'nb-widget-2'));
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(widgetLaunchChannelName, message, (_) {});

    expect(await first, 'nb-widget-2');
    launch.dispose();
  });

  test('empty warm ids are dropped, not surfaced', () async {
    final WidgetLaunch launch = WidgetLaunch(channel: channel);
    final List<String> seen = <String>[];
    final sub = launch.opens.listen(seen.add);

    for (final String bad in <String>['']) {
      final ByteData message = const StandardMethodCodec()
          .encodeMethodCall(MethodCall('openNotebook', bad));
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(widgetLaunchChannelName, message, (_) {});
    }
    await Future<void>.delayed(Duration.zero);

    expect(seen, isEmpty, reason: 'an empty id must never open an editor');
    await sub.cancel();
    launch.dispose();
  });

  // -----------------------------------------------------------------------
  // Hands-free record spine (spec 2026-09-28): the second payload on the
  // same channel. Cold start: takeLaunchCommand is read-once on the native
  // side; warm: a 'command' call lands on the commands stream.
  // -----------------------------------------------------------------------

  test('takeInitialCommand returns the cold-start record command once',
      () async {
    int calls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      expect(call.method, 'takeLaunchCommand');
      // The native side clears on read; mirror that here.
      return calls++ == 0 ? 'record' : null;
    });

    final WidgetLaunch launch = WidgetLaunch(channel: channel);
    expect(await launch.takeInitialCommand(), 'record');
    expect(
      await launch.takeInitialCommand(),
      isNull,
      reason: 'read-once: a hot restart must not start a second recording',
    );
    expect(calls, 2, reason: 'each take goes to the native side');
    launch.dispose();
  });

  test('takeInitialCommand maps null, empty and unknown to null', () async {
    for (final Object? raw in <Object?>[null, '', 'open-settings']) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        channel,
        (MethodCall call) async => raw,
      );
      final WidgetLaunch launch = WidgetLaunch(channel: channel);
      expect(
        await launch.takeInitialCommand(),
        isNull,
        reason: 'raw=$raw must read as "no launch command"',
      );
      launch.dispose();
    }
  });

  test('no native channel: takeInitialCommand is a normal launch', () async {
    final WidgetLaunch launch = WidgetLaunch(channel: channel);
    expect(await launch.takeInitialCommand(), isNull);
    launch.dispose();
  });

  test('a warm record command from native lands on the commands stream',
      () async {
    final WidgetLaunch launch = WidgetLaunch(channel: channel);
    final Future<String> first = launch.commands.first;

    final ByteData message = const StandardMethodCodec()
        .encodeMethodCall(const MethodCall('command', 'record'));
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(widgetLaunchChannelName, message, (_) {});

    expect(await first, 'record');
    launch.dispose();
  });

  test('unknown warm commands are ignored, and never leak onto opens',
      () async {
    final WidgetLaunch launch = WidgetLaunch(channel: channel);
    final List<String> commands = <String>[];
    final List<String> opens = <String>[];
    final sub1 = launch.commands.listen(commands.add);
    final sub2 = launch.opens.listen(opens.add);

    for (final Object? bad in <Object?>['', 'explode', null]) {
      final ByteData message = const StandardMethodCodec()
          .encodeMethodCall(MethodCall('command', bad));
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(widgetLaunchChannelName, message, (_) {});
    }
    await Future<void>.delayed(Duration.zero);

    expect(commands, isEmpty, reason: 'only "record" is a command');
    expect(opens, isEmpty, reason: 'a command is never a notebook open');
    await sub1.cancel();
    await sub2.cancel();
    launch.dispose();
  });

  test('dismissKeyguard without a native channel is a no-op, not an error',
      () async {
    final WidgetLaunch launch = WidgetLaunch(channel: channel);
    await launch.dismissKeyguard();
    launch.dispose();
  });
}
