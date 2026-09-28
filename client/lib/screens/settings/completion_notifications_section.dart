// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/due_reminder_scheduler.dart'
    show remindersSupportedProvider;
import 'settings_screen.dart';

/// Settings → Reminders → "Notify when transcription and notes finish"
/// (spec 2026-09-28 N6). Default ON. Lives under the Reminders heading and
/// shares its visibility rule: the hosts with a notification port (Android,
/// Linux, Windows) show it; elsewhere it is hidden, not greyed out — a
/// disabled switch would promise a notice the host cannot post.
class CompletionNotificationsSection extends ConsumerStatefulWidget {
  const CompletionNotificationsSection({super.key});

  static const Key enabledKey = Key('completion-notifications-enabled');

  @override
  ConsumerState<CompletionNotificationsSection> createState() =>
      _CompletionNotificationsSectionState();
}

class _CompletionNotificationsSectionState
    extends ConsumerState<CompletionNotificationsSection> {
  late bool _enabled =
      ref.read(settingsStoreProvider).completionNotificationsEnabled;

  Future<void> _toggle(bool on) async {
    setState(() => _enabled = on);
    await ref.read(settingsStoreProvider).setCompletionNotificationsEnabled(on);
  }

  @override
  Widget build(BuildContext context) {
    if (!ref.watch(remindersSupportedProvider)) return const SizedBox.shrink();
    return SwitchListTile(
      key: CompletionNotificationsSection.enabledKey,
      title: const Text('Notify when transcription and notes finish'),
      subtitle: const Text(
        'Shows "Transcribed" and "Notes ready" notices; tap one to open the '
        'recording. Nothing is shown while that recording is already open.',
      ),
      value: _enabled,
      onChanged: _toggle,
    );
  }
}
