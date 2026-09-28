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
            wordTimestamps: o.wordTimestamps,
          ),
        );
    await ref.read(settingsStoreProvider).setObsidianExportTimestamps(value);
  }

  Future<void> _setSummary(bool value) async {
    ref.read(obsidianMarkdownOptionsProvider.notifier).update(
          (o) => TranscriptMarkdownOptions(
            timestamps: o.timestamps,
            includeSummary: value,
            wordTimestamps: o.wordTimestamps,
          ),
        );
    await ref.read(settingsStoreProvider).setObsidianExportSummary(value);
  }

  Future<void> _setWordTimestamps(bool value) async {
    ref.read(obsidianMarkdownOptionsProvider.notifier).update(
          (o) => TranscriptMarkdownOptions(
            timestamps: o.timestamps,
            includeSummary: o.includeSummary,
            wordTimestamps: value,
          ),
        );
    await ref
        .read(settingsStoreProvider)
        .setObsidianExportWordTimestamps(value);
  }

  @override
  Widget build(BuildContext context) {
    final options = ref.watch(obsidianMarkdownOptionsProvider);
    // L4: the word switch exists only when some recording has word-level
    // timings — otherwise it could change nothing, and a control that
    // silently does nothing reads as broken. While the lookup is still
    // running (or failed) the switch is absent, not disabled.
    final bool wordTimingsExist =
        ref.watch(obsidianWordTimingsAvailableProvider).value ?? false;
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
        if (wordTimingsExist)
          SwitchListTile(
            key: const ValueKey<String>('obsidian-word-timestamps'),
            title: const Text('Include word timestamps'),
            subtitle: const Text(
              'A word⁽mm:ss⁾ marker on the first and every 10th word of a '
              'line (needs Include timestamps)',
            ),
            value: options.wordTimestamps,
            // Markers ride the segment lines: without those there is
            // nothing to mark, so the switch is disabled, not silent.
            onChanged:
                _running || !options.timestamps ? null : _setWordTimestamps,
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
            'Writes every recording and notebook as a markdown file into '
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
