// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart' as launcher;

import '../data/calendar_event_repository.dart';
import '../data/local_db.dart';

/// Live voice-captured calendar events for one dump (autoDispose like
/// [voiceTodosForDumpProvider]).
final voiceEventsForDumpProvider = StreamProvider.autoDispose
    .family<List<CalendarEventRow>, String>((ref, dumpId) {
  return ref
      .watch(calendarEventRepositoryProvider)
      .watchEventsFromSource(dumpId);
});

/// How the card opens a Google Calendar link. Overridden in widget tests;
/// the default is url_launcher in an external app.
typedef OpenExternal = Future<bool> Function(Uri url);

final openExternalProvider = Provider<OpenExternal>(
  (_) => (Uri url) =>
      launcher.launchUrl(url, mode: launcher.LaunchMode.externalApplication),
);

/// "Added to your calendar" — what voice capture put on Google from this
/// recording (v1.35.0). Same conventions as [VoiceTodosCard]: nothing when
/// there are no live rows, gone on its own after Undo.
///
/// Each row is its own tap target: with a Google link it opens the event
/// there (Google owns editing); before the server has pushed it, the row
/// says so and the tap is a no-op. A `needs_date` row says "no date said".
class VoiceEventsCard extends ConsumerWidget {
  const VoiceEventsCard({required this.dumpId, super.key});

  final String dumpId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final List<CalendarEventRow> items =
        ref.watch(voiceEventsForDumpProvider(dumpId)).valueOrNull ??
            const <CalendarEventRow>[];
    if (items.isEmpty) return const SizedBox.shrink();

    final ThemeData theme = Theme.of(context);
    return Column(
      key: ValueKey<String>('voice-events-card-$dumpId'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(
              Icons.event,
              size: 14,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 6),
            Text(
              'Added to your calendar',
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final CalendarEventRow item in items)
                      _EventRow(item: item, ref: ref),
                  ],
                ),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
                  child: TextButton(
                    key: ValueKey<String>('voice-events-undo-$dumpId'),
                    onPressed: () => _undo(context, ref, items.length),
                    child: const Text('Undo'),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  Future<void> _undo(BuildContext context, WidgetRef ref, int count) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    // Soft delete: the server worker removes them from Google on its next
    // tick, and the rows stay as provenance so capture never re-fires.
    await ref
        .read(calendarEventRepositoryProvider)
        .softDeleteFromSource(dumpId);
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          count == 1 ? 'Removed 1 event' : 'Removed $count events',
        ),
      ),
    );
  }
}

class _EventRow extends StatelessWidget {
  const _EventRow({required this.item, required this.ref});

  final CalendarEventRow item;
  final WidgetRef ref;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String? link = item.googleHtmlLink;
    final String when = describeEventWhen(item);
    final TextStyle? muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return InkWell(
      key: ValueKey<String>('voice-event-${item.id}'),
      onTap: link == null
          ? null
          : () => ref.read(openExternalProvider)(Uri.parse(link)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('•  ', style: theme.textTheme.bodyMedium),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(item.title, style: theme.textTheme.bodyMedium),
                  Text(
                    link == null ? '$when · syncing…' : when,
                    style: item.needsDate
                        ? muted?.copyWith(color: theme.colorScheme.error)
                        : muted,
                  ),
                ],
              ),
            ),
            if (link != null)
              Icon(
                Icons.open_in_new,
                size: 16,
                color: theme.colorScheme.onSurfaceVariant,
              ),
          ],
        ),
      ),
    );
  }
}

/// `Thu Oct 1, 2:00 PM`, `Thu Oct 1`, or for a flagged row
/// `today (no date said) — tap to fix`.
String describeEventWhen(CalendarEventRow item) {
  if (item.needsDate) {
    final String time = item.allDay ? '' : ', ${_clock(item.start)}';
    return 'today$time (no date said) — tap to fix';
  }
  final DateTime d = DateTime.parse(item.start);
  final String day =
      '${_weekdays[d.weekday - 1]} ${_months[d.month - 1]} ${d.day}';
  return item.allDay ? day : '$day, ${_clock(item.start)}';
}

String _clock(String iso) {
  final DateTime d = DateTime.parse(iso);
  final int h12 = d.hour % 12 == 0 ? 12 : d.hour % 12;
  final String mm = d.minute.toString().padLeft(2, '0');
  return '$h12:$mm ${d.hour < 12 ? 'AM' : 'PM'}';
}

const List<String> _weekdays = [
  'Mon',
  'Tue',
  'Wed',
  'Thu',
  'Fri',
  'Sat',
  'Sun',
];
const List<String> _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];
