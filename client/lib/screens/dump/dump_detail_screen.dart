// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../data/local_db.dart';
import '../../data/manual_transcript_publication.dart';
import '../../data/recording_metadata.dart';
import '../../data/storage/storage_contract.dart';
import '../../data/storage/storage_providers.dart';
import '../../models/dump_mode.dart';
import '../../models/sync_status.dart';
import '../../models/transcription_status.dart';
import '../../services/meeting_notes_processor.dart';
import '../../services/recording_playback.dart';
import '../../services/transcript_alignment.dart'
    show TranscriptAlignment, alignTranscript;
import '../../services/transcript_search.dart'
    show alignedTokenAt, findTranscriptMatches, matchSeekSeconds;
import '../../services/transcript_timings.dart';
import '../../widgets/listen_transcript_view.dart';
import '../../widgets/waveform_scrubber.dart';
import 'dumps_providers.dart';
import 'summarize_flow.dart';
import '../../services/transcription_notifications.dart'
    show describedWhisperModel;
import 'local_deletion_presentation.dart';
import 'sync_status_presentation.dart';
import '../home/home_screen.dart' show localDbProvider;
import '../settings/settings_screen.dart' show settingsStoreProvider;
import '../settings/ai_summaries_section.dart'
    show summariesClientProvider, summariesEnabledProvider;
import '../home/home_providers.dart'
    show
        recordingPlaybackEngineFactoryProvider,
        serverTranscriptionServiceProvider;

/// Padding for the recording screen's scrolling body.
///
/// The Save / Transcribe again row is the LAST child of that list, so nothing
/// below it pushes it clear of the system navigation bar: without reserving
/// the inset the Fold's taskbar sits on top of the buttons and swallows most
/// of "Save".
///
/// Reads `viewPadding` rather than `padding` deliberately — Flutter zeroes
/// `padding` where the on-screen keyboard covers the inset, so using it would
/// collapse the reservation the moment the title editor is focused and drop
/// the buttons back behind the bar mid-edit.
EdgeInsets actionRowSafePadding(BuildContext context) => EdgeInsets.fromLTRB(
      16,
      16,
      16,
      16 + MediaQuery.viewPaddingOf(context).bottom,
    );

/// Watch a single dump by id.
final dumpByIdProvider =
    StreamProvider.autoDispose.family<DumpRow?, String>((ref, id) {
  final db = ref.watch(localDbProvider);
  return db.watchDump(id);
});

/// Markdown styling for the AI summary body: headings are label-sized so
/// the server's '## Summary' / '## Action items' sections read as compact
/// section labels inside a card, never as page titles competing with the
/// recording's own title; body copy matches the transcript.
MarkdownStyleSheet _summaryStyleSheet(ThemeData theme) {
  final TextTheme text = theme.textTheme;
  final TextStyle? heading = text.titleSmall;
  return MarkdownStyleSheet.fromTheme(theme).copyWith(
    p: text.bodyMedium,
    h1: heading,
    h2: heading,
    h3: heading,
    h4: heading,
    h5: heading,
    h6: heading,
    listBullet: text.bodyMedium,
  );
}

class DumpDetailScreen extends ConsumerStatefulWidget {
  final String dumpId;
  final String audioPath;
  final int durationSeconds;

  /// The list's search query when this screen was opened from a search
  /// result (search-depth spec §2). Non-blank: the transcript's hits are
  /// highlighted and a match bar steps through them. Screen-local, never
  /// persisted.
  final String? initialSearchQuery;

  const DumpDetailScreen({
    super.key,
    required this.dumpId,
    required this.audioPath,
    required this.durationSeconds,
    this.initialSearchQuery,
  });

  @override
  ConsumerState<DumpDetailScreen> createState() => _DumpDetailScreenState();
}

class _DumpDetailScreenState extends ConsumerState<DumpDetailScreen> {
  late final TextEditingController _titleController;
  late final TextEditingController _transcriptController;

  /// Search hits in the transcript the editor currently holds, and which
  /// one the match bar points at. Recomputed whenever that text changes.
  List<TextRange> _matches = const <TextRange>[];
  int _matchIndex = 0;
  String? _matchedText;
  final GlobalKey _matchBarKey = GlobalKey();

  /// Alignment cached per (text, timings) pair: matches map to word
  /// indexes through it, and build runs on every playhead tick.
  TranscriptAlignment? _alignment;
  String? _alignmentText;
  TranscriptTimings? _alignmentTimings;
  RecordingPlaybackController? _playbackController;
  PlaybackLease? _playbackLease;
  late Future<void> _playbackInitialization;
  bool _playbackOpening = true;
  bool _canRetryPlayback = false;
  bool _deleteBusy = false;
  int _deletionPreviewGeneration = 0;
  String? _deletionPreviewError;
  final _deletionRecovery = LocalDeletionRecoveryState();
  BulkDeletionResult? get _deletionResult => _deletionRecovery.latest;
  String? _playbackError;
  bool _closing = false;
  bool _saving = false;
  bool _savingTranscript = false;
  bool _transcriptDirty = false;

  /// Option B: meeting transcripts start collapsed behind a summary header.
  bool _transcriptExpanded = false;

  /// Tap-to-hear (spec §3): Edit | Listen. Null until the row is first
  /// seen, then defaults from `defaultListenMode` and sticks to the user's
  /// last choice for this screen. Only ever true when timings exist.
  bool? _listenMode;

  /// The playhead the Listen view follows. Fed from the playback
  /// controller's state on every change (not a stream: the view wants a
  /// ValueListenable it can subscribe to synchronously).
  final ValueNotifier<Duration> _playhead = ValueNotifier(Duration.zero);

  /// Parsed once per distinct timings payload; parsing is cheap but the
  /// build runs on every playhead tick.
  String? _timingsRaw;
  TranscriptTimings? _timings;

  TranscriptTimings? _timingsFor(DumpRow row) {
    final raw = row.transcriptTimings;
    if (raw != _timingsRaw) {
      _timingsRaw = raw;
      _timings = TranscriptTimings.parse(raw);
    }
    return _timings;
  }

  /// Header summary for the collapsed transcript: duration + word count,
  /// with `[MM:SS]`-style paragraph markers excluded from the count.
  String _transcriptSummary(DumpRow row, String transcript) {
    final words = transcript
        .replaceAll(RegExp(r'\[\d{1,2}:\d{2}(?::\d{2})?\]'), ' ')
        .trim()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .length;
    final minutes = row.durationSeconds ~/ 60;
    final seconds = row.durationSeconds % 60;
    final duration = '$minutes:${seconds.toString().padLeft(2, '0')}';
    return '$duration · $words words';
  }

  String? _editorBaseTranscript;
  int? _editorBaseAttempt;
  String? _editorBaseRequestId;
  String? _statusMessage;
  String? _statusError;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController();
    _transcriptController = _MatchHighlightController(
      matches: () => _matches,
      current: () => _matchIndex,
    );
    // Opened from a search hit: a collapsed meeting transcript would hide
    // the very thing the user came for.
    if (_searchQuery != null) _transcriptExpanded = true;
    _playbackInitialization = _initializePlayback();
    unawaited(_discoverDeletion());
    final db = ref.read(localDbProvider);
    // Async-load the existing title.
    Future.microtask(() async {
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
    _closing = true;
    final playback = _playbackController;
    if (playback != null) {
      playback.removeListener(_onPlaybackChanged);
      playback.dispose();
    } else {
      unawaited(_playbackLease?.close());
    }
    _titleController.dispose();
    _transcriptController.dispose();
    _playhead.dispose();
    super.dispose();
  }

  void _onPlaybackChanged() {
    final p = _playbackController?.state.position;
    if (p != null && p != _playhead.value) _playhead.value = p;
    if (mounted) setState(() {});
  }

  Future<void> _initializePlayback() async {
    final DumpRow? existing;
    try {
      existing = await ref.read(localDbProvider).getDump(widget.dumpId);
    } catch (error) {
      if (mounted && !_closing) {
        setState(() => _playbackError = 'Playback unavailable: $error');
      }
      if (mounted) setState(() => _playbackOpening = false);
      return;
    }
    if (_closing || !mounted) return;
    if (existing != null &&
        DumpMode.fromWire(existing.mode) == DumpMode.textNote) {
      // Text notes publish markdown into the primary-content slot, not
      // audio: never construct a playback engine for them.
      setState(() => _playbackOpening = false);
      return;
    }
    final raw = ref.read(recordingPlaybackEngineFactoryProvider)();
    final access = ref.read(recordingAccessProvider);
    try {
      final binding =
          await ref.read(localDbProvider).boundRecording(widget.dumpId);
      if (binding == null) {
        // No local binding. The common, non-broken reason is that this
        // recording was made on another device and only its metadata has
        // synced here — say that, and point at the download, instead of
        // the internal 'storage is unresolved' wording.
        if (existing != null && dumpNeedsAudioDownload(existing)) {
          if (mounted && !_closing) {
            setState(
              () => _playbackError =
                  'Audio is on the server. Download it to play.',
            );
          }
          return;
        }
        throw StateError('Recording storage is unresolved');
      }
      final opened = await access.openPlayback(binding.key, raw);
      final lease = switch (opened) {
        Ok<PlaybackLease>(:final value) => value,
        Fail<PlaybackLease>(:final problem) => throw StorageFault(problem),
      };
      if (_closing || !mounted) {
        await lease.close();
        return;
      }
      final controller = RecordingPlaybackController(engine: lease.engine)
        ..addListener(_onPlaybackChanged);
      _playbackLease = lease;
      _playbackController = controller;
      setState(() {});
      await controller.initialize(lease.source);
    } catch (error) {
      await raw.dispose();
      if (mounted && !_closing) {
        setState(() => _playbackError = 'Playback unavailable: $error');
      }
    } finally {
      if (mounted) setState(() => _playbackOpening = false);
    }
  }

  Future<void> _retryPlayback() async {
    if (_deleteBusy || _playbackOpening || !_canRetryPlayback || !mounted) {
      return;
    }
    setState(() {
      _playbackOpening = true;
      _canRetryPlayback = false;
    });
    final service = ref.read(localDeletionServiceProvider);
    _playbackInitialization = () async {
      try {
        final preview = switch (await service.preview({widget.dumpId})) {
          Ok<DeletionPreview>(:final value) => value,
          Fail<DeletionPreview>(:final problem) => throw StorageFault(problem),
        };
        if (!mounted) return;
        final target = preview.targets.single;
        if (target.binding == null ||
            !{
              Eligibility.eligible,
              Eligibility.busy,
              Eligibility.nonterminal,
              Eligibility.syncing,
              Eligibility.publicationPending,
            }.contains(target.eligibility)) {
          setState(
            () => _playbackError =
                'Playback unavailable: ${target.eligibility.name}. Resolve local storage or retry pending local deletion.',
          );
          return;
        }
        // The previous engine/lease has actually closed. Only this explicit
        // user action may start a fresh binding lookup + engine on this route.
        _closing = false;
        _playbackError = null;
        await _initializePlayback();
      } catch (e) {
        if (mounted) {
          setState(() => _playbackError = 'Playback unavailable: $e');
        }
      } finally {
        if (mounted) setState(() => _playbackOpening = false);
      }
    }();
    await _playbackInitialization;
  }

  Future<void> _playbackAfterFailedDelete(LocalDeletionService service) async {
    try {
      final preview = switch (await service.preview({widget.dumpId})) {
        Ok<DeletionPreview>(:final value) => value,
        Fail<DeletionPreview>(:final problem) => throw StorageFault(problem),
      };
      if (!mounted) return;
      final target = preview.targets.single;
      final playable = target.binding != null &&
          {
            Eligibility.eligible,
            Eligibility.busy,
            Eligibility.nonterminal,
            Eligibility.syncing,
            Eligibility.publicationPending,
          }.contains(target.eligibility);
      setState(() {
        _canRetryPlayback = playable;
        _playbackError = playable
            ? 'Playback stopped after local deletion was blocked.'
            : target.eligibility == Eligibility.retryOnly
                ? 'Playback unavailable while local deletion is pending. Retry failed local deletion.'
                : 'Playback unavailable: ${target.eligibility.name}. Resolve local storage first.';
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _canRetryPlayback = false;
          _playbackError = 'Playback unavailable: $e';
        });
      }
    }
  }

  Future<void> _closePlayback() async {
    _closing = true;
    await _playbackInitialization;
    final controller = _playbackController;
    final lease = _playbackLease;
    _playbackController = null;
    _playbackLease = null;
    _playbackError = 'Playback stopped for local deletion.';
    if (mounted) setState(() {});
    if (controller != null) {
      controller.removeListener(_onPlaybackChanged);
      await controller.close();
    }
    if (lease != null) await lease.close();
  }

  Future<T> _withEdit<T>(Future<T> Function(RecordingKey key) action) async {
    final outcome = await ref
        .read(recordingMutationsProvider)
        .acquire(widget.dumpId, UseKind.edit);
    final lease = switch (outcome) {
      Ok<UseLease>(:final value) => value,
      Fail<UseLease>(:final problem) => throw StorageFault(problem),
    };
    try {
      return await action(lease.key);
    } finally {
      await lease.close();
    }
  }

  Future<void> _writeLatestMetadata(
    LocalDb db,
    RecordingKey key,
    RecordingAccess access,
  ) {
    return access.runSerializedMetadataWrite<void>(
      key,
      (writer) async {
        final latest = await db.getDump(widget.dumpId);
        if (latest == null) throw StateError('Dump not found');
        final pending =
            latest.transcriptionError?.startsWith('sidecar_sync_pending:') ??
                false;
        final restoredError =
            LocalDb.errorAfterSidecarSync(latest.transcriptionError);
        final metadata = dumpMetadata(latest);
        if (pending) metadata['transcriptionError'] = restoredError;
        await writer.write(metadata);
        if (pending) {
          await db.updateTranscriptionSidecarError(
            latest.id,
            storageKey: writer.binding.key,
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

  String? get _searchQuery {
    final q = widget.initialSearchQuery?.trim();
    return q == null || q.isEmpty ? null : q;
  }

  /// Keeps [_matches] in step with the editor text. Cheap enough to call
  /// from build: it only rescans when the text actually changed.
  void _recomputeMatches() {
    final query = _searchQuery;
    final text = _transcriptController.text;
    if (query == null || text == _matchedText) return;
    _matchedText = text;
    _matches = findTranscriptMatches(text, query);
    _matchIndex =
        _matches.isEmpty ? 0 : _matchIndex.clamp(0, _matches.length - 1);
  }

  TranscriptAlignment? _alignmentFor(String text, TranscriptTimings? timings) {
    if (timings == null || !timings.hasWords) return null;
    if (text != _alignmentText || timings != _alignmentTimings) {
      _alignmentText = text;
      _alignmentTimings = timings;
      _alignment = alignTranscript(text, timings);
    }
    return _alignment;
  }

  /// Start of the timed word under the current match, or null when there
  /// are no word timings or the word was edited in (no moment to play).
  double? _currentMatchSeekSeconds(TranscriptTimings? timings) {
    if (_matches.isEmpty) return null;
    final text = _transcriptController.text;
    final alignment = _alignmentFor(text, timings);
    if (alignment == null) return null;
    return matchSeekSeconds(alignment, text, _matches[_matchIndex]);
  }

  /// Token index for each match, for Listen mode's highlight.
  ({Set<int> all, int? current}) _matchWords(TranscriptTimings? timings) {
    final text = _transcriptController.text;
    final alignment = _alignmentFor(text, timings);
    if (alignment == null || _matches.isEmpty) {
      return (all: const <int>{}, current: null);
    }
    final all = <int>{};
    int? current;
    for (var i = 0; i < _matches.length; i++) {
      final tok = alignedTokenAt(alignment, text, _matches[i].start);
      if (tok == null) continue;
      all.add(tok);
      if (i == _matchIndex) current = tok;
    }
    return (all: all, current: current);
  }

  /// Wraps at both ends, same as the notebook editor's find bar.
  void _stepMatch(int delta) {
    final n = _matches.length;
    if (n == 0) return;
    setState(() => _matchIndex = (_matchIndex + delta + n) % n);
    _revealMatch();
  }

  /// Edit mode: park the caret on the hit so the field's own scrolling
  /// follows it. Either mode: bring the transcript section into view so a
  /// meeting page scrolled to its notes lands on the transcript. The Listen
  /// view scrolls its own word into view when `currentWord` changes.
  void _revealMatch() {
    if (_matches.isEmpty) return;
    final m = _matches[_matchIndex];
    if (m.start <= _transcriptController.text.length) {
      _transcriptController.selection =
          TextSelection.collapsed(offset: m.start);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _matchBarKey.currentContext;
      if (ctx != null && mounted) {
        unawaited(
          Scrollable.ensureVisible(
            ctx,
            duration: const Duration(milliseconds: 200),
          ),
        );
      }
    });
  }

  Widget _matchBar(TranscriptTimings? timings) {
    final n = _matches.length;
    final seek = _currentMatchSeekSeconds(timings);
    final theme = Theme.of(context);
    return Padding(
      key: const ValueKey('transcript-match-bar'),
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        key: _matchBarKey,
        children: [
          const Icon(Icons.search, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '${_matchIndex + 1} of $n',
              key: const ValueKey('transcript-match-label'),
              style: theme.textTheme.labelLarge,
            ),
          ),
          IconButton(
            key: const ValueKey('transcript-match-prev'),
            icon: const Icon(Icons.keyboard_arrow_up),
            tooltip: 'Previous match',
            visualDensity: VisualDensity.compact,
            onPressed: () => _stepMatch(-1),
          ),
          IconButton(
            key: const ValueKey('transcript-match-next'),
            icon: const Icon(Icons.keyboard_arrow_down),
            tooltip: 'Next match',
            visualDensity: VisualDensity.compact,
            onPressed: () => _stepMatch(1),
          ),
          // Only when the hit has a moment to play: word timings exist AND
          // the matched word survived alignment. Otherwise the button would
          // be a lie.
          if (seek != null)
            IconButton(
              key: const ValueKey('transcript-match-play'),
              icon: const Icon(Icons.play_arrow),
              tooltip: 'Play from match',
              visualDensity: VisualDensity.compact,
              onPressed: () => unawaited(_seekAndPlay(seekTargetFor(seek))),
            ),
        ],
      ),
    );
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
      // Captured before admission/DB awaits: publication can outlive the route.
      final access = ref.read(recordingAccessProvider);
      await _withEdit((key) async {
        final saved = await db.updateDumpTranscript(
          widget.dumpId,
          storageKey: key,
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
        final published = await publishManualTranscriptSidecar(
          db: db,
          access: access,
          storageKey: key,
          revision: saved,
        );
        if (!published) throw StateError('Manual edit was superseded');
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
      });
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
      final title = _titleController.text.trim();
      final access = ref.read(recordingAccessProvider);
      if (title.isEmpty) throw StateError('Title cannot be empty');
      await _withEdit((key) async {
        await db.updateDumpTitle(
          widget.dumpId,
          storageKey: key,
          title: title,
          now: DateTime.now().toUtc(),
        );
        await _writeLatestMetadata(db, key, access);
      });
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
    final access = ref.read(recordingAccessProvider);

    setState(() {
      _statusError = null;
      _statusMessage = 'Generating meeting notes…';
    });
    try {
      await _withEdit((key) async {
        final existing = await db.getDump(widget.dumpId);
        if (existing == null) throw StateError('Dump not found');
        const processor = MeetingNotesProcessor();
        final notes =
            processor.process(title: existing.title, transcript: transcript);
        await db.updateDumpMeetingNotes(
          widget.dumpId,
          storageKey: key,
          expectedTitle: existing.title,
          expectedTranscript: transcript,
          expectedTranscriptionAttempt: existing.transcriptionAttempt,
          expectedTranscriptionRequestId: existing.transcriptionRequestId,
          meetingNotes: notes,
          now: DateTime.now().toUtc(),
        );
        await _writeLatestMetadata(db, key, access);
      });
      if (mounted) {
        ref.invalidate(dumpByIdProvider(widget.dumpId));
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

  Future<DeleteTarget> _previewDeletionTarget(
    LocalDeletionService service,
  ) async {
    final preview = switch (await service.preview({widget.dumpId})) {
      Ok<DeletionPreview>(:final value) => value,
      Fail<DeletionPreview>(:final problem) => throw StorageFault(problem),
    };
    if (preview.targets.length != 1 ||
        preview.targets.single.id != widget.dumpId) {
      throw StateError('Recording deletion identity is unavailable');
    }
    final target = preview.targets.single;
    if (target.eligibility == Eligibility.retryOnly &&
        (target.binding?.key.dumpId != widget.dumpId ||
            target.retryTicketId == null ||
            target.retryTicketId!.isEmpty)) {
      throw StateError('Pending deletion identity is unavailable');
    }
    return target;
  }

  Future<void> _discoverDeletion() async {
    if (!mounted || _deleteBusy) return;
    final generation = ++_deletionPreviewGeneration;
    final service = ref.read(localDeletionServiceProvider);
    try {
      final target = await _previewDeletionTarget(service);
      if (!mounted || generation != _deletionPreviewGeneration) return;
      setState(() {
        if (target.eligibility == Eligibility.retryOnly) {
          _deletionRecovery.discover(target);
        }
        _deletionPreviewError = null;
      });
    } catch (e) {
      if (mounted && generation == _deletionPreviewGeneration) {
        setState(
          () => _deletionPreviewError =
              'Could not check pending local deletion. Check again before deleting: $e',
        );
      }
    }
  }

  Future<void> _delete() async {
    if (_deleteBusy || !mounted) return;
    setState(() => _deleteBusy = true);
    ++_deletionPreviewGeneration;
    final service = ref.read(localDeletionServiceProvider);
    try {
      // Revalidate before choosing the confirmation, including callbacks captured
      // before entry discovery completed. Never turn ordinary consent into retry.
      final before = await _previewDeletionTarget(service);
      if (!mounted) return;
      setState(() {
        _deletionPreviewError = null;
        if (before.eligibility == Eligibility.retryOnly) {
          if (!_deletionRecovery.discover(before)) {
            throw StateError('Pending deletion identity changed');
          }
        }
      });
      if (_deletionRecovery.hasPending) {
        await _confirmDeletionRetry(service);
        return;
      }
      if (!await confirmLocalDeletion(context, 1) || !mounted) return;
      await _closePlayback();
      // Already-confirmed work retains its owner through actual close/settlement,
      // even if the route leaves. A new pending ticket requires separate consent.
      final target = await _previewDeletionTarget(service);
      if (target.eligibility == Eligibility.retryOnly) {
        if (mounted) {
          setState(() {
            _deletionRecovery.discover(target);
            _deletionPreviewError =
                'A local deletion is pending. Choose Retry deletion to confirm it separately.';
          });
        }
        return;
      }
      if (target.binding != before.binding) {
        throw StateError(
          'Recording identity changed. Check again before deleting.',
        );
      }
      final result = switch (await service.deleteConfirmed(
        (
          operationId: const Uuid().v4(),
          targets: List<DeleteTarget>.unmodifiable([target]),
        ),
      )) {
        Ok<BulkDeletionResult>(:final value) => value,
        Fail<BulkDeletionResult>(:final problem) => throw StorageFault(problem),
      };
      final item = result.items.single;
      if (mounted) setState(() => _deletionRecovery.record(result));
      if (item.state != DeleteState.deleted) {
        throw StorageFault(
          item.problem ??
              const (
                code: ProblemCode.busy,
                message: 'Recording is still in use'
              ),
        );
      }
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(
          () => _deletionPreviewError =
              'Local deletion could not continue. Check again or retry the pending deletion: $e',
        );
      }
      if (mounted && _closing) {
        await _playbackAfterFailedDelete(service);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Delete failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _deleteBusy = false);
    }
  }

  Future<void> _retryLocalDeletion() async {
    if (_deleteBusy || !mounted) return;
    final ids = _deletionRecovery.ticketIds;
    if (ids.isEmpty) return;
    setState(() => _deleteBusy = true);
    ++_deletionPreviewGeneration;
    final service = ref.read(localDeletionServiceProvider);
    try {
      await _confirmDeletionRetry(service);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Delete failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _deleteBusy = false);
    }
  }

  Future<void> _confirmDeletionRetry(LocalDeletionService service) async {
    final ids = _deletionRecovery.ticketIds;
    if (ids.isEmpty ||
        !await confirmLocalDeletion(context, ids.length, retry: true) ||
        !mounted) {
      return;
    }
    await _closePlayback();
    final result = switch (await service
        .retryConfirmed((operationId: const Uuid().v4(), ticketIds: ids))) {
      Ok<BulkDeletionResult>(:final value) => value,
      Fail<BulkDeletionResult>(:final problem) => throw StorageFault(problem),
    };
    if (mounted) {
      setState(() {
        _deletionRecovery.record(result);
        _deletionPreviewError = null;
      });
      if (!_deletionRecovery.hasPending) Navigator.of(context).pop();
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
            tooltip: _deletionRecovery.hasPending ? 'Retry deletion' : 'Delete',
            onPressed: _deleteBusy || (_playbackOpening && _canRetryPlayback)
                ? null
                : _delete,
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
    _recomputeMatches();
    final sync = SyncStatus.fromWire(row.syncStatus);
    final mode = DumpMode.fromWire(row.mode);
    final isNote = mode == DumpMode.textNote;
    final transcription = TranscriptionStatus.fromWire(row.transcriptionStatus);
    final operationActive = transcription.isInProgress;
    final displayTranscript = row.transcript;
    // Arc B: the Summarize / Summarize again button follows the list
    // screen's regenerate action exactly — it needs a transcript to work on
    // and the AI-summaries capability switched on (while the feature is off,
    // none of its UI appears anywhere).
    final bool summarizable = (row.transcript?.trim().isNotEmpty ?? false) &&
        ref.watch(summariesEnabledProvider);
    // Tap-to-hear: timings are server-owned; Listen is offered only when
    // they exist and defaults on the first time we see them (spec §3.3).
    final timings = _timingsFor(row);
    final listen = timings != null &&
        (_listenMode ??= defaultListenMode(timings: timings, audioLocal: true));

    return ListView(
      // The action row is the LAST child, so the scroll view must reserve the
      // system bar's height on top of its own padding — otherwise the taskbar
      // (taller than a gesture pill on the Fold) sits on Save and Transcribe
      // again.
      padding: actionRowSafePadding(context),
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
            if (!isNote) _MetaChip(label: '${row.durationSeconds}s'),
            _MetaChip(label: sync.displayName, color: _syncColor(sync)),
          ],
        ),
        const SizedBox(height: 16),
        if (_deletionPreviewError != null) ...[
          Text(_deletionPreviewError!),
          TextButton(
            onPressed: _deleteBusy ? null : _discoverDeletion,
            child: const Text('Check pending deletion again'),
          ),
        ],
        if (_deletionResult != null || _deletionRecovery.hasPending)
          LocalDeletionResults(
            result: _deletionResult,
            pending: _deletionRecovery.pending,
            discovered: _deletionRecovery.discovered,
            onRetry: _retryLocalDeletion,
            busy: _deleteBusy,
          ),
        if (_canRetryPlayback || _playbackOpening && _closing)
          TextButton(
            key: const ValueKey('retry-playback'),
            onPressed: _playbackOpening || _deleteBusy ? null : _retryPlayback,
            child: const Text('Retry playback'),
          ),
        if (!isNote) ...[
          _RecordingPlaybackPanel(
            state: _playbackController?.state ??
                RecordingPlaybackState(
                  loading: _playbackOpening,
                  error: _playbackError,
                ),
            expectedDuration: Duration(seconds: row.durationSeconds),
            onToggle: _playbackController?.togglePlayback ?? () async {},
            onSeek: _playbackController?.seek ?? (_) async {},
          ),
          const SizedBox(height: 16),
        ],
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
        if (mode == DumpMode.meeting &&
            (row.meetingNotes == null || row.meetingNotes!.trim().isEmpty) &&
            displayTranscript != null &&
            displayTranscript.isNotEmpty) ...[
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              key: ValueKey('generate-notes-${widget.dumpId}'),
              icon: const Icon(Icons.auto_awesome),
              label: const Text('Generate meeting notes'),
              onPressed: () => _regenerateMeetingNotes(displayTranscript),
            ),
          ),
          const SizedBox(height: 16),
        ],
        if (displayTranscript != null && displayTranscript.isNotEmpty) ...[
          // Search-depth spec §2: the match bar sits above the transcript
          // header in either mode, only while there is something to step.
          if (_matches.isNotEmpty) _matchBar(timings),
          if (mode == DumpMode.meeting) ...[
            // Option B: the transcript lives behind a collapsible header so
            // meeting dumps lead with notes/actions instead of a text wall.
            InkWell(
              key: ValueKey('transcript-header-${widget.dumpId}'),
              onTap: () =>
                  setState(() => _transcriptExpanded = !_transcriptExpanded),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    Icon(
                      _transcriptExpanded
                          ? Icons.expand_more
                          : Icons.chevron_right,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      'Transcript',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _transcriptSummary(row, displayTranscript),
                        style: Theme.of(context).textTheme.bodySmall,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
          ] else ...[
            Row(
              children: [
                Expanded(
                  child: Text(
                    isNote ? 'Note' : 'Transcript',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                if (!isNote && timings != null) _listenToggle(listen),
              ],
            ),
            const SizedBox(height: 8),
          ],
          if ((mode != DumpMode.meeting || _transcriptExpanded) && listen) ...[
            // Listen mode (spec §3): read-only, tap a word to hear it.
            // Bounded height so the page still scrolls as one list and
            // the action row keeps its inset.
            if (mode == DumpMode.meeting) _listenToggle(listen),
            // Waveform scrubber (spec §3.6): peaks are server-computed and
            // ride with the timings, so it draws even before the audio is
            // local; tapping it then routes to the download affordance.
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: WaveformScrubber(
                key: ValueKey('waveform-${widget.dumpId}'),
                peaks: timings.peaks,
                position: _playhead,
                duration: _playbackController != null &&
                        _playbackController!.state.duration > Duration.zero
                    ? _playbackController!.state.duration
                    : Duration(seconds: row.durationSeconds),
                onSeek: (t) => unawaited(_seekAndPlay(t)),
                enabled: _playbackController != null &&
                    _playbackController!.state.error == null,
                onDisabledTap: ref.read(syncedAudioDownloaderProvider) == null
                    ? null
                    : () => unawaited(_downloadAudioForListen()),
              ),
            ),
            SizedBox(
              height: 360,
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: ListenTranscriptView(
                    key: ValueKey('listen-view-${widget.dumpId}'),
                    timings: timings,
                    transcript: _transcriptController.text,
                    position: _playhead,
                    onSeek: _seekAndPlay,
                    highlightedWords: _matchWords(timings).all,
                    currentWord: _matchWords(timings).current,
                    audioLocal: _playbackController != null &&
                        _playbackController!.state.error == null,
                    serverPaired: true,
                    onRetranscribe: () => _requestTranscription(row),
                    onDownloadAudio:
                        ref.read(syncedAudioDownloaderProvider) == null
                            ? null
                            : () => unawaited(_downloadAudioForListen()),
                  ),
                ),
              ),
            ),
          ] else if (mode != DumpMode.meeting || _transcriptExpanded) ...[
            if (mode == DumpMode.meeting && timings != null)
              _listenToggle(listen),
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
                            transcription == TranscriptionStatus.failed ||
                            transcription ==
                                TranscriptionStatus.notApplicable) &&
                        (_transcriptDirty || _manualSidecarPending) &&
                        _transcriptController.text.trim().isNotEmpty &&
                        !_savingTranscript
                    ? _saveTranscript
                    : null,
              ),
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
        // Task 4: the server-generated AI summary, BELOW the transcript per
        // the spec. Server-owned, arrives via normal dump sync; absent-safe —
        // a null/blank summary renders nothing at all. The subtle header
        // (label-sized, muted colour) keeps it visually secondary to the
        // transcript and meeting notes. The body is MARKDOWN (the server
        // writes '## Summary' sections and '- ' bullets), rendered with
        // deliberately modest heading styles so '## Summary' reads as a
        // compact label rather than a page title.
        if (row.summary != null && row.summary!.trim().isNotEmpty) ...[
          Row(
            key: ValueKey('ai-summary-header-${widget.dumpId}'),
            children: [
              Icon(
                Icons.auto_awesome,
                size: 14,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Text(
                'AI summary',
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: MarkdownBody(
                key: ValueKey('ai-summary-body-${widget.dumpId}'),
                data: row.summary!,
                selectable: true,
                styleSheet: _summaryStyleSheet(Theme.of(context)),
              ),
            ),
          ),
          // Preserve-until-success: tapping this never clears or hides the
          // body above — the new summary replaces it when it arrives via
          // sync, so the user keeps the old text until the server has a
          // better one.
          if (summarizable) ...[
            const SizedBox(height: 8),
            _summarizeButton(row, again: true),
          ],
          const SizedBox(height: 16),
        ] else if (summarizable) ...[
          // No summary yet: the button stands alone in the summary slot.
          _summarizeButton(row, again: false),
          const SizedBox(height: 16),
        ],
        if (operationActive || transcription == TranscriptionStatus.failed) ...[
          _ServerTranscriptionProgressPanel(
            row: row,
            status: transcription,
            // The offline MIRROR of the server's active model, so the running
            // line names the model actually decoding rather than the engine.
            // Read here, where a Consumer already exists, and passed down: a
            // panel that rebuilds once a second must not own a provider read.
            whisperModel: ref.read(settingsStoreProvider).whisperModel,
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
            if (!isNote) ...[
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
                      TranscriptionStatus.notApplicable => 'Not applicable',
                    },
                  ),
                  onPressed:
                      operationActive ? null : () => _requestTranscription(row),
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }

  /// Opens the template picker and queues a (re)summary for [row].
  ///
  /// [again] only changes the label: with a summary on screen the button
  /// reads 'Summarize again', otherwise 'Summarize'. The flow itself is the
  /// shared one the recordings list uses (pick → POST → snackbar).
  Widget _summarizeButton(DumpRow row, {required bool again}) {
    return Align(
      alignment: Alignment.centerLeft,
      child: FilledButton.tonalIcon(
        key: ValueKey('summarize-again-${widget.dumpId}'),
        icon: const Icon(Icons.auto_awesome, size: 18),
        label: Text(again ? 'Summarize again' : 'Summarize'),
        onPressed: () => runSummarizeFlow(
          context,
          client: ref.read(summariesClientProvider.future),
          dump: row,
        ),
      ),
    );
  }

  Widget _listenToggle(bool listen) {
    return SegmentedButton<bool>(
      key: ValueKey('listen-toggle-${widget.dumpId}'),
      showSelectedIcon: false,
      style: const ButtonStyle(
        visualDensity: VisualDensity.compact,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      segments: const [
        ButtonSegment(
          value: false,
          label: Text('Edit'),
          icon: Icon(Icons.edit_outlined),
        ),
        ButtonSegment(
          value: true,
          label: Text('Listen'),
          icon: Icon(Icons.hearing),
        ),
      ],
      selected: {listen},
      onSelectionChanged: (s) => setState(() => _listenMode = s.first),
    );
  }

  /// A tap in Listen mode: seek, then make sure audio is actually
  /// playing — a tap on a word means "play this", not "move the cursor".
  Future<void> _seekAndPlay(Duration target) async {
    final c = _playbackController;
    if (c == null) return;
    await c.seek(target);
    if (!c.state.playing) await c.togglePlayback();
  }

  /// Listen mode on a recording whose audio lives only on the server:
  /// fetch it through the same path the list screen uses, then open
  /// playback so the words become tappable.
  Future<void> _downloadAudioForListen() async {
    final downloader = ref.read(syncedAudioDownloaderProvider);
    if (downloader == null || !mounted) return;
    setState(() => _statusMessage = 'Downloading audio…');
    final outcome = await downloader.download(widget.dumpId);
    if (!mounted) return;
    switch (outcome) {
      case Ok<String>():
        setState(() {
          _statusMessage = null;
          _playbackError = null;
          _playbackOpening = true;
        });
        _playbackInitialization = _initializePlayback();
      case Fail<String>(:final problem):
        setState(() {
          _statusMessage = null;
          _statusError = 'Audio download failed: ${problem.message}';
        });
        // The status area sits far below the Listen card on a tall
        // screen; a refused download must be visible where it was asked.
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Audio download failed: ${problem.message}')),
        );
    }
  }

  Color? _syncColor(SyncStatus s) => syncStatusColor(s);
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
    required this.whisperModel,
  });

  final DumpRow row;
  final TranscriptionStatus status;

  /// The model this device last saw the server transcribing with, from the
  /// local mirror. Empty until the catalogue has been fetched at least once.
  final String whisperModel;

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
      TranscriptionStatus.notApplicable => 'Transcription not applicable',
    };
    final startedAt = widget.row.transcriptionStartedAt;
    final rawElapsed = startedAt == null
        ? Duration.zero
        : DateTime.now().difference(startedAt);
    final elapsed = rawElapsed.isNegative ? Duration.zero : rawElapsed;

    final scheme = Theme.of(context).colorScheme;
    // This panel is a FILLED lime surface, so its text must use the container's
    // dark on-colour. The app text theme is light (correct on the near-black
    // chassis) and is nearly invisible here if inherited.
    final onPanel = scheme.onSecondaryContainer;

    return Semantics(
      liveRegion: true,
      label: title,
      child: Card(
        color: scheme.secondaryContainer,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                title,
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(color: onPanel),
              ),
              const SizedBox(height: 8),
              Text(
                _detailText(status, elapsed),
                style: TextStyle(color: onPanel),
              ),
              if (status.isInProgress) ...[
                const SizedBox(height: 12),
                const LinearProgressIndicator(),
              ],
              if (status == TranscriptionStatus.failed &&
                  widget.row.transcriptionError != null) ...[
                const SizedBox(height: 8),
                Text(
                  // Deliberately still red: the error code is the one thing
                  // that should stand out against the lime panel.
                  widget.row.transcriptionError!,
                  style: TextStyle(color: scheme.error),
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
    // Name the MODEL that is decoding, not the engine: once the model became
    // selectable, "faster-whisper" stopped answering "which one is running?".
    // With nothing mirrored yet the engine name is still true, so that is the
    // fallback — better than a sentence with an empty slot in it.
    final String decoder =
        describedWhisperModel(widget.whisperModel) ?? 'faster-whisper';
    return switch (status) {
      TranscriptionStatus.uploading =>
        'Streaming the preserved recording to your personal Docker container · Elapsed $elapsedText',
      TranscriptionStatus.queued =>
        'Waiting for the server worker · Elapsed $elapsedText',
      TranscriptionStatus.running =>
        'The server is decoding audio with $decoder. This continues if you leave this screen · Elapsed $elapsedText',
      TranscriptionStatus.failed =>
        'The previous transcript and raw recording are preserved on this device.',
      TranscriptionStatus.completed => 'Saved locally',
      TranscriptionStatus.notTranscribed => 'No transcription attempt yet',
      TranscriptionStatus.notApplicable => 'Text notes are not transcribed',
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

/// Paints transcript search hits inside the editor: every match gets a
/// tint, the one the match bar points at a stronger one. The ranges are
/// read through closures so the controller never holds stale state; they
/// are clamped to the live text because an edit can shorten it before the
/// next rescan.
class _MatchHighlightController extends TextEditingController {
  _MatchHighlightController({required this.matches, required this.current});

  final List<TextRange> Function() matches;
  final int Function() current;

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final ranges = matches();
    if (ranges.isEmpty) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }
    final scheme = Theme.of(context).colorScheme;
    final cur = current();
    final children = <InlineSpan>[];
    var cursor = 0;
    for (var i = 0; i < ranges.length; i++) {
      final r = ranges[i];
      if (r.start >= text.length || r.start < cursor) break;
      final end = r.end.clamp(r.start, text.length);
      if (r.start > cursor) {
        children.add(TextSpan(text: text.substring(cursor, r.start)));
      }
      children.add(
        TextSpan(
          text: text.substring(r.start, end),
          style: TextStyle(
            backgroundColor: i == cur
                ? scheme.tertiaryContainer
                : scheme.tertiaryContainer.withValues(alpha: 0.5),
            fontWeight: i == cur ? FontWeight.w600 : null,
          ),
        ),
      );
      cursor = end;
    }
    if (cursor < text.length) {
      children.add(TextSpan(text: text.substring(cursor)));
    }
    return TextSpan(style: style, children: children);
  }
}
