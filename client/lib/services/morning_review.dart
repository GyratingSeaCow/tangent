// SPDX-License-Identifier: AGPL-3.0-or-later
/// The morning review as plain data (Ask-arc queued item 2, spec
/// 2026-09-30): at the chosen time, a notification AND a light-blue card
/// at the top of Home that stays until viewed, then tucks away. Contents
/// v1 are YESTERDAY'S captures only — recordings and notes, one line each.
///
/// Pure and unit-tested like `due_digest.dart`: everything that decides
/// WHAT the review shows and WHEN the card is visible lives here, because
/// none of it is reachable once entangled with the notification plugin or
/// the widget tree. The platform layer posts what this returns — and posts
/// NOTHING when it returns null. Zero captures yesterday means zero noise:
/// no notification, no empty-shell card.
library;

import '../data/local_db.dart';
import 'due_digest.dart';

/// How many capture titles the NOTIFICATION body spells out before
/// "and N more" (the card itself lists every item).
const int kMorningReviewNamedItems = 3;

/// The review that belongs to the morning of [reviewDay]: what the card
/// shows and what the notification says. [items] are yesterday's captures
/// relative to that morning, oldest first — the order the day happened.
class MorningReview {
  const MorningReview({
    required this.reviewDay,
    required this.capturesDay,
    required this.items,
  });

  /// The local date whose morning this review belongs to (date-only).
  final DateTime reviewDay;

  /// The local date the items were captured on: the day before [reviewDay].
  final DateTime capturesDay;

  /// Yesterday's captures, oldest first. Never empty — no captures means
  /// no review at all (see [buildMorningReview]).
  final List<DumpRow> items;

  int get recordingCount =>
      items.where((DumpRow d) => d.mode != 'text_note').length;

  int get noteCount => items.length - recordingCount;
}

/// The morning whose review applies at [now]: today once the chosen time
/// has passed, otherwise still yesterday's — an unviewed card from
/// yesterday morning keeps standing (spec: "stays until viewed") rather
/// than vanishing at midnight and reappearing at the next fire.
DateTime morningReviewDayFor(DateTime now, int minuteOfDay) {
  final int nowMinute = now.hour * 60 + now.minute;
  return nowMinute >= minuteOfDay
      ? DateTime(now.year, now.month, now.day)
      : DateTime(now.year, now.month, now.day - 1);
}

/// Builds the review for the morning of [reviewDay] (any time component is
/// ignored), or null when the day before it produced no captures — the
/// caller must then show nothing at all. Captures are compared on LOCAL
/// calendar days, so "yesterday" means the user's yesterday, not UTC's.
MorningReview? buildMorningReview(List<DumpRow> dumps, DateTime reviewDay) {
  final DateTime day = DateTime(reviewDay.year, reviewDay.month, reviewDay.day);
  final DateTime capturesDay = DateTime(day.year, day.month, day.day - 1);
  final List<DumpRow> items = dumps
      .where((DumpRow d) => _sameLocalDay(d.createdAt.toLocal(), capturesDay))
      .toList()
    ..sort((DumpRow a, DumpRow b) => a.createdAt.compareTo(b.createdAt));
  if (items.isEmpty) return null;
  return MorningReview(reviewDay: day, capturesDay: capturesDay, items: items);
}

bool _sameLocalDay(DateTime at, DateTime day) =>
    at.year == day.year && at.month == day.month && at.day == day.day;

/// Whether the Home card stands right now. True only while the feature is
/// on, the day before the current review morning produced captures, and
/// that morning has not been viewed yet ([viewedDay] is the `YYYY-MM-DD`
/// last recorded by the card's own tuck action; '' when never).
bool morningReviewCardVisible({
  required bool enabled,
  required String viewedDay,
  required MorningReview? review,
}) {
  if (!enabled || review == null) return false;
  return viewedDay != isoDate(review.reviewDay);
}

/// What a pinned row is, so the briefing can pick its icon and route.
enum MorningPinKind { recording, note, notebook, todo }

/// One pinned item on the briefing, already reduced to what renders.
class MorningPin {
  const MorningPin({
    required this.kind,
    required this.id,
    required this.title,
  });

  final MorningPinKind kind;
  final String id;
  final String title;
}

/// Everything the full-screen morning review shows, decided here so the
/// screen only renders. Sections are independent: any may be empty, and
/// the screen hides an empty one rather than drawing a hollow heading.
class MorningBriefing {
  const MorningBriefing({
    required this.reviewDay,
    required this.review,
    required this.dueToday,
    required this.overdue,
    required this.pinned,
  });

  /// The morning this briefing belongs to (date-only); the viewed-day key.
  final DateTime reviewDay;

  /// Yesterday's captures, or null when yesterday captured nothing.
  final MorningReview? review;

  /// Live to-dos due on the actual current day, then overdue ones.
  final List<TodoRow> dueToday;
  final List<TodoRow> overdue;

  /// Pinned recordings/notes, notebooks and to-dos, in that order.
  final List<MorningPin> pinned;

  List<DumpRow> get captures => review?.items ?? const <DumpRow>[];

  bool get isEmpty =>
      captures.isEmpty && dueToday.isEmpty && overdue.isEmpty && pinned.isEmpty;
}

/// Builds the briefing at [now]. [notebooks] are list headers (id, title,
/// pinned); a full document is never needed to render one line.
MorningBriefing buildMorningBriefing({
  required DateTime now,
  required int minuteOfDay,
  required List<DumpRow> dumps,
  required List<TodoRow> todos,
  required List<({String id, String title, bool pinned})> notebooks,
}) {
  final DateTime reviewDay = morningReviewDayFor(now, minuteOfDay);
  final DueBuckets due = dueBuckets(todos, now);
  int byTitle(MorningPin a, MorningPin b) =>
      a.title.toLowerCase().compareTo(b.title.toLowerCase());
  final List<MorningPin> pinnedDumps = <MorningPin>[
    for (final DumpRow d in dumps)
      if (d.pinned == true)
        MorningPin(
          kind: d.mode == 'text_note'
              ? MorningPinKind.note
              : MorningPinKind.recording,
          id: d.id,
          title: morningReviewLine(d),
        ),
  ]..sort(byTitle);
  final List<MorningPin> pinnedNotebooks = <MorningPin>[
    for (final n in notebooks)
      if (n.pinned)
        MorningPin(kind: MorningPinKind.notebook, id: n.id, title: n.title),
  ]..sort(byTitle);
  final List<MorningPin> pinnedTodos = <MorningPin>[
    for (final TodoRow t in todos)
      if (t.pinned == true && t.doneAt == null && t.deletedAt == null)
        MorningPin(kind: MorningPinKind.todo, id: t.id, title: t.body.trim()),
  ]..sort(byTitle);
  return MorningBriefing(
    reviewDay: reviewDay,
    review: buildMorningReview(dumps, reviewDay),
    dueToday: due.dueToday,
    overdue: due.overdue,
    pinned: <MorningPin>[...pinnedDumps, ...pinnedNotebooks, ...pinnedTodos],
  );
}

/// Whether the full screen presents itself over Home right now: with the
/// feature on, once per review morning. An empty briefing still presents
/// (its calm empty state) — the contract is "first open of the day".
bool morningReviewShouldAutoPresent({
  required bool enabled,
  required String viewedDay,
  required MorningBriefing briefing,
}) {
  if (!enabled) return false;
  return viewedDay != isoDate(briefing.reviewDay);
}

/// Sun icon in the Home app bar: present all day exactly while enabled.
bool morningReviewSunVisible({required bool enabled}) => enabled;

/// The one-line summary of a capture: its existing title, which every dump
/// carries (v1 deliberately adds no new summarisation).
String morningReviewLine(DumpRow dump) => dump.title.trim();

/// "Yesterday" while the review is current; the actual day once an
/// unviewed card has stood past its own morning, because by then
/// "yesterday" would be a lie about two-day-old captures.
String morningReviewDayLabel(MorningReview review, DateTime today) {
  final DateTime t = DateTime(today.year, today.month, today.day);
  if (_sameLocalDay(review.capturesDay, DateTime(t.year, t.month, t.day - 1))) {
    return 'Yesterday';
  }
  const List<String> weekdays = <String>[
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
    'Sunday',
  ];
  const List<String> months = <String>[
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
  final DateTime d = review.capturesDay;
  return '${weekdays[d.weekday - 1]}, ${months[d.month - 1]} ${d.day}';
}

/// "2 recordings · 1 note" — the card's count line.
String morningReviewCountLine(MorningReview review) {
  final List<String> parts = <String>[
    if (review.recordingCount > 0)
      '${review.recordingCount} '
          'recording${review.recordingCount == 1 ? '' : 's'}',
    if (review.noteCount > 0)
      '${review.noteCount} note${review.noteCount == 1 ? '' : 's'}',
  ];
  return parts.join(' \u00B7 ');
}

/// The notification text for [review], shaped as a [DueDigest] because the
/// reminder ports post exactly that: a title, a body and nothing else. The
/// counts ride along for tests; nothing overdue exists here, so
/// `overdueCount` is always zero.
DueDigest morningReviewNotification(MorningReview review) {
  final List<String> names = review.items.map(morningReviewLine).toList();
  final String listed = names.length <= kMorningReviewNamedItems
      ? names.join(', ')
      : '${names.take(kMorningReviewNamedItems).join(', ')} '
          'and ${names.length - kMorningReviewNamedItems} more';
  return DueDigest(
    title: 'Morning review',
    body: 'Yesterday: $listed',
    dueTodayCount: review.items.length,
    overdueCount: 0,
  );
}
