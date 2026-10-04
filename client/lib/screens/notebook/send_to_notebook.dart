// SPDX-License-Identifier: AGPL-3.0-or-later
//
// "Send to notebook…" from a recording (transcript-to-notebook spec §A):
// pick a notebook → pick a shape → the shared import service appends the
// blocks WITHOUT opening the editor → a snackbar offers to Open the page
// scrolled to what just landed.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/local_db.dart';
import '../../data/notebook_repository.dart';
import '../../models/notebook.dart';
import '../../models/speaker_names.dart';
import '../../services/notebook_import.dart';
import '../../services/notebook_persistence.dart';
import '../../services/notebook_password.dart';
import '../../services/transcript_timings.dart';
import '../../widgets/notebook_picker_sheet.dart';
import '../../widgets/notebook_password_dialog.dart';
import '../home/home_screen.dart' show localDbProvider;
import '../settings/ai_summaries_section.dart' show summariesEnabledProvider;
import 'import_shape_sheet.dart';
import 'notebook_editor_screen.dart';

/// The import call every UI entry point makes. Bound to the app's
/// persistence and timings/speaker-name lookups by [notebookImportProvider];
/// tests override the provider to record calls instead of writing.
typedef NotebookImportCall = Future<NotebookImportResult> Function({
  required String notebookId,
  required List<DumpRow> dumps,
  required ImportShape shape,
  required bool includeAudioCard,
});

/// Production binding of [importDumpsIntoNotebook]: timings come from the
/// row's own `transcript_timings` column (re-read so a row the caller has
/// held for a while is not stale), speaker names from `speaker_names`.
final Provider<NotebookImportCall> notebookImportProvider =
    Provider<NotebookImportCall>((Ref ref) {
  return ({
    required String notebookId,
    required List<DumpRow> dumps,
    required ImportShape shape,
    required bool includeAudioCard,
  }) =>
      importDumpsIntoNotebook(
        persistence: ref.read(notebookPersistenceProvider),
        notebookId: notebookId,
        dumps: dumps,
        shape: shape,
        includeAudioCard: includeAudioCard,
        timingsFor: (String dumpId) async {
          final DumpRow? fresh = await ref.read(localDbProvider).getDump(dumpId);
          final String? raw = fresh?.transcriptTimings ??
              dumps
                  .where((DumpRow d) => d.id == dumpId)
                  .map((DumpRow d) => d.transcriptTimings)
                  .firstOrNull;
          return TranscriptTimings.parse(raw);
        },
        speakerNamesFor: (DumpRow dump) => SpeakerNames.decode(dump.speakerNames),
      );
});

/// Whether "Send to notebook…" applies to [row]: anything with a non-blank
/// transcript OR summary (the same gate as the editor's import shapes).
/// Absent, not disabled, otherwise — nothing to send.
bool canSendToNotebook(DumpRow row) =>
    (row.transcript?.trim().isNotEmpty ?? false) ||
    (row.summary?.trim().isNotEmpty ?? false);

/// Runs the whole send flow for [dumps] from [context]. Every step can be
/// dismissed; nothing is written until a shape is chosen. Failures land in a
/// snackbar rather than vanishing.
Future<void> sendDumpsToNotebook(
  BuildContext context,
  WidgetRef ref,
  List<DumpRow> dumps,
) async {
  if (dumps.isEmpty) return;
  final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
  final NavigatorState navigator = Navigator.of(context);

  final String suggestedTitle = dumps.length == 1
      ? (dumps.single.title.trim().isEmpty
          ? '(untitled)'
          : dumps.single.title.trim())
      : '${dumps.length} recordings';
  final String? notebookId = await showNotebookPickerSheet(
    context,
    ref: ref,
    suggestedTitle: suggestedTitle,
  );
  if (notebookId == null || !context.mounted) return;

  final Notebook? destination =
      await ref.read(notebookRepositoryProvider).getNotebook(notebookId);
  if (destination == null || !context.mounted) return;
  if (destination.passwordProtected) {
    final NotebookUnlockRegistry unlocks =
        ref.read(notebookUnlockRegistryProvider);
    if (!unlocks.isUnlocked(notebookId, destination.passwordHash)) {
      final bool accepted = await showNotebookUnlockDialog(
        context,
        notebookTitle: destination.title,
        verify: (String password) => ref
            .read(notebookRepositoryProvider)
            .verifyPassword(notebookId, password),
      );
      if (!accepted || !context.mounted) return;
      unlocks.unlock(notebookId, destination.passwordHash!);
    }
  }

  final bool offerSummary = ref.read(summariesEnabledProvider) ||
      dumps.any((DumpRow d) => (d.summary ?? '').trim().isNotEmpty);
  final ImportShapeChoice? choice = await askImportShapeRemembered(
    context,
    ref,
    offerSummary: offerSummary,
  );
  if (choice == null || !context.mounted) return;

  try {
    final NotebookImportResult result = await ref.read(notebookImportProvider)(
      notebookId: notebookId,
      dumps: dumps,
      shape: choice.shape,
      includeAudioCard: choice.includeAudioCard,
    );
    final Notebook? notebook =
        await ref.read(notebookRepositoryProvider).getNotebook(notebookId);
    final String title = (notebook?.title.trim().isEmpty ?? true)
        ? 'notebook'
        : notebook!.title.trim();
    messenger.showSnackBar(
      SnackBar(
        key: const ValueKey<String>('send-to-notebook-done'),
        content: Text('Added to $title'),
        action: SnackBarAction(
          key: const ValueKey<String>('send-to-notebook-open'),
          label: 'Open',
          onPressed: () => unawaited(
            navigator.push<void>(
              MaterialPageRoute<void>(
                builder: (_) => NotebookEditorScreen(
                  notebookId: result.notebookId,
                  scrollToBlockId: result.newBlockIds.firstOrNull,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  } catch (error) {
    messenger.showSnackBar(
      SnackBar(content: Text('Could not add to the notebook: $error')),
    );
  }
}
