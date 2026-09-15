// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/local_db.dart';
import '../../models/sync_status.dart' show SyncStatus, SyncStatusX;
import '../../models/transcription_status.dart';
import 'dump_detail_screen.dart';
import 'dumps_providers.dart';

class DumpsListScreen extends ConsumerStatefulWidget {
  const DumpsListScreen({super.key});

  @override
  ConsumerState<DumpsListScreen> createState() => _DumpsListScreenState();
}

class _DumpsListScreenState extends ConsumerState<DumpsListScreen> {
  final _searchController = TextEditingController();
  bool _searching = false;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dumpsAsync = ref.watch(filteredDumpsProvider);
    final query = ref.watch(searchQueryProvider);
    final modeFilter = ref.watch(dumpModeFilterProvider);
    final transcriptFilter = ref.watch(transcriptFilterProvider);
    final searchAsync = ref.watch(searchResultsProvider);
    final showingSearch = query.trim().isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: _searching
            ? TextField(
                controller: _searchController,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: 'Search dumps…',
                  border: InputBorder.none,
                ),
                onChanged: (value) =>
                    ref.read(searchQueryProvider.notifier).state = value,
              )
            : const Text('Dumps'),
        actions: [
          if (_searching)
            IconButton(
              icon: const Icon(Icons.close),
              tooltip: 'Close search',
              onPressed: () {
                _searchController.clear();
                ref.read(searchQueryProvider.notifier).state = '';
                setState(() => _searching = false);
              },
            )
          else
            IconButton(
              icon: const Icon(Icons.search),
              tooltip: 'Search',
              onPressed: () => setState(() => _searching = true),
            ),
        ],
      ),
      body: Column(
        children: [
          _FilterRow<DumpModeFilter>(
            label: 'Mode',
            values: DumpModeFilter.values,
            selected: modeFilter,
            keyFor: (choice) => ValueKey('mode-filter-${choice.name}'),
            labelFor: (choice) => choice.label,
            onSelected: (choice) =>
                ref.read(dumpModeFilterProvider.notifier).state = choice,
          ),
          _FilterRow<TranscriptFilter>(
            label: 'Transcript',
            values: TranscriptFilter.values,
            selected: transcriptFilter,
            keyFor: (choice) => ValueKey('transcript-filter-${choice.name}'),
            labelFor: (choice) => choice.label,
            onSelected: (choice) =>
                ref.read(transcriptFilterProvider.notifier).state = choice,
          ),
          Expanded(
            child: showingSearch
                ? searchAsync.when(
                    data: (results) => _DumpList(
                      dumps: results,
                      empty: 'No matches',
                    ),
                    loading: () =>
                        const Center(child: CircularProgressIndicator()),
                    error: (error, _) =>
                        Center(child: Text('Search error: $error')),
                  )
                : dumpsAsync.when(
                    data: (dumps) => _DumpList(
                      dumps: dumps,
                      empty: 'No dumps yet — record one!',
                    ),
                    loading: () =>
                        const Center(child: CircularProgressIndicator()),
                    error: (error, _) =>
                        Center(child: Text('DB error: $error')),
                  ),
          ),
        ],
      ),
    );
  }
}

class _FilterRow<T> extends StatelessWidget {
  const _FilterRow({
    required this.label,
    required this.values,
    required this.selected,
    required this.keyFor,
    required this.labelFor,
    required this.onSelected,
  });

  final String label;
  final List<T> values;
  final T selected;
  final Key Function(T value) keyFor;
  final String Function(T value) labelFor;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 72,
            child: Text(
              label,
              style: Theme.of(context).textTheme.labelLarge,
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final choice in values) ...[
                    FilterChip(
                      key: keyFor(choice),
                      label: Text(labelFor(choice)),
                      selected: selected == choice,
                      onSelected: (_) => onSelected(choice),
                    ),
                    const SizedBox(width: 8),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DumpList extends StatelessWidget {
  const _DumpList({required this.dumps, required this.empty});

  final List<DumpRow> dumps;
  final String empty;

  @override
  Widget build(BuildContext context) {
    if (dumps.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(empty, textAlign: TextAlign.center),
        ),
      );
    }
    return ListView.separated(
      itemCount: dumps.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final dump = dumps[index];
        final sync = SyncStatusX.fromWire(dump.syncStatus);
        final transcription =
            TranscriptionStatus.fromWire(dump.transcriptionStatus);
        return ListTile(
          title: Text(
            dump.title.isEmpty ? '(untitled)' : dump.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Row(
            children: [
              _SyncBadge(status: sync),
              const SizedBox(width: 6),
              Expanded(child: Text(_subtitleFor(dump))),
            ],
          ),
          trailing: _TranscriptionStatusPill(
            dumpId: dump.id,
            status: transcription,
          ),
          onTap: () => Navigator.of(context).push<void>(
            MaterialPageRoute<void>(
              builder: (_) => DumpDetailScreen(
                dumpId: dump.id,
                audioPath: dump.audioPath,
                durationSeconds: dump.durationSeconds,
              ),
            ),
          ),
        );
      },
    );
  }

  String _subtitleFor(DumpRow dump) {
    final mins = (dump.durationSeconds / 60).floor();
    final secs = dump.durationSeconds % 60;
    final duration = mins > 0 ? '${mins}m ${secs}s' : '${secs}s';
    final date = dump.createdAt.toLocal().toString().split('.').first;
    return '$duration · $date';
  }
}

class _TranscriptionStatusPill extends StatelessWidget {
  const _TranscriptionStatusPill({
    required this.dumpId,
    required this.status,
  });

  final String dumpId;
  final TranscriptionStatus status;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final slug = status.wireValue.replaceAll('_', '-');
    final (label, icon, foreground, background, border) = switch (status) {
      TranscriptionStatus.notTranscribed => (
          'Not transcribed',
          Icons.radio_button_unchecked,
          colors.onSurfaceVariant,
          colors.surfaceContainerHighest,
          colors.outline,
        ),
      TranscriptionStatus.uploading => (
          'Uploading',
          Icons.cloud_upload_outlined,
          colors.onPrimaryContainer,
          colors.primaryContainer,
          colors.primary,
        ),
      TranscriptionStatus.queued => (
          'Queued',
          Icons.schedule,
          colors.onPrimaryContainer,
          colors.primaryContainer,
          colors.primary,
        ),
      TranscriptionStatus.running => (
          'Transcribing',
          null,
          colors.onPrimaryContainer,
          colors.primaryContainer,
          colors.primary,
        ),
      TranscriptionStatus.completed => (
          'Transcribed',
          Icons.check_circle_outline,
          colors.onTertiaryContainer,
          colors.tertiaryContainer,
          colors.tertiary,
        ),
      TranscriptionStatus.failed => (
          'Failed',
          Icons.error_outline,
          colors.onErrorContainer,
          colors.errorContainer,
          colors.error,
        ),
    };
    return Container(
      key: ValueKey('transcription-pill-$dumpId-$slug'),
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: background,
        border: Border.all(color: border),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon == null)
            SizedBox.square(
              dimension: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: foreground,
              ),
            )
          else
            Icon(icon, size: 16, color: foreground),
          const SizedBox(width: 5),
          Text(
            label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: foreground,
                  fontWeight: FontWeight.w600,
                ),
          ),
        ],
      ),
    );
  }
}

class _SyncBadge extends StatelessWidget {
  const _SyncBadge({required this.status});

  final SyncStatus status;

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      SyncStatus.synced => Colors.green,
      SyncStatus.syncing => Colors.blue,
      SyncStatus.pending => Colors.orange,
      SyncStatus.failed => Colors.red,
      SyncStatus.localOnly => Colors.grey,
    };
    final icon = switch (status) {
      SyncStatus.synced => Icons.cloud_done,
      SyncStatus.syncing => Icons.cloud_sync,
      SyncStatus.pending => Icons.cloud_upload,
      SyncStatus.failed => Icons.cloud_off,
      SyncStatus.localOnly => Icons.smartphone,
    };
    return Tooltip(
      message: status.displayName,
      child: Icon(icon, color: color, size: 16),
    );
  }
}
