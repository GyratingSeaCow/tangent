// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

const int kDebugLogMaxEntries = 200;
const int kDebugLogMaxBytes = 1024 * 1024;

/// One error observed by a top-level runtime hook.
///
/// Tangent does not inspect application state while creating these entries.
/// Error text can inherently contain values supplied by the throwing library,
/// but transcripts, notes, recordings, and database rows are never collected.
class DebugLogEntry {
  const DebugLogEntry({
    required this.timestamp,
    required this.source,
    required this.error,
    required this.stack,
  });

  final DateTime timestamp;
  final String source;
  final String error;
  final String stack;

  Map<String, Object?> toJson() => <String, Object?>{
    'timestamp': timestamp.toUtc().toIso8601String(),
    'source': source,
    'error': error,
    'stack': stack,
  };

  factory DebugLogEntry.fromJson(Map<String, Object?> json) => DebugLogEntry(
    timestamp: DateTime.parse(json['timestamp']! as String).toUtc(),
    source: json['source']! as String,
    error: json['error']! as String,
    stack: json['stack']! as String,
  );

  DebugLogEntry copyWith({String? error, String? stack}) => DebugLogEntry(
    timestamp: timestamp,
    source: source,
    error: error ?? this.error,
    stack: stack ?? this.stack,
  );
}

abstract class _DebugLogStore {
  Future<List<DebugLogEntry>> load();
  Future<void> save(List<DebugLogEntry> entries);
}

class _MemoryDebugLogStore implements _DebugLogStore {
  List<DebugLogEntry> saved = <DebugLogEntry>[];

  @override
  Future<List<DebugLogEntry>> load() async => List<DebugLogEntry>.of(saved);

  @override
  Future<void> save(List<DebugLogEntry> entries) async {
    saved = List<DebugLogEntry>.of(entries);
  }
}

/// JSON persistence with a recoverable atomic rotation.
///
/// The completed file is moved to `.backup`, the flushed `.next` file is
/// renamed into place, then the backup is removed. A process death at any
/// point leaves either the main file or the backup readable on next startup.
class _FileDebugLogStore implements _DebugLogStore {
  _FileDebugLogStore(this.file);

  final File file;

  File get _next => File('${file.path}.next');
  File get _backup => File('${file.path}.backup');

  @override
  Future<List<DebugLogEntry>> load() async {
    for (final File candidate in <File>[file, _backup]) {
      if (!await candidate.exists()) continue;
      try {
        final Object? decoded = jsonDecode(await candidate.readAsString());
        if (decoded is! List<Object?>) continue;
        return decoded
            .whereType<Map<Object?, Object?>>()
            .map(
              (Map<Object?, Object?> value) => DebugLogEntry.fromJson(
                value.map(
                  (Object? key, Object? item) =>
                      MapEntry<String, Object?>(key.toString(), item),
                ),
              ),
            )
            .toList(growable: true);
      } on Object {
        // A partial/corrupt candidate is ignored; try the recovery file.
      }
    }
    return <DebugLogEntry>[];
  }

  @override
  Future<void> save(List<DebugLogEntry> entries) async {
    await file.parent.create(recursive: true);
    final String encoded = jsonEncode(
      entries.map((DebugLogEntry entry) => entry.toJson()).toList(),
    );
    await _next.writeAsString(encoded, flush: true);
    if (await _backup.exists()) await _backup.delete();
    if (await file.exists()) await file.rename(_backup.path);
    try {
      await _next.rename(file.path);
      if (await _backup.exists()) await _backup.delete();
    } on Object {
      if (!await file.exists() && await _backup.exists()) {
        await _backup.rename(file.path);
      }
      rethrow;
    }
  }
}

/// Persistent oldest-to-newest rolling error buffer.
class DebugLogBuffer {
  DebugLogBuffer._({
    required _DebugLogStore store,
    this.maxEntries = kDebugLogMaxEntries,
    this.maxBytes = kDebugLogMaxBytes,
  }) : _store = store;

  factory DebugLogBuffer.inMemory({
    int maxEntries = kDebugLogMaxEntries,
    int maxBytes = kDebugLogMaxBytes,
  }) => DebugLogBuffer._(
    store: _MemoryDebugLogStore(),
    maxEntries: maxEntries,
    maxBytes: maxBytes,
  );

  factory DebugLogBuffer.file(
    File file, {
    int maxEntries = kDebugLogMaxEntries,
    int maxBytes = kDebugLogMaxBytes,
  }) => DebugLogBuffer._(
    store: _FileDebugLogStore(file),
    maxEntries: maxEntries,
    maxBytes: maxBytes,
  );

  final _DebugLogStore _store;
  final int maxEntries;
  final int maxBytes;
  final List<DebugLogEntry> _entries = <DebugLogEntry>[];
  Future<void> _writeQueue = Future<void>.value();
  bool _initialized = false;

  List<DebugLogEntry> get entries => List<DebugLogEntry>.unmodifiable(_entries);

  int get encodedByteLength => utf8.encode(_encode()).length;

  Future<void> initialize() async {
    if (_initialized) return;
    final List<DebugLogEntry> pending = List<DebugLogEntry>.of(_entries);
    final List<DebugLogEntry> loaded = await _store.load();
    _entries
      ..clear()
      ..addAll(loaded)
      ..addAll(pending);
    _trim();
    _initialized = true;
    await _store.save(_entries);
  }

  void record({
    required String source,
    required Object error,
    required StackTrace stackTrace,
    DateTime? timestamp,
  }) {
    _entries.add(
      DebugLogEntry(
        timestamp: (timestamp ?? DateTime.now()).toUtc(),
        source: source,
        error: error.toString(),
        stack: stackTrace.toString(),
      ),
    );
    _trim();
    _writeQueue = _writeQueue
        .catchError((Object _) {
          // A failed previous write must not permanently stop future writes.
        })
        .then((_) => _store.save(_entries))
        .catchError((Object _) {
          // Logging must never become a second uncaught error. A later record
          // retries persistence; the in-memory buffer remains exportable.
        });
  }

  Future<void> flush() => _writeQueue;

  String _encode() => jsonEncode(
    _entries.map((DebugLogEntry entry) => entry.toJson()).toList(),
  );

  void _trim() {
    while (_entries.length > maxEntries) {
      _entries.removeAt(0);
    }
    while (_entries.length > 1 && encodedByteLength > maxBytes) {
      _entries.removeAt(0);
    }
    if (_entries.length == 1 && encodedByteLength > maxBytes) {
      _entries[0] = _fitSingleEntry(_entries.single);
    }
  }

  DebugLogEntry _fitSingleEntry(DebugLogEntry entry) {
    DebugLogEntry candidate = entry;
    while (utf8.encode(jsonEncode(<Object?>[candidate.toJson()])).length >
            maxBytes &&
        candidate.stack.runes.length > 1) {
      candidate = candidate.copyWith(
        stack: _truncatedPrefix(
          candidate.stack,
          candidate.stack.runes.length ~/ 2,
        ),
      );
    }
    while (utf8.encode(jsonEncode(<Object?>[candidate.toJson()])).length >
            maxBytes &&
        candidate.error.runes.length > 1) {
      candidate = candidate.copyWith(
        error: _truncatedPrefix(
          candidate.error,
          candidate.error.runes.length ~/ 2,
        ),
      );
    }
    return candidate;
  }
}

String _truncatedPrefix(String value, int runeCount) {
  const String marker = '…[truncated]';
  final List<int> runes = value.runes.toList();
  if (runes.length <= runeCount) return value;
  return '${String.fromCharCodes(runes.take(runeCount))}$marker';
}

class DebugLogMetadata {
  const DebugLogMetadata({
    required this.version,
    required this.buildNumber,
    required this.deviceModel,
    required this.operatingSystem,
  });

  final String version;
  final String buildNumber;
  final String deviceModel;
  final String operatingSystem;
}

String renderDebugLogReport({
  required List<DebugLogEntry> entries,
  required DebugLogMetadata metadata,
  required DateTime generatedAt,
}) {
  final StringBuffer out = StringBuffer()
    ..writeln('Tangent debug logs')
    ..writeln('Generated: ${generatedAt.toUtc().toIso8601String()}')
    ..writeln('App: ${metadata.version} (build ${metadata.buildNumber})')
    ..writeln('Device: ${metadata.deviceModel}')
    ..writeln('OS: ${metadata.operatingSystem}')
    ..writeln(
      'Privacy: Tangent records runtime errors and stacks only; it does not '
      'intentionally collect transcripts, note content, recordings, or '
      'database rows.',
    )
    ..writeln('Entries: ${entries.length}')
    ..writeln('---');
  if (entries.isEmpty) {
    out.writeln('No recent errors');
    return out.toString();
  }
  for (final DebugLogEntry entry in entries) {
    out
      ..writeln(
        '[${entry.timestamp.toUtc().toIso8601String()}] ${entry.source}',
      )
      ..writeln(entry.error)
      ..writeln(entry.stack.isEmpty ? '(no stack trace)' : entry.stack)
      ..writeln('---');
  }
  return out.toString();
}

typedef PlatformErrorHandler = bool Function(Object error, StackTrace stack);

/// Installs top-level capture without replacing the reporting behavior that
/// Flutter or the embedder had before Tangent installed its hooks.
class DebugErrorCapture {
  DebugErrorCapture(this.buffer);

  final DebugLogBuffer buffer;

  VoidCallback installFlutterHandler() {
    final FlutterExceptionHandler? previous = FlutterError.onError;
    void handler(FlutterErrorDetails details) {
      buffer.record(
        source: 'flutter',
        error: details.exception,
        stackTrace: details.stack ?? StackTrace.current,
      );
      (previous ?? FlutterError.presentError)(details);
    }

    FlutterError.onError = handler;
    return () {
      if (identical(FlutterError.onError, handler)) {
        FlutterError.onError = previous;
      }
    };
  }

  PlatformErrorHandler platformHandler({PlatformErrorHandler? previous}) {
    return (Object error, StackTrace stack) {
      buffer.record(source: 'platform', error: error, stackTrace: stack);
      return previous?.call(error, stack) ?? false;
    };
  }

  void handleZoneError(
    Object error,
    StackTrace stack, {
    void Function(Object error, StackTrace stack)? forward,
  }) {
    buffer.record(source: 'zone', error: error, stackTrace: stack);
    if (forward != null) {
      forward(error, stack);
    } else {
      FlutterError.presentError(
        FlutterErrorDetails(exception: error, stack: stack, library: 'zone'),
      );
    }
  }
}
