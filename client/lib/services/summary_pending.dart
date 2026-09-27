// SPDX-License-Identifier: AGPL-3.0-or-later
/// "Summary in progress" (v1.18.0): is the server still writing the summary
/// this device asked for?
///
/// Pure functions over the local row so the detail screen, the recordings
/// list, and their tests share ONE rule. The row carries
/// `summary_requested_at` (local-only, stamped on the summarize 202) and
/// `summarized_at` (server-owned, set when the finished summary syncs
/// down). Pending = asked more recently than the last answer, and asked
/// less than [summaryPendingTimeout] ago — the cap is the give-up: with
/// the server offline or the job failed there is no signal, and a strip
/// that spins forever is worse than none.
library;

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../data/local_db.dart';

/// The wall clock behind every pending check on screen. Tests swap it so
/// fake-async pumps move the elapsed counter and can cross the ten-minute
/// cap; production never touches it.
@visibleForTesting
DateTime Function() summaryPendingClock = DateTime.now;

/// Now, as the pending rule sees it. Screens call this rather than
/// [DateTime.now] so the widget tests can drive time.
DateTime summaryPendingNow() => summaryPendingClock();

/// How long a request stays "pending" without an answer before the UI
/// gives up on it. One llama.cpp job takes 30-90 s; ten minutes covers a
/// queue of them and a slow CPU box.
const Duration summaryPendingTimeout = Duration(minutes: 10);

/// True while the server is (as far as this device knows) still writing
/// the summary requested from here.
bool summaryPending(DumpRow row, {required DateTime now}) {
  final int? requestedAt = row.summaryRequestedAt;
  if (requestedAt == null) return false;
  final int? summarizedAt = row.summarizedAt;
  if (summarizedAt != null && summarizedAt >= requestedAt) return false;
  return now.difference(_fromUnix(requestedAt)) < summaryPendingTimeout;
}

/// Wall-clock time since the request was accepted, clamped at zero.
/// [Duration.zero] when nothing was requested.
Duration summaryPendingElapsed(DumpRow row, DateTime now) {
  final int? requestedAt = row.summaryRequestedAt;
  if (requestedAt == null) return Duration.zero;
  final Duration elapsed = now.difference(_fromUnix(requestedAt));
  return elapsed.isNegative ? Duration.zero : elapsed;
}

/// Display name for the template the user picked, without a catalogue
/// fetch: the four server presets are fixed, the custom slot reads
/// 'Custom', and anything else falls back to the id with underscores as
/// spaces and a capital first letter.
String summaryTemplateDisplayName(String? templateId) {
  if (templateId == null || templateId.isEmpty) return 'AI';
  const Map<String, String> presets = <String, String>{
    'meeting': 'Meeting',
    'brain_dump': 'Brain dump',
    'lecture': 'Lecture',
    'actions_only': 'Actions only',
    'custom': 'Custom',
  };
  final String? known = presets[templateId];
  if (known != null) return known;
  final String spaced = templateId.replaceAll('_', ' ');
  return spaced[0].toUpperCase() + spaced.substring(1);
}

DateTime _fromUnix(int seconds) =>
    DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
