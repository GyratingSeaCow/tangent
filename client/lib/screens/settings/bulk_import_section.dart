// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Settings → Import audio files… (bulk; item 1.4, decided 2026-09-23).
// The home-screen button stays single-file; this is the batch door.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../screens/home/home_providers.dart';
import '../../services/bulk_audio_import.dart';
import '../../theme/tangent_tokens.dart';

class BulkImportSection extends ConsumerStatefulWidget {
  const BulkImportSection({super.key});

  @override
  ConsumerState<BulkImportSection> createState() => _BulkImportSectionState();
}

class _BulkImportSectionState extends ConsumerState<BulkImportSection> {
  bool _running = false;
  String? _progress;

  Future<void> _import() async {
    final files = await ref.read(bulkAudioFilePickerProvider).pickMany();
    if (files.isEmpty || !mounted) return; // cancelled or nothing usable

    setState(() {
      _running = true;
      _progress = null;
    });
    try {
      final summary = await runBulkImport(
        files: files,
        runner: ref.read(audioImportRunnerProvider),
        onProgress: (done, total, name) {
          if (mounted) {
            setState(() => _progress = 'Importing $done of $total — $name');
          }
        },
      );
      if (!mounted) return;
      final text = summary.failed.isEmpty
          ? 'Imported ${summary.imported} '
              '${summary.imported == 1 ? 'file' : 'files'}'
          : 'Imported ${summary.imported}, '
              '${summary.failed.length} failed: '
              '${summary.failed.map((f) => f.name).join(', ')}';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(text),
          // Failure lists deserve reading time.
          duration: summary.failed.isEmpty
              ? const Duration(seconds: 4)
              : const Duration(seconds: 10),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _running = false;
          _progress = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text(
            'Import',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
        ListTile(
          title: const Text('Import audio files…'),
          subtitle: _running && _progress != null ? Text(_progress!) : null,
          trailing: _running
              ? const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.library_music_outlined),
          onTap: _running ? null : _import,
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 4, 16, 12),
          child: Text(
            'Bring in existing recordings — voice memos, meeting audio, '
            'files from another app. Each file becomes a normal brain dump '
            'you can transcribe. A file that fails is skipped and named at '
            'the end; the rest still import.',
            style: TextStyle(fontSize: 12, color: TangentColors.textDim),
          ),
        ),
      ],
    );
  }
}
