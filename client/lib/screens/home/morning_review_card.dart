// SPDX-License-Identifier: AGPL-3.0-or-later
/// The morning-review card (Ask-arc queued item 2): a light-blue panel at
/// the top of Home listing yesterday's captures, one line each. Light blue
/// is the start-of-day signal ([TangentColors.daybreak]); this is the only
/// surface that wears it. The card STAYS — across launches — until the
/// user views it (a tap on an item, on "+ N more", or on the tuck check),
/// then tucks away with a collapse; the viewed day persists in
/// [SettingsStore], so nothing here needs the database schema.
///
/// Every decision (which morning, which captures, whether the card stands)
/// lives in the pure `morning_review.dart` layer; this file only renders
/// and records the view.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/local_db.dart';
import '../../data/settings_store.dart';
import '../../services/desktop_due_reminder_port.dart' show TimerFactory;
import '../../services/due_digest.dart' show isoDate;
import '../../services/due_reminder_scheduler.dart'
    show DueReminderScheduler;
import '../../services/morning_review.dart';
import '../../theme/tangent_tokens.dart';
import '../dump/dump_detail_screen.dart';
import '../dump/dumps_list_screen.dart';
import '../settings/settings_screen.dart' show settingsStoreProvider;
import 'home_screen.dart' show localDbProvider;

/// Rows spelled out on the card before the "+ N more" line. Home is not a
/// scroll surface, so a monster capture day must not push the record key
/// off screen.
const int kMorningReviewCardMaxItems = 5;

/// Injected clock so widget tests pin the morning; production is the wall
/// clock.
final Provider<DateTime Function()> morningReviewClockProvider =
    Provider<DateTime Function()>((ref) => DateTime.now);

/// Builds the card's boundary timer (the re-check at the next fire time).
/// Injected like the desktop port's [TimerFactory] so widget tests can
/// substitute a timer that never really runs — a real Timer armed for
/// "next 8:00" outlives any test and trips the pending-timer invariant.
final Provider<TimerFactory> morningReviewTimerFactoryProvider =
    Provider<TimerFactory>(
  (ref) => (Duration delay, void Function() fire) => Timer(delay, fire),
);

/// The review the card should show right now, or null for no card. Streams
/// over the live dumps table so a sync that lands yesterday's captures
/// updates the standing card — but only ever touches the database while
/// the feature is ON, so the many Home tests that never enable it never
/// need one.
final StreamProvider<MorningReview?> morningReviewProvider =
    StreamProvider<MorningReview?>((ref) {
  final SettingsStore settings = ref.watch(settingsStoreProvider);
  if (!settings.morningReviewEnabled) {
    return Stream<MorningReview?>.value(null);
  }
  final DateTime Function() clock = ref.watch(morningReviewClockProvider);
  return ref.watch(localDbProvider).watchAllDumps().map(
    (List<DumpRow> dumps) {
      final MorningReview? review = buildMorningReview(
        dumps,
        morningReviewDayFor(clock(), settings.morningReviewMinuteOfDay),
      );
      final bool visible = morningReviewCardVisible(
        enabled: settings.morningReviewEnabled,
        viewedDay: settings.morningReviewViewedDay,
        review: review,
      );
      return visible ? review : null;
    },
  );
});

class MorningReviewCard extends ConsumerStatefulWidget {
  const MorningReviewCard({super.key});

  static const Key cardKey = Key('morning-review-card');
  static const Key tuckKey = Key('morning-review-tuck');
  static const Key moreKey = Key('morning-review-more');

  static Key itemKey(String dumpId) =>
      ValueKey<String>('morning-review-item-$dumpId');

  @override
  ConsumerState<MorningReviewCard> createState() => _MorningReviewCardState();
}

class _MorningReviewCardState extends ConsumerState<MorningReviewCard> {
  Timer? _boundary;

  @override
  void dispose() {
    _boundary?.cancel();
    super.dispose();
  }

  /// Re-evaluates at the next fire time, so a Home already on screen at
  /// 8:00 gets its card AT 8:00 rather than on the next navigation.
  void _armBoundaryTimer() {
    final SettingsStore settings = ref.read(settingsStoreProvider);
    if (!settings.morningReviewEnabled) {
      _boundary?.cancel();
      _boundary = null;
      return;
    }
    final DateTime now = ref.read(morningReviewClockProvider)();
    final DateTime next = DueReminderScheduler.nextFireTime(
      now,
      settings.morningReviewMinuteOfDay,
    );
    _boundary?.cancel();
    _boundary = ref.read(morningReviewTimerFactoryProvider)(
      next.difference(now),
      () {
        if (!mounted) return;
        ref.invalidate(morningReviewProvider);
        _armBoundaryTimer();
      },
    );
  }

  Future<void> _markViewed(MorningReview review) async {
    await ref
        .read(settingsStoreProvider)
        .setMorningReviewViewedDay(isoDate(review.reviewDay));
    ref.invalidate(morningReviewProvider);
  }

  Future<void> _openItem(MorningReview review, DumpRow item) async {
    // Viewed FIRST: coming back from the capture must find the card
    // already tucked, not standing around asking again.
    await _markViewed(review);
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => DumpDetailScreen(
          dumpId: item.id,
          audioPath: item.audioPath,
          durationSeconds: item.durationSeconds,
        ),
      ),
    );
  }

  Future<void> _openMore(MorningReview review) async {
    await _markViewed(review);
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => const DumpsListScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final MorningReview? review =
        ref.watch(morningReviewProvider).valueOrNull;
    _armBoundaryTimer();
    // The tuck: when the review clears (viewed, toggled off, new morning
    // with nothing to show) the panel folds shut instead of blinking out.
    return AnimatedSize(
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeInOutCubic,
      alignment: Alignment.topCenter,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 250),
        child: review == null
            ? const SizedBox.shrink()
            : _panel(context, review),
      ),
    );
  }

  Widget _panel(BuildContext context, MorningReview review) {
    final ThemeData theme = Theme.of(context);
    final DateTime today = ref.read(morningReviewClockProvider)();
    final List<DumpRow> shown =
        review.items.take(kMorningReviewCardMaxItems).toList();
    final int overflow = review.items.length - shown.length;
    final String subtitle =
        '${morningReviewDayLabel(review, today)} \u00B7 '
        '${morningReviewCountLine(review)}';

    return Padding(
      key: MorningReviewCard.cardKey,
      padding: const EdgeInsets.fromLTRB(
        TangentSpacing.lg,
        0,
        TangentSpacing.lg,
        TangentSpacing.lg,
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: DecoratedBox(
          decoration: BoxDecoration(
            // Dawn light: lit at the top edge, settling into the face.
            gradient: const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              stops: <double>[0.0, 0.4],
              colors: <Color>[
                TangentColors.daybreakEdge,
                TangentColors.daybreak,
              ],
            ),
            borderRadius: BorderRadius.circular(TangentShapes.panelRadius),
            border: Border.all(
              color: TangentColors.daybreakEdge,
              width: TangentShapes.edgeWidth,
            ),
            boxShadow: TangentShapes.hardDrop,
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              TangentSpacing.lg,
              TangentSpacing.md,
              TangentSpacing.sm,
              TangentSpacing.md,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    const Icon(
                      Icons.wb_twilight,
                      size: 18,
                      color: TangentColors.daybreakInkDim,
                    ),
                    const SizedBox(width: TangentSpacing.sm),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            'Morning review',
                            style: theme.textTheme.titleSmall?.copyWith(
                              color: TangentColors.daybreakInk,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.2,
                            ),
                          ),
                          Text(
                            subtitle,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: TangentColors.daybreakInkDim,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      key: MorningReviewCard.tuckKey,
                      tooltip: 'Got it',
                      icon: const Icon(
                        Icons.check_rounded,
                        color: TangentColors.daybreakInk,
                      ),
                      onPressed: () => _markViewed(review),
                    ),
                  ],
                ),
                const SizedBox(height: TangentSpacing.xs),
                for (final DumpRow item in shown) _itemRow(review, item),
                if (overflow > 0)
                  InkWell(
                    key: MorningReviewCard.moreKey,
                    borderRadius:
                        BorderRadius.circular(TangentShapes.panelRadius),
                    onTap: () => _openMore(review),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(
                        26,
                        TangentSpacing.xs,
                        TangentSpacing.sm,
                        TangentSpacing.xs,
                      ),
                      child: Text(
                        'and $overflow more',
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(
                              color: TangentColors.daybreakInkDim,
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _itemRow(MorningReview review, DumpRow item) {
    final ThemeData theme = Theme.of(context);
    final String time = MaterialLocalizations.of(context).formatTimeOfDay(
      TimeOfDay.fromDateTime(item.createdAt.toLocal()),
    );
    return InkWell(
      key: MorningReviewCard.itemKey(item.id),
      borderRadius: BorderRadius.circular(TangentShapes.panelRadius),
      onTap: () => _openItem(review, item),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          vertical: TangentSpacing.xs + 2,
          horizontal: TangentSpacing.xs,
        ),
        child: Row(
          children: <Widget>[
            Icon(
              item.mode == 'text_note' ? Icons.sticky_note_2 : Icons.mic,
              size: 15,
              color: TangentColors.daybreakInkDim,
            ),
            const SizedBox(width: TangentSpacing.sm - 1),
            Expanded(
              child: Text(
                morningReviewLine(item),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: TangentColors.daybreakInk,
                ),
              ),
            ),
            const SizedBox(width: TangentSpacing.sm),
            Text(
              time,
              style: theme.textTheme.bodySmall?.copyWith(
                color: TangentColors.daybreakInkDim,
                fontFeatures: const <FontFeature>[
                  FontFeature.tabularFigures(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
