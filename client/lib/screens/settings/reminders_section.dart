// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/due_reminder_scheduler.dart';
import '../../services/morning_review_scheduler.dart';
import '../home/morning_review_screen.dart'
    show morningBriefingProvider, morningReviewEnabledProvider;
import 'completion_notifications_section.dart';
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
  static const Key morningEnabledKey = Key('morning-review-enabled');
  static const Key morningTimeKey = Key('morning-review-time');
  static const Key morningStatusKey = Key('morning-review-status');

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

  // The morning review (queued item 2) mirrors the due reminder's state
  // machine exactly — same permission dance, same status line — but on its
  // own scheduler, alarm and time.
  late bool _morningEnabled =
      ref.read(settingsStoreProvider).morningReviewEnabled;
  late int _morningMinuteOfDay =
      ref.read(settingsStoreProvider).morningReviewMinuteOfDay;
  bool _morningDenied = false;
  DateTime? _morningNextFire;
  bool _morningBusy = false;

  @override
  void initState() {
    super.initState();
    if (ref.read(remindersSupportedProvider)) {
      // Already on from a previous session: show the real next times.
      if (_enabled) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _rearm());
      }
      if (_morningEnabled) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _rearmMorning());
      }
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

  Future<void> _rearmMorning() async {
    final MorningReviewScheduler scheduler =
        ref.read(morningReviewSchedulerProvider);
    final DateTime next =
        await scheduler.scheduleNext(minuteOfDay: _morningMinuteOfDay);
    if (!mounted) return;
    setState(() => _morningNextFire = next);
  }

  Future<void> _toggleMorning(bool on) async {
    if (_morningBusy) return;
    setState(() => _morningBusy = true);
    final MorningReviewScheduler scheduler =
        ref.read(morningReviewSchedulerProvider);
    try {
      if (on) {
        final bool granted = await scheduler.requestPermission();
        if (!mounted) return;
        setState(() {
          _morningEnabled = true;
          _morningDenied = !granted;
        });
        await ref.read(settingsStoreProvider).setMorningReviewEnabled(true);
        ref.read(morningReviewEnabledProvider.notifier).state = true;
        if (granted) await _rearmMorning();
      } else {
        await scheduler.cancel();
        await ref.read(settingsStoreProvider).setMorningReviewEnabled(false);
        ref.read(morningReviewEnabledProvider.notifier).state = false;
        if (!mounted) return;
        setState(() {
          _morningEnabled = false;
          _morningDenied = false;
          _morningNextFire = null;
        });
      }
      // The sun icon and auto-present watch morningReviewEnabledProvider;
      // recompute the briefing now rather than on the next database event.
      ref.invalidate(morningBriefingProvider);
    } finally {
      if (mounted) setState(() => _morningBusy = false);
    }
  }

  Future<void> _pickMorningTime() async {
    final TimeOfDay? picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(
        hour: _morningMinuteOfDay ~/ 60,
        minute: _morningMinuteOfDay % 60,
      ),
      helpText: 'Morning review time',
    );
    if (picked == null || !mounted) return;
    final int minute = picked.hour * 60 + picked.minute;
    setState(() => _morningMinuteOfDay = minute);
    await ref.read(settingsStoreProvider).setMorningReviewMinuteOfDay(minute);
    ref.invalidate(morningBriefingProvider);
    if (_morningEnabled && !_morningDenied) await _rearmMorning();
  }

  String _timeLabel(BuildContext context) =>
      MaterialLocalizations.of(context).formatTimeOfDay(
        TimeOfDay(hour: _minuteOfDay ~/ 60, minute: _minuteOfDay % 60),
      );

  String _morningTimeLabel(BuildContext context) =>
      MaterialLocalizations.of(context).formatTimeOfDay(
        TimeOfDay(
          hour: _morningMinuteOfDay ~/ 60,
          minute: _morningMinuteOfDay % 60,
        ),
      );

  String _morningStatus(BuildContext context) {
    if (!_morningEnabled) return 'Off';
    if (_morningDenied) {
      return 'Notifications blocked — open system settings';
    }
    final DateTime? next = _morningNextFire;
    if (next == null) return 'Next: scheduling…';
    final DateTime now = DateTime.now();
    final bool today =
        next.year == now.year && next.month == now.month && next.day == now.day;
    return 'Next: ${today ? 'today' : 'tomorrow'} '
        '${_morningTimeLabel(context)}';
  }

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
        // Queued item 2: the morning review lives under the same heading —
        // it is the other thing that happens at a chosen time each morning.
        SwitchListTile(
          key: RemindersSection.morningEnabledKey,
          title: const Text('Morning review'),
          subtitle: const Text(
            "A notification and a card on Home with yesterday's captures.",
          ),
          value: _morningEnabled,
          onChanged: _morningBusy ? null : _toggleMorning,
        ),
        ListTile(
          key: RemindersSection.morningTimeKey,
          enabled: _morningEnabled,
          title: const Text('Review time'),
          subtitle: Text(_morningTimeLabel(context)),
          trailing: const Icon(Icons.schedule),
          onTap: _morningEnabled ? _pickMorningTime : null,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            _morningStatus(context),
            key: RemindersSection.morningStatusKey,
            style: theme.textTheme.bodySmall?.copyWith(
              color: _morningDenied ? theme.colorScheme.error : null,
            ),
          ),
        ),
        if (_morningEnabled &&
            _morningDenied &&
            ref.read(morningReviewSchedulerProvider).canOpenSystemSettings)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton(
                onPressed: () => ref
                    .read(morningReviewSchedulerProvider)
                    .openSystemSettings(),
                child: const Text('Open system settings'),
              ),
            ),
          ),
        // Spec 2026-09-28 N6: the completion switch sits under the same
        // heading — it is the other thing the shade says.
        const CompletionNotificationsSection(),
        const Divider(),
      ],
    );
  }
}
