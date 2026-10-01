// SPDX-License-Identifier: AGPL-3.0-or-later
/// The morning review as a full screen (v1.40; replaces the v1.39 Home
/// card). A calm start-of-day briefing on daybreak blue — the one surface
/// in the app that wears it — listing ALL of yesterday's captures, today's
/// due to-dos and everything pinned.
///
/// It presents itself over Home on the first open of each review morning
/// ([MorningReviewAutoPresenter]) and re-opens any time from the sun icon
/// ([MorningReviewSunButton]). Both exist only while the setting is on.
///
/// Every decision (which morning, what is due, what is pinned, whether to
/// present) lives in the pure `services/morning_review.dart` layer; this
/// file only renders and records the view.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemUiOverlayStyle;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/local_db.dart';
import '../../data/notebook_repository.dart';
import '../../data/settings_store.dart';
import '../../data/todo_repository.dart';
import '../../services/desktop_due_reminder_port.dart' show TimerFactory;
import '../../services/due_digest.dart' show isoDate;
import '../../services/due_reminder_scheduler.dart' show DueReminderScheduler;
import '../../services/morning_review.dart';
import '../../theme/tangent_tokens.dart';
import '../dump/dump_detail_screen.dart';
import '../notebook/notebook_editor_screen.dart';
import '../settings/settings_screen.dart' show settingsStoreProvider;
import '../todo/todo_list_screen.dart';
import 'home_screen.dart' show localDbProvider;

/// Injected clock so widget tests pin the morning; production is the wall
/// clock.
final Provider<DateTime Function()> morningReviewClockProvider =
    Provider<DateTime Function()>((ref) => DateTime.now);

/// Builds the boundary timer (the re-check at the next fire time). Injected
/// so widget tests can substitute a timer that never really runs — a real
/// Timer armed for "next 8:00" outlives any test and trips the
/// pending-timer invariant.
final Provider<TimerFactory> morningReviewTimerFactoryProvider =
    Provider<TimerFactory>(
  (ref) => (Duration delay, void Function() fire) => Timer(delay, fire),
);

/// The live on/off switch. [SettingsStore] is a plain object, so the
/// Settings toggle writes the store AND this provider; everything that
/// must react (the sun icon, auto-present, the briefing stream) watches it.
final StateProvider<bool> morningReviewEnabledProvider = StateProvider<bool>(
  (ref) => ref.watch(settingsStoreProvider).morningReviewEnabled,
);

/// The briefing right now, or null while the feature is off. Streams over
/// dumps, to-dos and notebook headers so a sync landing mid-morning updates
/// an open screen. Touches the database only while ON, so the many Home
/// tests that never enable it never need one.
final StreamProvider<MorningBriefing?> morningBriefingProvider =
    StreamProvider<MorningBriefing?>((ref) {
  if (!ref.watch(morningReviewEnabledProvider)) {
    return Stream<MorningBriefing?>.value(null);
  }
  final SettingsStore settings = ref.watch(settingsStoreProvider);
  final DateTime Function() clock = ref.watch(morningReviewClockProvider);
  final LocalDb db = ref.watch(localDbProvider);
  final Stream<List<DumpRow>> dumps = db.watchAllDumps();
  final Stream<List<TodoRow>> todos = TodoRepository(db: db).watchTodos();
  final Stream<List<NotebookListEntry>> notebooks =
      NotebookRepository(db: db).watchNotebookHeaders();

  final StreamController<MorningBriefing?> out =
      StreamController<MorningBriefing?>();
  List<DumpRow>? d;
  List<TodoRow>? t;
  List<NotebookListEntry>? n;
  void emit() {
    if (d == null || t == null || n == null) return;
    out.add(
      buildMorningBriefing(
        now: clock(),
        minuteOfDay: settings.morningReviewMinuteOfDay,
        dumps: d!,
        todos: t!,
        notebooks: <({String id, String title, bool pinned})>[
          for (final NotebookListEntry e in n!)
            (id: e.id, title: e.title, pinned: e.pinned),
        ],
      ),
    );
  }

  final List<StreamSubscription<Object?>> subs = <StreamSubscription<Object?>>[
    dumps.listen(
      (v) {
        d = v;
        emit();
      },
      onError: out.addError,
    ),
    todos.listen(
      (v) {
        t = v;
        emit();
      },
      onError: out.addError,
    ),
    notebooks.listen(
      (v) {
        n = v;
        emit();
      },
      onError: out.addError,
    ),
  ];
  ref.onDispose(() {
    for (final StreamSubscription<Object?> s in subs) {
      s.cancel();
    }
    out.close();
  });
  return out.stream;
});

/// Route name of the full-screen review.
const String kMorningReviewRouteName = 'morning-review';

/// Opens the full-screen review and records the morning as viewed.
Future<void> openMorningReview(BuildContext context) =>
    Navigator.of(context).push<void>(
      PageRouteBuilder<void>(
        settings: const RouteSettings(name: kMorningReviewRouteName),
        transitionDuration: const Duration(milliseconds: 420),
        reverseTransitionDuration: const Duration(milliseconds: 280),
        pageBuilder: (_, __, ___) => const MorningReviewScreen(),
        transitionsBuilder: (_, Animation<double> animation, __, Widget child) {
          final Animation<double> curved = CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          );
          return FadeTransition(
            opacity: curved,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 0.04),
                end: Offset.zero,
              ).animate(curved),
              child: child,
            ),
          );
        },
      ),
    );

/// The small sun in the Home app bar, left of Settings. Exists exactly
/// while the setting is on; plain, no badge.
class MorningReviewSunButton extends ConsumerWidget {
  const MorningReviewSunButton({super.key});

  static const Key buttonKey = Key('home-morning-review-button');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!morningReviewSunVisible(
      enabled: ref.watch(morningReviewEnabledProvider),
    )) {
      return const SizedBox.shrink();
    }
    return IconButton(
      key: buttonKey,
      icon: const Icon(Icons.wb_sunny_outlined),
      tooltip: 'Morning review',
      onPressed: () => openMorningReview(context),
    );
  }
}

/// Invisible Home companion: presents the review once per review morning,
/// including AT the fire time when Home is already open — but ONLY while
/// Home's own route is the current one. Over any other screen (a recording,
/// Settings, or the review itself, opened from the sun icon) it waits; the
/// [ModalRoute] dependency rebuilds it when Home is uncovered again.
class MorningReviewAutoPresenter extends ConsumerStatefulWidget {
  const MorningReviewAutoPresenter({super.key});

  @override
  ConsumerState<MorningReviewAutoPresenter> createState() =>
      _MorningReviewAutoPresenterState();
}

class _MorningReviewAutoPresenterState
    extends ConsumerState<MorningReviewAutoPresenter> {
  Timer? _boundary;
  bool? _armedFor;

  @override
  void dispose() {
    _boundary?.cancel();
    super.dispose();
  }

  /// Arms the fire-time re-check only when [enabled] changes (or after it
  /// fires) — never on every rebuild.
  void _syncBoundaryTimer(bool enabled) {
    if (_armedFor == enabled) return;
    _armedFor = enabled;
    _boundary?.cancel();
    _boundary = null;
    if (!enabled) return;
    final DateTime now = ref.read(morningReviewClockProvider)();
    final DateTime next = DueReminderScheduler.nextFireTime(
      now,
      ref.read(settingsStoreProvider).morningReviewMinuteOfDay,
    );
    _boundary = ref.read(morningReviewTimerFactoryProvider)(
      next.difference(now),
      () {
        if (!mounted) return;
        _armedFor = null;
        ref.invalidate(morningBriefingProvider);
        _syncBoundaryTimer(ref.read(morningReviewEnabledProvider));
      },
    );
  }

  /// No presenter-side latches: the guards are [homeOnTop] here, the
  /// post-frame `isCurrent` re-check (a second callback scheduled in the
  /// same frame finds Home already covered, because push installs the
  /// route synchronously), and the viewed day the open screen records.
  void _maybePresent(MorningBriefing? briefing, {required bool homeOnTop}) {
    if (briefing == null || !homeOnTop) return;
    if (!morningReviewShouldAutoPresent(
      enabled: ref.read(morningReviewEnabledProvider),
      viewedDay: ref.read(settingsStoreProvider).morningReviewViewedDay,
      briefing: briefing,
    )) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Re-check after the frame: a route (or this review) may have been
      // pushed meanwhile.
      if (!mounted || ModalRoute.of(context)?.isCurrent == false) return;
      openMorningReview(context);
    });
  }

  @override
  Widget build(BuildContext context) {
    final bool enabled = ref.watch(morningReviewEnabledProvider);
    // Null outside any route (bare widget tests): treat as on top.
    final bool homeOnTop = ModalRoute.of(context)?.isCurrent ?? true;
    _syncBoundaryTimer(enabled);
    _maybePresent(
      ref.watch(morningBriefingProvider).valueOrNull,
      homeOnTop: homeOnTop,
    );
    return const SizedBox.shrink();
  }
}

class MorningReviewScreen extends ConsumerStatefulWidget {
  const MorningReviewScreen({super.key});

  static const Key screenKey = Key('morning-review-screen');
  static const Key closeKey = Key('morning-review-close');
  static const Key capturesKey = Key('morning-review-captures');
  static const Key dueKey = Key('morning-review-due');
  static const Key overdueKey = Key('morning-review-overdue');
  static const Key pinnedKey = Key('morning-review-pinned');
  static const Key emptyKey = Key('morning-review-empty');

  static Key captureKey(String id) =>
      ValueKey<String>('morning-review-item-$id');
  static Key todoKey(String id) => ValueKey<String>('morning-review-todo-$id');
  static Key pinKey(String id) => ValueKey<String>('morning-review-pin-$id');

  @override
  ConsumerState<MorningReviewScreen> createState() =>
      _MorningReviewScreenState();
}

class _MorningReviewScreenState extends ConsumerState<MorningReviewScreen> {
  /// Review day already recorded by this open screen. Per DAY, not once:
  /// a screen left open across the next fire time shows (and so has
  /// viewed) the new morning too.
  String? _recordedDay;

  void _recordView(MorningBriefing briefing) {
    final String day = isoDate(briefing.reviewDay);
    if (_recordedDay == day) return;
    _recordedDay = day;
    unawaited(
      ref.read(settingsStoreProvider).setMorningReviewViewedDay(day),
    );
  }

  Future<void> _push(Widget screen) => Navigator.of(context)
      .push<void>(MaterialPageRoute<void>(builder: (_) => screen));

  Future<void> _openDump(String id) async {
    final DumpRow? row = await ref.read(localDbProvider).getDumpRow(id);
    if (!mounted) return;
    if (row == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('That item is no longer here')),
      );
      return;
    }
    await _push(
      DumpDetailScreen(
        dumpId: row.id,
        audioPath: row.audioPath,
        durationSeconds: row.durationSeconds,
      ),
    );
  }

  Future<void> _openPin(MorningPin pin) => switch (pin.kind) {
        MorningPinKind.recording || MorningPinKind.note => _openDump(pin.id),
        MorningPinKind.notebook =>
          _push(NotebookEditorScreen(notebookId: pin.id)),
        MorningPinKind.todo => _push(const TodoListScreen()),
      };

  @override
  Widget build(BuildContext context) {
    final MorningBriefing? briefing =
        ref.watch(morningBriefingProvider).valueOrNull;
    if (briefing != null) _recordView(briefing);
    final DateTime now = ref.watch(morningReviewClockProvider)();
    final MediaQueryData media = MediaQuery.of(context);

    return AnnotatedRegion<SystemUiOverlayStyle>(
      // STATUS BAR ONLY: dark icons over the light daybreak blue. Built
      // from scratch, never from SystemUiOverlayStyle.dark/.light — those
      // presets also carry systemNavigationBar* values, and Flutter only
      // ever sends NON-null fields, so a nav-bar value set here is never
      // reverted by any other screen (nothing else in the app sets one) and
      // sticks app-wide. Nav-bar fields stay null = the platform default.
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.dark,
        statusBarBrightness: Brightness.light,
      ),
      child: Scaffold(
        key: MorningReviewScreen.screenKey,
        backgroundColor: TangentColors.daybreak,
        body: DecoratedBox(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              stops: <double>[0, 0.45],
              colors: <Color>[
                TangentColors.daybreakEdge,
                TangentColors.daybreak,
              ],
            ),
          ),
          child: SafeArea(
            bottom: false,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: CustomScrollView(
                  slivers: <Widget>[
                    SliverToBoxAdapter(child: _header(context, now, briefing)),
                    if (briefing == null)
                      const SliverFillRemaining(
                        hasScrollBody: false,
                        child: Center(
                          child: CircularProgressIndicator(
                            color: TangentColors.daybreakInkDim,
                          ),
                        ),
                      )
                    else if (briefing.isEmpty)
                      SliverFillRemaining(
                        hasScrollBody: false,
                        child: _empty(context),
                      )
                    else ...<Widget>[
                      if (briefing.captures.isNotEmpty)
                        _section(
                          key: MorningReviewScreen.capturesKey,
                          icon: Icons.history_rounded,
                          title: morningReviewDayLabel(briefing.review!, now),
                          caption: morningReviewCountLine(briefing.review!),
                          rows: <Widget>[
                            for (final DumpRow d in briefing.captures)
                              _Line(
                                key: MorningReviewScreen.captureKey(d.id),
                                icon: d.mode == 'text_note'
                                    ? Icons.sticky_note_2_outlined
                                    : Icons.mic_none_rounded,
                                text: morningReviewLine(d),
                                trailing: MaterialLocalizations.of(context)
                                    .formatTimeOfDay(
                                  TimeOfDay.fromDateTime(d.createdAt.toLocal()),
                                ),
                                onTap: () => _openDump(d.id),
                              ),
                          ],
                        ),
                      if (briefing.dueToday.isNotEmpty)
                        _section(
                          key: MorningReviewScreen.dueKey,
                          icon: Icons.event_available_rounded,
                          title: 'Due today',
                          caption: '${briefing.dueToday.length}',
                          rows: <Widget>[
                            for (final TodoRow t in briefing.dueToday)
                              _todoLine(t, overdue: false),
                          ],
                        ),
                      if (briefing.overdue.isNotEmpty)
                        _section(
                          key: MorningReviewScreen.overdueKey,
                          icon: Icons.schedule_rounded,
                          title: 'Overdue',
                          caption: '${briefing.overdue.length}',
                          rows: <Widget>[
                            for (final TodoRow t in briefing.overdue)
                              _todoLine(t, overdue: true),
                          ],
                        ),
                      if (briefing.pinned.isNotEmpty)
                        _section(
                          key: MorningReviewScreen.pinnedKey,
                          icon: Icons.push_pin_outlined,
                          title: 'Pinned',
                          caption:
                              '${briefing.pinned.length} item${briefing.pinned.length == 1 ? '' : 's'}',
                          rows: <Widget>[
                            for (final MorningPin p in briefing.pinned)
                              _Line(
                                key: MorningReviewScreen.pinKey(p.id),
                                icon: _pinIcon(p.kind),
                                text: p.title.isEmpty ? '(untitled)' : p.title,
                                onTap: () => _openPin(p),
                              ),
                          ],
                        ),
                      SliverToBoxAdapter(
                        child: SizedBox(height: media.padding.bottom + 40),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _header(BuildContext context, DateTime now, MorningBriefing? b) {
    final TextTheme text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 8, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white.withValues(alpha: 0.55),
                  border: Border.all(color: Colors.white, width: 1.2),
                ),
                child: const Icon(
                  Icons.wb_sunny_rounded,
                  color: Color(0xFFE8A33D),
                  size: 24,
                ),
              ),
              const Spacer(),
              IconButton(
                key: MorningReviewScreen.closeKey,
                tooltip: 'Close',
                icon: const Icon(
                  Icons.close_rounded,
                  color: TangentColors.daybreakInk,
                ),
                onPressed: () => Navigator.of(context).maybePop(),
              ),
            ],
          ),
          const SizedBox(height: 28),
          Text(
            _greeting(now),
            style: text.headlineMedium?.copyWith(
              color: TangentColors.daybreakInk,
              fontWeight: FontWeight.w300,
              letterSpacing: -0.5,
              height: 1.1,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            _longDate(now),
            style: text.titleSmall?.copyWith(
              color: TangentColors.daybreakInkDim,
              fontWeight: FontWeight.w500,
              letterSpacing: 0.3,
            ),
          ),
        ],
      ),
    );
  }

  Widget _empty(BuildContext context) => Padding(
        key: MorningReviewScreen.emptyKey,
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 80),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Icon(
              Icons.spa_outlined,
              size: 40,
              color: TangentColors.daybreakInkDim.withValues(alpha: 0.7),
            ),
            const SizedBox(height: 16),
            Text(
              'A clear start',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: TangentColors.daybreakInk,
                    fontWeight: FontWeight.w600,
                  ),
            ),
            const SizedBox(height: 6),
            Text(
              'Nothing from yesterday, nothing due, nothing pinned.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: TangentColors.daybreakInkDim,
                  ),
            ),
          ],
        ),
      );

  Widget _section({
    required Key key,
    required IconData icon,
    required String title,
    required String caption,
    required List<Widget> rows,
  }) {
    final TextTheme text = Theme.of(context).textTheme;
    return SliverPadding(
      key: key,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
      sliver: SliverToBoxAdapter(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.42),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.75),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 14, 8, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
                  child: Row(
                    children: <Widget>[
                      Icon(icon, size: 18, color: TangentColors.daybreakInkDim),
                      const SizedBox(width: 10),
                      Text(
                        title.toUpperCase(),
                        style: text.labelMedium?.copyWith(
                          color: TangentColors.daybreakInk,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.2,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        caption,
                        style: text.bodySmall?.copyWith(
                          color: TangentColors.daybreakInkDim,
                        ),
                      ),
                    ],
                  ),
                ),
                ...rows,
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _todoLine(TodoRow t, {required bool overdue}) => _Line(
        key: MorningReviewScreen.todoKey(t.id),
        icon: Icons.check_box_outline_blank_rounded,
        text: t.body.trim(),
        // Overdue rows say how late, quietly emphasised.
        trailing: overdue && t.dueDate != null ? _dueLabel(t.dueDate!) : null,
        trailingEmphasis: overdue,
        onTap: () => _push(const TodoListScreen()),
      );

  /// 'Sep 27' from an ISO date; the raw string if it does not parse.
  static String _dueLabel(String iso) {
    final DateTime? d = DateTime.tryParse(iso);
    if (d == null) return iso;
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
    return '${months[d.month - 1]} ${d.day}';
  }

  static IconData _pinIcon(MorningPinKind kind) => switch (kind) {
        MorningPinKind.recording => Icons.mic_none_rounded,
        MorningPinKind.note => Icons.sticky_note_2_outlined,
        MorningPinKind.notebook => Icons.menu_book_outlined,
        MorningPinKind.todo => Icons.check_box_outline_blank_rounded,
      };

  static String _greeting(DateTime now) => now.hour < 12
      ? 'Good morning'
      : now.hour < 17
          ? 'Good afternoon'
          : 'Good evening';

  static String _longDate(DateTime d) {
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
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ];
    return '${weekdays[d.weekday - 1]}, ${months[d.month - 1]} ${d.day}';
  }
}

/// One briefing line: icon, single-line text, optional quiet trailing.
class _Line extends StatelessWidget {
  const _Line({
    super.key,
    required this.icon,
    required this.text,
    required this.onTap,
    this.trailing,
    this.trailingEmphasis = false,
  });

  final IconData icon;
  final String text;
  final String? trailing;
  final bool trailingEmphasis;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final TextTheme theme = Theme.of(context).textTheme;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
        child: Row(
          children: <Widget>[
            Icon(icon, size: 18, color: TangentColors.daybreakInkDim),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.bodyLarge?.copyWith(
                  color: TangentColors.daybreakInk,
                  height: 1.2,
                ),
              ),
            ),
            if (trailing != null) ...<Widget>[
              const SizedBox(width: 12),
              Text(
                trailing!,
                style: theme.bodySmall?.copyWith(
                  color: trailingEmphasis
                      ? const Color(0xFFB4532A)
                      : TangentColors.daybreakInkDim,
                  fontWeight:
                      trailingEmphasis ? FontWeight.w600 : FontWeight.w400,
                  fontFeatures: const <FontFeature>[
                    FontFeature.tabularFigures(),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
