// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../data/storage/storage_providers.dart';
import 'local_deletion_presentation.dart';

import '../../data/local_db.dart';
import '../../data/storage/storage_contract.dart';
import 'dump_selection_controller.dart';
import '../../models/sync_status.dart' show SyncStatus, SyncStatusX;
import '../../models/transcription_status.dart';
import 'dump_detail_screen.dart';
import 'dumps_providers.dart';

/// What the `+` FAB on the dumps list asks the home screen to create.
/// The list pops itself with one of these; home switches mode and either
/// opens note compose or starts recording immediately.
enum DumpsCreateAction { textNote, brainDump, meeting }

class DumpsListScreen extends ConsumerStatefulWidget {
  const DumpsListScreen({super.key, this.onOpenDump});
  final void Function(BuildContext, DumpRow)? onOpenDump;

  @override
  ConsumerState<DumpsListScreen> createState() => _DumpsListScreenState();
}

class _DumpsListScreenState extends ConsumerState<DumpsListScreen> {
  final _searchController = TextEditingController();
  bool _searching = false;
  final _selection = DumpSelectionController();
  bool _batchBusy = false;
  final _deletionRecovery = LocalDeletionRecoveryState();
  BulkDeletionResult? get _deleteResult => _deletionRecovery.latest;
  String? _deleteError;
  Object _scope() {
    final r = ref.read(presentedDumpsProvider).valueOrNull;
    return (
      r?.scopeKey,
      r?.generation,
      ref.read(searchQueryProvider),
      ref.read(dumpModeFilterProvider),
      ref.read(transcriptFilterProvider)
    );
  }

  Future<void> _deleteSelected() async {
    if (!mounted ||
        _batchBusy ||
        !_selection.selection.active ||
        _selection.selection.selectedIds.isEmpty) {
      return;
    }
    final source = ref.read(presentedDumpsProvider);
    if (source.isLoading ||
        source.hasError ||
        source.valueOrNull?.settled != true ||
        source.requireValue.generation != _selection.selection.generation ||
        source.requireValue.scopeKey != _selection.selection.scopeKey) {
      return;
    }
    final ids = Set<String>.unmodifiable(_selection.selection.selectedIds);
    final scope = _scope();
    final service = ref.read(localDeletionServiceProvider);
    setState(() => _batchBusy = true);
    try {
      final preview = switch (await service.preview(ids)) {
        Ok<DeletionPreview>(:final value) => value,
        Fail<DeletionPreview>(:final problem) => throw StorageFault(problem),
      };
      if (!mounted || _scope() != scope || !_selection.selection.active) return;
      final targets = List<DeleteTarget>.unmodifiable(preview.targets);
      if (!await confirmLocalDeletion(context, targets.length) || !mounted) {
        return;
      }
      final result = switch (await service.deleteConfirmed(
          (operationId: const Uuid().v4(), targets: targets),)) {
        Ok<BulkDeletionResult>(:final value) => value,
        Fail<BulkDeletionResult>(:final problem) => throw StorageFault(problem),
      };
      if (mounted) {
        setState(() {
          _deletionRecovery.record(result);
          _deleteError = null;
          if (_scope() == scope) _selection.cancel();
        });
      }
    } catch (e) {
      if (mounted) setState(() => _deleteError = 'Local deletion failed: $e');
    } finally {
      if (mounted) setState(() => _batchBusy = false);
    }
  }

  Future<void> _retryDeletion() async {
    if (!mounted || _batchBusy || _deleteResult == null) return;
    final ids = _deletionRecovery.ticketIds;
    if (ids.isEmpty) return;
    final service = ref.read(localDeletionServiceProvider);
    setState(() => _batchBusy = true);
    try {
      if (!await confirmLocalDeletion(context, ids.length, retry: true) ||
          !mounted) {
        return;
      }
      final result = switch (await service
          .retryConfirmed((operationId: const Uuid().v4(), ticketIds: ids))) {
        Ok<BulkDeletionResult>(:final value) => value,
        Fail<BulkDeletionResult>(:final problem) => throw StorageFault(problem),
      };
      if (mounted) {
        setState(() {
          _deletionRecovery.record(result);
          _deleteError = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _deleteError = 'Local deletion retry failed: $e');
      }
    } finally {
      if (mounted) setState(() => _batchBusy = false);
    }
  }

  void _change(VoidCallback action) => setState(action);

  /// Blue `+` FAB: an active mode chip picks the creation directly; under
  /// the All filter a bottom sheet asks which kind to create. Either way
  /// the screen pops with the [DumpsCreateAction] for home to act on.
  Future<void> _onCreatePressed() async {
    final direct = switch (ref.read(dumpModeFilterProvider)) {
      DumpModeFilter.textNote => DumpsCreateAction.textNote,
      DumpModeFilter.brainDump => DumpsCreateAction.brainDump,
      DumpModeFilter.meeting => DumpsCreateAction.meeting,
      DumpModeFilter.all => null,
    };
    final action = direct ??
        await showModalBottomSheet<DumpsCreateAction>(
          context: context,
          builder: (sheetContext) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  key: const ValueKey('create-option-textNote'),
                  leading: const Icon(Icons.sticky_note_2),
                  title: const Text('Text Note'),
                  onTap: () => Navigator.of(sheetContext)
                      .pop(DumpsCreateAction.textNote),
                ),
                ListTile(
                  key: const ValueKey('create-option-brainDump'),
                  leading: const Icon(Icons.psychology),
                  title: const Text('Brain Dump'),
                  onTap: () => Navigator.of(sheetContext)
                      .pop(DumpsCreateAction.brainDump),
                ),
                ListTile(
                  key: const ValueKey('create-option-meeting'),
                  leading: const Icon(Icons.groups),
                  title: const Text('Meeting'),
                  onTap: () => Navigator.of(sheetContext)
                      .pop(DumpsCreateAction.meeting),
                ),
              ],
            ),
          ),
        );
    if (action == null || !mounted) return;
    Navigator.of(context).pop(action);
  }

  @override
  void dispose() {
    _searchController.dispose();
    _selection.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final presented = ref.watch(presentedDumpsProvider);
    final eligibilityAsync = ref.watch(deletionEligibilityProvider);
    final eligibility =
        !eligibilityAsync.isLoading && !eligibilityAsync.hasError
            ? eligibilityAsync.valueOrNull ?? <String, Eligibility>{}
            : <String, Eligibility>{};
    final query = ref.watch(searchQueryProvider);
    final modeFilter = ref.watch(dumpModeFilterProvider);
    final transcriptFilter = ref.watch(transcriptFilterProvider);
    final showingSearch = query.trim().isNotEmpty;
    ref.listen(searchQueryProvider, (_, __) => _selection.cancel());
    ref.listen(dumpModeFilterProvider, (_, __) => _selection.cancel());
    ref.listen(transcriptFilterProvider, (_, __) => _selection.cancel());
    final results = presented.valueOrNull;
    if (results != null) {
      _selection.apply(
        (
          scopeKey: results.scopeKey,
          generation: results.generation,
          settled: results.settled &&
              !presented.isLoading &&
              !presented.hasError &&
              !eligibilityAsync.isLoading &&
              !eligibilityAsync.hasError,
          rows: results.rows,
          limit: results.limit
        ),
        eligibility,
      );
    }
    final selection = _selection.selection;
    final stale = results != null && results.generation < selection.generation;
    final ready = !stale &&
        results?.settled == true &&
        !presented.isLoading &&
        !presented.hasError &&
        !eligibilityAsync.isLoading &&
        !eligibilityAsync.hasError;
    final eligibleIds = results?.rows
            .where((r) => eligibility[r.id] == Eligibility.eligible)
            .map((r) => r.id)
            .toSet() ??
        <String>{};

    return PopScope(
      canPop: !selection.active,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && selection.active) _change(_selection.cancel);
      },
      child: Scaffold(
        floatingActionButton: FloatingActionButton(
          tooltip: 'Add',
          backgroundColor: Theme.of(context).colorScheme.primary,
          foregroundColor: Theme.of(context).colorScheme.onPrimary,
          onPressed: _onCreatePressed,
          child: const Icon(Icons.add),
        ),
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
            if (selection.active)
              Column(
                children: [
                  Row(
                    children: [
                      IconButton(
                          key: const ValueKey('selection-cancel'),
                          tooltip: 'Cancel selection',
                          onPressed: () => _change(_selection.cancel),
                          icon: const Icon(Icons.close),),
                      Expanded(
                          child: Text(
                              '${selection.selectedIds.length} selected',
                              maxLines: 2,),),
                      Semantics(
                        label: 'Select all returned results',
                        excludeSemantics: true,
                        button: true,
                        enabled: ready && !_batchBusy,
                        onTap: ready && !_batchBusy
                            ? () => _change(_selection.toggleAll)
                            : null,
                        checked: selection.selectedIds.isNotEmpty &&
                            selection.selectedIds.containsAll(eligibleIds),
                        mixed: selection.selectedIds.isNotEmpty &&
                            !selection.selectedIds.containsAll(eligibleIds),
                        child: IconButton(
                            key: const ValueKey('selection-all'),
                            tooltip: 'Select all returned results',
                            onPressed: ready && !_batchBusy
                                ? () => _change(_selection.toggleAll)
                                : null,
                            icon: const Icon(Icons.select_all),),
                      ),
                      IconButton(
                          key: const ValueKey('selection-delete'),
                          tooltip: 'Delete selected local recordings',
                          onPressed: ready &&
                                  !_batchBusy &&
                                  selection.selectedIds.isNotEmpty
                              ? _deleteSelected
                              : null,
                          icon: const Icon(Icons.delete_outline),),
                    ],
                  ),
                  if (results?.limit != null)
                    const Text(
                        'Select all covers returned results (100-candidate limit).',
                        textAlign: TextAlign.center,),
                ],
              ),
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
            if (_deleteError != null)
              Text(_deleteError!, textAlign: TextAlign.center),
            if (_deleteResult != null)
              LocalDeletionResults(
                  result: _deleteResult!,
                  pending: _deletionRecovery.pending,
                  onRetry: _retryDeletion,
                  busy: _batchBusy,),
            Expanded(
              child: stale
                  ? const Center(child: Text('Waiting for current results'))
                  : presented.hasError
                      ? Center(
                          child:
                              Text('Results unavailable: ${presented.error}'),)
                      : results == null ||
                              !results.settled ||
                              presented.isLoading
                          ? const Center(child: CircularProgressIndicator())
                          : _DumpList(
                              dumps: results.rows,
                              empty: showingSearch
                                  ? 'No matches'
                                  : 'No dumps yet — record one!',
                              onOpen: widget.onOpenDump,
                              selection: selection,
                              eligibility: eligibility,
                              enabled: ready && !_batchBusy,
                              onEnter: (id) =>
                                  _change(() => _selection.enter(id)),
                              onToggle: (id) =>
                                  _change(() => _selection.toggle(id)),
                            ),
            ),
          ],
        ),
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
  const _DumpList(
      {required this.dumps,
      required this.empty,
      this.onOpen,
      required this.selection,
      required this.eligibility,
      required this.enabled,
      required this.onEnter,
      required this.onToggle,});
  final void Function(BuildContext, DumpRow)? onOpen;
  final DumpSelectionState selection;
  final Map<String, Eligibility> eligibility;
  final bool enabled;
  final ValueChanged<String> onEnter, onToggle;

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
        return LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < 500 ||
                MediaQuery.textScalerOf(context).scale(14) > 21;
            final reason = _eligibilityReason(eligibility[dump.id]);
            final isNote = dump.mode == 'text_note';
            final pill = _TranscriptionStatusPill(
                dumpId: dump.id, status: transcription,);
            final subtitle = Row(children: [
              _SyncBadge(status: sync),
              const SizedBox(width: 6),
              if (isNote) ...[
                Icon(
                  Icons.edit_note,
                  key: ValueKey('note-row-icon-${dump.id}'),
                  size: 16,
                ),
                const SizedBox(width: 6),
              ],
              Expanded(
                  child: Text(_subtitleFor(dump),
                      maxLines: 2, overflow: TextOverflow.ellipsis,),),
            ],);
            return ListTile(
              key: ValueKey('dump-row-${dump.id}'),
              selected: selection.selectedIds.contains(dump.id),
              leading: selection.active
                  ? Tooltip(
                      message: 'Select ${dump.title}; $reason',
                      child: SizedBox.square(
                        dimension: 48,
                        child: Checkbox(
                          key: ValueKey('dump-select-${dump.id}'),
                          shape: const CircleBorder(),
                          semanticLabel: 'Select ${dump.title}; $reason',
                          value: selection.selectedIds.contains(dump.id),
                          onChanged: enabled &&
                                  eligibility[dump.id] == Eligibility.eligible
                              ? (_) => onToggle(dump.id)
                              : null,
                        ),
                      ),
                    )
                  : null,
              title: Text(
                dump.title.isEmpty ? '(untitled)' : dump.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: compact
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [subtitle, const SizedBox(height: 4), pill],)
                  : subtitle,
              trailing: compact ? null : pill,
              onLongPress:
                  enabled && eligibility[dump.id] == Eligibility.eligible
                      ? () => onEnter(dump.id)
                      : null,
              onTap: selection.active
                  ? (enabled && eligibility[dump.id] == Eligibility.eligible
                      ? () => onToggle(dump.id)
                      : null)
                  : () => onOpen != null
                      ? onOpen!(context, dump)
                      : Navigator.of(context).push<void>(
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
      },
    );
  }

  String _eligibilityReason(Eligibility? eligibility) => switch (eligibility) {
        Eligibility.eligible => 'Available for local deletion',
        Eligibility.nonterminal => 'Transcription in progress',
        Eligibility.syncing => 'Sync in progress',
        Eligibility.publicationPending => 'Saving transcript or metadata',
        Eligibility.busy => 'Recording is in use',
        Eligibility.retryOnly => 'Local deletion pending; open recording to retry',
        Eligibility.deleting => 'Local deletion in progress',
        Eligibility.denied => 'Storage permission denied',
        Eligibility.unresolved => 'Original storage is unresolved',
        Eligibility.retired => 'Recording already removed',
        Eligibility.missing => 'Recording unavailable',
        null => 'Checking availability',
      };

  String _subtitleFor(DumpRow dump) {
    final date = dump.createdAt.toLocal().toString().split('.').first;
    if (dump.mode == 'text_note') return date;
    final mins = (dump.durationSeconds / 60).floor();
    final secs = dump.durationSeconds % 60;
    final duration = mins > 0 ? '${mins}m ${secs}s' : '${secs}s';
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
      TranscriptionStatus.notApplicable => (
          'Note',
          Icons.edit_note,
          colors.onSurfaceVariant,
          colors.surfaceContainerHighest,
          colors.outline,
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
          Flexible(
            child: Text(
              label,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: foreground,
                    fontWeight: FontWeight.w600,
                  ),
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
