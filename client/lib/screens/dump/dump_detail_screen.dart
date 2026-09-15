// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/audio_storage.dart';
import '../../data/local_db.dart';
import '../../data/recording_metadata.dart';
import '../../models/dump_mode.dart';
import '../../models/sync_status.dart';
import '../../models/transcription_status.dart';
import '../../services/meeting_notes_processor.dart';
import '../../services/recording_playback.dart';
import '../home/home_screen.dart' show localDbProvider;
import '../home/home_providers.dart'
    show
        audioStorageProvider,
        recordingPlaybackEngineFactoryProvider,
        serverTranscriptionServiceProvider;

/// Watch a single dump by id.
final dumpByIdProvider =
    StreamProvider.autoDispose.family<DumpRow?, String>((ref, id) {
  final db = ref.watch(localDbProvider);
  return db.watchDump(id);
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
  late final TextEditingController _transcriptController;
  late final RecordingPlaybackController _playbackController;
  bool _saving = false;
  bool _savingTranscript = false;
  bool _transcriptDirty = false;
  String? _editorBaseTranscript;
  int? _editorBaseAttempt;
  String? _editorBaseRequestId;
  String? _statusMessage;
  String? _statusError;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController();
    _transcriptController = TextEditingController();
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
    _transcriptController.dispose();
    super.dispose();
  }

  void _onPlaybackChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _writeLatestMetadata(LocalDb db, AudioStorage audio) {
    return audio.runSerializedMetadataWrite<void>(
      widget.dumpId,
      (write) async {
        final latest = await db.getDump(widget.dumpId);
        if (latest == null) throw StateError('Dump not found');
        final pending =
            latest.transcriptionError?.startsWith('sidecar_sync_pending:') ??
                false;
        final restoredError =
            LocalDb.errorAfterSidecarSync(latest.transcriptionError);
        final metadata = dumpMetadata(latest);
        if (pending) metadata['transcriptionError'] = restoredError;
        await write(metadata);
        if (pending) {
          await db.updateTranscriptionSidecarError(
            latest.id,
            attempt: latest.transcriptionAttempt,
            requestId: latest.transcriptionRequestId,
            error: restoredError,
            now: DateTime.now().toUtc(),
            expectedTranscript: latest.transcript,
            expectedError: latest.transcriptionError,
          );
        }
      },
    );
  }

  void _syncTranscriptEditor(DumpRow row) {
    final transcript = row.transcript;
    if (transcript == null || transcript.isEmpty) return;
    final revisionChanged = _editorBaseTranscript != transcript ||
        _editorBaseAttempt != row.transcriptionAttempt ||
        _editorBaseRequestId != row.transcriptionRequestId;
    if (_editorBaseTranscript == null ||
        (!_savingTranscript && !_transcriptDirty && revisionChanged)) {
      _transcriptController.value = TextEditingValue(
        text: transcript,
        selection: TextSelection.collapsed(offset: transcript.length),
      );
      _editorBaseTranscript = transcript;
      _editorBaseAttempt = row.transcriptionAttempt;
      _editorBaseRequestId = row.transcriptionRequestId;
      _transcriptDirty = false;
    }
  }

  void _onTranscriptChanged(String value) {
    final dirty = value != _editorBaseTranscript;
    setState(() => _transcriptDirty = dirty);
  }

  bool _manualSidecarPending = false;

  Future<void> _saveTranscript() async {
    final expectedTranscript = _editorBaseTranscript;
    final expectedAttempt = _editorBaseAttempt;
    if (expectedTranscript == null || expectedAttempt == null) return;
    final transcript = _transcriptController.text;
    if (transcript.trim().isEmpty) return;
    setState(() {
      _savingTranscript = true;
      _statusError = null;
      _statusMessage = 'Saving transcript…';
    });
    try {
      final db = ref.read(localDbProvider);
      final audio = ref.read(audioStorageProvider);
      final saved = await db.updateDumpTranscript(
        widget.dumpId,
        expectedTranscript: expectedTranscript,
        expectedTranscriptionAttempt: expectedAttempt,
        expectedTranscriptionRequestId: _editorBaseRequestId,
        transcript: transcript,
        now: DateTime.now().toUtc(),
      );
      // SQLite owns this revision even when the following sidecar write fails.
      // A retry must compare against it, not against the old editor base.
      if (mounted) {
        setState(() {
          _editorBaseTranscript = saved.transcript;
          _editorBaseAttempt = saved.transcriptionAttempt;
          _editorBaseRequestId = saved.transcriptionRequestId;
          _transcriptDirty = _transcriptController.text != saved.transcript;
          _manualSidecarPending = true;
        });
      }
      await _writeLatestMetadata(db, audio);
      if (mounted) {
        setState(() {
          _manualSidecarPending = false;
          _editorBaseTranscript = saved.transcript;
          _editorBaseAttempt = saved.transcriptionAttempt;
          _editorBaseRequestId = saved.transcriptionRequestId;
          _transcriptDirty = _transcriptController.text != saved.transcript;
          _statusMessage = _transcriptDirty
              ? 'Previous edit saved; newer changes are unsaved'
              : 'Transcript saved';
        });
      }
    } on StateError {
      if (mounted) {
        setState(() {
          _statusMessage = null;
          _statusError =
              'Transcript not saved: a newer transcription or recording change won. Your draft is still here.';
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _statusMessage = null;
          _statusError = 'Transcript save failed: $error';
        });
      }
    } finally {
      // The app-scoped durable-row observer owns repair, even after navigation
      // or client replacement. mounted guards only the editor's UI state.
      if (mounted) setState(() => _savingTranscript = false);
    }
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _statusError = null;
      _statusMessage = 'Saving…';
    });
    try {
      final db = ref.read(localDbProvider);
      final audio = ref.read(audioStorageProvider);
      final title = _titleController.text.trim();
      if (title.isEmpty) throw StateError('Title cannot be empty');
      await db.updateDumpTitle(
        widget.dumpId,
        title: title,
        now: DateTime.now().toUtc(),
      );
      await _writeLatestMetadata(db, audio);
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

  void _requestTranscription(DumpRow row) {
    if (row.transcript?.trim().isNotEmpty ?? false) {
      showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Overwrite transcript?'),
          content: const Text(
            'The current transcript stays visible while replacement transcription runs. It is replaced only if the new transcription succeeds.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.of(dialogContext).pop();
                unawaited(_runTranscription());
              },
              child: const Text('Overwrite'),
            ),
          ],
        ),
      );
      return;
    }
    unawaited(_runTranscription());
  }

  Future<void> _runTranscription() async {
    if (!mounted) return;
    setState(() {
      _statusError = null;
      _statusMessage = null;
    });
    final service = ref.read(serverTranscriptionServiceProvider);
    try {
      await service.transcribeDump(widget.dumpId);
    } catch (error) {
      if (mounted) {
        setState(() => _statusError = 'Transcribe failed: $error');
      }
    }
  }

  /// Regenerate secretary notes from the existing transcript without
  /// re-running Whisper. Preserves the raw transcript; only writes to
  /// `meeting_notes` and the public sidecar.
  Future<void> _regenerateMeetingNotes(String transcript) async {
    final db = ref.read(localDbProvider);
    final audio = ref.read(audioStorageProvider);
    setState(() {
      _statusError = null;
      _statusMessage = 'Generating meeting notes…';
    });
    try {
      final existing = await db.getDump(widget.dumpId);
      if (existing == null) throw StateError('Dump not found');
      const processor = MeetingNotesProcessor();
      final notes = processor.process(
        title: existing.title,
        transcript: transcript,
      );
      await db.updateDumpMeetingNotes(
        widget.dumpId,
        expectedTitle: existing.title,
        expectedTranscript: transcript,
        expectedTranscriptionAttempt: existing.transcriptionAttempt,
        expectedTranscriptionRequestId: existing.transcriptionRequestId,
        meetingNotes: notes,
        now: DateTime.now().toUtc(),
      );
      await _writeLatestMetadata(db, audio);
      ref.invalidate(dumpByIdProvider(widget.dumpId));
      if (mounted) {
        setState(() => _statusMessage = 'Meeting notes updated');
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _statusError = 'Generate notes failed: $e';
          _statusMessage = null;
        });
      }
    }
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
    final rowAsync = ref.watch(dumpByIdProvider(widget.dumpId));

    return Scaffold(
      appBar: AppBar(
        title: Text(_modeTitle(rowAsync.valueOrNull)),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Delete',
            onPressed: _delete,
          ),
        ],
      ),
      body: rowAsync.when(
        data: (row) => _buildBody(context, row),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
      ),
    );
  }

  String _modeTitle(DumpRow? row) {
    if (row == null) return 'Dump';
    final mode = DumpMode.fromWire(row.mode);
    return mode == DumpMode.meeting ? 'Meeting' : 'Dump';
  }

  Widget _buildBody(BuildContext context, DumpRow? row) {
    if (row == null) {
      return const Center(child: Text('Dump not found'));
    }

    _syncTranscriptEditor(row);
    final sync = SyncStatus.fromWire(row.syncStatus);
    final mode = DumpMode.fromWire(row.mode);
    final transcription = TranscriptionStatus.fromWire(row.transcriptionStatus);
    final operationActive = transcription.isInProgress;
    final displayTranscript = row.transcript;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        TextField(
          key: ValueKey('title-editor-${widget.dumpId}'),
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
        if (mode == DumpMode.meeting &&
            row.meetingNotes != null &&
            row.meetingNotes!.trim().isNotEmpty) ...[
          Text(
            'Meeting Notes',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: SelectableText(row.meetingNotes!),
            ),
          ),
          const SizedBox(height: 8),
          if (displayTranscript != null && displayTranscript.isNotEmpty)
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                key: ValueKey('regenerate-notes-${widget.dumpId}'),
                icon: const Icon(Icons.refresh),
                label: const Text('Regenerate notes'),
                onPressed: () => _regenerateMeetingNotes(displayTranscript),
              ),
            ),
          const SizedBox(height: 16),
        ],
        if (displayTranscript != null && displayTranscript.isNotEmpty) ...[
          Text(
            mode == DumpMode.meeting ? 'Raw Transcript' : 'Transcript',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          TextField(
            key: ValueKey('transcript-editor-${widget.dumpId}'),
            controller: _transcriptController,
            keyboardType: TextInputType.multiline,
            minLines: 6,
            maxLines: null,
            onChanged: _onTranscriptChanged,
            decoration: InputDecoration(
              alignLabelWithHint: true,
              border: const OutlineInputBorder(),
              errorText: _transcriptController.text.isNotEmpty &&
                      _transcriptController.text.trim().isEmpty
                  ? 'Transcript cannot be blank'
                  : null,
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              key: ValueKey('save-transcript-${widget.dumpId}'),
              icon: _savingTranscript
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save),
              label: const Text('Save transcript'),
              onPressed: (transcription == TranscriptionStatus.completed ||
                          transcription == TranscriptionStatus.failed) &&
                      (_transcriptDirty || _manualSidecarPending) &&
                      _transcriptController.text.trim().isNotEmpty &&
                      !_savingTranscript
                  ? _saveTranscript
                  : null,
            ),
          ),
          if (mode == DumpMode.meeting &&
              (row.meetingNotes == null ||
                  row.meetingNotes!.trim().isEmpty)) ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: ValueKey('generate-notes-${widget.dumpId}'),
              icon: const Icon(Icons.auto_awesome),
              label: const Text('Generate meeting notes'),
              onPressed: () => _regenerateMeetingNotes(displayTranscript),
            ),
          ],
        ] else ...[
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                'No transcript yet. Tap Transcribe to upload to your server.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          ),
        ],
        const SizedBox(height: 16),
        if (operationActive || transcription == TranscriptionStatus.failed) ...[
          _ServerTranscriptionProgressPanel(
            row: row,
            status: transcription,
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
                key: ValueKey('transcribe-${widget.dumpId}'),
                icon: operationActive
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.cloud_upload),
                label: Text(
                  switch (transcription) {
                    TranscriptionStatus.uploading => 'Uploading…',
                    TranscriptionStatus.queued => 'Queued',
                    TranscriptionStatus.running => 'Transcribing on server',
                    TranscriptionStatus.completed => 'Transcribe again',
                    TranscriptionStatus.failed => 'Retry',
                    TranscriptionStatus.notTranscribed => 'Transcribe',
                  },
                ),
                onPressed:
                    operationActive ? null : () => _requestTranscription(row),
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

class _ServerTranscriptionProgressPanel extends StatefulWidget {
  const _ServerTranscriptionProgressPanel({
    required this.row,
    required this.status,
  });

  final DumpRow row;
  final TranscriptionStatus status;

  @override
  State<_ServerTranscriptionProgressPanel> createState() =>
      _ServerTranscriptionProgressPanelState();
}

class _ServerTranscriptionProgressPanelState
    extends State<_ServerTranscriptionProgressPanel> {
  Timer? _elapsedTimer;

  @override
  void initState() {
    super.initState();
    _syncTimer();
  }

  @override
  void didUpdateWidget(_ServerTranscriptionProgressPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncTimer();
  }

  void _syncTimer() {
    if (widget.status.isInProgress && _elapsedTimer == null) {
      _elapsedTimer = Timer.periodic(
        const Duration(seconds: 1),
        (_) {
          if (mounted) setState(() {});
        },
      );
    } else if (!widget.status.isInProgress) {
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
    final status = widget.status;
    final title = switch (status) {
      TranscriptionStatus.uploading => 'Uploading audio to your server',
      TranscriptionStatus.queued => 'Queued on your server',
      TranscriptionStatus.running => 'Transcribing on your server',
      TranscriptionStatus.failed => 'Server transcription failed',
      TranscriptionStatus.completed => 'Transcription complete',
      TranscriptionStatus.notTranscribed => 'Not transcribed',
    };
    final startedAt = widget.row.transcriptionStartedAt;
    final rawElapsed = startedAt == null
        ? Duration.zero
        : DateTime.now().difference(startedAt);
    final elapsed = rawElapsed.isNegative ? Duration.zero : rawElapsed;

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
              Text(_detailText(status, elapsed)),
              if (status.isInProgress) ...[
                const SizedBox(height: 12),
                const LinearProgressIndicator(),
              ],
              if (status == TranscriptionStatus.failed &&
                  widget.row.transcriptionError != null) ...[
                const SizedBox(height: 8),
                Text(
                  widget.row.transcriptionError!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  String _detailText(TranscriptionStatus status, Duration elapsed) {
    final elapsedText = _formatElapsed(elapsed);
    return switch (status) {
      TranscriptionStatus.uploading =>
        'Streaming the preserved recording to your personal Docker container · Elapsed $elapsedText',
      TranscriptionStatus.queued =>
        'Waiting for the server worker · Elapsed $elapsedText',
      TranscriptionStatus.running =>
        'The server is decoding audio with faster-whisper. This continues if you leave this screen · Elapsed $elapsedText',
      TranscriptionStatus.failed =>
        'The previous transcript and raw recording are preserved on this device.',
      TranscriptionStatus.completed => 'Saved locally',
      TranscriptionStatus.notTranscribed => 'No transcription attempt yet',
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
