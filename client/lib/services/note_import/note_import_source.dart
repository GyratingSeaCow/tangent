// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

import 'note_import_model.dart';

const int maxImportArchiveEntries = 10000;
const int maxImportEntryBytes = 64 * 1024 * 1024;
const int maxImportExpandedBytes = 512 * 1024 * 1024;
const int maxImportCompressionRatio = 250;

String _safeRelativePath(String input) {
  final String slashed = input.replaceAll('\\', '/');
  if (slashed.startsWith('/') || RegExp(r'^[A-Za-z]:/').hasMatch(slashed)) {
    throw const FormatException('Archive contains an absolute path');
  }
  final List<String> parts = <String>[];
  for (final String part in slashed.split('/')) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..') {
      throw const FormatException('Archive contains a parent path');
    }
    parts.add(part);
  }
  if (parts.isEmpty) throw const FormatException('Archive entry has no name');
  return parts.join('/');
}

class DirectoryNoteImportSource implements NoteImportSource {
  DirectoryNoteImportSource._(this.root);

  final Directory root;

  static Future<DirectoryNoteImportSource> open(String path) async {
    final Directory directory = Directory(path);
    if (!await directory.exists()) {
      throw FileSystemException('Import folder does not exist', path);
    }
    return DirectoryNoteImportSource._(directory);
  }

  @override
  String get displayName => p.basename(root.path);

  @override
  Stream<NoteImportEntry> entries() async* {
    await for (final FileSystemEntity entity in root.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File) continue;
      final String relative = _safeRelativePath(
        p.relative(entity.path, from: root.path),
      );
      final int length = await entity.length();
      if (length > maxImportEntryBytes) {
        throw FormatException('$relative exceeds the 64 MiB import limit');
      }
      yield NoteImportEntry(
        path: relative,
        size: length,
        readBytes: entity.readAsBytes,
        modifiedAt: (await entity.lastModified()).toUtc(),
      );
    }
  }

  @override
  Future<NoteImportEntry?> find(String relativePath) async {
    final String wanted = _safeRelativePath(relativePath);
    await for (final NoteImportEntry entry in entries()) {
      if (entry.path == wanted) return entry;
    }
    return null;
  }
}

class FileNoteImportSource implements NoteImportSource {
  FileNoteImportSource._(this.file);

  final File file;

  static Future<FileNoteImportSource> open(String path) async {
    final File file = File(path);
    if (!await file.exists()) {
      throw FileSystemException('Import file does not exist', path);
    }
    final int length = await file.length();
    if (length > maxImportEntryBytes) {
      throw const FormatException(
        'Selected file exceeds the 64 MiB import limit',
      );
    }
    return FileNoteImportSource._(file);
  }

  @override
  String get displayName => p.basename(file.path);

  @override
  Stream<NoteImportEntry> entries() async* {
    yield NoteImportEntry(
      path: p.basename(file.path),
      size: await file.length(),
      readBytes: file.readAsBytes,
      modifiedAt: (await file.lastModified()).toUtc(),
    );
  }

  @override
  Future<NoteImportEntry?> find(String relativePath) async {
    final String wanted = _safeRelativePath(relativePath);
    return wanted == p.basename(file.path) ? entries().first : null;
  }
}

/// ZIP source that scans from disk and bounded-inflates every file before it is
/// exposed. Nothing is extracted, and no decompressed entry is retained.
class ZipNoteImportSource implements NoteImportSource {
  ZipNoteImportSource._(this.path, this._entries);

  final String path;
  final List<NoteImportEntry> _entries;

  static Future<ZipNoteImportSource> open(String path) async {
    final File file = File(path);
    if (!await file.exists()) {
      throw FileSystemException('Import archive does not exist', path);
    }
    final int archiveBytes = await file.length();
    if (archiveBytes > maxImportExpandedBytes) {
      throw const FormatException('Archive exceeds the 512 MiB import limit');
    }

    final InputFileStream input = InputFileStream(path);
    final List<NoteImportEntry> entries = <NoteImportEntry>[];
    try {
      final Archive archive = ZipDecoder().decodeStream(input);
      if (archive.length > maxImportArchiveEntries) {
        throw const FormatException(
          'Archive contains more than 10,000 entries',
        );
      }
      int expanded = 0;
      for (int index = 0; index < archive.length; index++) {
        final ArchiveFile archived = archive[index];
        if (!archived.isFile || archived.isSymbolicLink) continue;
        final String safePath = _safeRelativePath(archived.name);
        final int compressed = archived.rawContent?.length ?? 0;
        final _CountingOutput output = _CountingOutput(
          maxLength: _entryOutputLimit(
            advertised: archived.size,
            compressed: compressed,
            expandedSoFar: expanded,
          ),
          path: safePath,
        );
        _decompressTo(archived, output, safePath);
        final int actualSize = output.length;
        _validateActualSize(
          path: safePath,
          advertised: archived.size,
          compressed: compressed,
          actual: actualSize,
          expandedSoFar: expanded,
        );
        expanded += actualSize;
        final int archiveIndex = index;
        entries.add(
          NoteImportEntry(
            path: safePath,
            size: actualSize,
            modifiedAt: archived.lastModDateTime,
            readBytes: () => _readZipEntry(
              path,
              archiveIndex: archiveIndex,
              expectedPath: safePath,
              expectedSize: actualSize,
            ),
          ),
        );
      }
    } finally {
      // Reads reopen a short-lived stream, so the selected ZIP is not locked
      // while the import report remains open on Windows.
      input.closeSync();
    }
    return ZipNoteImportSource._(
      path,
      List<NoteImportEntry>.unmodifiable(entries),
    );
  }

  @override
  String get displayName => p.basename(path);

  @override
  Stream<NoteImportEntry> entries() =>
      Stream<NoteImportEntry>.fromIterable(_entries);

  @override
  Future<NoteImportEntry?> find(String relativePath) async {
    final String wanted = _safeRelativePath(relativePath);
    for (final NoteImportEntry entry in _entries) {
      if (entry.path == wanted) return entry;
    }
    return null;
  }
}

int _entryOutputLimit({
  required int advertised,
  required int compressed,
  required int expandedSoFar,
}) {
  if (advertised < 0) return 0;
  final int ratioLimit = compressed <= 0
      ? 1024 * 1024
      : _maxInt(1024 * 1024, compressed * maxImportCompressionRatio);
  return <int>[
    advertised,
    maxImportEntryBytes,
    maxImportExpandedBytes - expandedSoFar,
    ratioLimit,
  ].reduce(_minInt);
}

void _validateActualSize({
  required String path,
  required int advertised,
  required int compressed,
  required int actual,
  required int expandedSoFar,
}) {
  if (actual != advertised) {
    throw FormatException('$path has an invalid expanded size');
  }
  if (actual > maxImportEntryBytes) {
    throw FormatException('$path exceeds the 64 MiB import limit');
  }
  if (expandedSoFar + actual > maxImportExpandedBytes) {
    throw const FormatException(
      'Archive expands beyond the 512 MiB import limit',
    );
  }
  if (actual > 1024 * 1024 &&
      (compressed <= 0 || actual > compressed * maxImportCompressionRatio)) {
    throw FormatException('$path has an unsafe compression ratio');
  }
}

void _decompressTo(ArchiveFile entry, OutputStream output, String path) {
  try {
    if (entry.compression == CompressionType.deflate &&
        entry.rawContent != null) {
      // archive 4.3's dart:io ZLibDecoder collects every output chunk before
      // forwarding it, so its decodeStream is not memory-bounded. Use the
      // package's pure-Dart inflater with our capped OutputStream instead.
      Inflate.stream(
        entry.rawContent!.getStream(decompress: false),
        output: output,
      );
    } else {
      entry.decompress(output);
    }
  } on FormatException {
    rethrow;
  } catch (error) {
    throw FormatException('Could not decode $path: $error');
  }
}

Future<Uint8List> _readZipEntry(
  String zipPath, {
  required int archiveIndex,
  required String expectedPath,
  required int expectedSize,
}) async {
  final InputFileStream input = InputFileStream(zipPath);
  try {
    final Archive archive = ZipDecoder().decodeStream(input);
    if (archiveIndex >= archive.length) {
      throw FormatException('Archive changed while reading $expectedPath');
    }
    final ArchiveFile entry = archive[archiveIndex];
    if (_safeRelativePath(entry.name) != expectedPath || !entry.isFile) {
      throw FormatException('Archive changed while reading $expectedPath');
    }
    final _BoundedMemoryOutput output = _BoundedMemoryOutput(
      maxLength: expectedSize,
      path: expectedPath,
    );
    _decompressTo(entry, output, expectedPath);
    if (output.length != expectedSize) {
      throw FormatException('Archive changed while reading $expectedPath');
    }
    final Uint8List bytes = Uint8List.fromList(output.getBytes());
    final int? expectedCrc = entry.crc32;
    if (expectedCrc != null && getCrc32(bytes) != expectedCrc) {
      throw FormatException('$expectedPath failed its ZIP checksum');
    }
    return bytes;
  } finally {
    input.closeSync();
  }
}

class _BoundedMemoryOutput extends OutputMemoryStream {
  _BoundedMemoryOutput({required this.maxLength, required this.path})
    : super(size: _minInt(maxLength, OutputMemoryStream.defaultBufferSize));

  final int maxLength;
  final String path;

  void _reserve(int count) {
    if (count < 0 || length + count > maxLength) {
      throw FormatException('$path exceeds its safe expanded size');
    }
  }

  @override
  void writeByte(int value) {
    _reserve(1);
    super.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    _reserve(length ?? bytes.length);
    super.writeBytes(bytes, length: length);
  }

  @override
  void writeStream(InputStream stream) {
    _reserve(stream.length);
    super.writeStream(stream);
  }

  @override
  void writeBackReference(int distance, int count) {
    _reserve(count);
    super.writeBackReference(distance, count);
  }
}

/// Counts actual inflated bytes while retaining only the DEFLATE history
/// window needed to resolve back-references.
class _CountingOutput extends OutputStream {
  _CountingOutput({required this.maxLength, required this.path})
    : super(byteOrder: ByteOrder.littleEndian);

  static const int _windowSize = 64 * 1024;
  final int maxLength;
  final String path;
  final Uint8List _window = Uint8List(_windowSize);

  @override
  int length = 0;

  void _reserve(int count) {
    if (count < 0 || length + count > maxLength) {
      throw FormatException('$path exceeds its safe expanded size');
    }
  }

  @override
  void writeByte(int value) {
    _reserve(1);
    _window[length % _windowSize] = value;
    length++;
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    final int count = length ?? bytes.length;
    _reserve(count);
    for (int i = 0; i < count; i++) {
      _window[this.length % _windowSize] = bytes[i];
      this.length++;
    }
  }

  @override
  void writeStream(InputStream stream) {
    while (!stream.isEOS) {
      final int count = _minInt(stream.length, 64 * 1024);
      writeBytes(stream.readBytes(count).toUint8List());
    }
  }

  @override
  void writeBackReference(int distance, int count) {
    _reserve(count);
    if (distance <= 0 || distance > _windowSize || distance > length) {
      throw FormatException('$path contains an invalid back-reference');
    }
    for (int i = 0; i < count; i++) {
      final int value = _window[(length - distance) % _windowSize];
      _window[length % _windowSize] = value;
      length++;
    }
  }

  @override
  Uint8List subset(int start, [int? end]) {
    final int absoluteStart = start < 0 ? length + start : start;
    final int absoluteEnd = end == null
        ? length
        : end < 0
        ? length + end
        : end;
    if (absoluteStart < length - _windowSize ||
        absoluteStart < 0 ||
        absoluteEnd < absoluteStart ||
        absoluteEnd > length) {
      throw FormatException('$path contains an invalid back-reference');
    }
    return Uint8List.fromList(<int>[
      for (int i = absoluteStart; i < absoluteEnd; i++)
        _window[i % _windowSize],
    ]);
  }

  @override
  void clear() => length = 0;

  @override
  void flush() {}
}

int _minInt(int a, int b) => a < b ? a : b;
int _maxInt(int a, int b) => a > b ? a : b;
