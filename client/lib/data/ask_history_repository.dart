// SPDX-License-Identifier: AGPL-3.0-or-later
library;

import 'dart:convert';

import '../services/ask_client.dart';
import 'local_db.dart';

final class AskHistoryMessage {
  const AskHistoryMessage({
    required this.id,
    required this.role,
    required this.text,
    required this.sources,
    required this.createdAt,
  });
  final String id;
  final String role;
  final String text;
  final List<AskSource> sources;
  final DateTime createdAt;
}

final class AskHistoryRepository {
  const AskHistoryRepository(this._db);
  final LocalDb _db;

  Stream<List<AskHistoryMessage>> watch() => _db.watchAskHistory().map(_map);
  Future<List<AskHistoryMessage>> list() async => _map(await _db.askHistory());

  static List<AskHistoryMessage> _map(List<AskMessageRow> rows) => rows
      .map(
        (AskMessageRow row) => AskHistoryMessage(
          id: row.id,
          role: row.role,
          text: row.body,
          sources: (jsonDecode(row.sourcesJson) as List<dynamic>)
              .map(
                (dynamic item) =>
                    AskSource.fromJson((item as Map).cast<String, dynamic>()),
              )
              .toList(growable: false),
          createdAt: DateTime.fromMillisecondsSinceEpoch(
            row.createdAt * 1000,
            isUtc: true,
          ),
        ),
      )
      .toList(growable: false);
}
