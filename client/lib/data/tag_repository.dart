// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Shared custom tags (v33): one vocabulary across notebooks and recordings.
//
// Screens talk to [TagStore], never to LocalDb directly: widget tests cannot
// host a real drift database (its stream store leaves a zero-duration timer
// pending), so they override [tagStoreProvider] with an in-memory fake while
// the drift semantics are covered by unit tests against [LocalTagStore].
//
// Everything the list screens watch here is a PROJECTION — tag ids and names,
// (target id, tag id) pairs — never a notebook or recording row. Tagging an
// item therefore re-streams two short text columns, not document bodies.
//
// Follow-up (not in this feature): bulk tagging from the multi-select
// toolbars, and merging same-named tags created independently on two devices
// while offline (they sync by id and stay separate, like folders).
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../screens/home/home_screen.dart' show localDbProvider;
import 'local_db.dart';

/// A tag as the UI needs it.
typedef TagSummary = ({String id, String name});

/// Wire names of the two taggable kinds.
abstract final class TagTarget {
  static const String notebook = LocalDb.tagTargetNotebook;
  static const String dump = LocalDb.tagTargetDump;
}

abstract interface class TagStore {
  /// Every tag, alphabetical.
  Stream<List<TagSummary>> watchTags();

  /// (target id, tag id) pairs for one target kind, live tags only.
  Stream<List<TagLink>> watchTagLinks(String targetType);

  /// Creates a tag, or returns the id of the one already holding [name].
  Future<String> createTag(String name);
  Future<void> renameTag(String id, String name);

  /// Deletes the tag AND removes it from every notebook and recording.
  Future<void> deleteTag(String id);

  /// Notebooks + recordings carrying [id], for the delete confirmation.
  Future<int> usageCount(String id);
  Future<void> assignTag({
    required String tagId,
    required String targetType,
    required String targetId,
  });
  Future<void> unassignTag({
    required String tagId,
    required String targetType,
    required String targetId,
  });
}

/// The production store: a thin adapter over [LocalDb]'s tag methods, which
/// own dirty-marking and tombstones so sync sees every write.
class LocalTagStore implements TagStore {
  LocalTagStore(this._db);
  final LocalDb _db;

  @override
  Stream<List<TagSummary>> watchTags() => _db.watchTags().map(
    (List<TagRow> rows) => <TagSummary>[
      for (final TagRow row in rows) (id: row.id, name: row.name),
    ],
  );

  @override
  Stream<List<TagLink>> watchTagLinks(String targetType) =>
      _db.watchTagLinks(targetType);

  @override
  Future<String> createTag(String name) => _db.createTag(name);

  @override
  Future<void> renameTag(String id, String name) => _db.renameTag(id, name);

  @override
  Future<void> deleteTag(String id) => _db.deleteTag(id);

  @override
  Future<int> usageCount(String id) => _db.tagAssignmentCount(id);

  @override
  Future<void> assignTag({
    required String tagId,
    required String targetType,
    required String targetId,
  }) => _db.assignTag(tagId: tagId, targetType: targetType, targetId: targetId);

  @override
  Future<void> unassignTag({
    required String tagId,
    required String targetType,
    required String targetId,
  }) =>
      _db.unassignTag(tagId: tagId, targetType: targetType, targetId: targetId);
}

final tagStoreProvider = Provider<TagStore>(
  (ref) => LocalTagStore(ref.watch(localDbProvider)),
);

/// Live tag vocabulary.
final tagsProvider = StreamProvider<List<TagSummary>>(
  (ref) => ref.watch(tagStoreProvider).watchTags(),
);

/// target id → its tag ids, for one target kind ('notebook' or 'dump').
final tagLinksProvider =
    StreamProvider.family<Map<String, Set<String>>, String>(
      (ref, String targetType) => ref
          .watch(tagStoreProvider)
          .watchTagLinks(targetType)
          .map(groupTagLinks),
    );

/// The tag filter of one list screen: a tag id, or null for "all". Keyed by
/// target kind so the notebook and recording lists filter independently
/// through the identical control.
final tagFilterProvider = StateProvider.family<String?, String>(
  (ref, String targetType) => null,
);

Map<String, Set<String>> groupTagLinks(List<TagLink> links) {
  final Map<String, Set<String>> byTarget = <String, Set<String>>{};
  for (final TagLink link in links) {
    (byTarget[link.targetId] ??= <String>{}).add(link.tagId);
  }
  return byTarget;
}

/// The names of [tagIds] in vocabulary (alphabetical) order. Unknown ids are
/// skipped: an assignment can briefly outlive its tag mid-sync.
List<String> tagNamesFor(Set<String>? tagIds, List<TagSummary> tags) {
  if (tagIds == null || tagIds.isEmpty) return const <String>[];
  return <String>[
    for (final TagSummary tag in tags)
      if (tagIds.contains(tag.id)) tag.name,
  ];
}

/// The filter that actually applies: a selected tag that no longer exists
/// (deleted here or on a peer) filters nothing rather than emptying the list.
String? effectiveTagFilter(String? selected, List<TagSummary> tags) {
  if (selected == null) return null;
  return tags.any((TagSummary t) => t.id == selected) ? selected : null;
}
