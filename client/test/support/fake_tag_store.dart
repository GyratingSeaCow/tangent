// SPDX-License-Identifier: AGPL-3.0-or-later
//
// In-memory [TagStore] for widget tests. A real drift database in a widget
// test trips '!timersPending', so the UI is driven against this and the
// drift semantics (dirty flags, tombstones, cascade) live in
// tag_store_test.dart. The fake mirrors the observable rules the UI relies
// on: case-insensitive dedupe on create, rename conflicts, and a delete that
// removes the tag from notebooks AND recordings.
import 'dart:async';

import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/tag_repository.dart';

class FakeTagStore implements TagStore {
  final List<TagSummary> _tags = <TagSummary>[];
  final Map<String, List<TagLink>> _links = <String, List<TagLink>>{
    TagTarget.notebook: <TagLink>[],
    TagTarget.dump: <TagLink>[],
  };
  final StreamController<void> _changes = StreamController<void>.broadcast();
  final List<String> deletedTagIds = <String>[];
  int _nextId = 1;

  /// Seeds a tag directly (no dedupe), returning its id.
  String seedTag(String name, {String? id}) {
    final String tagId = id ?? 'tag-${_nextId++}';
    _tags.add((id: tagId, name: name));
    return tagId;
  }

  void seedLink(String targetType, String targetId, String tagId) {
    _links[targetType]!.add((targetId: targetId, tagId: tagId));
  }

  Set<String> tagIdsOn(String targetType, String targetId) => <String>{
    for (final TagLink l in _links[targetType]!)
      if (l.targetId == targetId) l.tagId,
  };

  List<TagSummary> get tags => List<TagSummary>.unmodifiable(_tags);

  void _emit() => _changes.add(null);

  List<TagSummary> _sorted() => List<TagSummary>.of(_tags)
    ..sort(
      (TagSummary a, TagSummary b) =>
          a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    );

  @override
  Stream<List<TagSummary>> watchTags() async* {
    yield _sorted();
    yield* _changes.stream.map((_) => _sorted());
  }

  @override
  Stream<List<TagLink>> watchTagLinks(String targetType) async* {
    yield List<TagLink>.of(_links[targetType]!);
    yield* _changes.stream.map((_) => List<TagLink>.of(_links[targetType]!));
  }

  @override
  Future<String> createTag(String name) async {
    final String normal = LocalDb.normalizeTagName(name);
    for (final TagSummary t in _tags) {
      if (t.name.toLowerCase() == normal.toLowerCase()) return t.id;
    }
    final String id = seedTag(normal);
    _emit();
    return id;
  }

  @override
  Future<void> renameTag(String id, String name) async {
    final String normal = LocalDb.normalizeTagName(name);
    if (_tags.any(
      (TagSummary t) =>
          t.id != id && t.name.toLowerCase() == normal.toLowerCase(),
    )) {
      throw TagNameException('A tag named “$normal” already exists');
    }
    final int i = _tags.indexWhere((TagSummary t) => t.id == id);
    _tags[i] = (id: id, name: normal);
    _emit();
  }

  @override
  Future<void> deleteTag(String id) async {
    _tags.removeWhere((TagSummary t) => t.id == id);
    for (final List<TagLink> links in _links.values) {
      links.removeWhere((TagLink l) => l.tagId == id);
    }
    deletedTagIds.add(id);
    _emit();
  }

  @override
  Future<int> usageCount(String id) async => _links.values
      .expand((List<TagLink> l) => l)
      .where((TagLink l) => l.tagId == id)
      .length;

  @override
  Future<void> assignTag({
    required String tagId,
    required String targetType,
    required String targetId,
  }) async {
    if (!tagIdsOn(targetType, targetId).contains(tagId)) {
      seedLink(targetType, targetId, tagId);
    }
    _emit();
  }

  @override
  Future<void> unassignTag({
    required String tagId,
    required String targetType,
    required String targetId,
  }) async {
    _links[targetType]!.removeWhere(
      (TagLink l) => l.targetId == targetId && l.tagId == tagId,
    );
    _emit();
  }

  Future<void> dispose() => _changes.close();
}
