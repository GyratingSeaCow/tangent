// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/local_db.dart';
import '../../data/recording_metadata.dart';
import '../../models/dump_mode.dart';
import '../../models/sync_status.dart';
import '../../services/local_transcription_coordinator.dart';
import '../../services/on_device_transcription.dart';
import '../../services/recording_playback.dart';
import '../home/home_screen.dart' show localDbProvider;
import '../home/home_providers.dart'
    show
        audioStorageProvider,
        localTranscriptionCoordinatorProvider,
        recordingPlaybackEngineFactoryProvider;

/// Watch a single dump by id.
final dumpByIdProvider =
    FutureProvider.family<DumpRow?, String>((ref, id) async {
  final db = ref.watch(localDbProvider);
  return db.getDump(id);
});

class DumpDetailScreen extends ConsumerStatefulWidget {
  final String dumpId;
  final String audioPath;
  final int durationSeconds;

  const DumpDetailScreen({
    super.key,
    required this.dumpId,
    required this.audioPath,
    required this.durationSeconds,
  });

  @override
  ConsumerState<DumpDetailScreen> createState() => _DumpDetailScreenState();
}

class _DumpDetailScreenState extends ConsumerState<DumpDetailScreen> {
  late final TextEditingController _titleController;
  late final RecordingPlaybackController _playbackController;
  bool _saving = false;
  String? _statusMessage;
  String? _statusError;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController();
    _playbackController = RecordingPlaybackController(
      engine: ref.read(recordingPlaybackEngineFactoryProvider)(),
    )..addListener(_onPlaybackChanged);
    unawaited(_playbackController.initialize(widget.audioPath));
    // Async-load the existing title.
    Future.microtask(() async {
      final db = ref.read(localDbProvider);
      final row = await db.getDump(widget.dumpId);
      if (row != null && mounted) {
        setState(() {
          _titleController.text = row.title;
        });
      }
    });
  }

  @override
  void dispose() {
    _playbackController
      ..removeListener(_onPlaybackChanged)
      ..dispose();
    _titleController.dispose();
    super.dispose();
  }

  void _onPlaybackChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _statusError = null;
      _statusMessage = 'Saving…';
    });
    try {
      final db = ref.read(localDbProvider);
      final existing = await db.getDump(widget.dumpId);
      if (existing == null) {
        throw StateError('Dump not found');
      }
      final updated = existing.copyWith(
        title: _titleController.text.trim(),
        updatedAt: DateTime.now(),
      );
      if (updated.title.isEmpty) throw StateError('Title cannot be empty');
      await ref.read(audioStorageProvider).writeMetadata(
            updated.id,
            dumpMetadata(updated),
          );
      await db.upsertDump(updated);
      if (mounted) {
        setState(() => _statusMessage = 'Saved');
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _statusError = 'Save failed: $e';
          _statusMessage = null;
        });
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _transcribe() async {
    setState(() {
      _statusError = null;
      _statusMessage = null;
    });
    final coordinator = ref.read(localTranscriptionCoordinatorProvider);
    try {
      await coordinator.transcribeDump(widget.dumpId);
      if (!mounted) return;
      ref.invalidate(dumpByIdProvider(widget.dumpId));
      if (coordinator.operation.status == LocalTranscriptionStatus.error) {
        setState(() {
          _statusError = 'Transcribe failed: ${coordinator.operation.error}';
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() => _statusError = 'Transcribe failed: $error');
      }
    }
  }

  void _cancelTranscription() {
    ref.read(localTranscriptionCoordinatorProvider).cancel(widget.dumpId);
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete dump?'),
        content: const Text('This removes the local record and audio file.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      final db = ref.read(localDbProvider);
      final audio = ref.read(audioStorageProvider);
      await audio.deleteFile(widget.dumpId);
      await db.deleteDump(widget.dumpId);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Delete failed: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final dumpAsync = ref.watch(dumpByIdProvider(widget.dumpId));
    final coordinator = ref.watch(localTranscriptionCoordinatorProvider);
    final operation = coordinator.operationFor(widget.dumpId);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Dump'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Delete',
            onPressed: _delete,
          ),
        ],
      ),
      body: dumpAsync.when(
        data: (row) => _buildBody(context, row, operation),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
      ),
    );
  }

  Widget _buildBody(
    BuildContext context,
    DumpRow? row,
    LocalTranscriptionOperation operation,
  ) {
    if (row == null) {
      return const Center(child: Text('Dump not found'));
    }

    final sync = SyncStatus.fromWire(row.syncStatus);
    final mode = DumpMode.fromWire(row.mode);
    final isCurrentOperation = operation.dumpId == widget.dumpId &&
        operation.status != LocalTranscriptionStatus.idle;
    final operationActive = isCurrentOperation && operation.isActive;
    final displayTranscript = isCurrentOperation &&
            operation.status == LocalTranscriptionStatus.complete
        ? operation.transcript
        : row.transcript;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        TextField(
          controller: _titleController,
          decoration: const InputDecoration(
            labelText: 'Title',
            border: OutlineInputBorder(),
          ),
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _save(),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          children: [
            _MetaChip(label: 'Mode: ${mode.displayName}'),
            _MetaChip(label: '${row.durationSeconds}s'),
            _MetaChip(label: sync.displayName, color: _syncColor(sync)),
          ],
        ),
        const SizedBox(height: 16),
        _RecordingPlaybackPanel(
          state: _playbackController.state,
          expectedDuration: Duration(seconds: row.durationSeconds),
          onToggle: _playbackController.togglePlayback,
          onSeek: _playbackController.seek,
        ),
        const SizedBox(height: 16),
        if (displayTranscript != null && displayTranscript.isNotEmpty) ...[
          Text(
            'Transcript',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: SelectableText(displayTranscript),
            ),
          ),
        ] else ...[
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                'No transcript yet. Tap Transcribe to queue.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          ),
        ],
        const SizedBox(height: 16),
        if (isCurrentOperation) ...[
          _LocalTranscriptionProgressPanel(
            operation: operation,
            onCancel: _cancelTranscription,
          ),
          const SizedBox(height: 16),
        ],
        if (_statusMessage != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              _statusMessage!,
              style: TextStyle(color: Theme.of(context).colorScheme.primary),
            ),
          ),
        if (_statusError != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              _statusError!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.save),
                label: const Text('Save'),
                onPressed: _saving ? null : _save,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton.icon(
                icon: operationActive
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.transcribe),
                label: Text(
                  switch (operation.status) {
                    LocalTranscriptionStatus.queued =>
                      'Queued #${operation.queuePosition}',
                    LocalTranscriptionStatus.running ||
                    LocalTranscriptionStatus.cancelling =>
                      'Working locally',
                    _ => 'Transcribe',
                  },
                ),
                onPressed: operationActive ||
                        operation.status == LocalTranscriptionStatus.queued
                    ? null
                    : _transcribe,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Color? _syncColor(SyncStatus s) => switch (s) {
        SyncStatus.synced => Colors.green,
        SyncStatus.syncing => Colors.blue,
        SyncStatus.pending => Colors.orange,
        SyncStatus.failed => Colors.red,
        SyncStatus.localOnly => Colors.grey,
      };
}

class _RecordingPlaybackPanel extends StatelessWidget {
  const _RecordingPlaybackPanel({
    required this.state,
    required this.expectedDuration,
    required this.onToggle,
    required this.onSeek,
  });

  final RecordingPlaybackState state;
  final Duration expectedDuration;
  final Future<void> Function() onToggle;
  final Future<void> Function(Duration position) onSeek;

  @override
  Widget build(BuildContext context) {
    final duration =
        state.duration > Duration.zero ? state.duration : expectedDuration;
    final durationSeconds = duration.inMilliseconds / 1000;
    final positionSeconds = state.position.inMilliseconds
            .clamp(0, duration.inMilliseconds)
            .toDouble() /
        1000;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Recording playback',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                IconButton.filledTonal(
                  tooltip: state.playing ? 'Pause recording' : 'Play recording',
                  onPressed: state.loading || state.error != null
                      ? null
                      : () => unawaited(onToggle()),
                  icon: state.loading
                      ? const SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(state.playing ? Icons.pause : Icons.play_arrow),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Slider(
                    key: const ValueKey('recording-seek-bar'),
                    value: positionSeconds,
                    max: durationSeconds > 0 ? durationSeconds : 1,
                    onChanged: state.loading || state.error != null
                        ? null
                        : (seconds) => unawaited(
                              onSeek(
                                Duration(
                                  milliseconds: (seconds * 1000).round(),
                                ),
                              ),
                            ),
                    onChangeEnd: state.loading || state.error != null
                        ? null
                        : (seconds) => unawaited(
                              onSeek(
                                Duration(
                                  milliseconds: (seconds * 1000).round(),
                                ),
                              ),
                            ),
                  ),
                ),
              ],
            ),
            Text(
              '${_formatMediaTime(state.position)} / ${_formatMediaTime(duration)}',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.labelLarge,
            ),
            if (state.error != null) ...[
              const SizedBox(height: 8),
              Text(
                state.error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _formatMediaTime(Duration value) {
    final hours = value.inHours;
    final minutes = (value.inMinutes % 60).toString().padLeft(2, '0');
    final seconds = (value.inSeconds % 60).toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }
}

class _LocalTranscriptionProgressPanel extends StatefulWidget {
  const _LocalTranscriptionProgressPanel({
    required this.operation,
    required this.onCancel,
  });

  final LocalTranscriptionOperation operation;
  final VoidCallback onCancel;

  @override
  State<_LocalTranscriptionProgressPanel> createState() =>
      _LocalTranscriptionProgressPanelState();
}

class _LocalTranscriptionProgressPanelState
    extends State<_LocalTranscriptionProgressPanel> {
  Timer? _elapsedTimer;

  @override
  void initState() {
    super.initState();
    _syncTimer();
  }

  @override
  void didUpdateWidget(_LocalTranscriptionProgressPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncTimer();
  }

  void _syncTimer() {
    if (widget.operation.isActive && _elapsedTimer == null) {
      _elapsedTimer = Timer.periodic(
        const Duration(seconds: 1),
        (_) {
          if (mounted) setState(() {});
        },
      );
    } else if (!widget.operation.isActive) {
      _elapsedTimer?.cancel();
      _elapsedTimer = null;
    }
  }

  @override
  void dispose() {
    _elapsedTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final operation = widget.operation;
    final progress = operation.progress;
    final stage = progress?.stage;
    final title = switch (operation.status) {
      LocalTranscriptionStatus.queued =>
        'Queued for local transcription #${operation.queuePosition}',
      LocalTranscriptionStatus.cancelling => 'Cancelling local transcription',
      LocalTranscriptionStatus.complete => 'Transcription complete',
      LocalTranscriptionStatus.error => 'Local transcription failed',
      _ => switch (stage) {
          LocalTranscriptionStage.preparingAudio => 'Preparing recording',
          LocalTranscriptionStage.downloadingModel =>
            'Downloading Whisper large-v3-turbo',
          LocalTranscriptionStage.loadingModel =>
            'Loading Whisper large-v3-turbo',
          LocalTranscriptionStage.transcribing => 'Transcribing on this phone',
          LocalTranscriptionStage.complete => 'Transcription complete',
          null => 'Starting local transcription',
        },
    };
    final fraction = stage == LocalTranscriptionStage.downloadingModel ||
            stage == LocalTranscriptionStage.transcribing
        ? progress?.fraction
        : null;
    final startedAt = operation.startedAt;
    final elapsed = startedAt == null
        ? Duration.zero
        : DateTime.now().difference(startedAt);

    return Semantics(
      liveRegion: true,
      label: title,
      child: Card(
        color: Theme.of(context).colorScheme.secondaryContainer,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(_detailText(operation, elapsed)),
              if (operation.isActive ||
                  operation.status == LocalTranscriptionStatus.queued) ...[
                const SizedBox(height: 12),
                if (operation.isActive)
                  LinearProgressIndicator(value: fraction),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed:
                      operation.status == LocalTranscriptionStatus.cancelling
                          ? null
                          : widget.onCancel,
                  icon: const Icon(Icons.cancel_outlined),
                  label: Text(
                    operation.status == LocalTranscriptionStatus.cancelling
                        ? 'Cancelling…'
                        : 'Cancel',
                  ),
                ),
              ],
              if (operation.status == LocalTranscriptionStatus.error &&
                  operation.error != null) ...[
                const SizedBox(height: 8),
                Text(
                  operation.error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  String _detailText(
    LocalTranscriptionOperation operation,
    Duration elapsed,
  ) {
    final progress = operation.progress;
    final elapsedText = _formatElapsed(elapsed);
    return switch (progress?.stage) {
      LocalTranscriptionStage.downloadingModel =>
        'Whisper large-v3-turbo · 1.5 GB · one-time verified download\n'
            '${progress?.fraction == null ? 'Receiving model data' : '${((progress!.fraction!) * 100).round()}% downloaded'} · Elapsed $elapsedText',
      LocalTranscriptionStage.loadingModel =>
        'Whisper large-v3-turbo · 1.5 GB · on this phone\n'
            'First load can take roughly a minute while Tangent initializes the model in memory. · Elapsed $elapsedText',
      LocalTranscriptionStage.transcribing =>
        '${progress?.fraction == null ? 'Processing speech locally' : '${((progress!.fraction!) * 100).round()}% processed'} · Elapsed $elapsedText',
      LocalTranscriptionStage.preparingAudio =>
        'Decoding the recording locally · Elapsed $elapsedText',
      LocalTranscriptionStage.complete => 'Saved locally',
      null => operation.status == LocalTranscriptionStatus.error
          ? 'The recording was preserved.'
          : operation.status == LocalTranscriptionStatus.queued
              ? 'Waiting for the active recording to finish. You can leave this screen.'
              : 'Elapsed $elapsedText',
    };
  }

  String _formatElapsed(Duration value) {
    final minutes = value.inMinutes.toString().padLeft(2, '0');
    final seconds = (value.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}

class _MetaChip extends StatelessWidget {
  final String label;
  final Color? color;
  const _MetaChip({required this.label, this.color});

  @override
  Widget build(BuildContext context) {
    return Chip(
      label: Text(label),
      backgroundColor: color?.withValues(alpha: 0.15),
      side: BorderSide(color: color ?? Theme.of(context).colorScheme.outline),
    );
  }
}
