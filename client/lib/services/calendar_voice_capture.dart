// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert' show utf8;

import 'package:crypto/crypto.dart' show sha1;

import '../data/calendar_event_repository.dart';
import '../data/local_db.dart';
import '../models/dump_mode.dart';
import 'calendar_voice_parser.dart';

/// Auto-creates calendar events spoken into a recording (v1.35.0).
///
/// Sits at the SAME three transcript sinks as [captureVoiceTodos] and owns
/// the same idempotency rule, keyed by (dumpId, fingerprint of the parsed
/// RESULT): rows for the dump — live OR soft-deleted — carrying this
/// fingerprint mean this exact capture already happened. A different
/// fingerprint is a re-transcription: events whose (title, start) has no
/// row are added; live rows are left alone (Google may have edited them);
/// soft-deleted rows are never re-created, so Undo is permanent.
///
/// [recordedOn] is the dump's `created_at` (the day the words were said);
/// [mode] drives the no-date rule (C3). Spec:
/// docs/design/2026-09-28-voice-calendar-events.md.
Future<List<CalendarEventRow>> captureVoiceEvents({
  required LocalDb db,
  required String dumpId,
  required String? transcript,
  required DateTime recordedOn,
  required DumpMode mode,
  required String timeZone,
  CalendarEventRepository? repository,
}) async {
  final CalendarEventRepository repo =
      repository ?? CalendarEventRepository(db: db);
  final List<VoiceCalendarEvent> parsed = CalendarVoiceParser.parse(
    transcript,
    recordedOn: recordedOn.toLocal(),
    mode: mode,
    timeZone: timeZone,
  );
  final List<CalendarEventRow> existing = await repo.eventsFromSource(dumpId);
  if (parsed.isEmpty) return const <CalendarEventRow>[];
  final String fingerprint = eventCaptureFingerprintOf(parsed);
  if (existing
      .any((CalendarEventRow r) => r.captureFingerprint == fingerprint)) {
    return const <CalendarEventRow>[];
  }
  final List<CalendarEventRow> created = <CalendarEventRow>[];
  for (final VoiceCalendarEvent e in parsed) {
    final bool known = existing.any(
      (CalendarEventRow r) => r.title == e.title && r.start == e.start,
    );
    if (known) continue; // live: Google's copy wins; deleted: stays deleted
    created.add(
      await repo.add(
        title: e.title,
        start: e.start,
        end: e.end,
        allDay: e.allDay,
        timeZone: e.timeZone,
        needsDate: e.needsDate,
        sourceRef: dumpId,
        captureFingerprint: fingerprint,
      ),
    );
  }
  await repo.setCaptureFingerprint(dumpId, fingerprint);
  return created;
}

/// SHA-1 hex over `title|start|end` per event — the parsed RESULT, not the
/// raw transcript, so a re-transcription yielding the same events is the
/// same capture.
String eventCaptureFingerprintOf(Iterable<VoiceCalendarEvent> events) {
  final String joined = events
      .map((VoiceCalendarEvent e) => '${e.title}|${e.start}|${e.end}')
      .join('\n');
  return sha1.convert(utf8.encode(joined)).toString();
}

/// Calls [captureVoiceEvents] and swallows any failure — same reasoning as
/// [captureVoiceTodosQuietly]: a calendar bug must never cost the user the
/// transcript that just finished. Skips the parse (and the platform zone
/// lookup) entirely when the transcript has no trigger.
Future<void> captureVoiceEventsQuietly({
  required LocalDb db,
  required String dumpId,
  required String? transcript,
  required DateTime recordedOn,
  required String mode,
}) async {
  try {
    if (!CalendarVoiceParser.hasTrigger(transcript)) return;
    await captureVoiceEvents(
      db: db,
      dumpId: dumpId,
      transcript: transcript,
      recordedOn: recordedOn,
      mode: DumpMode.fromWire(mode),
      timeZone: await CalendarVoiceParser.deviceTimeZone(),
    );
  } catch (_) {
    // Deliberately ignored; see above.
  }
}
