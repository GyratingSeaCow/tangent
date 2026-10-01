// SPDX-License-Identifier: AGPL-3.0-or-later
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../data/ask_history_repository.dart';
import '../../data/local_db.dart';
import '../../data/notebook_repository.dart';
import '../../services/ask_client.dart';
import '../../services/server_defaults.dart';
import '../../services/document_sync_engine.dart';
import '../../services/transcription_client.dart';
import '../../models/api_exception.dart';
import '../../data/storage/storage_contract.dart';
import '../../data/storage/storage_providers.dart'
    show localDeletionServiceProvider;
import '../dump/dump_detail_screen.dart';
import '../home/home_providers.dart'
    show documentSyncEngineProvider, serverTranscriptionServiceProvider;
import '../home/home_screen.dart' show localDbProvider;
import '../notebook/notebook_editor_screen.dart';
import '../server/server_connection_screen.dart'
    show secureStoreProvider, transcriptionClientProvider;
import '../todo/todo_list_screen.dart';
import 'ask_source_actions.dart';
import '../recording/recording_controller.dart';

final askHistoryRepositoryProvider = Provider<AskHistoryRepository>(
  (ref) => AskHistoryRepository(ref.watch(localDbProvider)),
);

final askHistoryProvider = StreamProvider<List<AskHistoryMessage>>(
  (ref) => ref.watch(askHistoryRepositoryProvider).watch(),
);

/// Opened citations, as `<messageId>#<sourceIndex>` keys. Local only.
final askSourceVisitsProvider = StreamProvider<Set<String>>(
  (ref) => ref.watch(localDbProvider).watchAskSourceVisits(),
);

final askClientProvider = FutureProvider<AskClient>((ref) async {
  ref.watch(transcriptionClientProvider);
  final store = ref.watch(secureStoreProvider);
  String? url;
  String? token;
  try {
    url = await store.getServerUrl();
    token = await store.getToken();
  } catch (_) {}
  return AskClient(baseUrl: url ?? defaultServerBaseUrl(), token: token);
});

typedef AskVoiceQuestion = Future<String?> Function();
typedef AskOpenDestination = Future<void> Function(Widget destination);

abstract interface class AskVoiceRecorderPort {
  RecordingState get state;
  Future<void> start();
  Future<DumpRow?> stop();
}

final class _ControllerAskVoiceRecorder implements AskVoiceRecorderPort {
  const _ControllerAskVoiceRecorder(this.ref);
  final Ref ref;
  @override
  RecordingState get state => ref.read(recordingControllerProvider);
  @override
  Future<void> start() =>
      ref.read(recordingControllerProvider.notifier).start(mode: 'brain_dump');
  @override
  Future<DumpRow?> stop() =>
      ref.read(recordingControllerProvider.notifier).stop();
}

final askVoiceRecorderProvider = Provider<AskVoiceRecorderPort>((ref) {
  // The adapter's [state] getter uses ref.read, which does not subscribe.
  // Watch the underlying controller here so widgets watching this provider
  // rebuild when the recording state changes (idle -> recording -> saving);
  // without this the mic/stop icon would freeze on first build.
  ref.watch(recordingControllerProvider);
  return _ControllerAskVoiceRecorder(ref);
});

final askVoiceTranscribeProvider = Provider<Future<String> Function(DumpRow)>(
  (ref) => (row) async {
    await ref.read(serverTranscriptionServiceProvider).transcribeDump(row.id);
    return (await ref.read(localDbProvider).getDumpRow(row.id))?.transcript ??
        '';
  },
);

void ensureAskVoiceDeletionComplete(BulkDeletionResult result) {
  for (final item in result.items) {
    if (item.state != DeleteState.deleted) {
      throw StorageFault(
        item.problem ??
            const (
              code: ProblemCode.busy,
              message: 'Recording is still in use',
            ),
      );
    }
  }
}

final askVoiceDiscardProvider = Provider<Future<void> Function(DumpRow)>(
  (ref) => (row) async {
    await ref.read(transcriptionClientProvider).deleteDump(row.id);
    final deletion = ref.read(localDeletionServiceProvider);
    var preview = switch (await deletion.preview(<String>{row.id})) {
      Ok<DeletionPreview>(:final value) => value,
      Fail<DeletionPreview>(:final problem) => throw StorageFault(problem),
    };
    if (preview.targets
        .any((target) => target.eligibility != Eligibility.eligible)) {
      await deletion
          .watchEligibility()
          .firstWhere((snapshot) => snapshot[row.id] == Eligibility.eligible)
          .timeout(const Duration(seconds: 5));
      preview = switch (await deletion.preview(<String>{row.id})) {
        Ok<DeletionPreview>(:final value) => value,
        Fail<DeletionPreview>(:final problem) => throw StorageFault(problem),
      };
    }
    final result = switch (await deletion.deleteConfirmed(
      (
        operationId: const Uuid().v4(),
        targets: preview.targets,
      ),
    )) {
      Ok<BulkDeletionResult>(:final value) => value,
      Fail<BulkDeletionResult>(:final problem) => throw StorageFault(problem),
    };
    ensureAskVoiceDeletionComplete(result);
  },
);

Future<void> finishAskVoiceRecording({
  required int durationSeconds,
  required Future<String> Function() transcribe,
  required Future<void> Function() discard,
  required Future<void> Function(String transcript) submit,
  Future<void> Function(Object error)? onCleanupError,
}) async {
  final String transcript = (await transcribe()).trim();
  if (transcript.isEmpty) throw StateError('Transcription returned no text');
  await submit(transcript);
  if (durationSeconds < 25) {
    try {
      await discard();
    } catch (error) {
      if (onCleanupError != null) await onCleanupError(error);
    }
  }
}

class AskScreen extends ConsumerStatefulWidget {
  const AskScreen({super.key, this.voiceQuestion, this.openDestination});
  final AskVoiceQuestion? voiceQuestion;
  final AskOpenDestination? openDestination;

  @override
  ConsumerState<AskScreen> createState() => _AskScreenState();
}

class _AskScreenState extends ConsumerState<AskScreen> {
  final TextEditingController _question = TextEditingController();
  bool _pending = false;
  String? _error;

  @override
  void dispose() {
    _question.dispose();
    super.dispose();
  }

  Future<void> _submit([String? spoken, bool allowWhilePending = false]) async {
    final String text = (spoken ?? _question.text).trim();
    if (text.isEmpty || (_pending && !allowWhilePending)) return;
    setState(() {
      _pending = true;
      _error = null;
    });
    try {
      final client = await ref.read(askClientProvider.future);
      await client.ask(text);
      _question.clear();
      final SyncReport report =
          await ref.read(documentSyncEngineProvider).syncNow();
      if (report.outcome == SyncOutcome.alreadyRunning) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await ref.read(documentSyncEngineProvider).syncNow();
      }
    } on ApiException catch (error) {
      if (mounted) {
        setState(
          () => _error = error.statusCode == 409
              ? 'Install AI summaries in Settings first'
              : error.message,
        );
      }
    } catch (_) {
      if (mounted) setState(() => _error = 'Server unreachable. Try again.');
    } finally {
      if (mounted) setState(() => _pending = false);
    }
  }

  Future<void> _voice() async {
    final voice = widget.voiceQuestion;
    if (voice != null) {
      final String? text = await voice();
      if (text != null && text.trim().isNotEmpty) await _submit(text);
      return;
    }
    final controller = ref.read(askVoiceRecorderProvider);
    try {
      if (controller.state == RecordingState.idle) {
        await controller.start();
        if (mounted) setState(() => _error = null);
        return;
      }
      if (controller.state != RecordingState.recording) {
        return;
      }
      final DumpRow? row = await controller.stop();
      if (row == null) throw StateError('Recorder returned no audio');
      setState(() {
        _pending = true;
        _error = null;
      });
      try {
        await finishAskVoiceRecording(
          durationSeconds: row.durationSeconds,
          transcribe: () => ref.read(askVoiceTranscribeProvider)(row),
          discard: () => ref.read(askVoiceDiscardProvider)(row),
          submit: (text) async {
            final client = await ref.read(askClientProvider.future);
            await client.ask(text);
          },
          onCleanupError: (error) async {
            if (mounted) {
              setState(() => _error = 'Voice cleanup failed: $error');
            }
          },
        );
        final report = await ref.read(documentSyncEngineProvider).syncNow();
        if (report.outcome == SyncOutcome.alreadyRunning) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          await ref.read(documentSyncEngineProvider).syncNow();
        }
      } finally {
        if (mounted) setState(() => _pending = false);
      }
    } on ApiException catch (error) {
      if (mounted) {
        setState(() {
          _pending = false;
          _error = error.statusCode == 409
              ? 'Install AI summaries in Settings first'
              : error.message;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _pending = false;
          _error = 'Voice transcription failed. Try again.';
        });
      }
    }
  }

  Future<void> _openSource(
    AskSource source,
    String messageId,
    int index,
  ) async {
    await ref.read(localDbProvider).markAskSourceVisited(
          messageId: messageId,
          sourceIndex: index,
        );
    final db = ref.read(localDbProvider);
    Widget? destination;
    if (source.entityType == 'dump' || source.entityType == 'summary') {
      final DumpRow? row = await db.getDumpRow(source.entityId);
      if (row != null) {
        destination = DumpDetailScreen(
          dumpId: row.id,
          audioPath: row.audioPath,
          durationSeconds: row.durationSeconds,
          initialSeekSeconds:
              source.entityType == 'dump' ? source.seekSeconds : null,
        );
      }
    } else if (source.entityType == 'notebook') {
      final notebook =
          await NotebookRepository(db: db).getNotebook(source.entityId);
      if (notebook != null) {
        destination = NotebookEditorScreen(notebookId: source.entityId);
      }
    } else if (source.entityType == 'todo') {
      destination = const TodoListScreen();
    }
    if (!mounted) return;
    if (destination == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Source no longer exists: ${source.snippet}')),
      );
      return;
    }
    final open = widget.openDestination;
    if (open != null) {
      await open(destination);
    } else {
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(builder: (_) => destination!),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final history = ref.watch(askHistoryProvider);
    final Set<String> visited =
        ref.watch(askSourceVisitsProvider).valueOrNull ?? const <String>{};
    // Live entity state: one rename/pin/delete reflects on EVERY chip that
    // cites the entity. Null while loading/unavailable: chips then render
    // exactly as before rather than flashing "missing".
    final Map<String, AskSourceEntity>? entities =
        ref.watch(askSourceEntitiesProvider).valueOrNull;
    final RecordingState recordingState = widget.voiceQuestion == null
        ? ref.watch(askVoiceRecorderProvider).state
        : RecordingState.idle;
    return Scaffold(
      appBar: AppBar(title: const Text('Ask')),
      body: Column(
        children: <Widget>[
          Expanded(
            child: history.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (_, __) =>
                  const Center(child: Text('Could not load Ask history.')),
              // Chat order: reversed so the view STARTS at the newest message
              // (offset 0 = bottom) and stays there as answers arrive —
              // independent of when the history stream first emits, unlike
              // a post-frame jumpTo. History stays oldest-first; only the
              // index maps from the end.
              data: (messages) => ListView.builder(
                key: const ValueKey<String>('ask-history'),
                reverse: true,
                padding: const EdgeInsets.all(12),
                itemCount: messages.length,
                itemBuilder: (context, index) {
                  final message = messages[messages.length - 1 - index];
                  final bool user = message.role == 'user';
                  return Align(
                    alignment:
                        user ? Alignment.centerRight : Alignment.centerLeft,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: MediaQuery.sizeOf(context).width - 24,
                      ),
                      child: Card(
                        key: Key('ask-message-${message.id}'),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(message.text),
                              if (message.sources.isNotEmpty) ...<Widget>[
                                const SizedBox(height: 4),
                                ...message.sources.indexed.map(
                                  (entry) => _SourceRow(
                                    key: Key(
                                      'ask-source-${message.id}-${entry.$1}-${entry.$2.entityType}-${entry.$2.entityId}',
                                    ),
                                    icon: _sourceIcon(entry.$2.entityType),
                                    label: _sourceLabel(entry.$2),
                                    detail: entities?[askSourceEntityKey(
                                      entry.$2,
                                    )]
                                        ?.title,
                                    pinned: entities?[askSourceEntityKey(
                                          entry.$2,
                                        )]
                                            ?.pinned ??
                                        false,
                                    missing: entities != null &&
                                        !entities.containsKey(
                                          askSourceEntityKey(entry.$2),
                                        ),
                                    visited: visited.contains(
                                      '${message.id}#${entry.$1}',
                                    ),
                                    onTap: () => _openSource(
                                      entry.$2,
                                      message.id,
                                      entry.$1,
                                    ),
                                    onLongPress: () => showAskSourceActions(
                                      context,
                                      ref,
                                      entry.$2,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
          if (_pending) const LinearProgressIndicator(key: Key('ask-pending')),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                _error!,
                key: const Key('ask-error'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: TextField(
                      key: const Key('ask-question'),
                      controller: _question,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _submit(),
                      decoration: const InputDecoration(
                        hintText: 'Ask your notes…',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  IconButton(
                    key: const Key('ask-mic'),
                    tooltip: recordingState == RecordingState.recording
                        ? 'Stop and ask'
                        : 'Ask by voice',
                    onPressed: _pending ? null : _voice,
                    icon: Icon(
                      recordingState == RecordingState.recording
                          ? Icons.stop
                          : Icons.mic,
                    ),
                  ),
                  IconButton(
                    key: const Key('ask-send'),
                    tooltip: 'Ask',
                    onPressed: _pending ? null : _submit,
                    icon: const Icon(Icons.send),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _sourceLabel(AskSource source) => switch (source.entityType) {
      'dump' => source.seekSeconds == null
          ? 'Recording'
          : 'Recording ${_timestamp(source.seekSeconds!)}',
      'summary' => 'Summary',
      'notebook' => 'Notebook',
      'todo' => 'To Do',
      _ => 'Source',
    };

IconData _sourceIcon(String type) => switch (type) {
      'dump' => Icons.mic,
      'summary' => Icons.summarize,
      'notebook' => Icons.menu_book,
      'todo' => Icons.check_box,
      _ => Icons.link,
    };

String _timestamp(double seconds) {
  final int total = seconds.floor();
  return '${total ~/ 60}:${(total % 60).toString().padLeft(2, '0')}';
}

/// One citation, rendered full-width on its own line so a list of sources
/// reads as a single scannable column instead of a reflowing chip cloud.
///
/// A [visited] row dims and swaps its leading icon for a filled check, so a
/// long source list shows what has already been opened without relying on
/// colour alone.
class _SourceRow extends StatelessWidget {
  const _SourceRow({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.onLongPress,
    this.detail,
    this.pinned = false,
    this.missing = false,
    this.visited = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  /// Long-press: the per-entity action sheet (chips keep their own gesture;
  /// long-press-to-select is a list-row contract).
  final VoidCallback? onLongPress;

  /// The cited entity's CURRENT title, shown quietly after the label.
  final String? detail;
  final bool pinned;

  /// The entity is gone locally: struck through, tap explains via snackbar.
  final bool missing;
  final bool visited;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextStyle? base = Theme.of(context).textTheme.bodyMedium;
    final String? shownDetail =
        detail == null || detail!.trim().isEmpty ? null : detail!.trim();
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      borderRadius: BorderRadius.circular(8),
      child: Opacity(
        opacity: visited || missing ? 0.55 : 1,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
          child: Row(
            children: <Widget>[
              Icon(
                visited ? Icons.check_circle : icon,
                key: ValueKey<bool>(visited),
                size: 18,
                color: visited ? scheme.onSurfaceVariant : scheme.primary,
              ),
              const SizedBox(width: 12),
              Flexible(
                flex: 0,
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: (visited
                          ? base?.copyWith(color: scheme.onSurfaceVariant)
                          : base)
                      ?.copyWith(
                    decoration: missing ? TextDecoration.lineThrough : null,
                  ),
                ),
              ),
              Expanded(
                child: shownDetail == null
                    ? const SizedBox.shrink()
                    : Text(
                        '  ·  $shownDetail',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: base?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
              ),
              if (pinned)
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: Icon(
                    Icons.push_pin,
                    key: const ValueKey<String>('ask-source-pinned'),
                    size: 14,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              Icon(
                Icons.chevron_right,
                size: 18,
                color: scheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
