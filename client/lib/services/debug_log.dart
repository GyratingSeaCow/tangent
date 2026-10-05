// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:sqlite3/sqlite3.dart';

const int kDebugLogMaxEntries = 200;
const int kDebugLogMaxBytes = 1024 * 1024;
const int kDebugLogMaxErrorBytes = 16 * 1024;
const int kDebugLogMaxStackBytes = 64 * 1024;
const Duration _kDebugLogSaveDebounce = Duration(milliseconds: 25);

/// One error observed by a top-level runtime hook.
///
/// Tangent does not inspect application state while creating these entries.
/// Before storage, error text is capped and sanitized to remove SQL details,
/// credentials, and fields labelled as transcript or note content.
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

class _CallbackDebugLogStore implements _DebugLogStore {
  _CallbackDebugLogStore({
    required this.loadCallback,
    required this.saveCallback,
  });

  final Future<List<DebugLogEntry>> Function() loadCallback;
  final Future<void> Function(List<DebugLogEntry>) saveCallback;

  @override
  Future<List<DebugLogEntry>> load() => loadCallback();

  @override
  Future<void> save(List<DebugLogEntry> entries) => saveCallback(entries);
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
    Duration saveDebounce = _kDebugLogSaveDebounce,
  }) : _store = store,
       _saveDebounce = saveDebounce;

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

  @visibleForTesting
  factory DebugLogBuffer.testing({
    required Future<List<DebugLogEntry>> Function() load,
    required Future<void> Function(List<DebugLogEntry>) save,
    int maxEntries = kDebugLogMaxEntries,
    int maxBytes = kDebugLogMaxBytes,
    Duration saveDebounce = _kDebugLogSaveDebounce,
  }) => DebugLogBuffer._(
    store: _CallbackDebugLogStore(loadCallback: load, saveCallback: save),
    maxEntries: maxEntries,
    maxBytes: maxBytes,
    saveDebounce: saveDebounce,
  );

  _DebugLogStore _store;
  final int maxEntries;
  final int maxBytes;
  final Duration _saveDebounce;
  final List<DebugLogEntry> _entries = <DebugLogEntry>[];
  final List<int> _entryByteLengths = <int>[];
  int _encodedByteLength = 2; // The surrounding JSON array brackets.
  Timer? _saveTimer;
  Future<void>? _saveWorker;
  bool _dirty = false;
  bool _initialized = false;

  List<DebugLogEntry> get entries => List<DebugLogEntry>.unmodifiable(_entries);

  int get encodedByteLength => _encodedByteLength;

  /// Attaches persistence to the same buffer used during early startup.
  Future<void> initializeWithFile(File file) async {
    if (_initialized) return;
    _store = _FileDebugLogStore(file);
    await initialize();
  }

  Future<void> initialize() async {
    if (_initialized) return;
    final List<DebugLogEntry> loaded = await _store.load();
    // Read pending entries after the asynchronous load so errors captured while
    // startup I/O was in flight are replayed too.
    final List<DebugLogEntry> pending = List<DebugLogEntry>.of(_entries);
    _entries.clear();
    _entryByteLengths.clear();
    _encodedByteLength = 2;
    for (final DebugLogEntry entry in <DebugLogEntry>[...loaded, ...pending]) {
      _appendPrepared(_prepareStoredEntry(entry));
    }
    _initialized = true;
    _dirty = true;
    await flush();
  }

  void record({
    required String source,
    required Object error,
    required StackTrace stackTrace,
    DateTime? timestamp,
  }) {
    final DebugLogEntry? entry = _fitSingleEntry(
      DebugLogEntry(
        timestamp: (timestamp ?? DateTime.now()).toUtc(),
        source: source,
        error: _truncateUtf8(_sanitizeError(error), kDebugLogMaxErrorBytes),
        stack: _truncateUtf8(
          _sanitizeText(stackTrace.toString()),
          kDebugLogMaxStackBytes,
        ),
      ),
    );
    if (entry == null) return;
    _appendPrepared(entry, alreadyFitted: true);
    if (_initialized) _markDirty();
  }

  Future<void> flush() async {
    if (!_initialized) return;
    while (true) {
      _saveTimer?.cancel();
      _saveTimer = null;
      if (_saveWorker == null && _dirty) _startSaveWorker();
      final Future<void>? worker = _saveWorker;
      if (worker == null) return;
      await worker;
    }
  }

  DebugLogEntry _prepareStoredEntry(DebugLogEntry entry) => entry.copyWith(
    error: _truncateUtf8(_sanitizeText(entry.error), kDebugLogMaxErrorBytes),
    stack: _truncateUtf8(_sanitizeText(entry.stack), kDebugLogMaxStackBytes),
  );

  bool _appendPrepared(DebugLogEntry entry, {bool alreadyFitted = false}) {
    final DebugLogEntry? candidate = alreadyFitted
        ? entry
        : _fitSingleEntry(entry);
    if (candidate == null || maxEntries <= 0) return false;

    final int byteLength = _encodedEntryByteLength(candidate);
    _encodedByteLength += byteLength + (_entries.isEmpty ? 0 : 1);
    _entries.add(candidate);
    _entryByteLengths.add(byteLength);
    while (_entries.length > maxEntries || _encodedByteLength > maxBytes) {
      _removeOldest();
    }
    return true;
  }

  void _removeOldest() {
    final bool hadSeparator = _entries.length > 1;
    _entries.removeAt(0);
    _encodedByteLength -=
        _entryByteLengths.removeAt(0) + (hadSeparator ? 1 : 0);
  }

  DebugLogEntry? _fitSingleEntry(DebugLogEntry entry) {
    if (_encodedEntryByteLength(entry) + 2 <= maxBytes) return entry;

    final DebugLogEntry withoutStack = entry.copyWith(stack: '');
    if (_encodedEntryByteLength(withoutStack) + 2 <= maxBytes) {
      return _largestFittingPrefix(entry, field: _EntryField.stack);
    }

    final DebugLogEntry withoutVariableFields = withoutStack.copyWith(
      error: '',
    );
    if (_encodedEntryByteLength(withoutVariableFields) + 2 > maxBytes) {
      return null;
    }
    return _largestFittingPrefix(withoutStack, field: _EntryField.error);
  }

  DebugLogEntry _largestFittingPrefix(
    DebugLogEntry entry, {
    required _EntryField field,
  }) {
    final String value = switch (field) {
      _EntryField.error => entry.error,
      _EntryField.stack => entry.stack,
    };
    final List<int> runes = value.runes.toList(growable: false);
    DebugLogEntry best = switch (field) {
      _EntryField.error => entry.copyWith(error: ''),
      _EntryField.stack => entry.copyWith(stack: ''),
    };
    int low = 1;
    int high = runes.length - 1;
    while (low <= high) {
      final int middle = (low + high) ~/ 2;
      final String shortened = _truncatedRunes(runes, middle);
      final DebugLogEntry candidate = switch (field) {
        _EntryField.error => entry.copyWith(error: shortened),
        _EntryField.stack => entry.copyWith(stack: shortened),
      };
      if (_encodedEntryByteLength(candidate) + 2 <= maxBytes) {
        best = candidate;
        low = middle + 1;
      } else {
        high = middle - 1;
      }
    }
    return best;
  }

  void _markDirty() {
    _dirty = true;
    if (_saveWorker != null) return;
    _saveTimer?.cancel();
    _saveTimer = Timer(_saveDebounce, _startSaveWorker);
  }

  void _startSaveWorker() {
    _saveTimer?.cancel();
    _saveTimer = null;
    if (_saveWorker != null || !_dirty || !_initialized) return;
    _saveWorker = _saveUntilClean();
  }

  Future<void> _saveUntilClean() async {
    try {
      while (_dirty) {
        _dirty = false;
        final List<DebugLogEntry> snapshot = List<DebugLogEntry>.of(_entries);
        try {
          await _store.save(snapshot);
        } on Object {
          // Logging must never become a second uncaught error. A later record
          // retries persistence; the in-memory buffer remains exportable.
        }
      }
    } finally {
      _saveWorker = null;
      if (_dirty) _markDirty();
    }
  }
}

enum _EntryField { error, stack }

String _sanitizeError(Object error) => switch (error) {
  SqliteException() => _sanitizeSqliteException(error),
  FormatException() => 'FormatException: ${_sanitizeText(error.message)}',
  _ => _sanitizeText(error.toString()),
};

String _sanitizeSqliteException(SqliteException error) {
  final String operation = error.operation == null
      ? ''
      : ' while ${_sanitizeText(error.operation!)}';
  return 'SqliteException(${error.extendedResultCode})$operation: '
      '${_sanitizeText(error.message)}';
}

String _sanitizeText(String value) {
  String sanitized = value;
  final Match? causingStatement = RegExp(
    r'\bCausing statement\b',
    caseSensitive: false,
  ).firstMatch(sanitized);
  if (causingStatement != null) {
    sanitized =
        '${sanitized.substring(0, causingStatement.start).trimRight()}'
        '\n[REDACTED SQL STATEMENT AND PARAMETERS]';
  }

  sanitized = sanitized.replaceAll(
    RegExp(
      r'^\s*(?:SELECT|INSERT|UPDATE|DELETE|WITH|CREATE|ALTER|DROP|PRAGMA)\b.*$',
      caseSensitive: false,
      multiLine: true,
    ),
    '[REDACTED SQL STATEMENT]',
  );
  sanitized = sanitized.replaceAllMapped(
    RegExp(
      r'\b(?:sql|statement|parameters(?:ToStatement)?|bindings?|bound\s+values?)\s*[:=][^\r\n]*',
      caseSensitive: false,
    ),
    (Match match) =>
        '${match.group(0)!.split(RegExp(r'[:=]')).first}: '
        '[REDACTED]',
  );
  sanitized = sanitized.replaceAllMapped(
    RegExp(
      r'''["']?(?:password(?:_?hash)?|salt|prev(?:ious)?|transcript(?:_?text)?|note(?:_?content)?)["']?\s*[:=][^\r\n]*''',
      caseSensitive: false,
    ),
    (Match match) =>
        '${match.group(0)!.split(RegExp(r'[:=]')).first}: '
        '[REDACTED]',
  );
  sanitized = sanitized.replaceAll(
    RegExp(r'''["'][^"'\r\n]{256,}["']'''),
    '[REDACTED LARGE VALUE]',
  );
  sanitized = sanitized.replaceAll(
    RegExp(r'\b[A-Za-z0-9+/_=-]{256,}\b'),
    '[REDACTED LARGE VALUE]',
  );
  return sanitized;
}

const String _truncationMarker = '…[truncated]';

int _encodedEntryByteLength(DebugLogEntry entry) =>
    utf8.encode(jsonEncode(entry.toJson())).length;

String _truncatedRunes(List<int> runes, int runeCount) =>
    '${String.fromCharCodes(runes.take(runeCount))}$_truncationMarker';

String _truncateUtf8(String value, int maxBytes) {
  if (utf8.encode(value).length <= maxBytes) return value;
  final List<int> runes = value.runes.toList(growable: false);
  final int markerBytes = utf8.encode(_truncationMarker).length;
  if (markerBytes >= maxBytes) return '';
  int low = 0;
  int high = runes.length;
  while (low < high) {
    final int middle = (low + high + 1) ~/ 2;
    if (utf8.encode(String.fromCharCodes(runes.take(middle))).length <=
        maxBytes - markerBytes) {
      low = middle;
    } else {
      high = middle - 1;
    }
  }
  return _truncatedRunes(runes, low);
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
      'Privacy: Tangent records sanitized runtime errors and stacks only. SQL '
      'statements and parameters, credentials, and fields labelled as '
      'transcript or note content are removed before storage.',
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
