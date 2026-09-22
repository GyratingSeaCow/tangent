// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';
import 'dart:ui' show Color;

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'transcription_notifications.dart';

/// The real Android notification, behind [TranscriptionNotificationPort].
///
/// Kept deliberately thin: all of the "what should it say, and has it
/// changed?" logic lives in the tested pure layer, because none of that is
/// reachable from a widget test once it is entangled with the plugin.
class AndroidTranscriptionNotificationPort
    implements TranscriptionNotificationPort {
  AndroidTranscriptionNotificationPort({
    FlutterLocalNotificationsPlugin? plugin,
    this.notificationId = transcriptionNotificationId,
    this.channelId = 'transcription_progress',
    this.channelName = 'Transcription progress',
    this.channelDescription = 'Shows when a recording is being transcribed.',
  }) : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;

  /// One fixed id per feature: the shade shows a single notice that is
  /// REPLACED as progress changes, never a stack of them. Defaults keep this
  /// the transcription notification; other long-running server work (the OCR
  /// install) reuses the same plumbing under its own id and channel.
  static const int transcriptionNotificationId = 1001;
  final int notificationId;

  final String channelId;
  final String channelName;
  final String channelDescription;

  /// The brand purple, carried by the notification's accent colour.
  ///
  /// Android masks a status-bar icon to a flat silhouette — every opaque
  /// pixel is repainted one system colour — so the dot's purple cannot
  /// survive in the drawable. This field is the only channel the platform
  /// leaves under the app's control.
  static const Color _accent = Color(0xFF9B2594);

  bool _initialised = false;
  bool _permissionRequested = false;

  /// Android 13+ silently DROPS posts without the runtime permission — no
  /// error, nothing in the shade — so the request is made once, lazily, at
  /// the moment the first notification would appear. Asking at launch would
  /// put the prompt in front of a user with no idea what it is for.
  Future<void> _ensureReady() async {
    if (!_initialised) {
      await _plugin.initialize(
        const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        ),
      );
      _initialised = true;
    }
    if (_permissionRequested) return;
    _permissionRequested = true;
    final AndroidFlutterLocalNotificationsPlugin? android =
        _plugin.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    await android?.requestNotificationsPermission();
  }

  @override
  Future<void> show(TranscriptionNotice notice) async {
    if (!Platform.isAndroid) return;
    try {
      await _ensureReady();
      await _plugin.show(
        notificationId,
        notice.title,
        notice.body,
        NotificationDetails(
          android: AndroidNotificationDetails(
            channelId,
            channelName,
            channelDescription: channelDescription,
            // The waveform mark, not the launcher icon: Android silhouettes
            // status-bar icons, and a full-colour launcher PNG comes out a
            // solid blob.
            icon: '@drawable/ic_notification',
            color: _accent,
            // Progress, not an alert: it belongs in the shade without a sound
            // or a heads-up card interrupting whatever the user is doing.
            importance: Importance.low,
            priority: Priority.low,
            playSound: false,
            enableVibration: false,
            showWhen: false,
            // Dismissible by design. This notification REPORTS work; it does
            // not keep it alive, so pinning it in place would overstate what
            // the app actually guarantees.
            ongoing: false,
            autoCancel: false,
          ),
        ),
      );
    } catch (error, stack) {
      // A failed notification must never take down a transcription that is
      // otherwise working.
      _report('show', error, stack);
    }
  }

  @override
  Future<void> cancel() async {
    if (!Platform.isAndroid) return;
    try {
      await _plugin.cancel(notificationId);
    } catch (error, stack) {
      _report('cancel', error, stack);
    }
  }

  void _report(String operation, Object error, StackTrace stack) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stack,
        library: 'tangent',
        context: ErrorDescription(
          'while trying to $operation the transcription notification',
        ),
      ),
    );
  }
}
