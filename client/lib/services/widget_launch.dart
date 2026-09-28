// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The home-screen widget's half of the deep link. Kotlin catches
// tangent://notebook/<id> VIEW intents (cold start stashes the id, warm
// start pushes it over the channel); this service exposes both sides to
// the app: a one-shot initial id to consume at startup and a stream of
// ids arriving while the app is alive.
//
// Jeff (2026-09-23): "build a desktop widget for opening to a specific
// notebook … click it and go directly into the Notebook you selected
// during the setup process."
//
// Spec 2026-09-28 adds the second payload on the same channel: launch
// COMMANDS ("record", from tangent://record — the 1x1 mic widget, the
// launcher shortcut and the Assistant App Action). Same two shapes:
// [takeInitialCommand] read-once for a cold start, [commands] for warm.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Channel shared with MainActivity.kt — names must match exactly.
const String widgetLaunchChannelName = 'dev.tangent.tangent/launch';

/// The one launch command the app understands: start (or stop) a brain
/// dump. Anything else the native side might send is ignored, never
/// forwarded — a typo in a shortcut must not turn into a mystery action.
const String widgetLaunchRecordCommand = 'record';

class WidgetLaunch {
  WidgetLaunch({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(widgetLaunchChannelName) {
    _channel.setMethodCallHandler(_onCall);
  }

  final MethodChannel _channel;
  final StreamController<String> _opens = StreamController<String>.broadcast();
  final StreamController<String> _commands =
      StreamController<String>.broadcast();

  /// Notebook ids arriving while the app is already running (widget tap
  /// with a warm app). The editor push happens at the listener.
  Stream<String> get opens => _opens.stream;

  /// Launch commands arriving while the app is already running (mic widget
  /// tap, shortcut, Assistant with a warm app). Only known commands land.
  Stream<String> get commands => _commands.stream;

  /// The notebook id the app was cold-started for, or null for a normal
  /// launch. The native side clears it on read: a launch intent must open
  /// its notebook once, not on every hot restart.
  ///
  /// Platforms without the native channel (Linux/Windows desktop, tests)
  /// simply have no widget launches — that is a normal launch, not an
  /// error.
  Future<String?> initialNotebook() async {
    try {
      final String? id =
          await _channel.invokeMethod<String>('takeLaunchNotebook');
      if (id == null || id.isEmpty) return null;
      return id;
    } on MissingPluginException {
      return null;
    }
  }

  /// The launch command the app was cold-started for ('record'), or null
  /// for a normal launch. Read-once on the native side, like
  /// [initialNotebook]: a hot restart must not start a second recording.
  Future<String?> takeInitialCommand() async {
    try {
      final String? command =
          await _channel.invokeMethod<String>('takeLaunchCommand');
      return _known(command);
    } on MissingPluginException {
      return null;
    }
  }

  static String? _known(String? command) =>
      command == widgetLaunchRecordCommand ? command : null;

  /// H3: asks the native side to stop showing over the lock screen and to
  /// prompt for the unlock (KeyguardManager.requestDismissKeyguard). Called
  /// when a recording stops, so review needs the credential while start
  /// and stop did not. No-op when the phone is not locked, and on
  /// platforms without the channel.
  Future<void> dismissKeyguard() async {
    try {
      await _channel.invokeMethod<void>('dismissKeyguard');
    } on MissingPluginException {
      // Desktop / tests: no keyguard to dismiss.
    }
  }

  Future<dynamic> _onCall(MethodCall call) async {
    if (call.method == 'openNotebook') {
      final String? id = call.arguments as String?;
      if (id != null && id.isNotEmpty) _opens.add(id);
    } else if (call.method == 'command') {
      final String? command = _known(call.arguments as String?);
      if (command != null) _commands.add(command);
    }
    return null;
  }

  void dispose() {
    _opens.close();
    _commands.close();
  }
}

final Provider<WidgetLaunch> widgetLaunchProvider = Provider<WidgetLaunch>(
  (ref) {
    final WidgetLaunch launch = WidgetLaunch();
    ref.onDispose(launch.dispose);
    return launch;
  },
);
