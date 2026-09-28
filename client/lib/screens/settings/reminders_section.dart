// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/due_reminder_scheduler.dart';
import 'settings_screen.dart';

/// Settings → Reminders (spec 2026-09-27 Half B, N4; Half A adds Linux +
/// Windows). Android, Linux and Windows have a port; the whole section is
/// HIDDEN elsewhere, not disabled — a greyed-out switch would promise it.
///
/// Turning the switch on asks for the notification permission right there
/// (the prompt arrives with its reason on screen) and arms the alarm.
/// Refusal is never silent: the status line says the reminder is blocked
/// and offers the system settings.
class RemindersSection extends ConsumerStatefulWidget {
  const RemindersSection({super.key});

  static const Key enabledKey = Key('reminders-enabled');
  static const Key timeKey = Key('reminders-time');
  static const Key statusKey = Key('reminders-status');
  static const Key openSettingsKey = Key('reminders-open-settings');

  @override
  ConsumerState<RemindersSection> createState() => _RemindersSectionState();
}

class _RemindersSectionState extends ConsumerState<RemindersSection> {
  late bool _enabled = ref.read(settingsStoreProvider).remindersEnabled;
  late int _minuteOfDay = ref.read(settingsStoreProvider).reminderMinuteOfDay;
  bool _denied = false;
  bool _exact = true;
  DateTime? _nextFire;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if (_enabled && ref.read(remindersSupportedProvider)) {
      // Already on from a previous session: show the real next time.
      WidgetsBinding.instance.addPostFrameCallback((_) => _rearm());
    }
  }

  Future<void> _rearm() async {
    final DueReminderScheduler scheduler =
        ref.read(dueReminderSchedulerProvider);
    final bool exact = await scheduler.exactAllowed();
    final DateTime next =
        await scheduler.scheduleNext(minuteOfDay: _minuteOfDay);
    if (!mounted) return;
    setState(() {
      _exact = exact;
      _nextFire = next;
    });
  }

  Future<void> _toggle(bool on) async {
    if (_busy) return;
    setState(() => _busy = true);
    final DueReminderScheduler scheduler =
        ref.read(dueReminderSchedulerProvider);
    try {
      if (on) {
        final bool granted = await scheduler.requestPermission();
        if (!mounted) return;
        setState(() {
          _enabled = true;
          _denied = !granted;
        });
        await ref.read(settingsStoreProvider).setRemindersEnabled(true);
        if (granted) await _rearm();
      } else {
        await scheduler.cancel();
        await ref.read(settingsStoreProvider).setRemindersEnabled(false);
        if (!mounted) return;
        setState(() {
          _enabled = false;
          _denied = false;
          _nextFire = null;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickTime() async {
    final TimeOfDay? picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(
        hour: _minuteOfDay ~/ 60,
        minute: _minuteOfDay % 60,
      ),
      helpText: 'Reminder time',
    );
    if (picked == null || !mounted) return;
    final int minute = picked.hour * 60 + picked.minute;
    setState(() => _minuteOfDay = minute);
    await ref.read(settingsStoreProvider).setReminderMinuteOfDay(minute);
    if (_enabled && !_denied) await _rearm();
  }

  String _timeLabel(BuildContext context) => MaterialLocalizations.of(context)
      .formatTimeOfDay(
        TimeOfDay(hour: _minuteOfDay ~/ 60, minute: _minuteOfDay % 60),
      );

  String _status(BuildContext context) {
    if (!_enabled) return 'Off';
    if (_denied) return 'Notifications blocked \u2014 open system settings';
    final DateTime? next = _nextFire;
    final String when;
    if (next == null) {
      when = 'scheduling\u2026';
    } else {
      final DateTime now = DateTime.now();
      final bool today = next.year == now.year &&
          next.month == now.month &&
          next.day == now.day;
      when = '${today ? 'today' : 'tomorrow'} ${_timeLabel(context)}';
    }
    final String timing =
        _exact ? '' : ' \u00B7 exact alarms not allowed, timing may drift';
    return 'Next: $when$timing';
  }

  @override
  Widget build(BuildContext context) {
    if (!ref.watch(remindersSupportedProvider)) return const SizedBox.shrink();
    final ThemeData theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(
            'Reminders',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
        SwitchListTile(
          key: RemindersSection.enabledKey,
          title: const Text('Daily due-date reminder'),
          subtitle: const Text(
            'Shows a system notification each morning listing to-dos due today.',
          ),
          value: _enabled,
          onChanged: _busy ? null : _toggle,
        ),
        ListTile(
          key: RemindersSection.timeKey,
          enabled: _enabled,
          title: const Text('Reminder time'),
          subtitle: Text(_timeLabel(context)),
          trailing: const Icon(Icons.schedule),
          onTap: _enabled ? _pickTime : null,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            _status(context),
            key: RemindersSection.statusKey,
            style: theme.textTheme.bodySmall?.copyWith(
              color: _denied ? theme.colorScheme.error : null,
            ),
          ),
        ),
        if (_enabled &&
            _denied &&
            ref.read(dueReminderSchedulerProvider).canOpenSystemSettings)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton(
                key: RemindersSection.openSettingsKey,
                onPressed: () =>
                    ref.read(dueReminderSchedulerProvider).openSystemSettings(),
                child: const Text('Open system settings'),
              ),
            ),
          ),
        const Divider(),
      ],
    );
  }
}
