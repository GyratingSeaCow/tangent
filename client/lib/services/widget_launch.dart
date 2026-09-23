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

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Channel shared with MainActivity.kt — names must match exactly.
const String widgetLaunchChannelName = 'dev.tangent.tangent/launch';

class WidgetLaunch {
  WidgetLaunch({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(widgetLaunchChannelName) {
    _channel.setMethodCallHandler(_onCall);
  }

  final MethodChannel _channel;
  final StreamController<String> _opens = StreamController<String>.broadcast();

  /// Notebook ids arriving while the app is already running (widget tap
  /// with a warm app). The editor push happens at the listener.
  Stream<String> get opens => _opens.stream;

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

  Future<dynamic> _onCall(MethodCall call) async {
    if (call.method == 'openNotebook') {
      final String? id = call.arguments as String?;
      if (id != null && id.isNotEmpty) _opens.add(id);
    }
    return null;
  }

  void dispose() {
    _opens.close();
  }
}

final Provider<WidgetLaunch> widgetLaunchProvider = Provider<WidgetLaunch>(
  (ref) {
    final WidgetLaunch launch = WidgetLaunch();
    ref.onDispose(launch.dispose);
    return launch;
  },
);
