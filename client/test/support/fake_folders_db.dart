// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Live-folder fake shared by folder-UI widget tests. A REAL drift db in a
// widget test trips '!timersPending' (StreamQueryStore closes queries via a
// zero-duration timer), so folder-affecting screens fake persistence and the
// db-layer semantics (unfiling, tombstones) are covered by unit tests
// instead.
import 'dart:async';

import 'package:tangent/data/local_db.dart';

class FakeFoldersDb implements LocalDb {
  final List<Folder> _folders = <Folder>[];
  final StreamController<List<Folder>> _stream =
      StreamController<List<Folder>>.broadcast();
  final List<String> deletedFolderIds = <String>[];

  void seedFolder(Folder folder) {
    _folders.add(folder);
  }

  void _emit() => _stream.add(List<Folder>.from(_folders));

  @override
  Stream<List<Folder>> watchFolders() async* {
    yield List<Folder>.from(_folders);
    yield* _stream.stream;
  }

  @override
  Future<void> deleteFolder(String folderId) async {
    _folders.removeWhere((Folder f) => f.id == folderId);
    deletedFolderIds.add(folderId);
    _emit();
  }

  @override
  Future<void> renameFolder({
    required String folderId,
    required String name,
  }) async {
    final int i = _folders.indexWhere((Folder f) => f.id == folderId);
    if (i != -1) {
      _folders[i] = Folder(
        id: _folders[i].id,
        name: name,
        createdAt: _folders[i].createdAt,
      );
    }
    _emit();
  }

  Future<void> dispose() => _stream.close();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
