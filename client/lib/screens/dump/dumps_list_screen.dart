// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../data/storage/storage_providers.dart';
import 'local_deletion_presentation.dart';
import 'sync_status_presentation.dart';

import '../../data/local_db.dart';
import '../../data/storage/storage_contract.dart';
import 'dump_grouping.dart';
import 'dump_selection_controller.dart';
import '../../models/sync_status.dart' show SyncStatus, SyncStatusX;
import '../../models/transcription_status.dart';
import 'dump_detail_screen.dart';
import 'dumps_providers.dart';
import '../../widgets/signal_bars.dart';
import '../../widgets/sync_button.dart';
import '../home/home_providers.dart' show documentSyncEngineProvider;
import '../../services/bulk_dump_actions.dart';
import '../../services/server_transcription_service.dart';
import '../../services/synced_audio_download.dart';
import '../home/home_providers.dart' show serverTranscriptionServiceProvider;
import '../../widgets/item_action_sheet.dart';
import '../../widgets/folder_header_actions.dart';
import '../../widgets/folder_picker.dart';
import '../notebook/notebook_grouping.dart' show FolderSummary;
import '../../data/notebook_repository.dart' show foldersProvider;
import '../home/home_screen.dart' show localDbProvider;

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

  /// Rows with a download in flight. Per-row rather than a single flag: one
  /// slow fetch must not make every other row look busy.
  final Set<String> _downloading = <String>{};
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
        (operationId: const Uuid().v4(), targets: targets),
      )) {
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
                  onTap: () =>
                      Navigator.of(sheetContext).pop(DumpsCreateAction.meeting),
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
    // Everything presented is selectable; the select-all indicator compares
    // against the full result set, not the delete-eligible subset.
    final selectableIds = results?.rows.map((r) => r.id).toSet() ?? <String>{};

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
            if (!_searching)
              SyncButton(engineProvider: documentSyncEngineProvider),
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
                        icon: const Icon(Icons.close),
                      ),
                      Expanded(
                        child: Text(
                          '${selection.selectedIds.length} selected',
                          maxLines: 2,
                        ),
                      ),
                      Semantics(
                        label: 'Select all returned results',
                        excludeSemantics: true,
                        button: true,
                        enabled: ready && !_batchBusy,
                        onTap: ready && !_batchBusy
                            ? () => _change(_selection.toggleAll)
                            : null,
                        checked: selection.selectedIds.isNotEmpty &&
                            selection.selectedIds.containsAll(selectableIds),
                        mixed: selection.selectedIds.isNotEmpty &&
                            !selection.selectedIds.containsAll(selectableIds),
                        child: IconButton(
                          key: const ValueKey('selection-all'),
                          tooltip: 'Select all returned results',
                          onPressed: ready && !_batchBusy
                              ? () => _change(_selection.toggleAll)
                              : null,
                          icon: const Icon(Icons.select_all),
                        ),
                      ),
                      IconButton(
                        key: const ValueKey('selection-download'),
                        tooltip: 'Download audio for selected',
                        onPressed: ready &&
                                !_batchBusy &&
                                selection.selectedIds.isNotEmpty
                            ? _downloadSelected
                            : null,
                        icon: const Icon(Icons.download_for_offline_outlined),
                      ),
                      IconButton(
                        key: const ValueKey('selection-transcribe'),
                        tooltip: 'Transcribe selected',
                        onPressed: ready &&
                                !_batchBusy &&
                                selection.selectedIds.isNotEmpty
                            ? _transcribeSelected
                            : null,
                        icon: const Icon(Icons.text_snippet_outlined),
                      ),
                      IconButton(
                        key: const ValueKey('selection-delete'),
                        tooltip: 'Delete selected local recordings',
                        onPressed: ready &&
                                !_batchBusy &&
                                selection.selectedIds.isNotEmpty
                            ? _deleteSelected
                            : null,
                        icon: const Icon(Icons.delete_outline),
                      ),
                    ],
                  ),
                  if (results?.limit != null)
                    const Text(
                      'Select all covers returned results (100-candidate limit).',
                      textAlign: TextAlign.center,
                    ),
                ],
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
              child: Row(
                children: [
                  Expanded(
                    child: _FilterDropdown<DumpModeFilter>(
                      menuKey: const ValueKey('mode-filter-menu'),
                      label: 'Mode',
                      values: DumpModeFilter.values,
                      selected: modeFilter,
                      keyFor: (choice) =>
                          ValueKey('mode-filter-${choice.name}'),
                      labelFor: (choice) => choice.label,
                      onSelected: (choice) => ref
                          .read(dumpModeFilterProvider.notifier)
                          .state = choice,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _FilterDropdown<TranscriptFilter>(
                      menuKey: const ValueKey('transcript-filter-menu'),
                      label: 'Transcript',
                      values: TranscriptFilter.values,
                      selected: transcriptFilter,
                      keyFor: (choice) =>
                          ValueKey('transcript-filter-${choice.name}'),
                      labelFor: (choice) => choice.label,
                      onSelected: (choice) => ref
                          .read(transcriptFilterProvider.notifier)
                          .state = choice,
                    ),
                  ),
                ],
              ),
            ),
            if (_deleteError != null)
              Text(_deleteError!, textAlign: TextAlign.center),
            if (_deleteResult != null)
              LocalDeletionResults(
                result: _deleteResult!,
                pending: _deletionRecovery.pending,
                onRetry: _retryDeletion,
                busy: _batchBusy,
              ),
            Expanded(
              child: stale
                  ? const Center(child: Text('Waiting for current results'))
                  : presented.hasError
                      ? Center(
                          child:
                              Text('Results unavailable: ${presented.error}'),
                        )
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
                              downloading: _downloading,
                              enabled: ready && !_batchBusy,
                              // Folders mirror the notebooks list; search
                              // results stay flat — a search is already a
                              // selection, and slicing it by folder would
                              // hide hits in collapsed sections.
                              folders: showingSearch
                                  ? const <FolderSummary>[]
                                  : ref.watch(foldersProvider).maybeWhen(
                                        data: (List<Folder> rows) => rows
                                            .map(
                                              (Folder f) => FolderSummary(
                                                id: f.id,
                                                name: f.name,
                                              ),
                                            )
                                            .toList(growable: false),
                                        orElse: () => const <FolderSummary>[],
                                      ),
                              onHeaderLongPress: (
                                String folderId,
                                String name,
                              ) =>
                                  showFolderHeaderActions(
                                context,
                                folderId: folderId,
                                name: name,
                                db: ref.read(localDbProvider),
                              ),
                              onEnter: (id) =>
                                  _change(() => _selection.enter(id)),
                              onToggle: (id) =>
                                  _change(() => _selection.toggle(id)),
                              onLongPressItem: (context, dump) =>
                                  _showItemActions(context, dump, eligibility),
                            ),
            ),
          ],
        ),
      ),
    );
  }

  /// Renames a recording or note.
  ///
  /// The controller is disposed a frame late: disposing it the moment
  /// showDialog returns tears it down while the route is still animating out
  /// and its TextField is still building, which throws "A TextEditingController
  /// was used after being disposed".
  Future<void> _renameDump(DumpRow dump) async {
    final TextEditingController controller =
        TextEditingController(text: dump.title);
    final String? name = await showDialog<String>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('Rename'),
        content: TextField(
          key: const ValueKey('dump-rename-field'),
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Title'),
          onSubmitted: (String value) =>
              Navigator.of(dialogContext).pop(value.trim()),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const ValueKey('dump-rename-save'),
            onPressed: () =>
                Navigator.of(dialogContext).pop(controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => controller.dispose());
    if (!mounted || name == null || name.isEmpty) return;
    try {
      await ref.read(localDbProvider).renameDump(dumpId: dump.id, title: name);
    } catch (e) {
      if (mounted) {
        setState(() => _deleteError = 'Rename failed: $e');
      }
    }
  }

  /// Files a recording or note into a folder.
  Future<void> _moveDump(DumpRow dump) async {
    final LocalDb db = ref.read(localDbProvider);
    final List<Folder> folders = await db.watchFolders().first;
    if (!mounted) return;
    final FolderChoice? choice = await showFolderPicker(
      context,
      folders: folders
          .map((Folder f) => FolderOption(id: f.id, name: f.name))
          .toList(growable: false),
      currentFolderId: dump.folderId,
    );
    if (!mounted || choice == null) return;
    try {
      String? folderId = choice.folderId;
      if (choice.isNewFolder && choice.newFolderName != null) {
        folderId = await db.createFolder(name: choice.newFolderName!);
      }
      await db.moveDumpToFolder(dumpId: dump.id, folderId: folderId);
    } catch (e) {
      if (mounted) {
        setState(() => _deleteError = 'Move failed: $e');
      }
    }
  }

  /// The shared long-press menu for one recording or note.
  ///
  /// Delete deliberately does NOT call a deletion API here. It enters the
  /// existing selection flow with just this row selected, so every local
  /// deletion still goes through the one audited, eligibility-guarded,
  /// retry-aware path in [_deleteSelected] rather than a second one that would
  /// have to re-implement those rules correctly.
  Future<void> _showItemActions(
    BuildContext context,
    DumpRow dump,
    Map<String, Eligibility> eligibility,
  ) async {
    final Eligibility? state = eligibility[dump.id];
    final bool deletable = state == Eligibility.eligible;
    // Offered only when the server holds audio this device does not. A row
    // that already has its bytes has nothing to fetch.
    final bool downloadable = dumpNeedsAudioDownload(dump);
    final bool canDownload =
        downloadable && ref.read(syncedAudioDownloaderProvider) != null;
    final ItemAction? action = await showItemActionSheet(
      context,
      title: dump.title.isEmpty ? '(untitled)' : dump.title,
      subtitle: dumpSubtitle(dump),
      actions: <ItemAction>[
        ItemAction.open,
        if (downloadable) ItemAction.download,
        ItemAction.rename,
        ItemAction.move,
        ItemAction.select,
        ItemAction.delete,
      ],
      disabledActions: <ItemAction, String>{
        if (!deletable) ItemAction.delete: eligibilityReason(state),
        // Shown-but-disabled rather than hidden: a control that vanishes
        // reads as a bug, while a greyed row carrying the reason explains
        // the app.
        if (downloadable && !canDownload)
          ItemAction.download: 'Choose a storage folder first',
      },
    );
    if (!mounted || action == null) return;

    switch (action) {
      case ItemAction.open:
        if (!context.mounted) return;
        if (widget.onOpenDump != null) {
          widget.onOpenDump!(context, dump);
        } else {
          await Navigator.of(context).push<void>(
            MaterialPageRoute<void>(
              builder: (_) => DumpDetailScreen(
                dumpId: dump.id,
                audioPath: dump.audioPath,
                durationSeconds: dump.durationSeconds,
              ),
            ),
          );
        }
      case ItemAction.rename:
        await _renameDump(dump);
      case ItemAction.move:
        await _moveDump(dump);
      case ItemAction.select:
        _change(() => _selection.enter(dump.id));
      case ItemAction.delete:
        // Select this row, then run the same bulk path the toolbar uses.
        _change(() => _selection.enter(dump.id));
        await _deleteSelected();
      case ItemAction.download:
        await _downloadAudio(dump);
      case ItemAction.duplicate:
      case ItemAction.share:
      case ItemAction.exportPdf:
        break;
    }
  }

  /// Downloads audio for every selected recording that needs it.
  ///
  /// Selection is cleared only AFTER the run: while rows are being worked,
  /// the user can still see what they asked for. `_batchBusy` serializes
  /// this against delete and transcribe — two bulk runs interleaving over
  /// one selection would produce a receipt neither run can explain.
  Future<void> _downloadSelected() async {
    final SyncedAudioDownloader? downloader =
        ref.read(syncedAudioDownloaderProvider);
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    if (downloader == null) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Choose a storage folder first'),
        ),
      );
      return;
    }
    final List<DumpRow> rows = _selectedRows();
    setState(() => _batchBusy = true);
    BulkActionSummary summary;
    try {
      summary = await runBulkDownload(
        rows: rows,
        download: (String id) async {
          setState(() => _downloading.add(id));
          try {
            return switch (await downloader.download(id)) {
              Ok<String>() => null,
              // The service's wording is written for the user; carry it into
              // the receipt rather than flattening to a count.
              Fail<String>(:final StorageProblem problem) => problem.message,
            };
          } finally {
            if (mounted) setState(() => _downloading.remove(id));
          }
        },
      );
    } finally {
      if (mounted) setState(() => _batchBusy = false);
    }
    if (!mounted) return;
    _change(_selection.cancel);
    _showBulkReceipt(messenger, summary);
  }

  /// Queues transcription for every selected recording that can transcribe
  /// without a question: local audio, no transcript worth protecting.
  ///
  /// Completed rows are skipped BY DESIGN — the per-row flow confirms before
  /// overwriting and a bulk loop cannot ask, so it must not overwrite.
  Future<void> _transcribeSelected() async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final ServerTranscriptionService service =
        ref.read(serverTranscriptionServiceProvider);
    final List<DumpRow> rows = _selectedRows();
    setState(() => _batchBusy = true);
    BulkActionSummary summary;
    try {
      summary = await runBulkTranscribe(
        rows: rows,
        transcribe: service.transcribeDump,
      );
    } finally {
      if (mounted) setState(() => _batchBusy = false);
    }
    if (!mounted) return;
    _change(_selection.cancel);
    _showBulkReceipt(messenger, summary, resultKey: 'bulk-transcribe-result');
  }

  /// Shows the one-line receipt, and — when rows failed — a Details action
  /// opening the per-row reasons. The count alone cannot tell a Wi-Fi gate
  /// from a dead server from a fenced identity, and 43 indistinguishable
  /// failures cost a debugging session; the reasons are already in hand.
  void _showBulkReceipt(
    ScaffoldMessengerState messenger,
    BulkActionSummary summary, {
    String resultKey = 'bulk-download-result',
  }) {
    final Map<String, String> titles = <String, String>{
      for (final DumpRow row
          in ref.read(presentedDumpsProvider).valueOrNull?.rows ??
              const <DumpRow>[])
        row.id: row.title.isEmpty ? '(untitled)' : row.title,
    };
    messenger.showSnackBar(
      SnackBar(
        key: ValueKey<String>(resultKey),
        content: Text(describeBulkSummary(summary)),
        action: summary.failures.isEmpty
            ? null
            : SnackBarAction(
                label: 'Details',
                onPressed: () => _showBulkFailures(summary, titles),
              ),
      ),
    );
  }

  /// The per-row failure list: each failed row by TITLE with the storage
  /// layer's own wording, scrollable because a bulk run can fail dozens of
  /// rows at once.
  void _showBulkFailures(
    BulkActionSummary summary,
    Map<String, String> titles,
  ) {
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        key: const ValueKey<String>('bulk-failure-details'),
        title: Text('${summary.failed} failed'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.separated(
            shrinkWrap: true,
            itemCount: summary.failures.length,
            separatorBuilder: (_, __) => const Divider(height: 12),
            itemBuilder: (BuildContext context, int index) {
              final BulkFailure failure = summary.failures[index];
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    titles[failure.id] ?? failure.id,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    failure.reason,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              );
            },
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  /// The selected rows in list order, resolved from the presented results —
  /// the same rows the user is looking at, not a fresh query that might
  /// have shifted under them.
  List<DumpRow> _selectedRows() {
    final Set<String> ids = _selection.selection.selectedIds;
    final PresentedDumpResults? results =
        ref.read(presentedDumpsProvider).valueOrNull;
    return <DumpRow>[
      for (final DumpRow row in results?.rows ?? const <DumpRow>[])
        if (ids.contains(row.id)) row,
    ];
  }

  /// Fetches a synced recording's audio onto this device.
  ///
  /// Reports the outcome either way. While a download renders as idle, a
  /// stalled fetch, a refused one and a dead button all look identical, so
  /// the busy state is an instrument rather than decoration.
  Future<void> _downloadAudio(DumpRow dump) async {
    final SyncedAudioDownloader? downloader =
        ref.read(syncedAudioDownloaderProvider);
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    if (downloader == null) {
      // Never fail silently: a tapped control that does nothing reads as a
      // broken app. Say why.
      messenger.showSnackBar(
        const SnackBar(content: Text('Choose a storage folder first')),
      );
      return;
    }

    setState(() => _downloading.add(dump.id));
    Outcome<String> result;
    try {
      result = await downloader.download(dump.id);
    } finally {
      if (mounted) setState(() => _downloading.remove(dump.id));
    }
    if (!mounted) return;

    messenger.showSnackBar(
      SnackBar(
        key: const ValueKey<String>('download-audio-result'),
        content: Text(
          switch (result) {
            Ok<String>() => 'Audio downloaded',
            // The service's wording is written for the user; show it as-is
            // rather than flattening every failure to "download failed".
            Fail<String>(:final StorageProblem problem) => problem.message,
          },
        ),
      ),
    );
  }
}

/// One filter as a dropdown: the closed anchor names the filter and its
/// ACTIVE selection ("Mode · Text Note"), so state stays readable without
/// opening anything. Menu items keep the chip-era keys
/// (`mode-filter-<name>`) — four test files select by them, and a stable key
/// makes this change mechanical for them: open the menu, then tap the same
/// key as before.
class _FilterDropdown<T> extends StatelessWidget {
  const _FilterDropdown({
    required this.menuKey,
    required this.label,
    required this.values,
    required this.selected,
    required this.keyFor,
    required this.labelFor,
    required this.onSelected,
  });

  final Key menuKey;
  final String label;
  final List<T> values;
  final T selected;
  final Key Function(T value) keyFor;
  final String Function(T value) labelFor;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return MenuAnchor(
      menuChildren: [
        for (final choice in values)
          MenuItemButton(
            key: keyFor(choice),
            leadingIcon: choice == selected
                ? const Icon(Icons.check, size: 18)
                : const SizedBox.square(dimension: 18),
            onPressed: () => onSelected(choice),
            child: Text(labelFor(choice)),
          ),
      ],
      builder: (context, controller, _) => OutlinedButton.icon(
        key: menuKey,
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
        style: OutlinedButton.styleFrom(
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        ),
        icon: const Icon(Icons.arrow_drop_down),
        iconAlignment: IconAlignment.end,
        label: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                '$label · ${labelFor(selected)}',
                style: theme.textTheme.labelLarge,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DumpList extends StatefulWidget {
  const _DumpList({
    required this.dumps,
    required this.empty,
    this.onOpen,
    required this.selection,
    required this.eligibility,
    this.downloading = const <String>{},
    required this.enabled,
    required this.onEnter,
    required this.onToggle,
    this.onLongPressItem,
    this.folders = const <FolderSummary>[],
    this.onHeaderLongPress,
  });

  /// Folders presented as section headers, mirroring the notebooks list.
  final List<FolderSummary> folders;

  /// Long-press on a REAL folder header (never the 'No folder' one).
  final void Function(String folderId, String name)? onHeaderLongPress;
  final void Function(BuildContext, DumpRow)? onOpen;
  final DumpSelectionState selection;
  final Map<String, Eligibility> eligibility;

  /// Ids whose audio download is in flight right now. A fetch can take
  /// seconds; a row that shows nothing while working reads as a dead tap.
  final Set<String> downloading;

  final bool enabled;
  final ValueChanged<String> onEnter, onToggle;

  /// Opens the shared long-press menu for one row.
  ///
  /// Long-press here used to jump straight into multi-select. It still does
  /// once a selection is active — that is the audited bulk-delete path — but
  /// with no selection it opens the same sheet as every other list, which
  /// offers Select as one of its actions.
  final Future<void> Function(BuildContext, DumpRow)? onLongPressItem;

  final List<DumpRow> dumps;
  final String empty;

  @override
  State<_DumpList> createState() => _DumpListState();
}

class _DumpListState extends State<_DumpList> {
  /// Session-scoped collapse state, same contract as the notebooks list.
  final Set<String> _collapsed = <String>{};

  @override
  Widget build(BuildContext context) {
    if (widget.dumps.isEmpty && widget.folders.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(widget.empty, textAlign: TextAlign.center),
        ),
      );
    }
    final List<DumpSection> sections = groupDumps(
      dumps: widget.dumps,
      folders: widget.folders,
    );
    // The flat path: no folders exist, so no headers -- the list a user who
    // never opted into folders has always had.
    if (sections.length == 1 && sections.first.title == null) {
      return ListView.separated(
        itemCount: widget.dumps.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (context, index) => _rowTile(widget.dumps[index]),
      );
    }
    final List<Widget> children = <Widget>[];
    for (final DumpSection section in sections) {
      final String sectionKey = section.folderId ?? 'unfiled';
      final bool collapsed = _collapsed.contains(sectionKey);
      children.add(
        InkWell(
          key: ValueKey<String>('dump-section-$sectionKey'),
          onTap: () => setState(() {
            if (!_collapsed.remove(sectionKey)) _collapsed.add(sectionKey);
          }),
          // Only real folders have actions; the 'No folder' pseudo-section
          // is not a folder and cannot be renamed or deleted.
          onLongPress:
              section.folderId == null || widget.onHeaderLongPress == null
                  ? null
                  : () => widget.onHeaderLongPress!(
                        section.folderId!,
                        section.title!,
                      ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Row(
              children: <Widget>[
                Icon(
                  collapsed ? Icons.chevron_right : Icons.expand_more,
                  size: 20,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    section.title!,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                Text(
                  '${section.dumps.length}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
      );
      if (collapsed) continue;
      if (section.isEmpty) {
        children.add(
          const Padding(
            padding: EdgeInsets.fromLTRB(40, 0, 16, 12),
            child: Text('Empty'),
          ),
        );
        continue;
      }
      for (final DumpRow dump in section.dumps) {
        children.add(_rowTile(dump));
        children.add(const Divider(height: 1));
      }
    }
    return ListView(children: children);
  }

  Widget _rowTile(DumpRow dump) {
    return Builder(
      builder: (context) {
        final sync = SyncStatusX.fromWire(dump.syncStatus);
        final transcription =
            TranscriptionStatus.fromWire(dump.transcriptionStatus);
        return LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < 500 ||
                MediaQuery.textScalerOf(context).scale(14) > 21;
            final reason = eligibilityReason(widget.eligibility[dump.id]);
            final isNote = dump.mode == 'text_note';
            final pill = _TranscriptionStatusPill(
              dumpId: dump.id,
              status: transcription,
            );
            final subtitle = Row(
              children: [
                _SyncBadge(status: sync),
                const SizedBox(width: 6),
                // An in-flight audio fetch replaces the idle motif: the row
                // is WORKING, and nothing else on screen says so.
                if (widget.downloading.contains(dump.id)) ...[
                  SizedBox.square(
                    dimension: 14,
                    child: CircularProgressIndicator(
                      key: ValueKey('dump-downloading-${dump.id}'),
                      strokeWidth: 2,
                    ),
                  ),
                  const SizedBox(width: 8),
                ] else if (isNote) ...[
                  Icon(
                    Icons.edit_note,
                    key: ValueKey('note-row-icon-${dump.id}'),
                    size: 16,
                  ),
                  const SizedBox(width: 6),
                ] else ...[
                  // The waveform motif: audio always looks like audio. Idle rows
                  // stay dim and unglowed so a long list costs nothing extra.
                  SignalBars(
                    key: ValueKey('dump-waveform-${dump.id}'),
                    seed: dump.id,
                    barCount: 14,
                    height: 14,
                  ),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: Text(
                    dumpSubtitle(dump),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            );
            return ListTile(
              key: ValueKey('dump-row-${dump.id}'),
              selected: widget.selection.selectedIds.contains(dump.id),
              leading: widget.selection.active
                  ? Tooltip(
                      message: 'Select ${dump.title}; $reason',
                      child: SizedBox.square(
                        dimension: 48,
                        child: Checkbox(
                          key: ValueKey('dump-select-${dump.id}'),
                          shape: const CircleBorder(),
                          semanticLabel: 'Select ${dump.title}; $reason',
                          value: widget.selection.selectedIds.contains(dump.id),
                          // Selection is action-agnostic: any presented row
                          // may be selected. Delete/download/transcribe each
                          // decide widget.eligibility at execution and report skips.
                          onChanged: widget.enabled
                              ? (_) => widget.onToggle(dump.id)
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
                      children: [subtitle, const SizedBox(height: 4), pill],
                    )
                  : subtitle,
              // The ⋮ button carries per-item actions, so long-press can stay
              // multi-select. Hidden during selection: a menu that mutates one
              // row while several are selected is ambiguous, and the toolbar
              // already owns bulk actions.
              trailing: widget.selection.active
                  ? (compact ? null : pill)
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        if (!compact) pill,
                        IconButton(
                          key: ValueKey<String>('dump-more-${dump.id}'),
                          icon: const Icon(Icons.more_vert),
                          tooltip: 'More actions',
                          onPressed: !widget.enabled ||
                                  widget.onLongPressItem == null
                              ? null
                              : () => widget.onLongPressItem!(context, dump),
                        ),
                      ],
                    ),
              // Long-press stays multi-select here. It is the entry point to
              // the audited bulk local-deletion flow, and 28 tests encode that
              // contract deliberately ("long press selects; row and circular
              // control never navigate"). Per-item actions get their own ⋮
              // button instead — the same split Drive, Files and Samsung's
              // own apps use, so the gesture is not overloaded.
              onLongPress:
                  widget.enabled ? () => widget.onEnter(dump.id) : null,
              onTap: widget.selection.active
                  ? (widget.enabled ? () => widget.onToggle(dump.id) : null)
                  : () => widget.onOpen != null
                      ? widget.onOpen!(context, dump)
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
}

/// Shared by the list rows and the long-press sheet, so the wording a user
/// sees for an ineligible recording is identical in both places.
String eligibilityReason(Eligibility? eligibility) => switch (eligibility) {
      Eligibility.eligible => 'Available for local deletion',
      Eligibility.nonterminal => 'Transcription in progress',
      Eligibility.syncing => 'Sync in progress',
      Eligibility.publicationPending => 'Saving transcript or metadata',
      Eligibility.busy => 'Recording is in use',
      Eligibility.retryOnly =>
        'Local deletion pending; open recording to retry',
      Eligibility.deleting => 'Local deletion in progress',
      Eligibility.denied => 'Storage permission denied',
      Eligibility.unresolved => 'Original storage is unresolved',
      Eligibility.retired => 'Recording already removed',
      Eligibility.missing => 'Recording unavailable',
      null => 'Checking availability',
    };

String dumpSubtitle(DumpRow dump) {
  final date = dump.createdAt.toLocal().toString().split('.').first;
  if (dump.mode == 'text_note') return date;
  final mins = (dump.durationSeconds / 60).floor();
  final secs = dump.durationSeconds % 60;
  final duration = mins > 0 ? '${mins}m ${secs}s' : '${secs}s';
  return '$duration · $date';
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
    final color = syncStatusColor(status);
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
