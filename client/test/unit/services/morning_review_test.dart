// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/settings_store.dart';
import 'package:tangent/services/morning_review.dart';

/// Ask-arc queued item 2, the pure layer: which morning a moment belongs
/// to, which captures count as "yesterday's", what the card and the
/// notification say, and when the card stands.
void main() {
  DumpRow dump(
    String id, {
    required DateTime createdAt,
    String mode = 'brain_dump',
    String? title,
  }) =>
      DumpRow(
        id: id,
        createdAt: createdAt,
        updatedAt: createdAt,
        mode: mode,
        durationSeconds: 30,
        title: title ?? id,
        audioPath: mode == 'text_note' ? '' : '/synthetic/$id.opus',
        audioSizeBytes: 1024,
        syncStatus: 'local_only',
        syncAttempts: 0,
        transcriptionStatus: 'not_transcribed',
        transcriptionAttempt: 0,
      );

  const int eight = 8 * 60;

  group('morningReviewDayFor', () {
    test('07:59 still belongs to yesterday morning', () {
      expect(
        morningReviewDayFor(DateTime(2026, 9, 30, 7, 59), eight),
        DateTime(2026, 9, 29),
      );
    });

    test('exactly 08:00 starts today morning', () {
      expect(
        morningReviewDayFor(DateTime(2026, 9, 30, 8), eight),
        DateTime(2026, 9, 30),
      );
    });

    test('rolls over a month start', () {
      expect(
        morningReviewDayFor(DateTime(2026, 10, 1, 6), eight),
        DateTime(2026, 9, 30),
      );
    });
  });

  group('buildMorningReview', () {
    final DateTime reviewDay = DateTime(2026, 9, 30);

    test("keeps yesterday's captures only, oldest first", () {
      final MorningReview? review = buildMorningReview(
        <DumpRow>[
          dump('today', createdAt: DateTime(2026, 9, 30, 7)),
          dump('late', createdAt: DateTime(2026, 9, 29, 22, 5)),
          dump('early', createdAt: DateTime(2026, 9, 29, 0, 0)),
          dump('two-days', createdAt: DateTime(2026, 9, 28, 23, 59)),
        ],
        reviewDay,
      );
      expect(review, isNotNull);
      expect(
        review!.items.map((DumpRow d) => d.id).toList(),
        <String>['early', 'late'],
      );
      expect(review.capturesDay, DateTime(2026, 9, 29));
      expect(review.reviewDay, reviewDay);
    });

    test('null when yesterday captured nothing — the caller shows nothing', () {
      expect(
        buildMorningReview(
          <DumpRow>[dump('today', createdAt: DateTime(2026, 9, 30, 7))],
          reviewDay,
        ),
        isNull,
      );
      expect(buildMorningReview(const <DumpRow>[], reviewDay), isNull);
    });

    test('counts recordings and notes by mode', () {
      final MorningReview review = buildMorningReview(
        <DumpRow>[
          dump('a', createdAt: DateTime(2026, 9, 29, 9)),
          dump('b', createdAt: DateTime(2026, 9, 29, 10), mode: 'meeting'),
          dump('c', createdAt: DateTime(2026, 9, 29, 11), mode: 'text_note'),
        ],
        reviewDay,
      )!;
      expect(review.recordingCount, 2);
      expect(review.noteCount, 1);
    });

    test('a time component on reviewDay is ignored', () {
      final MorningReview? review = buildMorningReview(
        <DumpRow>[dump('x', createdAt: DateTime(2026, 9, 29, 12))],
        DateTime(2026, 9, 30, 14, 45),
      );
      expect(review, isNotNull);
      expect(review!.reviewDay, DateTime(2026, 9, 30));
    });
  });

  group('morningReviewCardVisible', () {
    MorningReview review() => buildMorningReview(
          <DumpRow>[dump('x', createdAt: DateTime(2026, 9, 29, 12))],
          DateTime(2026, 9, 30),
        )!;

    test('stands while enabled and unviewed', () {
      expect(
        morningReviewCardVisible(
          enabled: true,
          viewedDay: '',
          review: review(),
        ),
        isTrue,
      );
    });

    test('an older viewed day does not satisfy this morning', () {
      expect(
        morningReviewCardVisible(
          enabled: true,
          viewedDay: '2026-09-29',
          review: review(),
        ),
        isTrue,
      );
    });

    test('tucked once its own day is viewed', () {
      expect(
        morningReviewCardVisible(
          enabled: true,
          viewedDay: '2026-09-30',
          review: review(),
        ),
        isFalse,
      );
    });

    test('never stands while off, and never without captures', () {
      expect(
        morningReviewCardVisible(
          enabled: false,
          viewedDay: '',
          review: review(),
        ),
        isFalse,
      );
      expect(
        morningReviewCardVisible(enabled: true, viewedDay: '', review: null),
        isFalse,
      );
    });
  });

  group('presentation lines', () {
    test('day label says Yesterday while the review is current', () {
      final MorningReview review = buildMorningReview(
        <DumpRow>[dump('x', createdAt: DateTime(2026, 9, 29, 12))],
        DateTime(2026, 9, 30),
      )!;
      expect(
        morningReviewDayLabel(review, DateTime(2026, 9, 30, 8)),
        'Yesterday',
      );
    });

    test('day label names the actual day once the card has stood past it', () {
      final MorningReview review = buildMorningReview(
        <DumpRow>[dump('x', createdAt: DateTime(2026, 9, 29, 12))],
        DateTime(2026, 9, 30),
      )!;
      expect(
        morningReviewDayLabel(review, DateTime(2026, 10, 1, 7)),
        'Tuesday, Sep 29',
      );
    });

    test('count line spells out recordings and notes', () {
      final MorningReview review = buildMorningReview(
        <DumpRow>[
          dump('a', createdAt: DateTime(2026, 9, 29, 9)),
          dump('b', createdAt: DateTime(2026, 9, 29, 10), mode: 'text_note'),
          dump('c', createdAt: DateTime(2026, 9, 29, 11), mode: 'text_note'),
        ],
        DateTime(2026, 9, 30),
      )!;
      expect(morningReviewCountLine(review), '1 recording \u00B7 2 notes');
    });

    test('count line drops an absent kind rather than saying "0 notes"', () {
      final MorningReview review = buildMorningReview(
        <DumpRow>[dump('a', createdAt: DateTime(2026, 9, 29, 9))],
        DateTime(2026, 9, 30),
      )!;
      expect(morningReviewCountLine(review), '1 recording');
    });
  });

  group('morningReviewNotification', () {
    test('names every capture when three or fewer', () {
      final MorningReview review = buildMorningReview(
        <DumpRow>[
          dump('a', createdAt: DateTime(2026, 9, 29, 9), title: 'Standup'),
          dump(
            'b',
            createdAt: DateTime(2026, 9, 29, 10),
            title: 'Grocery idea',
          ),
        ],
        DateTime(2026, 9, 30),
      )!;
      final digest = morningReviewNotification(review);
      expect(digest.title, 'Morning review');
      expect(digest.body, 'Yesterday: Standup, Grocery idea');
      expect(digest.dueTodayCount, 2);
      expect(digest.overdueCount, 0);
    });

    test('folds the tail into "and N more", in capture order', () {
      final MorningReview review = buildMorningReview(
        <DumpRow>[
          for (int i = 0; i < 5; i++)
            dump(
              'd$i',
              createdAt: DateTime(2026, 9, 29, 9 + i),
              title: 'Capture $i',
            ),
        ],
        DateTime(2026, 9, 30),
      )!;
      expect(
        morningReviewNotification(review).body,
        'Yesterday: Capture 0, Capture 1, Capture 2 and 2 more',
      );
    });
  });

  group('SettingsStore round-trips', () {
    test('defaults: off, 08:00, nothing shown, nothing viewed', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final SettingsStore store = await SettingsStore.load();
      expect(store.morningReviewEnabled, isFalse);
      expect(store.morningReviewMinuteOfDay, 480);
      expect(store.lastMorningReviewShownDay, '');
      expect(store.morningReviewViewedDay, '');
    });

    test('set then reload', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final SettingsStore store = await SettingsStore.load();
      await store.setMorningReviewEnabled(true);
      await store.setMorningReviewMinuteOfDay(9 * 60 + 15);
      await store.setLastMorningReviewShownDay('2026-09-30');
      await store.setMorningReviewViewedDay('2026-09-30');
      final SettingsStore again = await SettingsStore.load();
      expect(again.morningReviewEnabled, isTrue);
      expect(again.morningReviewMinuteOfDay, 555);
      expect(again.lastMorningReviewShownDay, '2026-09-30');
      expect(again.morningReviewViewedDay, '2026-09-30');
    });

    test('out-of-range minute is clamped inside one day', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final SettingsStore store = await SettingsStore.load();
      await store.setMorningReviewMinuteOfDay(30 * 60);
      expect(store.morningReviewMinuteOfDay, 24 * 60 - 1);
      await store.setMorningReviewMinuteOfDay(-5);
      expect(store.morningReviewMinuteOfDay, 0);
    });

    test('the due reminder keeps its own 07:00 default', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final SettingsStore store = await SettingsStore.load();
      expect(store.reminderMinuteOfDay, 420);
      expect(store.morningReviewMinuteOfDay, 480);
    });
  });

  group('full-screen briefing (v1.40)', () {
    TodoRow todo(
      String id, {
      String? due,
      bool pinned = false,
      bool done = false,
    }) =>
        TodoRow(
          id: id,
          body: id,
          doneAt: done ? '2026-09-29T10:00:00Z' : null,
          dueDate: due,
          source: 'manual',
          sourceRef: null,
          createdAt: '2026-09-28T10:00:00Z',
          updatedAt: '2026-09-28T10:00:00Z',
          deletedAt: null,
          syncDirty: false,
          syncedSeq: null,
          folderId: null,
          pinned: pinned,
        );
    final DateTime now = DateTime(2026, 9, 30, 9);

    MorningBriefing brief({
      List<DumpRow> dumps = const <DumpRow>[],
      List<TodoRow> todos = const <TodoRow>[],
      List<({String id, String title, bool pinned})> notebooks = const <({
        String id,
        String title,
        bool pinned
      })>[],
    }) =>
        buildMorningBriefing(
          now: now,
          minuteOfDay: eight,
          dumps: dumps,
          todos: todos,
          notebooks: notebooks,
        );

    test('captures are uncapped', () {
      final MorningBriefing b = brief(
        dumps: <DumpRow>[
          for (int i = 0; i < 12; i++)
            dump('c$i', createdAt: DateTime(2026, 9, 29, 8, i)),
        ],
      );
      expect(b.captures, hasLength(12));
    });

    test('due today / overdue reuse the digest buckets; done and future out',
        () {
      final MorningBriefing b = brief(
        todos: <TodoRow>[
          todo('today', due: '2026-09-30'),
          todo('late', due: '2026-09-28'),
          todo('future', due: '2026-10-02'),
          todo('done', due: '2026-09-30', done: true),
        ],
      );
      expect(b.dueToday.map((t) => t.id), <String>['today']);
      expect(b.overdue.map((t) => t.id), <String>['late']);
    });

    test('pinned spans recordings, notebooks and live to-dos', () {
      final MorningBriefing b = brief(
        dumps: <DumpRow>[
          dump('p-rec', createdAt: DateTime(2026, 8, 1)).copyWith(
            pinned: const Value<bool?>(true),
          ),
        ],
        todos: <TodoRow>[
          todo('p-todo', pinned: true),
          todo('p-done', pinned: true, done: true),
        ],
        notebooks: const <({String id, String title, bool pinned})>[
          (id: 'nb', title: 'Plans', pinned: true),
          (id: 'nb2', title: 'Other', pinned: false),
        ],
      );
      expect(
        b.pinned.map((p) => (p.kind, p.id)),
        <(MorningPinKind, String)>[
          (MorningPinKind.recording, 'p-rec'),
          (MorningPinKind.notebook, 'nb'),
          (MorningPinKind.todo, 'p-todo'),
        ],
      );
    });

    test('auto-present: on and unviewed, even when empty', () {
      final MorningBriefing full = brief(
        dumps: <DumpRow>[dump('x', createdAt: DateTime(2026, 9, 29, 9))],
      );
      expect(
        morningReviewShouldAutoPresent(
          enabled: true,
          viewedDay: '2026-09-29',
          briefing: full,
        ),
        isTrue,
      );
      expect(
        morningReviewShouldAutoPresent(
          enabled: true,
          viewedDay: '2026-09-30',
          briefing: full,
        ),
        isFalse,
      );
      expect(
        morningReviewShouldAutoPresent(
          enabled: false,
          viewedDay: '',
          briefing: full,
        ),
        isFalse,
      );
      expect(
        morningReviewShouldAutoPresent(
          enabled: true,
          viewedDay: '',
          briefing: brief(),
        ),
        isTrue,
      );
      expect(morningReviewSunVisible(enabled: true), isTrue);
      expect(morningReviewSunVisible(enabled: false), isFalse);
    });
  });
}
