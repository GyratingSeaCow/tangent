// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/storage/storage_contract.dart';
import '../dump/dump_detail_screen.dart';
import '../home/home_providers.dart';

/// Compose a typed text note. Saving is explicit: the Save action stays
/// disabled while the note is blank, and leaving with typed text asks for
/// confirmation before discarding. A successful save replaces this route
/// with the note's detail screen; a failed save reports the problem in a
/// SnackBar and preserves the typed text for retry.
class NoteComposeScreen extends ConsumerStatefulWidget {
  const NoteComposeScreen({super.key});

  @override
  ConsumerState<NoteComposeScreen> createState() => _NoteComposeScreenState();
}

class _NoteComposeScreenState extends ConsumerState<NoteComposeScreen> {
  final _controller = TextEditingController();
  bool _saving = false;

  bool get _hasText => _controller.text.trim().isNotEmpty;

  @override
  void initState() {
    super.initState();
    // Re-evaluate the Save gate (and the pop gate) on every keystroke.
    _controller.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final row = await ref
          .read(notePersistenceProvider)
          .saveNote(text: _controller.text, now: DateTime.now());
      if (!mounted) return;
      unawaited(
        Navigator.of(context).pushReplacement(
          MaterialPageRoute<void>(
            builder: (_) => DumpDetailScreen(
              dumpId: row.id,
              audioPath: row.audioPath,
              durationSeconds: 0,
            ),
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      // The typed text stays in the field; only the failure is reported.
      final problem =
          error is StorageFault ? error.problem.message : '$error';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Note save failed: $problem')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _confirmDiscard() async {
    final discard = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Discard note?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Keep editing'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    if (discard == true && mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_hasText && !_saving,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || _saving) return;
        unawaited(_confirmDiscard());
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Text Note'),
          actions: [
            TextButton(
              onPressed: _hasText && !_saving ? _save : null,
              child: const Text('Save'),
            ),
          ],
        ),
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: TextField(
            controller: _controller,
            maxLines: null,
            autofocus: true,
            enabled: !_saving,
            decoration: const InputDecoration(
              hintText: 'Type your note…',
              border: InputBorder.none,
            ),
          ),
        ),
      ),
    );
  }
}
