// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Settings → Export → "Export to Obsidian…" (2026-09-23). One-shot: every
// dump and notebook becomes a markdown file under Obsidian Export/ in the
// storage folder, ready for a vault to index.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/obsidian_export.dart';
import '../../services/transcript_markdown.dart';
import '../../theme/tangent_tokens.dart';
import 'settings_screen.dart' show settingsStoreProvider;

class ObsidianExportSection extends ConsumerStatefulWidget {
  const ObsidianExportSection({super.key});

  @override
  ConsumerState<ObsidianExportSection> createState() =>
      _ObsidianExportSectionState();
}

class _ObsidianExportSectionState extends ConsumerState<ObsidianExportSection> {
  bool _running = false;
  String? _progress;

  Future<void> _export() async {
    setState(() {
      _running = true;
      _progress = null;
    });
    try {
      final summary = await ref.read(obsidianExporterProvider).run(
        onProgress: (done, total, name) {
          if (mounted) {
            setState(() => _progress = 'Exporting $done of $total — $name');
          }
        },
      );
      if (!mounted) return;
      final text = summary.failed.isEmpty
          ? 'Exported ${summary.exported} '
              '${summary.exported == 1 ? 'note' : 'notes'} to Obsidian Export'
          : 'Exported ${summary.exported}, '
              '${summary.failed.length} failed: '
              '${summary.failed.map((f) => f.name).join(', ')}';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(text),
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

  Future<void> _setTimestamps(bool value) async {
    ref.read(obsidianMarkdownOptionsProvider.notifier).update(
          (o) => TranscriptMarkdownOptions(
            timestamps: value,
            includeSummary: o.includeSummary,
          ),
        );
    await ref.read(settingsStoreProvider).setObsidianExportTimestamps(value);
  }

  Future<void> _setSummary(bool value) async {
    ref.read(obsidianMarkdownOptionsProvider.notifier).update(
          (o) => TranscriptMarkdownOptions(
            timestamps: o.timestamps,
            includeSummary: value,
          ),
        );
    await ref.read(settingsStoreProvider).setObsidianExportSummary(value);
  }

  @override
  Widget build(BuildContext context) {
    final options = ref.watch(obsidianMarkdownOptionsProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile(
          key: const ValueKey<String>('obsidian-timestamps'),
          title: const Text('Include timestamps'),
          subtitle: const Text(
            'One line per transcript segment, [mm:ss] Name: text',
          ),
          value: options.timestamps,
          onChanged: _running ? null : _setTimestamps,
        ),
        SwitchListTile(
          key: const ValueKey<String>('obsidian-summary'),
          title: const Text('Include summary'),
          subtitle: const Text('A Summary section when a recording has one'),
          value: options.includeSummary,
          onChanged: _running ? null : _setSummary,
        ),
        ListTile(
          title: const Text('Export to Obsidian…'),
          subtitle: _running && _progress != null ? Text(_progress!) : null,
          trailing: _running
              ? const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.upload_file_outlined),
          onTap: _running ? null : _export,
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 4, 16, 12),
          child: Text(
            'Writes every brain dump and notebook as a markdown file into '
            'an "Obsidian Export" folder inside your recordings folder. '
            'Point an Obsidian vault at it (or copy it into one) and your '
            'notes are searchable there. Transcripts export as text; '
            'handwritten ink is noted but not drawn. Running it again '
            'overwrites the previous export with current notes.',
            style: TextStyle(fontSize: 12, color: TangentColors.textDim),
          ),
        ),
      ],
    );
  }
}
