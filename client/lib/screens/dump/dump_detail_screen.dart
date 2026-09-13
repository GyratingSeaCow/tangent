// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/audio_storage.dart';
import '../../data/local_db.dart';
import '../../models/dump_mode.dart';
import '../../models/sync_status.dart';
import '../../services/transcription_client.dart';
import '../home/home_screen.dart' show localDbProvider;
import '../server/server_connection_screen.dart' show transcriptionClientProvider;
import 'dumps_providers.dart';

/// Watch a single dump by id.
final dumpByIdProvider = FutureProvider.family<DumpRow?, String>((ref, id) async {
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
  bool _saving = false;
  bool _transcribing = false;
  String? _statusMessage;
  String? _statusError;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController();
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
    _titleController.dispose();
    super.dispose();
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
      await db.upsertDump(existing.copyWith(
        title: _titleController.text.trim(),
        updatedAt: DateTime.now(),
      ));
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
      _transcribing = true;
      _statusError = null;
      _statusMessage = 'Uploading + queueing transcription…';
    });
    try {
      final db = ref.read(localDbProvider);
      final client = ref.read(transcriptionClientProvider);
      final row = await db.getDump(widget.dumpId);
      if (row == null) throw StateError('Dump not found');

      final file = File(widget.audioPath);
      if (!await file.exists()) {
        throw StateError('Audio file missing');
      }

      // Upload + enqueue in one shot using the existing client API.
      await client.createDump(
        id: row.id,
        mode: row.mode,
        durationSeconds: row.durationSeconds,
        title: row.title,
        createdAt: row.createdAt,
      );
      await client.uploadAudio(
        dumpId: row.id,
        audioBytes: await file.readAsBytes(),
      );
      await client.enqueueTranscription(row.id);
      await db.updateSyncStatus(row.id, SyncStatus.pending);

      if (mounted) {
        setState(() => _statusMessage = 'Queued. Use Dumps → Sync to upload.');
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _statusError = 'Transcribe failed: $e';
          _statusMessage = null;
        });
      }
    } finally {
      if (mounted) setState(() => _transcribing = false);
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
      final audio = AudioStorage.test(Directory.systemTemp);
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
        data: (row) => _buildBody(context, row),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
      ),
    );
  }

  Widget _buildBody(BuildContext context, DumpRow? row) {
    if (row == null) {
      return const Center(child: Text('Dump not found'));
    }

    final sync = SyncStatus.fromWire(row.syncStatus);
    final mode = DumpMode.fromWire(row.mode);

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
        if (row.transcript != null && row.transcript!.isNotEmpty) ...[
          Text(
            'Transcript',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: SelectableText(row.transcript!),
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
        if (_statusMessage != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(_statusMessage!,
                style: TextStyle(color: Theme.of(context).colorScheme.primary)),
          ),
        if (_statusError != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(_statusError!,
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
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
                icon: _transcribing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.transcribe),
                label: const Text('Transcribe'),
                onPressed: _transcribing ? null : _transcribe,
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

class _MetaChip extends StatelessWidget {
  final String label;
  final Color? color;
  const _MetaChip({required this.label, this.color});

  @override
  Widget build(BuildContext context) {
    return Chip(
      label: Text(label),
      backgroundColor: color?.withOpacity(0.15),
      side: BorderSide(color: color ?? Theme.of(context).colorScheme.outline),
    );
  }
}