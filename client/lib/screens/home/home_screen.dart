// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/local_db.dart';

import '../../models/dump_mode.dart';

import '../dump/dump_detail_screen.dart';
import '../dump/dumps_list_screen.dart';
import '../recording/recording_controller.dart';
import '../recording/recording_waveform.dart';
import '../settings/settings_screen.dart';
import 'home_providers.dart';

final localDbProvider = Provider<LocalDb>((ref) {
  throw UnimplementedError('Override in main()');
});

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  bool _syncing = false;
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

  Future<void> _syncNow() async {
    setState(() => _syncing = true);
    try {
      await ref.read(syncEngineProvider).syncNow();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Sync complete')),
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

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(recordingControllerProvider);
    final isRecording = state == RecordingState.recording;
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
            onPressed: () => Navigator.of(context).push<void>(
              MaterialPageRoute<void>(
                builder: (_) => const DumpsListScreen(),
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
            ] else
              const SizedBox(height: 32),
            GestureDetector(
              onTap: _toggleRecording,
              child: Container(
                width: 120,
                height: 120,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isRecording
                      ? Theme.of(context).colorScheme.error
                      : Theme.of(context).colorScheme.primary,
                ),
                child: Icon(
                  isRecording ? Icons.stop : Icons.mic,
                  size: 64,
                  color: Colors.white,
                ),
              ),
            ),
            const SizedBox(height: 24),
            Text(
              isRecording ? 'Tap to stop' : 'Tap to record',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 24),
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
      ],
      selected: {current},
      onSelectionChanged: onChanged == null ? null : (s) => onChanged!(s.first),
    );
  }
}
