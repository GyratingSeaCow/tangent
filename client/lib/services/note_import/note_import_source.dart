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

/// ZIP source that validates every path and advertised size before exposing a
/// byte. Nothing is extracted to disk, which removes the zip-slip write path.
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
    // Decode from owned bytes. A lazy InputFileStream would keep the selected
    // ZIP locked on Windows for the lifetime of the report screen.
    final Archive archive = ZipDecoder().decodeBytes(
      await file.readAsBytes(),
      verify: true,
    );
    if (archive.length > maxImportArchiveEntries) {
      throw const FormatException('Archive contains more than 10,000 entries');
    }
    int expanded = 0;
    final List<NoteImportEntry> entries = <NoteImportEntry>[];
    for (final ArchiveFile archived in archive) {
      if (!archived.isFile || archived.isSymbolicLink) continue;
      final String safePath = _safeRelativePath(archived.name);
      if (archived.size < 0 || archived.size > maxImportEntryBytes) {
        throw FormatException('$safePath exceeds the 64 MiB import limit');
      }
      expanded += archived.size;
      if (expanded > maxImportExpandedBytes) {
        throw const FormatException(
          'Archive expands beyond the 512 MiB import limit',
        );
      }
      final int compressed = archived.rawContent?.length ?? archived.size;
      if (archived.size > 1024 * 1024 &&
          compressed > 0 &&
          archived.size ~/ compressed > maxImportCompressionRatio) {
        throw FormatException('$safePath has an unsafe compression ratio');
      }
      entries.add(
        NoteImportEntry(
          path: safePath,
          size: archived.size,
          modifiedAt: archived.lastModDateTime,
          readBytes: () async {
            final Uint8List? bytes = archived.readBytes();
            if (bytes == null || bytes.length != archived.size) {
              throw FormatException('Could not decode $safePath');
            }
            return bytes;
          },
        ),
      );
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
