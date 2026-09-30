// SPDX-License-Identifier: AGPL-3.0-or-later
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/ask_history_repository.dart';
import '../../data/local_db.dart';
import '../../data/notebook_repository.dart';
import '../../services/ask_client.dart';
import '../../services/server_defaults.dart';
import '../../services/document_sync_engine.dart';
import '../../models/api_exception.dart';
import '../dump/dump_detail_screen.dart';
import '../home/home_providers.dart'
    show documentSyncEngineProvider, serverTranscriptionServiceProvider;
import '../home/home_screen.dart' show localDbProvider;
import '../notebook/notebook_editor_screen.dart';
import '../server/server_connection_screen.dart'
    show secureStoreProvider, transcriptionClientProvider;
import '../todo/todo_list_screen.dart';
import '../recording/recording_controller.dart';

final askHistoryRepositoryProvider = Provider<AskHistoryRepository>(
  (ref) => AskHistoryRepository(ref.watch(localDbProvider)),
);

final askHistoryProvider = StreamProvider<List<AskHistoryMessage>>(
  (ref) => ref.watch(askHistoryRepositoryProvider).watch(),
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

Future<void> finishAskVoiceRecording({
  required double durationSeconds,
  required Future<String> Function() transcribe,
  required Future<void> Function() discard,
  required Future<void> Function(String transcript) submit,
}) async {
  final String transcript = (await transcribe()).trim();
  if (transcript.isEmpty) throw StateError('Transcription returned no text');
  if (durationSeconds < 25.0) await discard();
  await submit(transcript);
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
    final controller = ref.read(recordingControllerProvider.notifier);
    try {
      if (ref.read(recordingControllerProvider) == RecordingState.idle) {
        await controller.start(mode: 'brain_dump');
        if (mounted) setState(() => _error = null);
        return;
      }
      if (ref.read(recordingControllerProvider) != RecordingState.recording) {
        return;
      }
      final DumpRow? row = await controller.stop();
      if (row == null) throw StateError('Recorder returned no audio');
      setState(() {
        _pending = true;
        _error = null;
      });
      final LocalDb db = ref.read(localDbProvider);
      final bool discard = row.durationSeconds < 25.0;
      if (discard) {
        // Prevent the auto-sync watcher from observing this temporary row
        // while the existing transcription path extracts its text.
        await db.customStatement(
          'UPDATE dumps SET sync_dirty = 0 WHERE id = ?',
          <Object?>[row.id],
        );
      }
      await finishAskVoiceRecording(
        durationSeconds: row.durationSeconds.toDouble(),
        transcribe: () async {
          await ref
              .read(serverTranscriptionServiceProvider)
              .transcribeDump(row.id);
          final DumpRow? transcribed = await db.getDumpRow(row.id);
          return transcribed?.transcript ?? '';
        },
        discard: () async {
          await db.applyRemoteDumpDeletion(row.id);
          final File audio = File(row.audioPath);
          if (await audio.exists()) await audio.delete();
        },
        submit: (text) => _submit(text, true),
      );
    } catch (_) {
      if (mounted) {
        setState(() {
          _pending = false;
          _error = 'Voice transcription failed. Try again.';
        });
      }
    }
  }

  Future<void> _openSource(AskSource source) async {
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
    final RecordingState recordingState = widget.voiceQuestion == null
        ? ref.watch(recordingControllerProvider)
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
              data: (messages) => ListView.builder(
                padding: const EdgeInsets.all(12),
                itemCount: messages.length,
                itemBuilder: (context, index) {
                  final message = messages[index];
                  final bool user = message.role == 'user';
                  return Align(
                    alignment:
                        user ? Alignment.centerRight : Alignment.centerLeft,
                    child: Card(
                      key: Key('ask-message-${message.id}'),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(message.text),
                            if (message.sources.isNotEmpty)
                              const SizedBox(height: 8),
                            Wrap(
                              spacing: 6,
                              runSpacing: 6,
                              children: message.sources.indexed
                                  .map(
                                    (entry) => ActionChip(
                                      key: Key(
                                        'ask-source-${message.id}-${entry.$1}-${entry.$2.entityType}-${entry.$2.entityId}',
                                      ),
                                      avatar: Icon(
                                        _sourceIcon(entry.$2.entityType),
                                        size: 16,
                                      ),
                                      label: Text(_sourceLabel(entry.$2)),
                                      onPressed: () => _openSource(entry.$2),
                                    ),
                                  )
                                  .toList(growable: false),
                            ),
                          ],
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
