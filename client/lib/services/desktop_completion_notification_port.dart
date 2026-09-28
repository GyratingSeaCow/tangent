// SPDX-License-Identifier: AGPL-3.0-or-later
/// The desktop (Linux + Windows) [CompletionNotificationPort] (spec
/// 2026-09-28 N5): one `local_notifier` notification per fixed id through
/// the same [DesktopNotifier] seam the due-date reminder uses, so the port
/// is unit-tested with a fake and never touches the plugin. A click raises
/// the window and opens that recording.
library;

import 'package:flutter/foundation.dart';

import 'completion_notifications.dart';
import 'desktop_due_reminder_port.dart' show DesktopNotifier;

class DesktopCompletionNotificationPort implements CompletionNotificationPort {
  DesktopCompletionNotificationPort({
    required DesktopNotifier Function() newNotifier,
    required void Function(String dumpId) onClick,
  })  : _newNotifier = newNotifier,
        _onClick = onClick;

  /// One backend per fixed id: [DesktopNotifier] tracks a single "last"
  /// notification, and Transcribed must not close Notes ready.
  final DesktopNotifier Function() _newNotifier;
  final Map<int, DesktopNotifier> _byId = <int, DesktopNotifier>{};
  final void Function(String dumpId) _onClick;

  DesktopNotifier _notifierFor(int id) => _byId[id] ??= _newNotifier();

  @override
  Future<void> show(CompletionNotice notice) async {
    try {
      await _notifierFor(notice.notificationId).show(
        title: notice.title,
        body: notice.body,
        onClick: () => _onClick(notice.dumpId),
      );
    } catch (error, stack) {
      _report('show', error, stack);
    }
  }

  @override
  Future<void> cancel(int notificationId) async {
    final DesktopNotifier? notifier = _byId[notificationId];
    if (notifier == null) return;
    try {
      await notifier.closeLast();
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
          'while trying to $operation a desktop completion notification',
        ),
      ),
    );
  }
}
