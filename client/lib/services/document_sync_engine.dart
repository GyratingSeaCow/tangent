// SPDX-License-Identifier: AGPL-3.0-or-later
/// Two-way document sync against the user's own server.
///
/// Scope, from the design: notebooks and text notes sync; AUDIO DOES NOT.
/// Audio stays on the device that recorded it and moves only on explicit
/// request. This engine therefore moves kilobytes of JSON, which is why it is
/// allowed to run on cellular while bulk audio backup is not.
///
/// Distinct from [SyncEngine], which is one-way opt-in audio backup. The two
/// are deliberately not merged: they answer to different settings, different
/// network rules, and different failure consequences.
library;

import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

import '../data/local_db.dart';
import '../models/sync_change.dart';
import 'connectivity_service.dart';
import 'calendar_voice_capture.dart';
import 'notebook_password.dart';
import 'todo_voice_capture.dart';
import 'transcription_client.dart';

/// How a sync attempt ended, for the UI to report honestly.
enum SyncOutcome { success, offline, failed, alreadyRunning }

@immutable
class SyncReport {
  const SyncReport({
    required this.outcome,
    this.pulled = 0,
    this.pushed = 0,
    this.conflicts = 0,
    this.error,
  });

  final SyncOutcome outcome;
  final int pulled;
  final int pushed;
  final int conflicts;
  final String? error;

  bool get isSuccess => outcome == SyncOutcome.success;
}

/// Pulls remote changes, merges them, then pushes local ones.
///
/// Pull BEFORE push, always. Pushing first would send a local edit that the
/// merge step might have forked, so the server would record a change the user
/// never actually resolved.
/// A summary this device requested has synced down onto [dumpId].
/// [requestedAt] is the row's `summary_requested_at` at the moment the
/// answer landed (unix seconds) — always non-null here, because a summary
/// nobody on this device asked for is never reported. Must never throw.
typedef SummaryLandedHook =
    void Function({
  required String dumpId,
  required String title,
  required String? template,
  required int requestedAt,
});

class DocumentSyncEngine extends ChangeNotifier {
  DocumentSyncEngine({
    required LocalDb Function() db,
    required TranscriptionClient Function() client,
    required ConnectivityService connectivity,
    required Future<String> Function() deviceLabel,
    required String newDeviceId,
    SummaryLandedHook? onSummaryLanded,
  })  : _dbFactory = db,
        _client = client,
        _connectivity = connectivity,
        _deviceLabel = deviceLabel,
        _newDeviceId = newDeviceId,
        _onSummaryLanded = onSummaryLanded;

  /// Spec 2026-09-28 N4: told when a pull lands a summary THIS device asked
  /// for. Null when nobody listens (tests, background isolate).
  final SummaryLandedHook? _onSummaryLanded;

  /// Resolved on first use, not at construction. Building this engine must
  /// not open a database: it is created whenever a screen with a sync button
  /// is built, including in tests that deliberately provide no database at
  /// all, and an eager handle turns rendering a button into a hard failure.
  final LocalDb Function() _dbFactory;
  LocalDb? _resolvedDb;
  LocalDb get _db => _resolvedDb ??= _dbFactory();

  /// Resolved per call: the server URL and token can change under the user
  /// (re-pairing, a new token), and a captured client would keep talking to
  /// the old one.
  final TranscriptionClient Function() _client;
  final ConnectivityService _connectivity;

  /// Resolved asynchronously on first registration: the real Android model
  /// comes from a platform channel, which cannot be read synchronously while
  /// building a provider.
  final Future<String> Function() _deviceLabel;
  final String _newDeviceId;

  bool _syncing = false;
  bool _disposed = false;
  DateTime? _lastSync;
  String? _lastError;
  int _lastConflicts = 0;

  bool get isSyncing => _syncing;
  DateTime? get lastSync => _lastSync;
  String? get lastError => _lastError;

  /// Conflicts from the most recent sync, so the UI can say so plainly rather
  /// than leaving forked notebooks to be discovered by accident.
  int get lastConflicts => _lastConflicts;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Runs one full sync cycle.
  ///
  /// Reentrancy is refused rather than queued: the 30-minute timer and the
  /// sync button can fire together, and two concurrent cycles would race on
  /// the same checkpoint.
  Future<SyncReport> syncNow() async {
    if (_syncing || _disposed) {
      return const SyncReport(outcome: SyncOutcome.alreadyRunning);
    }
    _syncing = true;
    _lastError = null;
    _notify();

    int pulled = 0;
    int pushed = 0;
    int conflicts = 0;
    try {
      final ConnectivityStatus status = await _connectivity.currentStatus();
      if (!status.isOnline) {
        return const SyncReport(outcome: SyncOutcome.offline);
      }
      // Deliberately NOT gated on wifiOnlySync. That setting governs bulk
      // audio upload; document sync is kilobytes of JSON and the user asked
      // for it to work everywhere.

      final SyncStateRow state = await _db.syncState(newDeviceId: _newDeviceId);
      final TranscriptionClient client = _client();

      // A device that cannot name itself is a cosmetic problem: the server
      // keys on the id, and the label is only there so a human can tell the
      // tablet from the phone. Letting it throw would turn that into no sync
      // at all.
      String label;
      try {
        label = await _deviceLabel();
      } catch (_) {
        label = 'Android device';
      }

      await client.registerDevice(
        deviceId: state.deviceId,
        displayName: label,
        platform: 'android',
      );

      // --- pull ---
      int since = state.lastPulledSeq;
      bool more = true;
      while (more && !_disposed) {
        final SyncPullPage page = await client.pullChanges(
          deviceId: state.deviceId,
          sinceSeq: since,
        );
        for (final RemoteChange change in page.changes) {
          final bool forked = await _applyRemote(change);
          if (forked) conflicts++;
          pulled++;
        }
        // Advance only after the whole page landed: a crash mid-page must
        // re-fetch it, never skip it.
        await _db.recordPullCheckpoint(page.headSeq);
        since = page.headSeq;
        more = page.hasMore;
      }

      // Twins that were BOTH already here before v1.28.0 never re-arrive,
      // so the per-change dedupe above cannot see them; sweep before the
      // push so the soft-deletes travel in this same cycle.
      if (!_disposed) await _sweepVoiceTodoDuplicates();

      // --- push ---
      if (!_disposed) {
        pushed = await _pushLocal(client, state.deviceId);
      }

      if (!_disposed) _lastSync = DateTime.now();
      _lastConflicts = conflicts;
      return SyncReport(
        outcome: SyncOutcome.success,
        pulled: pulled,
        pushed: pushed,
        conflicts: conflicts,
      );
    } catch (error) {
      _lastError = error.toString();
      return SyncReport(
        outcome: SyncOutcome.failed,
        pulled: pulled,
        pushed: pushed,
        conflicts: conflicts,
        error: error.toString(),
      );
    } finally {
      _syncing = false;
      _notify();
    }
  }

  /// Applies one incoming change. Returns true when it forked a conflict.
  Future<bool> _applyRemote(RemoteChange change) async {
    if (change.entityType == 'ink_index') {
      await _applyRemoteInkIndex(change);
      return false;
    }
    if (change.entityType == 'dump') {
      await _applyRemoteDump(change);
      return false;
    }
    if (change.entityType == 'todo') {
      await _applyRemoteTodo(change);
      return false;
    }
    if (change.entityType == 'todo_column') {
      await _applyRemoteTodoColumn(change);
      return false;
    }
    if (change.entityType == 'calendar_event') {
      await _applyRemoteCalendarEvent(change);
      return false;
    }
    if (change.entityType == 'ask_message') {
      // Ask history is server-authored and its protocol never emits deletes;
      // unlike ink_index, ignore one defensively for forward compatibility.
      if (change.op == SyncOp.delete) return false;
      final Map<String, dynamic> payload = change.payload ?? const {};
      await _db.applyRemoteAskMessage(
        id: change.entityId,
        role: payload['role'] as String? ?? 'assistant',
        text: payload['text'] as String? ?? '',
        sourcesJson: jsonEncode(payload['sources'] ?? const <dynamic>[]),
        createdAt: (payload['created_at'] as num?)?.toInt() ?? 0,
        seq: change.seq,
      );
      return false;
    }
    if (change.entityType == 'folder') {
      if (change.op == SyncOp.delete) {
        await _db.applyRemoteFolderDeletion(change.entityId);
      } else {
        final Map<String, dynamic> p = change.payload ?? const {};
        await _db.applyRemoteFolder(
          id: change.entityId,
          name: p['name'] as String? ?? 'Folder',
          createdAt:
              (p['created_at'] as num?)?.toInt() ??
              DateTime.now().millisecondsSinceEpoch,
          seq: change.seq,
        );
      }
      return false;
    }
    if (change.entityType == 'tag') {
      await _applyRemoteTag(change);
      return false;
    }
    if (change.entityType == 'tag_assignment') {
      await _applyRemoteTagAssignment(change);
      return false;
    }
    if (change.entityType != 'notebook') return false;

    if (change.op == SyncOp.delete) {
      await _db.applyRemoteNotebookDeletion(change.entityId);
      return false;
    }

    final Map<String, dynamic> payload = change.payload ?? const {};
    final NotebookRow? local = await _db.getNotebookRow(change.entityId);
    final int remoteUpdatedAt = (payload['updated_at'] as num?)?.toInt() ?? 0;

    final MergeDecision decision = decideMerge(
      localExists: local != null,
      localDirty: local?.syncDirty ?? false,
      localUpdatedAt: local?.updatedAt ?? 0,
      remoteUpdatedAt: remoteUpdatedAt,
    );

    switch (decision) {
      case MergeDecision.keepLocal:
        return false;
      case MergeDecision.accept:
        await _writeRemote(change.entityId, payload, change.seq);
        return false;
      case MergeDecision.fork:
        // Both sides edited. The incoming copy lands beside the local one
        // under a conflict name; nothing is overwritten and nothing is lost.
        await _writeRemote(
          '${change.entityId}-conflict-${change.seq}',
          <String, dynamic>{
            ...payload,
            'title': forkedTitle(
              payload['title'] as String? ?? 'Notebook',
              change.deviceId ?? 'another device',
            ),
          },
          change.seq,
        );
        return true;
    }
  }

  /// Shared tags (v33). A tag deletion cascades to every local assignment of
  /// that tag — the single tombstone stands for all of them.
  Future<void> _applyRemoteTag(RemoteChange change) async {
    if (change.op == SyncOp.delete) {
      await _db.applyRemoteTagDeletion(change.entityId);
      return;
    }
    final Map<String, dynamic> p = change.payload ?? const {};
    final Object? name = p['name'];
    // The server validates names; a payload without one is not a tag this
    // build can show, and inventing a placeholder would rename it fleet-wide
    // on the next local edit.
    if (name is! String || name.trim().isEmpty) return;
    final int now = DateTime.now().millisecondsSinceEpoch;
    await _db.applyRemoteTag(
      id: change.entityId,
      name: name,
      createdAt: (p['created_at'] as num?)?.toInt() ?? now,
      updatedAt: (p['updated_at'] as num?)?.toInt() ?? now,
      seq: change.seq,
    );
  }

  Future<void> _applyRemoteTagAssignment(RemoteChange change) async {
    if (change.op == SyncOp.delete) {
      await _db.applyRemoteTagAssignmentDeletion(change.entityId);
      return;
    }
    final Map<String, dynamic> p = change.payload ?? const {};
    final Object? tagId = p['tag_id'];
    final Object? targetType = p['target_type'];
    final Object? targetId = p['target_id'];
    if (tagId is! String || targetType is! String || targetId is! String) {
      return;
    }
    await _db.applyRemoteTagAssignment(
      id: change.entityId,
      tagId: tagId,
      targetType: targetType,
      targetId: targetId,
      createdAt: (p['created_at'] as num?)?.toInt() ??
          DateTime.now().millisecondsSinceEpoch,
      seq: change.seq,
    );
  }

  /// Applies one incoming recording change.
  ///
  /// Recordings do NOT fork on conflict the way notebooks do. A notebook
  /// carries handwriting that cannot be merged, so a fork protects it; a
  /// recording's synced fields are short metadata (title, transcript, notes)
  /// and the audio itself never travels this path. Forking here would litter
  /// the list with duplicate entries for a renamed recording. A local edit
  /// still pending push therefore WINS and stays dirty, which is the same
  /// "never silently discard the user's edit" rule expressed for flat data.
  Future<void> _applyRemoteDump(RemoteChange change) async {
    if (change.op == SyncOp.delete) {
      await _db.applyRemoteDumpDeletion(change.entityId);
      return;
    }

    final Map<String, dynamic> payload = change.payload ?? const {};
    final DumpRow? local = await _db.getDumpRow(change.entityId);
    if (local != null && local.syncDirty == true) {
      // This device has an unpushed edit. Keep it; our push will carry it up
      // and the peer converges on the next cycle.
      return;
    }

    final int remoteUpdatedAt = (payload['updated_at'] as num?)?.toInt() ?? 0;
    // A change the SERVER authored (job completion, summary, timings
    // backfill) carries fields no device can produce locally. It must land
    // regardless of timestamps: the device that requested a transcription
    // stamps its own updated_at when the transcript arrives, typically a
    // second AFTER the server's row time, and the newer-wins shortcut below
    // then discarded the server's timings on every Fold-made recording.
    // Device-authored edits (a rename on the tablet) still compete on
    // updated_at so a stale peer copy cannot roll back a local edit.
    final bool serverAuthored = change.deviceId == serverDeviceId;
    if (local != null &&
        !serverAuthored &&
        remoteUpdatedAt > 0 &&
        local.updatedAt.millisecondsSinceEpoch ~/ 1000 > remoteUpdatedAt) {
      // Our copy is newer than what the peer sent; nothing to learn from it.
      return;
    }

    await _db.applyRemoteDump(
      id: change.entityId,
      mode: payload['mode'] as String? ?? 'brain_dump',
      title: payload['title'] as String? ?? 'Untitled',
      transcript: payload['transcript'] as String?,
      meetingNotes: payload['meeting_notes'] as String?,
      durationSeconds: (payload['duration_seconds'] as num?)?.toInt() ?? 0,
      audioOnServer: payload['audio_kept'] == true,
      createdAt: _tsToDate(payload['created_at']),
      updatedAt: _tsToDate(payload['updated_at']),
      // Summary fields are server-generated. Absence means an older server
      // that has never heard of summaries — keep whatever this device
      // already holds (absence is not an eraser, the notebooks.ink rule).
      // A PRESENT null is the server's authoritative "no summary exists".
      summary: payload.containsKey('summary')
          ? payload['summary'] as String?
          : LocalDb.absentSummaryField,
      summaryModel: payload.containsKey('summary_model')
          ? payload['summary_model'] as String?
          : LocalDb.absentSummaryField,
      summarizedAt: payload.containsKey('summarized_at')
          ? (payload['summarized_at'] as num?)?.toInt()
          : LocalDb.absentSummaryField,
      // Word timings: same absent-vs-null contract as the summary fields.
      // The server sends either a JSON string or a structured value;
      // store the canonical JSON text either way.
      transcriptTimings: payload.containsKey('transcript_timings')
          ? _timingsText(payload['transcript_timings'])
          : LocalDb.absentSummaryField,
      // Template choice: same absent-vs-null contract. A server that has
      // never heard of templates leaves the stored choice alone; a present
      // null is authoritative "mode default".
      summaryTemplate: payload.containsKey('summary_template')
          ? payload['summary_template'] as String?
          : LocalDb.absentSummaryField,
      // Speaker names: device-authored, same absent-vs-null contract. The
      // column is JSON text on both sides; a structured object is accepted
      // too and stored as its canonical JSON (same helper as timings).
      speakerNames: payload.containsKey('speaker_names')
          ? _timingsText(payload['speaker_names'])
          : LocalDb.absentSpeakerNamesField,
      // v1.19.0 server-authored fields (translation + summary status): same
      // absent-vs-null contract. None of them is ever pushed from here.
      language: payload.containsKey('language')
          ? payload['language'] as String?
          : LocalDb.absentSummaryField,
      translated: payload.containsKey('translated')
          ? payload['translated']
          : LocalDb.absentSummaryField,
      summaryStatus: payload.containsKey('summary_status')
          ? payload['summary_status'] as String?
          : LocalDb.absentSummaryField,
      summaryError: payload.containsKey('summary_error')
          ? payload['summary_error'] as String?
          : LocalDb.absentSummaryField,
      summaryQueuePosition: payload.containsKey('summary_queue_position')
          ? (payload['summary_queue_position'] as num?)?.toInt()
          : LocalDb.absentSummaryField,
      // v1.38 filing: same pattern as the notebook folder_id — null means
      // UNFILED while absence means "older server, keep the local filing".
      folderId: payload.containsKey('folder_id')
          ? payload['folder_id'] as String?
          : LocalDb.absentFolderId,
      // Auto-file markers (server-authored): while auto_filed_at is set the
      // card shows "Auto-filed to <folder> · Undo".
      autoFiledAt: payload.containsKey('auto_filed_at')
          ? (payload['auto_filed_at'] as num?)?.toInt()
          : LocalDb.absentSummaryField,
      autoFilePrevFolderId: payload.containsKey('auto_file_prev_folder_id')
          ? payload['auto_file_prev_folder_id'] as String?
          : LocalDb.absentSummaryField,
      pinned: payload.containsKey('pinned')
          ? payload['pinned']
          : LocalDb.absentPinnedField,
      seq: change.seq,
    );
    await _reportSummaryLanded(change.entityId, local, payload);
    // To Do phase 2: the SERVER-synced transcript sink. A transcript made on
    // another device (or by the server job) lands here; the local
    // transcription sink is server_transcription_service's completion
    // paths. Both call captureVoiceTodos, which owns the idempotency rule,
    // so the same transcript arriving on both routes adds items once.
    await captureVoiceTodosQuietly(
      db: _db,
      dumpId: change.entityId,
      transcript: payload['transcript'] as String?,
      recordedOn: _tsToDate(payload['created_at']),
    );
    await captureVoiceEventsQuietly(
      db: _db,
      dumpId: change.entityId,
      transcript: payload['transcript'] as String?,
      recordedOn: _tsToDate(payload['created_at']),
      mode: payload['mode'] as String? ?? local?.mode ?? 'brain_dump',
    );
  }

  /// N4 (spec 2026-09-28): "Notes ready" fires from where the fact is
  /// learned — right here, after the pull's write — and only for a summary
  /// THIS device asked for: [before] must carry `summary_requested_at`, the
  /// marker `recordRequestedSummaryTemplate` stamps on the summarize 202
  /// (the summaryPending contract). A summary another device requested
  /// lands on this row too, and must land silently.
  ///
  /// Exactly once: the write above spends the marker when the answer is at
  /// least as new as the request, so the next pull of the same row finds no
  /// marker; and a stale echo that leaves the marker (older summarized_at,
  /// or no summarized_at at all) carries the same text this row already
  /// holds, which is nothing new to announce.
  Future<void> _reportSummaryLanded(
    String dumpId,
    DumpRow? before,
    Map<String, dynamic> payload,
  ) async {
    final SummaryLandedHook? hook = _onSummaryLanded;
    if (hook == null) return;
    final int? requestedAt = before?.summaryRequestedAt;
    if (requestedAt == null) return;
    final String? summary = payload['summary'] as String?;
    if (summary == null || summary.isEmpty) return;
    final DumpRow? after = await _db.getDumpRow(dumpId);
    if (after == null) return;
    final bool answered = after.summaryRequestedAt == null;
    if (!answered && summary == before!.summary) return;
    try {
      hook(
        dumpId: dumpId,
        title: after.title,
        template: after.summaryTemplate,
        requestedAt: requestedAt,
      );
    } catch (error, stack) {
      debugPrint('tangent.notifications summary hook failed: $error');
      debugPrintStack(stackTrace: stack, label: 'tangent.notifications');
    }
  }

  /// Applies one incoming todo change.
  ///
  /// Todos follow the DUMP rules, not the notebook ones: the synced fields
  /// are short flat data, so a conflict never forks. A local edit still
  /// pending push WINS and stays dirty (own-echo protection — our push
  /// carries it up and the peer converges next cycle); otherwise newer
  /// `updated_at` wins, compared as ISO instant strings, which collate
  /// chronologically. Deletion is soft and rides the same upsert as a
  /// `deleted_at` value, so there is no separate delete path to keep in
  /// step — but a peer's op:delete is honoured anyway for forward compat.
  /// Calendar events: the same merge as todos (dirty local wins until
  /// pushed; older remote ignored) plus the three server-authored
  /// `google_*` fields, which only ever arrive this way.
  Future<void> _applyRemoteCalendarEvent(RemoteChange change) async {
    final Map<String, dynamic> payload = change.payload ?? const {};
    final CalendarEventRow? local = await _db.getCalendarEventRow(
      change.entityId,
    );
    if (local != null && local.syncDirty == true) return;
    if (change.op == SyncOp.delete) {
      if (local != null && local.deletedAt == null) {
        await _db.applyRemoteCalendarEvent(
          id: local.id,
          title: local.title,
          start: local.start,
          end: local.end,
          allDay: local.allDay,
          timeZone: local.timeZone,
          needsDate: local.needsDate,
          createdAt: local.createdAt,
          updatedAt: local.updatedAt,
          deletedAt: DateTime.now().toUtc().toIso8601String(),
          seq: change.seq,
        );
      }
      return;
    }
    final String remoteUpdatedAt = payload['updated_at'] as String? ?? '';
    if (local != null &&
        remoteUpdatedAt.isNotEmpty &&
        local.updatedAt.compareTo(remoteUpdatedAt) > 0) {
      return;
    }
    final String fallbackStamp = DateTime.now().toUtc().toIso8601String();
    Object? field(String key) => payload.containsKey(key)
        ? payload[key] as String?
        : LocalDb.absentTodoField;
    await _db.applyRemoteCalendarEvent(
      id: change.entityId,
      title: payload['title'] as String? ?? local?.title ?? '',
      start: payload['start'] as String? ?? local?.start ?? '',
      end: payload['end'] as String? ?? local?.end ?? '',
      allDay: _truthy(payload['all_day'], local?.allDay ?? true),
      timeZone: payload['time_zone'] as String? ?? local?.timeZone ?? 'local',
      needsDate: _truthy(payload['needs_date'], local?.needsDate ?? false),
      createdAt: payload['created_at'] as String? ?? fallbackStamp,
      updatedAt: remoteUpdatedAt.isEmpty ? fallbackStamp : remoteUpdatedAt,
      source: payload['source'] as String?,
      sourceRef: field('source_ref'),
      deletedAt: field('deleted_at'),
      googleEventId: field('google_event_id'),
      googleHtmlLink: field('google_html_link'),
      googleUpdated: field('google_updated'),
      seq: change.seq,
    );
  }

  /// sqlite sends 0/1, a JSON-native peer may send true/false.
  static bool _truthy(Object? v, bool held) => switch (v) {
        null => held,
        bool b => b,
        num n => n != 0,
        String s => s == '1' || s == 'true',
        _ => held,
      };

  Future<void> _applyRemoteTodo(RemoteChange change) async {
    final Map<String, dynamic> payload = change.payload ?? const {};
    final TodoRow? local = await _db.getTodoRow(change.entityId);
    if (local != null && local.syncDirty == true) {
      // This device has an unpushed edit. Keep it; our push will carry it
      // up and the peer converges on the next cycle.
      return;
    }
    if (change.op == SyncOp.delete) {
      // Defensive: Phase 1 peers send deletion as a deleted_at upsert, but
      // an explicit delete op must still land as the soft delete it means.
      if (local != null && local.deletedAt == null) {
        await _db.applyRemoteTodo(
          id: local.id,
          text: local.body,
          createdAt: local.createdAt,
          updatedAt: local.updatedAt,
          deletedAt: DateTime.now().toUtc().toIso8601String(),
          seq: change.seq,
        );
      }
      return;
    }

    final String remoteUpdatedAt = payload['updated_at'] as String? ?? '';
    if (local != null &&
        remoteUpdatedAt.isNotEmpty &&
        local.updatedAt.compareTo(remoteUpdatedAt) > 0) {
      // Our copy is newer than what the peer sent; nothing to learn.
      return;
    }

    final String fallbackStamp = DateTime.now().toUtc().toIso8601String();
    await _db.applyRemoteTodo(
      id: change.entityId,
      text: payload['text'] as String? ?? local?.body ?? '',
      createdAt: payload['created_at'] as String? ?? fallbackStamp,
      updatedAt: remoteUpdatedAt.isEmpty ? fallbackStamp : remoteUpdatedAt,
      source: payload['source'] as String?,
      // Absent-vs-null discipline (the summary-field rule): a payload
      // missing a key keeps the local value; a PRESENT null is
      // authoritative (unchecked / undated / live / no provenance).
      doneAt: payload.containsKey('done_at')
          ? payload['done_at'] as String?
          : LocalDb.absentTodoField,
      dueDate: payload.containsKey('due_date')
          ? payload['due_date'] as String?
          : LocalDb.absentTodoField,
      sourceRef: payload.containsKey('source_ref')
          ? payload['source_ref'] as String?
          : LocalDb.absentTodoField,
      deletedAt: payload.containsKey('deleted_at')
          ? payload['deleted_at'] as String?
          : LocalDb.absentTodoField,
      // v1.24.0: folder_id joins the nullable family. Absent (a pre-1.24
      // peer) keeps the local filing; a present null is an explicit unfile.
      folderId: payload.containsKey('folder_id')
          ? payload['folder_id'] as String?
          : LocalDb.absentTodoField,
      pinned: payload.containsKey('pinned')
          ? payload['pinned']
          : LocalDb.absentPinnedField,
      columnId: payload.containsKey('column_id')
          ? payload['column_id'] as String?
          : LocalDb.absentTodoField,
      boardOrder: payload.containsKey('board_order')
          ? payload['board_order']
          : LocalDb.absentTodoField,
      seq: change.seq,
    );
    await _dedupeVoiceTodo(change.entityId);
  }

  Future<void> _applyRemoteTodoColumn(RemoteChange change) async {
    final Map<String, dynamic> payload = change.payload ?? const {};
    final TodoColumnRow? local = await _db.getTodoColumnRow(change.entityId);
    if (local?.syncDirty == true) return;
    final String stamp =
        payload['updated_at'] as String? ??
        DateTime.now().toUtc().toIso8601String();
    await _db.applyRemoteTodoColumn(
      id: change.entityId,
      name: payload['name'] as String? ?? local?.name ?? 'Column',
      sortOrder:
          (payload['sort_order'] as num?)?.toInt() ?? local?.sortOrder ?? 0,
      createdAt: payload['created_at'] as String? ?? local?.createdAt ?? stamp,
      updatedAt: stamp,
      deletedAt: change.op == SyncOp.delete
          ? stamp
          : payload.containsKey('deleted_at')
          ? payload['deleted_at'] as String?
          : LocalDb.absentTodoField,
      seq: change.seq,
    );
  }

  /// v1.28.0 cross-device dedupe (retranscribe-guard spec, rule 4).
  ///
  /// Two devices that each captured the same recording before either push
  /// landed hold the same item under two ids. Once the peer's copy arrives
  /// here, a LIVE voice row with the same `source_ref` + `text` but a
  /// different id is a duplicate: the OLDER `created_at` stays, the other
  /// is soft-deleted as an ordinary dirty edit so it travels back as the
  /// deletion it is. Soft-deleted rows are not candidates (an Undo must not
  /// be reversed by a late arrival) and the check is per `source_ref`: two
  /// recordings that both said "call the dentist" are two items.
  Future<void> _dedupeVoiceTodo(String id) async {
    final TodoRow? applied = await _db.getTodoRow(id);
    if (applied == null ||
        applied.source != voiceTodoSource ||
        applied.sourceRef == null ||
        applied.deletedAt != null) {
      return;
    }
    final List<TodoRow> twins =
        await (_db.select(_db.todos)..where(
            (t) =>
                t.sourceRef.equals(applied.sourceRef!) &
                t.body.equals(applied.body) &
                t.source.equals(voiceTodoSource) &
                t.deletedAt.isNull() &
                t.id.equals(id).not(),
          ))
        .get();
    if (twins.isEmpty) return;
    await _resolveTwins(<TodoRow>[applied, ...twins]);
  }

  /// Same rule as [_dedupeVoiceTodo], applied to every live voice twin
  /// group already in the local DB — the pre-v1.28.0 duplicates that both
  /// devices pulled long ago. Runs once per sync cycle; a clean DB is one
  /// query and no writes.
  Future<int> _sweepVoiceTodoDuplicates() async {
    final List<TodoRow> live =
        await (_db.select(_db.todos)..where(
            (t) =>
                t.source.equals(voiceTodoSource) &
                t.sourceRef.isNotNull() &
                t.deletedAt.isNull(),
          ))
        .get();
    final Map<String, List<TodoRow>> groups = <String, List<TodoRow>>{};
    for (final TodoRow row in live) {
      groups
          .putIfAbsent('${row.sourceRef}\u0000${row.body}', () => <TodoRow>[])
          .add(row);
    }
    int removed = 0;
    for (final List<TodoRow> twins in groups.values) {
      if (twins.length < 2) continue;
      removed += await _resolveTwins(twins);
    }
    return removed;
  }

  /// The OLDER `created_at` stays; every other row is soft-deleted as an
  /// ordinary dirty edit. Returns the number soft-deleted.
  Future<int> _resolveTwins(List<TodoRow> twins) async {
    final List<TodoRow> all = <TodoRow>[...twins]
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    final String stamp = DateTime.now().toUtc().toIso8601String();
    for (final TodoRow loser in all.skip(1)) {
      await (_db.update(_db.todos)..where((t) => t.id.equals(loser.id))).write(
        TodosCompanion(
          deletedAt: Value(stamp),
          updatedAt: Value(stamp),
          syncDirty: const Value(true),
        ),
      );
    }
    return all.length - 1;
  }

  /// Canonical JSON text for a timings payload value: the server sends the
  /// stored column verbatim (a JSON string), but a structured value is
  /// accepted too. Null stays null (authoritative "no timings").
  String? _timingsText(Object? raw) {
    if (raw == null) return null;
    if (raw is String) return raw.trim().isEmpty ? null : raw;
    return jsonEncode(raw);
  }

  /// Server timestamps are whole seconds; Drift stores DateTime.
  DateTime _tsToDate(Object? raw) {
    final int seconds = (raw as num?)?.toInt() ?? 0;
    if (seconds <= 0) return DateTime.now().toUtc();
    return DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
  }

  /// Applies one incoming ink_index change: the search mirror for one
  /// notebook's handwriting.
  ///
  /// The payload is built by the server AT PULL TIME and carries the
  /// notebook's ENTIRE current index, so applying it is a REPLACE-SET: drop
  /// everything stored for that notebook, insert what arrived. There is no
  /// merge decision — the server is the only writer (OCR runs there), so
  /// nothing local can ever be at risk. The notebook document itself may not
  /// have arrived yet; the rows are stored regardless, because rejecting them
  /// would wedge the pull loop on this page forever.
  Future<void> _applyRemoteInkIndex(RemoteChange change) async {
    if (change.op == SyncOp.delete) {
      await _db.applyRemoteInkIndexDeletion(change.entityId);
      return;
    }
    final Map<String, dynamic> payload = change.payload ?? const {};
    final List<dynamic> raw =
        payload['rows'] as List<dynamic>? ?? const <dynamic>[];
    final List<InkIndexEntriesCompanion> rows = <InkIndexEntriesCompanion>[];
    for (final dynamic entry in raw) {
      if (entry is! Map<String, dynamic>) continue;
      final Object? id = entry['id'];
      final Object? lineId = entry['line_id'];
      final Object? wordText = entry['word_text'];
      // A malformed row is skipped, not fatal: one bad word must not cost
      // the notebook its whole index or wedge the pull loop.
      if (id is! String || lineId is! String || wordText is! String) continue;
      rows.add(
        InkIndexEntriesCompanion.insert(
          id: id,
          notebookId: change.entityId,
          lineId: lineId,
          wordText: wordText,
          wordTextLower: wordText.toLowerCase(),
          bboxJson: jsonEncode(entry['bbox'] ?? const <num>[0, 0, 0, 0]),
          strokeIdsJson: jsonEncode(entry['stroke_ids'] ?? const <String>[]),
          model: entry['model'] as String? ?? '',
          indexedAt: (entry['indexed_at'] as num?)?.toInt() ?? 0,
        ),
      );
    }
    await _db.applyRemoteInkIndex(notebookId: change.entityId, rows: rows);
  }

  Future<void> _writeRemote(
    String id,
    Map<String, dynamic> payload,
    int seq,
  ) async {
    final Object? doc = payload['doc'];
    final Object? ink = payload['ink'];
    // Verifier metadata is an untrusted subdocument. A malformed or causally
    // invalid tuple is ignored while the rest of the notebook still lands, so
    // one bad payload cannot poison this pull page's checkpoint forever.
    final NotebookRow? existing = await _db.getNotebookRow(id);
    Object? passwordHash = LocalDb.absentPasswordMetadata;
    String? passwordSalt;
    int? passwordIterations;
    String? passwordHashPrev;
    if (payload.containsKey('password_hash')) {
      final Object? incomingHash = payload['password_hash'];
      final Object? incomingSalt = payload['password_salt'];
      final Object? incomingIterations = payload['password_iterations'];
      final Object? incomingPrev = payload['password_hash_prev'];
      final bool validPrev =
          incomingPrev == null ||
          incomingPrev is String && incomingPrev.isNotEmpty;

      if (incomingHash == null) {
        // A clear is bounded by the verifier currently held locally.
        // Missing/wrong predecessors and mixed null/non-null tuples preserve it.
        if (incomingSalt == null &&
            incomingIterations == null &&
            validPrev &&
            (existing == null ||
                incomingPrev is String &&
                    incomingPrev.isNotEmpty &&
                    existing.passwordHash == incomingPrev)) {
          passwordHash = null;
          passwordHashPrev = incomingPrev as String?;
        }
      } else if (incomingHash is String &&
          incomingHash.isNotEmpty &&
          incomingSalt is String &&
          incomingSalt.isNotEmpty &&
          incomingIterations is int &&
          incomingIterations >= notebookPasswordMinIterations &&
          incomingIterations <= notebookPasswordMaxIterations &&
          validPrev) {
        final String? heldHash = existing?.passwordHash;
        final String? heldPrev = existing?.passwordHashPrev;
        final bool authorized =
            existing == null ||
            incomingHash == heldHash ||
            (heldHash != null
                ? incomingPrev == heldHash
                : heldPrev == null
                    ? incomingPrev == null
                    : incomingPrev == heldPrev && incomingHash != heldPrev);
        if (authorized) {
          passwordHash = incomingHash;
          passwordSalt = incomingSalt;
          passwordIterations = incomingIterations;
          passwordHashPrev = incomingPrev as String?;
        }
      }
    }
    await _db.applyRemoteNotebook(
      id: id,
      title: payload['title'] as String? ?? 'Notebook',
      createdAt:
          (payload['created_at'] as num?)?.toInt() ??
          DateTime.now().millisecondsSinceEpoch,
      updatedAt:
          (payload['updated_at'] as num?)?.toInt() ??
          DateTime.now().millisecondsSinceEpoch,
      // Bodies travel as JSON text. Encoding a decoded map back to a string
      // keeps the column's contract regardless of what the transport handed
      // us.
      docJson: doc is String ? doc : jsonEncode(doc ?? const {}),
      inkJson: ink is String ? ink : jsonEncode(ink ?? const {}),
      // Absent means the peer is an older build that does not know about
      // ruling. Passing null through would erase a ruling this device already
      // has, so a missing value leaves the local one alone.
      ruling: payload.containsKey('ruling')
          ? payload['ruling'] as String?
          : null,
      // The nib rides the same rule: absent means an older peer, and null
      // through applyRemoteNotebook falls back to the locally stored value.
      lastPenStyle: payload.containsKey('last_pen_style')
          ? payload['last_pen_style'] as String?
          : null,
      // Same pattern, sharper edge: folder_id null means UNFILED while
      // absence means "older peer, keep the local filing" — collapsing the
      // two would either strand filings or erase them.
      folderId: payload.containsKey('folder_id')
          ? payload['folder_id'] as String?
          : LocalDb.absentFolderId,
      pinned: payload.containsKey('pinned')
          ? payload['pinned']
          : LocalDb.absentPinnedField,
      passwordHash: passwordHash,
      passwordSalt: passwordSalt,
      passwordIterations: passwordIterations,
      passwordHashPrev: passwordHashPrev,
      seq: seq,
    );
  }

  Future<void> _rebaseRejectedNotebookPassword(
    PushResult result,
    int pushedUpdatedAt,
  ) async {
    final Map<String, dynamic>? canonical = result.canonicalPayload;
    if (canonical == null || !canonical.containsKey('password_hash')) return;

    final Object? hash = canonical['password_hash'];
    final Object? salt = canonical['password_salt'];
    final Object? iterations = canonical['password_iterations'];
    final Object? previous = canonical['password_hash_prev'];
    final bool validPrevious =
        previous == null || previous is String && previous.isNotEmpty;
    final bool valid =
        validPrevious &&
        (hash == null
            ? salt == null && iterations == null
            : hash is String &&
                hash.isNotEmpty &&
                salt is String &&
                salt.isNotEmpty &&
                iterations is int &&
                iterations >= notebookPasswordMinIterations &&
                iterations <= notebookPasswordMaxIterations);
    if (!valid) return;

    await _db.rebaseNotebookPasswordState(
      result.entityId,
      pushedUpdatedAt: pushedUpdatedAt,
      passwordHash: hash as String?,
      passwordSalt: salt as String?,
      passwordIterations: iterations as int?,
      passwordHashPrev: previous as String?,
    );
  }

  Future<int> _pushLocal(TranscriptionClient client, String deviceId) async {
    final List<NotebookRow> dirty = await _db.notebooksNeedingPush();
    final List<DumpRow> dirtyDumps = await _db.dumpsNeedingMetadataPush();
    final List<Folder> dirtyFolders = await _db.foldersNeedingPush();
    final List<TagRow> dirtyTags = await _db.tagsNeedingPush();
    final List<TagAssignmentRow> dirtyAssignments =
        await _db.tagAssignmentsNeedingPush();
    final List<TodoColumnRow> dirtyTodoColumns = await _db
        .todoColumnsNeedingPush();
    final List<TodoRow> dirtyTodos = await _db.todosNeedingPush();
    final List<CalendarEventRow> dirtyEvents = await _db
        .calendarEventsNeedingPush();
    final List<SyncTombstoneRow> tombstones = await _db.pendingTombstones();
    if (dirty.isEmpty &&
        dirtyDumps.isEmpty &&
        dirtyFolders.isEmpty &&
        dirtyTags.isEmpty &&
        dirtyAssignments.isEmpty &&
        dirtyTodoColumns.isEmpty &&
        dirtyTodos.isEmpty &&
        dirtyEvents.isEmpty &&
        tombstones.isEmpty) {
      return 0;
    }

    final List<Map<String, dynamic>> changes = <Map<String, dynamic>>[
      // Folders FIRST: a notebook payload can name a folder the peer has
      // never heard of, and applying them folder-before-notebook within one
      // push keeps the reference resolvable on arrival.
      for (final Folder row in dirtyFolders)
        <String, dynamic>{
          'entity_type': 'folder',
          'entity_id': row.id,
          'op': 'upsert',
          'payload': <String, dynamic>{
            'name': row.name,
            'created_at': row.createdAt,
          },
        },
      // Tags next, for the same reason: an assignment later in this batch
      // names its tag, and the server refuses an assignment to a tag it has
      // never heard of.
      for (final TagRow row in dirtyTags)
        <String, dynamic>{
          'entity_type': 'tag',
          'entity_id': row.id,
          'op': 'upsert',
          'payload': <String, dynamic>{
            'name': row.name,
            'created_at': row.createdAt,
            'updated_at': row.updatedAt,
          },
        },
      // Columns before todos: todo placement references the lane id.
      for (final TodoColumnRow row in dirtyTodoColumns)
        <String, dynamic>{
          'entity_type': 'todo_column',
          'entity_id': row.id,
          'op': 'upsert',
          'payload': <String, dynamic>{
            'name': row.name,
            'sort_order': row.sortOrder,
            'created_at': row.createdAt,
            'updated_at': row.updatedAt,
            'deleted_at': row.deletedAt,
          },
        },
      for (final NotebookRow row in dirty)
        <String, dynamic>{
          'entity_type': 'notebook',
          'entity_id': row.id,
          'op': 'upsert',
          'payload': <String, dynamic>{
            'title': row.title,
            'created_at': row.createdAt,
            'updated_at': row.updatedAt,
            'doc': row.docJson,
            'ink': row.inkJson,
            'ruling': row.ruling,
            'last_pen_style': row.lastPenStyle,
            // Filing travels with the notebook. Null is meaningful here —
            // it says "unfiled", and the server stores it verbatim.
            'folder_id': row.folderId,
            'pinned': row.pinned == true,
            // The plaintext password never leaves the password dialog. A
            // complete verifier installs/rotates protection on peers. A null
            // clears only when password_hash_prev matches the held verifier;
            // the predecessor also persists as a stale-generation tombstone.
            'password_hash': row.passwordHash,
            'password_salt': row.passwordSalt,
            'password_iterations': row.passwordIterations,
            'password_hash_prev': row.passwordHashPrev,
          },
        },
      for (final DumpRow row in dirtyDumps)
        <String, dynamic>{
          'entity_type': 'dump',
          'entity_id': row.id,
          'op': 'upsert',
          'payload': <String, dynamic>{
            'mode': row.mode,
            'title': row.title,
            'transcript': row.transcript,
            // The speaker name map travels with every push; null means
            // "no names" and the server stores it verbatim.
            'speaker_names': row.speakerNames,
            'meeting_notes': row.meetingNotes,
            'duration_seconds': row.durationSeconds,
            'created_at': row.createdAt.millisecondsSinceEpoch ~/ 1000,
            'updated_at': row.updatedAt.millisecondsSinceEpoch ~/ 1000,
            // v1.38: filing travels with the dump, todo-style — null is
            // always meaningful (unfiled), so the key is always present.
            'folder_id': row.folderId,
            'pinned': row.pinned == true,
            // audio_kept is deliberately absent: whether the SERVER holds the
            // audio is the server's own fact, and sending our view of it
            // would let a device that never uploaded clear the flag.
            // Likewise absent (v1.19.0): language, translated,
            // summary_status, summary_error, summary_queue_position are
            // server-authored, and summary_error_dismissed_at is local-only.
            // The auto-file markers are server-authored too: a push never
            // carries them — pushing a CHANGED folder_id is what clears
            // them server-side.
          },
        },
      for (final TodoRow row in dirtyTodos)
        <String, dynamic>{
          'entity_type': 'todo',
          'entity_id': row.id,
          'op': 'upsert',
          // Every field travels on every push, nulls included: for todos a
          // null is always meaningful (unchecked / undated / live), and a
          // soft delete IS the deleted_at value riding an ordinary upsert.
          'payload': <String, dynamic>{
            'text': row.body,
            'done_at': row.doneAt,
            'due_date': row.dueDate,
            'source': row.source,
            'source_ref': row.sourceRef,
            'created_at': row.createdAt,
            'updated_at': row.updatedAt,
            'deleted_at': row.deletedAt,
            // v1.24.0: filing travels with the item; null means unfiled.
            'folder_id': row.folderId,
            'pinned': row.pinned == true,
            'column_id': row.columnId,
            'board_order': row.boardOrder,
          },
        },
      for (final CalendarEventRow row in dirtyEvents)
        <String, dynamic>{
          'entity_type': 'calendar_event',
          'entity_id': row.id,
          'op': 'upsert',
          // Projection: google_event_id / google_html_link / google_updated
          // are SERVER-authored and capture_fingerprint is local-only —
          // none of the four ever rides a device push.
          'payload': <String, dynamic>{
            'title': row.title,
            'start': row.start,
            'end': row.end,
            'all_day': row.allDay ? 1 : 0,
            'time_zone': row.timeZone,
            'needs_date': row.needsDate ? 1 : 0,
            'source': row.source,
            'source_ref': row.sourceRef,
            'created_at': row.createdAt,
            'updated_at': row.updatedAt,
            'deleted_at': row.deletedAt,
          },
        },
      // Assignments after every tag and target; removals (and tag deletes)
      // ride the tombstones below.
      for (final TagAssignmentRow row in dirtyAssignments)
        <String, dynamic>{
          'entity_type': 'tag_assignment',
          'entity_id': row.id,
          'op': 'upsert',
          'payload': <String, dynamic>{
            'tag_id': row.tagId,
            'target_type': row.targetType,
            'target_id': row.targetId,
            'created_at': row.createdAt,
          },
        },
      for (final SyncTombstoneRow stone in tombstones)
        if (stone.entityType != 'ask_message')
          <String, dynamic>{
            'entity_type': stone.entityType,
            'entity_id': stone.entityId,
            'op': 'delete',
          },
    ];

    final List<PushResult> results = await client.pushChanges(
      deviceId: deviceId,
      changes: changes,
    );

    final Map<String, int> pushedUpdatedAt = <String, int>{
      for (final NotebookRow row in dirty) row.id: row.updatedAt,
    };
    final Map<String, DateTime> pushedDumpUpdatedAt = <String, DateTime>{
      for (final DumpRow row in dirtyDumps) row.id: row.updatedAt,
    };
    final Set<String> pushedFolderIds = <String>{
      for (final Folder row in dirtyFolders) row.id,
    };
    final Map<String, int> pushedTagUpdatedAt = <String, int>{
      for (final TagRow row in dirtyTags) row.id: row.updatedAt,
    };
    final Set<String> pushedAssignmentIds = <String>{
      for (final TagAssignmentRow row in dirtyAssignments) row.id,
    };
    final Map<String, String> pushedTodoUpdatedAt = <String, String>{
      for (final TodoRow row in dirtyTodos) row.id: row.updatedAt,
    };
    final Map<String, String> pushedTodoColumnUpdatedAt = <String, String>{
      for (final TodoColumnRow row in dirtyTodoColumns) row.id: row.updatedAt,
    };
    final Map<String, String> pushedEventUpdatedAt = <String, String>{
      for (final CalendarEventRow row in dirtyEvents) row.id: row.updatedAt,
    };

    int accepted = 0;
    final List<String> rejections = <String>[];
    for (final PushResult result in results) {
      // A rejected notebook stays dirty, but rebases a stale or malformed
      // verifier tuple from the canonical server response. Its body retries
      // next cycle with that tuple rather than sending the same bad state
      // forever. The rejection is still surfaced as a failed sync below.
      if (!result.applied) {
        final int? was = pushedUpdatedAt[result.entityId];
        if (result.entityType == 'notebook' && was != null) {
          await _rebaseRejectedNotebookPassword(result, was);
        }
        rejections.add(
          '${result.entityType}/${result.entityId}: '
          '${result.reason ?? 'server rejected change'}',
        );
        continue;
      }
      accepted++;
      // Dispatch on the entity TYPE, not on "was it in the notebook map":
      // an accepted dump would otherwise fall through to clearTombstone and
      // stay dirty forever, re-pushing on every cycle.
      if (result.entityType == 'dump') {
        final DateTime? wasDump = pushedDumpUpdatedAt[result.entityId];
        if (wasDump != null) {
          await _db.markDumpSynced(
            result.entityId,
            seq: result.seq,
            pushedUpdatedAt: wasDump,
          );
        } else {
          await _db.clearTombstone(
            entityType: result.entityType,
            entityId: result.entityId,
          );
        }
        continue;
      }
      if (result.entityType == 'folder') {
        if (pushedFolderIds.contains(result.entityId)) {
          await _db.markFolderSynced(result.entityId, seq: result.seq);
        } else {
          await _db.clearTombstone(
            entityType: result.entityType,
            entityId: result.entityId,
          );
        }
        continue;
      }
      if (result.entityType == 'tag') {
        final int? was = pushedTagUpdatedAt[result.entityId];
        if (was != null) {
          await _db.markTagSynced(
            result.entityId,
            seq: result.seq,
            pushedUpdatedAt: was,
          );
        } else {
          await _db.clearTombstone(
            entityType: result.entityType,
            entityId: result.entityId,
          );
        }
        continue;
      }
      if (result.entityType == 'tag_assignment') {
        if (pushedAssignmentIds.contains(result.entityId)) {
          await _db.markTagAssignmentSynced(result.entityId, seq: result.seq);
        } else {
          await _db.clearTombstone(
            entityType: result.entityType,
            entityId: result.entityId,
          );
        }
        continue;
      }
      if (result.entityType == 'calendar_event') {
        final String? was = pushedEventUpdatedAt[result.entityId];
        if (was != null) {
          await _db.markCalendarEventSynced(
            result.entityId,
            seq: result.seq,
            pushedUpdatedAt: was,
          );
        }
        continue;
      }
      if (result.entityType == 'todo') {
        // Todos never write tombstones (soft delete travels as an upsert),
        // so an accepted todo is always a dirty-row confirmation. Guarded
        // on updated_at like the others: an edit made while the push was
        // in flight must stay dirty.
        final String? wasTodo = pushedTodoUpdatedAt[result.entityId];
        if (wasTodo != null) {
          await _db.markTodoSynced(
            result.entityId,
            seq: result.seq,
            pushedUpdatedAt: wasTodo,
          );
        }
        continue;
      }
      if (result.entityType == 'todo_column') {
        final String? was = pushedTodoColumnUpdatedAt[result.entityId];
        if (was != null) {
          await _db.markTodoColumnSynced(
            result.entityId,
            seq: result.seq,
            pushedUpdatedAt: was,
          );
        }
        continue;
      }
      final int? was = pushedUpdatedAt[result.entityId];
      if (was != null) {
        await _db.markNotebookSynced(
          result.entityId,
          seq: result.seq,
          pushedUpdatedAt: was,
        );
      } else {
        await _db.clearTombstone(
          entityType: result.entityType,
          entityId: result.entityId,
        );
      }
    }
    if (rejections.isNotEmpty) {
      throw StateError('Sync push rejected: ${rejections.join('; ')}');
    }
    return accepted;
  }
}
