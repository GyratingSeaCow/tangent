// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/local_db.dart';

import '../../data/storage/storage_contract.dart';
import '../../models/dump_mode.dart';
import '../../services/document_sync_engine.dart';
import '../../widgets/sync_button.dart' show syncMessageFor;

import '../dump/dump_detail_screen.dart';
import '../dump/dumps_list_screen.dart';
import '../note/note_compose_screen.dart';
import '../notebook/notebook_list_screen.dart';
import '../recording/recording_controller.dart';
import '../recording/recording_waveform.dart';
import '../settings/settings_screen.dart';
import '../../theme/tangent_tokens.dart';
import 'home_providers.dart';
import 'record_button_palette.dart';

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

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  bool _syncing = false;
  bool _importing = false;
  DumpMode _mode = DumpMode.brainDump;

  @override
  void initState() {
    super.initState();
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

  /// Pushes the dumps list and honors the [DumpsCreateAction] it pops with
  /// (its `+` FAB): switch [_mode] to match, then reuse the existing entry
  /// points — compose for text notes, `_toggleRecording` for voice modes.
  Future<void> _openDumpsList() async {
    final action = await Navigator.of(context).push<DumpsCreateAction?>(
      MaterialPageRoute<DumpsCreateAction?>(
        builder: (_) => const DumpsListScreen(),
      ),
    );
    if (action == null || !mounted) return;
    setState(() {
      _mode = switch (action) {
        DumpsCreateAction.textNote => DumpMode.textNote,
        DumpsCreateAction.brainDump => DumpMode.brainDump,
        DumpsCreateAction.meeting => DumpMode.meeting,
      };
    });
    if (action == DumpsCreateAction.textNote) {
      await _openNoteCompose();
    } else {
      await _toggleRecording();
    }
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

    return Scaffold(
      appBar: AppBar(
        title: const Text('Tangent'),
        actions: [
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
          IconButton(
            icon: const Icon(Icons.list),
            tooltip: 'View dumps',
            onPressed: _openDumpsList,
          ),
          IconButton(
            icon: const Icon(Icons.menu_book),
            tooltip: 'Notebooks',
            onPressed: () => Navigator.of(context).push<void>(
              MaterialPageRoute<void>(
                builder: (_) => const NotebookListScreen(),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Settings',
            onPressed: () => Navigator.of(context).push<void>(
              MaterialPageRoute<void>(
                builder: (_) => const SettingsScreen(),
              ),
            ),
          ),
        ],
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (!isNoteMode)
              Text(
                timeLabel,
                style: TextStyle(
                  fontSize: 72,
                  fontWeight: FontWeight.w200,
                  color: isRecording
                      ? Theme.of(context).colorScheme.error
                      : Theme.of(context).colorScheme.onSurface,
                ),
              ),
            if (isRecording) ...[
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: RecordingWaveformConsumer(
                  color: Theme.of(context).colorScheme.error,
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
            // Jeff: "There also needs to be an Import Audio button which will
            // allow you to import audio into the tangent folder by copying it
            // to the tangent folder and then processing it."
            TextButton.icon(
              key: const ValueKey('home-import-audio'),
              // Importing reserves a capture, so it must not run while one is
              // already active.
              onPressed: isRecording || _importing ? null : _importAudio,
              icon: _importing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.library_music),
              label: Text(_importing ? 'Importing…' : 'Import audio'),
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
    );
  }

  String _modeDescription(DumpMode m) => switch (m) {
        DumpMode.brainDump =>
          'Quick voice memo — gets transcribed and searchable.',
        DumpMode.meeting =>
          'Secretary mode — meeting notes with action items extracted.',
        DumpMode.textNote =>
          'Type a quick note — searchable with your dumps.',
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
