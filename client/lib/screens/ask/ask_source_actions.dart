// SPDX-License-Identifier: AGPL-3.0-or-later
/// Long-press actions on Ask source citations (v1.40).
///
/// A citation row is not a list row, so long-press here opens the shared
/// [ItemActionSheet] for the UNDERLYING entity rather than entering
/// selection. Move / Rename / Pin reuse the origin list's own write path,
/// so a pin set here is the same flag the Recordings / Notebooks / To Do
/// lists read.
///
/// Delete is NOT the Recordings-list delete: that one is device-only
/// (LocalDeletionService). Here a recording is deleted from the server AND
/// the device — local eligibility checked first, then the server tombstone,
/// then local cleanup — because an Ask citation is a server-side reference.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../data/local_db.dart';
import '../../data/notebook_repository.dart';
import '../../data/storage/storage_contract.dart';
import '../../data/storage/storage_providers.dart'
    show localDeletionServiceProvider;
import '../../data/todo_repository.dart';
import '../../models/api_exception.dart';
import '../../models/notebook.dart';
import '../../services/ask_client.dart';
import '../../services/transcription_client.dart' show ServerDumpDeletion;
import '../../services/notebook_persistence.dart'
    show notebookPersistenceProvider;
import '../../widgets/folder_picker.dart';
import '../../widgets/item_action_sheet.dart';
import '../home/home_screen.dart' show localDbProvider;
import '../dump/dumps_list_screen.dart' show eligibilityReason;
import '../server/server_connection_screen.dart'
    show transcriptionClientProvider;

/// What a citation currently points at, for live chip rendering. Missing
/// from the map means the entity no longer exists locally.
typedef AskSourceEntity = ({String title, bool pinned});

/// `'<kind>:<id>'` where kind is dump | notebook | todo (summary chips
/// resolve to their parent dump).
String askSourceEntityKey(AskSource source) =>
    '${source.entityType == 'summary' ? 'dump' : source.entityType}:'
    '${source.entityId}';

/// Live title/pin state of every entity an Ask citation can name, so every
/// chip for the same entity (one recording cited at several seeks) reflects
/// a rename, pin or delete at once. Errors degrade to "unknown" rather than
/// breaking the chat.
final StreamProvider<Map<String, AskSourceEntity>> askSourceEntitiesProvider =
    StreamProvider<Map<String, AskSourceEntity>>((ref) {
  final LocalDb db = ref.watch(localDbProvider);
  final StreamController<Map<String, AskSourceEntity>> out =
      StreamController<Map<String, AskSourceEntity>>();
  List<DumpRow>? d;
  List<NotebookListEntry>? n;
  List<TodoRow>? t;
  void emit() {
    if (d == null || n == null || t == null) return;
    out.add(<String, AskSourceEntity>{
      for (final DumpRow r in d!)
        'dump:${r.id}': (title: r.title, pinned: r.pinned == true),
      for (final NotebookListEntry r in n!)
        'notebook:${r.id}': (title: r.title, pinned: r.pinned),
      for (final TodoRow r in t!)
        'todo:${r.id}': (title: r.body, pinned: r.pinned == true),
    });
  }

  final List<StreamSubscription<Object?>> subs = <StreamSubscription<Object?>>[
    db.watchAllDumps().listen(
      (v) {
        d = v;
        emit();
      },
      onError: out.addError,
    ),
    NotebookRepository(db: db).watchNotebookHeaders().listen(
      (v) {
        n = v;
        emit();
      },
      onError: out.addError,
    ),
    TodoRepository(db: db).watchTodos().listen(
      (v) {
        t = v;
        emit();
      },
      onError: out.addError,
    ),
  ];
  ref.onDispose(() {
    for (final StreamSubscription<Object?> s in subs) {
      s.cancel();
    }
    out.close();
  });
  return out.stream;
});

/// True only for a recording that never even ATTEMPTED an upload: zero
/// sync attempts, no confirmed sync sequence, not server-sourced, no server
/// audio, and not synced/syncing. New captures sit in 'pending' with zero
/// attempts and qualify; an attempt whose reply was lost may have landed
/// server-side, so any attempt fails closed.
bool askDumpNeverSynced(DumpRow row) =>
    row.syncAttempts == 0 &&
    row.syncedSeq == null &&
    row.remoteOnly != true &&
    row.audioOnServer != true &&
    row.syncStatus != 'synced' &&
    row.syncStatus != 'syncing';

/// Authoritative server delete (publishes the sync tombstone). A seam so
/// tests can record ordering; production is [ServerDumpDeletion.deleteDump].
final Provider<Future<void> Function(String dumpId)>
    askSourceServerDeleteProvider = Provider<Future<void> Function(String)>(
  (ref) => (String dumpId) =>
      ref.read(transcriptionClientProvider).deleteDump(dumpId),
);

/// Deletes a recording the only safe way: local eligibility, then the
/// exclusive deletion lease, then the authoritative server DELETE
/// (publishes the tombstone, so the next pull cannot resurrect it) while
/// that lease is held, then local cleanup through [LocalDeletionService] —
/// never dart:io, because Android audio lives behind SAF content:// URIs.
/// Every item in the Ok envelope must report [DeleteState.deleted];
/// skipped/failed throws. A recording that cannot get the lease never
/// reaches the server.
///
/// A 404 lets local cleanup proceed ONLY for a never-synced recording
/// ([askDumpNeverSynced]); for a synced one it is a failure and nothing
/// local is touched.
final Provider<Future<void> Function(String dumpId)>
    askSourceDeleteDumpProvider = Provider<Future<void> Function(String)>(
  (ref) => (String dumpId) async {
    final DumpRow? row = await ref.read(localDbProvider).getDumpRow(dumpId);
    final LocalDeletionService deletion =
        ref.read(localDeletionServiceProvider);
    // Eligibility FIRST. The server tombstone is irreversible and the next
    // pull raw-deletes the local row (applyRemoteDumpDeletion), bypassing
    // LocalDeletionService and orphaning audio — so a row the local service
    // would refuse (mid-transcription, syncing, in use…) must never reach
    // the server delete at all.
    final DeletionPreview preview =
        switch (await deletion.preview(<String>{dumpId})) {
      Ok<DeletionPreview>(:final value) => value,
      Fail<DeletionPreview>(:final problem) => throw StorageFault(problem),
    };
    if (preview.targets.isEmpty) {
      throw const StorageFault(
        (code: ProblemCode.busy, message: 'Recording unavailable'),
      );
    }
    for (final DeleteTarget target in preview.targets) {
      if (target.eligibility != Eligibility.eligible) {
        throw StorageFault(
          (
            code: ProblemCode.busy,
            message: eligibilityReason(target.eligibility),
          ),
        );
      }
    }
    // The server tombstone runs INSIDE the local deletion lease
    // (whileLeased): the eligibility checked above cannot change while the
    // call is in flight, because nothing else can acquire the recording
    // until local cleanup finishes. Without the lease, a recording that
    // became busy mid-call got a server tombstone that local cleanup then
    // refused, and the next pull raw-deleted the row, orphaning its audio.
    Object? serverError;
    StackTrace? serverTrace;
    Future<void> serverDelete(String id) async {
      try {
        await ref.read(askSourceServerDeleteProvider)(id);
      } on ApiException catch (error, trace) {
        // A 404 proves nothing on its own (already deleted, or an upload
        // still in flight that lands after the local delete and resurrects
        // on the next pull). Only a recording that never attempted an
        // upload may proceed; anything else fails closed.
        if (error.statusCode == 404 && row != null && askDumpNeverSynced(row)) {
          return;
        }
        serverError = error;
        serverTrace = trace;
        rethrow;
      } catch (error, trace) {
        serverError = error;
        serverTrace = trace;
        rethrow;
      }
    }

    final BulkDeletionResult result = switch (await deletion.deleteConfirmed(
      (operationId: const Uuid().v4(), targets: preview.targets),
      whileLeased: serverDelete,
    )) {
      Ok<BulkDeletionResult>(:final value) => value,
      Fail<BulkDeletionResult>(:final problem) => throw StorageFault(problem),
    };
    if (serverError != null) {
      // Surface the server's own failure, not the generic skipped item.
      Error.throwWithStackTrace(serverError!, serverTrace!);
    }
    for (final DeletionItemResult item in result.items) {
      if (item.state != DeleteState.deleted) {
        throw StorageFault(
          item.problem ??
              const (
                code: ProblemCode.busy,
                message: 'Recording is still in use',
              ),
        );
      }
    }
  },
);

/// Runs the long-press flow for [source]. Resolves after the chosen action
/// finished (or immediately when dismissed / the entity is gone).
Future<void> showAskSourceActions(
  BuildContext context,
  WidgetRef ref,
  AskSource source,
) async {
  final LocalDb db = ref.read(localDbProvider);
  final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
  void say(String text) =>
      messenger.showSnackBar(SnackBar(content: Text(text)));

  final String kind =
      source.entityType == 'summary' ? 'dump' : source.entityType;
  String title;
  bool pinned;
  String? folderId;
  switch (kind) {
    case 'dump':
      final DumpRow? row = await db.getDumpRow(source.entityId);
      if (row == null) return say('Source no longer exists: ${source.snippet}');
      (title, pinned, folderId) = (row.title, row.pinned == true, row.folderId);
    case 'notebook':
      final Notebook? nb =
          await NotebookRepository(db: db).getNotebook(source.entityId);
      if (nb == null) return say('Source no longer exists: ${source.snippet}');
      (title, pinned, folderId) = (nb.title, nb.pinned, nb.folderId);
    case 'todo':
      final TodoRow? row = await db.getTodoRow(source.entityId);
      if (row == null || row.deletedAt != null) {
        return say('Source no longer exists: ${source.snippet}');
      }
      (title, pinned, folderId) = (row.body, row.pinned == true, row.folderId);
    default:
      return;
  }
  if (!context.mounted) return;

  // Summary chips act on the parent recording for Move / Rename / Pin, but
  // do not offer Delete: deleting a whole recording from its summary's
  // citation is too easy to misread as "delete the summary".
  final bool canDelete = source.entityType != 'summary';
  // Recordings: ask the local deletion service up front so Delete is shown
  // greyed with its reason (the Recordings-list pattern) instead of failing
  // after confirmation. The provider re-checks before any server call.
  String? deleteBlocked;
  if (canDelete && kind == 'dump') {
    final Outcome<DeletionPreview> preview = await ref
        .read(localDeletionServiceProvider)
        .preview(<String>{source.entityId});
    deleteBlocked = switch (preview) {
      Ok<DeletionPreview>(:final value) => value.targets.isEmpty
          ? eligibilityReason(Eligibility.missing)
          : value.targets
              .map((DeleteTarget t) => t.eligibility)
              .where((Eligibility e) => e != Eligibility.eligible)
              .map(eligibilityReason)
              .firstOrNull,
      Fail<DeletionPreview>(:final problem) => problem.message,
    };
    if (!context.mounted) return;
  }
  final ItemAction? action = await showItemActionSheet(
    context,
    title: title.trim().isEmpty ? '(untitled)' : title,
    subtitle: switch (source.entityType) {
      'summary' => 'Recording (from its summary)',
      'dump' => 'Recording',
      'notebook' => 'Notebook',
      _ => 'To Do',
    },
    actions: <ItemAction>[
      ItemAction.rename,
      ItemAction.move,
      pinned ? ItemAction.unpin : ItemAction.pin,
      if (canDelete) ItemAction.delete,
    ],
    labelOverrides: kind == 'todo'
        ? const <ItemAction, String>{ItemAction.rename: 'Edit'}
        : const <ItemAction, String>{},
    disabledActions: <ItemAction, String>{
      if (deleteBlocked != null) ItemAction.delete: deleteBlocked,
    },
  );
  if (action == null || !context.mounted) return;

  try {
    switch (action) {
      case ItemAction.rename:
        final String? name = await _askName(context, title, kind);
        if (name == null) return;
        await _rename(ref, kind, source.entityId, name);
      case ItemAction.move:
        final List<Folder> folders = await db.watchFolders().first;
        if (!context.mounted) return;
        final FolderChoice? choice = await showFolderPicker(
          context,
          folders: folders
              .map((Folder f) => FolderOption(id: f.id, name: f.name))
              .toList(growable: false),
          currentFolderId: folderId,
        );
        // Null = dismissed: nothing moves.
        if (choice == null) return;
        String? destination = choice.folderId;
        if (choice.isNewFolder && choice.newFolderName != null) {
          destination = await db.createFolder(name: choice.newFolderName!);
        }
        await _move(ref, kind, source.entityId, destination);
      case ItemAction.pin:
      case ItemAction.unpin:
        await _setPinned(ref, kind, source.entityId, action == ItemAction.pin);
      case ItemAction.delete:
        if (!context.mounted) return;
        if (!await _confirmDelete(context, title, kind)) return;
        await _delete(ref, kind, source.entityId);
      case ItemAction.open:
      case ItemAction.duplicate:
      case ItemAction.share:
      case ItemAction.exportPdf:
      case ItemAction.exportMarkdown:
      case ItemAction.sendToNotebook:
      case ItemAction.download:
      case ItemAction.regenerateSummary:
      case ItemAction.nameSpeakers:
      case ItemAction.select:
        break;
    }
  } catch (error) {
    say('Could not ${ItemActionSheet.labelFor(action).toLowerCase()}: $error');
  }
}

Future<void> _rename(WidgetRef ref, String kind, String id, String name) async {
  switch (kind) {
    case 'dump':
      await ref.read(localDbProvider).renameDump(dumpId: id, title: name);
    case 'notebook':
      // Never save a hollow header: fetch the FULL notebook (document + ink)
      // and rename that, through persistence so the durable file follows.
      final Notebook? full =
          await ref.read(notebookRepositoryProvider).getNotebook(id);
      if (full == null) throw StateError('Notebook is no longer available');
      await ref
          .read(notebookPersistenceProvider)
          .saveNotebook(full.copyWith(title: name));
    case 'todo':
      await ref.read(todoRepositoryProvider).editText(id, name);
  }
}

Future<void> _move(
  WidgetRef ref,
  String kind,
  String id,
  String? folderId,
) async {
  final LocalDb db = ref.read(localDbProvider);
  switch (kind) {
    case 'dump':
      await db.moveDumpToFolder(dumpId: id, folderId: folderId);
    case 'notebook':
      await db.moveNotebookToFolder(notebookId: id, folderId: folderId);
    case 'todo':
      await ref.read(todoRepositoryProvider).moveToFolder(id, folderId);
  }
}

Future<void> _setPinned(
  WidgetRef ref,
  String kind,
  String id,
  bool pinned,
) async {
  switch (kind) {
    case 'dump':
      await ref.read(localDbProvider).setDumpPinned(id, pinned);
    case 'notebook':
      await ref.read(notebookRepositoryProvider).setPinned(id, pinned);
    case 'todo':
      await ref.read(todoRepositoryProvider).setPinned(id, pinned);
  }
}

Future<void> _delete(WidgetRef ref, String kind, String id) async {
  switch (kind) {
    case 'dump':
      await ref.read(askSourceDeleteDumpProvider)(id);
    case 'notebook':
      // Persistence deletes the row AND its durable file (the list's path).
      await ref.read(notebookPersistenceProvider).deleteNotebook(id);
    case 'todo':
      await ref.read(todoRepositoryProvider).softDelete(id);
  }
}

Future<String?> _askName(
  BuildContext context,
  String current,
  String kind,
) async {
  final TextEditingController controller = TextEditingController(text: current);
  final String? name = await showDialog<String>(
    context: context,
    builder: (BuildContext dialogContext) => AlertDialog(
      title: Text(kind == 'todo' ? 'Edit to-do' : 'Rename'),
      content: TextField(
        key: const ValueKey<String>('ask-source-rename-field'),
        controller: controller,
        autofocus: true,
        decoration: InputDecoration(
          labelText: kind == 'todo' ? 'To-do' : 'Title',
        ),
        onSubmitted: (String v) => Navigator.of(dialogContext).pop(v.trim()),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          key: const ValueKey<String>('ask-source-rename-save'),
          onPressed: () =>
              Navigator.of(dialogContext).pop(controller.text.trim()),
          child: const Text('Save'),
        ),
      ],
    ),
  );
  // The dialog route is still animating out; dispose on the next frame.
  WidgetsBinding.instance.addPostFrameCallback((_) => controller.dispose());
  return (name == null || name.isEmpty) ? null : name;
}

Future<bool> _confirmDelete(
  BuildContext context,
  String title,
  String kind,
) async {
  final String noun = switch (kind) {
    'dump' => 'recording',
    'notebook' => 'notebook',
    _ => 'to-do',
  };
  final bool? ok = await showDialog<bool>(
    context: context,
    builder: (BuildContext dialogContext) => AlertDialog(
      title: Text('Delete $noun?'),
      content: Text(
        kind == 'dump'
            ? '“$title” will be deleted from the server and this device.'
            : '“$title” will be deleted.',
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          key: const ValueKey<String>('ask-source-delete-confirm'),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  return ok == true;
}
