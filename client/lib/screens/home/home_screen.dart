// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/local_db.dart';

import '../../data/storage/storage_contract.dart';
import '../../data/storage/storage_providers.dart' show captureReadyProvider;
import '../../models/dump_mode.dart';
import '../../services/document_sync_engine.dart';
import '../../services/instance_commands.dart';
import '../../services/widget_launch.dart';
import '../../widgets/sync_button.dart' show syncMessageFor;

import '../dump/dump_detail_screen.dart';
import '../note/note_compose_screen.dart';
import '../recording/recording_controller.dart';
import '../recording/recording_waveform.dart';
import '../../services/create_requests.dart';
import '../../theme/tangent_tokens.dart';
import '../../widgets/instrument_scaffold.dart';
import '../../widgets/top_nav_rail.dart';
import '../settings/settings_screen.dart' show settingsStoreProvider;
import 'home_providers.dart';
import 'morning_review_screen.dart';
import 'welcome_pairing_dialog.dart';
import 'record_button_palette.dart';
import 'speaker_backfill_banner.dart';

final localDbProvider = Provider<LocalDb>((ref) {
  throw UnimplementedError('Override in main()');
});

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  /// The spinner shown while the app is working — starting a capture, or
  /// finalising one after stop. Without it a slow save is indistinguishable
  /// from a button that did nothing.
  static const Key busyIndicatorKey = Key('home-busy-indicator');

  /// The record/stop key itself.
  static const Key recordButtonKey = Key('home-record-button');

  /// The one command every trigger collapses to: the desktop hotkey sends
  /// it verbatim; the Android hands-free spine (tangent://record from the
  /// 1x1 widget, the launcher shortcut, Assistant) is translated to it.
  static const String toggleRecordCommand = 'toggle-record';

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  bool _syncing = false;
  bool _importing = false;
  DumpMode _mode = DumpMode.brainDump;
  StreamSubscription<String>? _instanceCommands;
  StreamSubscription<String>? _launchCommands;
  StreamSubscription<CreateRequest>? _createRequests;

  /// Resolves once the recording controller can actually start: DB init,
  /// storage bootstrap, fence restore — the same future the controller
  /// itself awaits. Hands-free commands queue behind it (see
  /// [_onLaunchCommand]); it never rejects, a failed bootstrap surfaces as
  /// the controller's own "Recording failed" rather than a dropped intent.
  Future<void>? _readyForCommands;

  @override
  void initState() {
    super.initState();
    // Desktop hotkey path: `tangent --record` from another process arrives
    // here as 'toggle-record'. Same entry point as the on-screen button so
    // the two can never diverge.
    _instanceCommands = ref.read(instanceCommandsProvider).listen(_onCommand);
    // Android hands-free spine (spec 2026-09-28): tangent://record from the
    // 1x1 mic widget, the launcher "Record" shortcut or Assistant. Cold
    // start hands the command over once (read-once on the native side, so
    // a hot restart cannot replay it); warm arrivals ride the stream. Both
    // funnel into the SAME toggle path as the hotkey and the button.
    final WidgetLaunch launch = ref.read(widgetLaunchProvider);
    _launchCommands = launch.commands.listen(_onLaunchCommand);
    unawaited(
      launch.takeInitialCommand().then((String? command) {
        if (command != null && mounted) _onLaunchCommand(command);
      }),
    );
    // Global create funnel (Instrument Console v2): the lime FAB's sheet and
    // the Recordings-list create flow both deliver here, so every creation
    // path runs through the SAME mode switch and toggle the button uses.
    _createRequests =
        ref.read(createRequestsProvider).stream.listen(_onCreateRequest);
    // First-run welcome (spec 2026-10-02): repeat the pairing walkthrough at
    // EVERY launch — paired or not — until the user checks DO NOT REMIND ME
    // AGAIN and hits Confirm in the dialog itself.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_maybeShowWelcome());
    });
  }

  /// Shows [WelcomePairingDialog] whenever the welcome pref is on. Pairing
  /// state is deliberately NOT consulted (spec 2026-10-02): the ONLY thing
  /// that stops the reminder is the dialog's own checkbox + Confirm.
  Future<void> _maybeShowWelcome() async {
    if (!ref.read(settingsStoreProvider).showWelcomeMessage) return;
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (BuildContext context) => const WelcomePairingDialog(),
    );
  }

  /// A create request switches the mode selector and fires the matching
  /// entry point — exactly what [_openDumpsList]'s pop-result handling has
  /// always done, generalized to any trigger.
  void _onCreateRequest(CreateRequest request) {
    if (!mounted) return;
    setState(() {
      _mode = switch (request) {
        CreateRequest.textNote => DumpMode.textNote,
        CreateRequest.meeting => DumpMode.meeting,
        CreateRequest.recording => DumpMode.brainDump,
        // Notebook/to-do creation never reaches Capture; routed elsewhere.
        CreateRequest.notebook || CreateRequest.todo => _mode,
      };
    });
    switch (request) {
      case CreateRequest.textNote:
        unawaited(_openNoteCompose());
      case CreateRequest.recording:
      case CreateRequest.meeting:
        unawaited(_toggleRecording());
      case CreateRequest.notebook:
      case CreateRequest.todo:
        break;
    }
  }

  @override
  void dispose() {
    unawaited(_instanceCommands?.cancel());
    unawaited(_launchCommands?.cancel());
    unawaited(_createRequests?.cancel());
    super.dispose();
  }

  /// The single command handler. Text Note mode is voice-less; a trigger
  /// is about capturing a thought at the speed of speech, so it records a
  /// brain dump (H4) rather than opening a compose screen nobody asked for
  /// — then toggles exactly as a tap on the centre button would (H1
  /// start, H2 stop).
  void _onCommand(String command) {
    if (command != HomeScreen.toggleRecordCommand || !mounted) return;
    if (_mode == DumpMode.textNote) {
      setState(() => _mode = DumpMode.brainDump);
    }
    unawaited(_toggleRecording());
  }

  /// A hands-free 'record' is held until the controller is ready, then
  /// applied exactly once through [_onCommand]. A cold start can deliver
  /// the intent before permissions and the DB bootstrap have run; acting
  /// early would flip the screen busy on a controller that cannot start
  /// yet, and dropping it would make the widget tap silently do nothing.
  /// RECORD_AUDIO is requested inside the controller's start (the recorder
  /// prompts when not yet granted and proceeds on grant), so a first-ever
  /// tap still ends in a running recording rather than a lost intent.
  void _onLaunchCommand(String command) {
    if (command != widgetLaunchRecordCommand || !mounted) return;
    final Future<void> ready = _readyForCommands ??=
        ref.read(captureReadyProvider.future).catchError((Object _) {});
    unawaited(
      ready.then((_) {
        if (mounted) _onCommand(HomeScreen.toggleRecordCommand);
      }),
    );
  }

  /// Reads the elapsed-seconds counter. Wrapped in a method so the build()
  /// below can call it after watching recordingTickProvider, which forces
  /// a rebuild every second while recording.
  int _readElapsedSeconds(WidgetRef ref) {
    // Touch the tick provider so this build re-runs when the tick increments.
    ref.watch(recordingTickProvider);
    final controller = ref.read(recordingControllerProvider.notifier);
    return controller.elapsedSeconds;
  }

  Future<void> _toggleRecording() async {
    final controller = ref.read(recordingControllerProvider.notifier);
    final state = ref.read(recordingControllerProvider);
    try {
      if (state == RecordingState.recording) {
        final row = await controller.stop();
        if (row == null) throw StateError('Recorder returned no audio');
        // H3: a session started over the lock screen may stop there, but
        // review needs the unlock. No-op when the phone is not locked and
        // on platforms without the channel.
        unawaited(ref.read(widgetLaunchProvider).dismissKeyguard());
        if (mounted) {
          await Navigator.of(context).push<void>(
            MaterialPageRoute<void>(
              builder: (_) => DumpDetailScreen(
                dumpId: row.id,
                audioPath: row.audioPath,
                durationSeconds: row.durationSeconds,
              ),
            ),
          );
        }
      } else if (state == RecordingState.idle) {
        await controller.start(mode: _mode.wireValue);
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Recording failed: $error')),
        );
      }
    }
  }

  /// Text Note mode never touches the recording state machine: the center
  /// button opens the compose screen instead of `controller.start`.
  Future<void> _openNoteCompose() {
    return Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => const NoteComposeScreen(),
      ),
    );
  }

  Future<void> _syncNow() async {
    setState(() => _syncing = true);
    try {
      // Two different things share this button: audio backup (opt-in, Wi-Fi
      // gated) and document sync (notebooks and notes, always allowed). A
      // second app-bar button for the second kind would leave the user
      // guessing which one they need, so one press does both.
      await ref.read(syncEngineProvider).syncNow();
      final SyncReport report =
          await ref.read(documentSyncEngineProvider).syncNow();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(syncMessageFor(report))),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Sync error: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  /// Copies an existing audio file into the Tangent folder and catalogs it.
  Future<void> _importAudio() async {
    final picked = await ref.read(audioFilePickerProvider).pick();
    if (picked == null) return; // cancelled
    if (!mounted) return;

    setState(() => _importing = true);
    try {
      final result = await ref.read(audioImportRunnerProvider).run(
            sourcePath: picked.path,
            mode: _mode.wireValue,
            title: picked.name,
          );
      if (!mounted) return;
      switch (result) {
        case Ok<String>():
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Imported ${picked.name}')),
          );
        case Fail<String>(:final problem):
          // Surfaced, never swallowed: a silent failure would look like the
          // import worked.
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Import failed: ${problem.message}')),
          );
      }
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(recordingControllerProvider);
    final isRecording = state == RecordingState.recording;
    // Starting a capture and finalising one are both real work with no visible
    // output of their own. Reported from the device: after stop, the screen
    // looked idle while the save ran, so a slow finalise was indistinguishable
    // from a dead button.
    final isBusy =
        state == RecordingState.starting || state == RecordingState.saving;
    final isNoteMode = _mode == DumpMode.textNote;
    // Read the current elapsed seconds. Watching recordingTickProvider
    // makes this build re-run every second while recording so the timer
    // text updates. Without this the timer stays frozen at 00:00 even
    // though the mic stream is active.
    final seconds = isRecording ? _readElapsedSeconds(ref) : 0;
    final timeLabel = (() {
      final m = (seconds ~/ 60).toString().padLeft(2, '0');
      final s = (seconds % 60).toString().padLeft(2, '0');
      return '$m:$s';
    })();

    return InstrumentScaffold(
      root: TangentRoot.capture,
      maxContentWidth: InstrumentScaffold.readingWidth,
      appBar: AppBar(
        title: const Text('Tangent'),
        actions: [
          // Mockup: import lives in the app bar, not the capture column.
          IconButton(
            key: const ValueKey('home-import-audio'),
            icon: _importing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.library_music),
            tooltip: 'Import audio',
            // Importing reserves a capture, so it must not run while one
            // is already active.
            onPressed: isRecording || _importing ? null : _importAudio,
          ),
          IconButton(
            icon: _syncing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.cloud_sync),
            tooltip: 'Sync now',
            onPressed: _syncing ? null : _syncNow,
          ),
          // Morning review sun: rightmost action, present only while the
          // setting is on.
          const MorningReviewSunButton(),
        ],
      ),
      // Scrollable-center: the column centres when it fits and scrolls when
      // it does not (short screens, large text). A plain Center+Column
      // overflowed by the rail's height the day the rail landed.
      body: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
            // v1.40: renders nothing itself; presents the full-screen
            // morning review over Home on the first open of each morning.
            const MorningReviewAutoPresenter(),
            const SpeakerBackfillBanner(),
            // Eyebrow status line (mockup): quiet uppercase mono over the
            // timer, naming the capture state.
            Text(
              isNoteMode
                  ? 'TEXT NOTE'
                  : isRecording
                      ? 'RECORDING'
                      : 'READY TO RECORD',
              style: Theme.of(context).textTheme.labelSmall,
            ),
            if (!isNoteMode) ...[
              const SizedBox(height: 8),
              Text(
                timeLabel,
                style: TextStyle(
                  fontSize: 72,
                  fontWeight: FontWeight.w200,
                  // Tabular figures: the timer must not wobble as digits
                  // change.
                  fontFeatures: const [FontFeature.tabularFigures()],
                  color: isRecording
                      ? Theme.of(context).colorScheme.error
                      : Theme.of(context).colorScheme.onSurface,
                ),
              ),
            ],
            if (isRecording) ...[
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: RecordingWaveformConsumer(
                  // Signal, not red: the token contract says lime marks the
                  // LIVE thing, and the active waveform is the live thing.
                  // The red key + red timer already say "capturing".
                  color: TangentColors.signal,
                ),
              ),
              const SizedBox(height: 12),
            ] else if (isBusy) ...[
              const SizedBox(height: 12),
              // Grey, not red or lime: red means capture and lime means live,
              // and a save is neither.
              const SizedBox(
                key: HomeScreen.busyIndicatorKey,
                width: 28,
                height: 28,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: TangentColors.textDim,
                ),
              ),
              const SizedBox(height: 12),
            ] else
              const SizedBox(height: 32),
            GestureDetector(
              key: HomeScreen.recordButtonKey,
              // Taps are refused while busy: tapping through a finalising save
              // starts a second capture before the first has committed, which
              // is how orphaned staging files appeared on device.
              onTap: isBusy
                  ? null
                  : (isNoteMode ? _openNoteCompose : _toggleRecording),
              child: Container(
                width: 120,
                height: 120,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: recordButtonColor(
                    isNoteMode: isNoteMode,
                    isRecording: isRecording,
                  ),
                ),
                child: Icon(
                  isNoteMode
                      ? Icons.edit_note
                      : isRecording
                          ? Icons.stop
                          : Icons.mic,
                  size: 64,
                  color: recordButtonIconColor(isNoteMode: isNoteMode),
                ),
              ),
            ),
            const SizedBox(height: 24),
            Text(
              isNoteMode
                  ? 'Tap to write'
                  : isRecording
                      ? 'Tap to stop'
                      : 'Tap to record',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            _ModeSelector(
              current: _mode,
              onChanged: isRecording ? null : (m) => setState(() => _mode = m),
            ),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                _modeDescription(_mode),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _modeDescription(DumpMode m) => switch (m) {
        DumpMode.brainDump =>
          'Quick voice memo — gets transcribed and searchable.',
        DumpMode.meeting =>
          'Secretary mode — meeting notes with action items extracted.',
        DumpMode.textNote =>
          'Type a quick note — searchable with your recordings.',
      };
}

class _ModeSelector extends StatelessWidget {
  final DumpMode current;
  final ValueChanged<DumpMode>? onChanged;

  const _ModeSelector({required this.current, this.onChanged});

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<DumpMode>(
      segments: const [
        ButtonSegment(
          value: DumpMode.brainDump,
          label: Text('Brain Dump'),
          icon: Icon(Icons.psychology),
        ),
        ButtonSegment(
          value: DumpMode.meeting,
          label: Text('Meeting'),
          icon: Icon(Icons.groups),
        ),
        ButtonSegment(
          value: DumpMode.textNote,
          label: Text('Text Note'),
          // Distinct from the center button's Icons.edit_note so the compose
          // affordance stays uniquely identifiable.
          icon: Icon(Icons.sticky_note_2),
        ),
      ],
      selected: {current},
      onSelectionChanged: onChanged == null ? null : (s) => onChanged!(s.first),
    );
  }
}
