// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/storage/storage_contract.dart';
import '../../data/storage/storage_providers.dart';

class StorageSettingsSection extends ConsumerStatefulWidget {
  const StorageSettingsSection({super.key});
  @override
  ConsumerState<StorageSettingsSection> createState() =>
      _StorageSettingsSectionState();
}

class _StorageSettingsSectionState
    extends ConsumerState<StorageSettingsSection> {
  bool _busy = false;
  String? _error;

  String _problemMessage(StorageProblem problem) => switch (problem.code) {
        ProblemCode.denied =>
          'Folder access denied. Choose a folder with read and write permission.',
        ProblemCode.staleRevision =>
          'Default folder changed elsewhere. Choose the folder again.',
        ProblemCode.busy =>
          'Recording or storage work is still active. Wait for it to finish, then try again.',
        ProblemCode.persistence =>
          'Could not save the default folder. Try again.',
        ProblemCode.unavailable ||
        ProblemCode.absent =>
          'Folder unavailable. Reconnect the storage or choose another folder.',
        ProblemCode.unsupported =>
          'Folder selection is not supported on this platform.',
        _ =>
          'Could not change folder. Try again or choose another writable folder.',
      };

  Future<void> _choose() async {
    if (!mounted || _busy) return;
    final observed = ref.read(defaultFolderProvider);
    final current = observed.valueOrNull;
    if (observed.isLoading ||
        observed.hasError ||
        current == null ||
        !current.canChooseDefault) {
      return;
    }
    // Capture before the picker. Never replace this revision with a later one.
    final revision = current.revision;
    final catalog = ref.read(storageCatalogProvider);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final picked = await catalog.chooseFolderCandidate();
      if (!mounted) return;
      final candidate = switch (picked) {
        Ok<FolderCandidate?>(:final value) => value,
        Fail<FolderCandidate?>(:final problem) => throw StorageFault(problem),
      };
      if (candidate == null) return;
      final committed =
          await catalog.commitDefault(candidate, expectedRevision: revision);
      if (!mounted) return;
      if (committed case Fail(:final problem)) throw StorageFault(problem);
      // Only defaultFolderProvider owns the displayed committed label.
    } on StorageFault catch (e) {
      if (mounted) setState(() => _error = _problemMessage(e.problem));
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Could not change folder. Try again.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final observed = ref.watch(defaultFolderProvider);
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Storage', style: Theme.of(context).textTheme.titleMedium),
            const Text('Default save folder'),
            observed.when(
              data: (state) => Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(state.location?.label ?? 'No default folder'),
                    if (!state.available)
                      Text(state.canChooseDefault
                          ? 'Default folder unavailable. Choose a writable folder to record new audio.'
                          : 'Default folder unavailable. Reconnect storage or restore access to record new audio.',),
                    if (state.problem != null && state.canChooseDefault)
                      Text(_problemMessage(state.problem!)),
                    if (state.canChooseDefault)
                      TextButton(
                        key: const ValueKey('change-default-folder'),
                        onPressed:
                            _busy || observed.isLoading || observed.hasError
                                ? null
                                : _choose,
                        child:
                            Text(_busy ? 'Changing folder…' : 'Change folder'),
                      )
                    else
                      const Text('Read-only on this platform.'),
                  ],),
              loading: () => const Text('Loading storage…'),
              error: (_, __) =>
                  const Text('Storage unavailable. Try reopening Settings.'),
            ),
            if (_error != null)
              Text(_error!, key: const ValueKey('storage-change-error')),
            const Text(
                'Changes apply to new recordings only. Existing recordings stay in their original folders.',),
          ],),
    );
  }
}
