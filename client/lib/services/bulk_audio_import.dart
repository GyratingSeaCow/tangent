// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Bulk audio import (Settings → "Import audio files…", item 1.4).
//
// Jeff (2026-09-23): single-file import lives on the home screen; "If
// it's not bulk import, then we can just add that into the settings
// menu". Each file goes through the SAME AudioImportRunner the
// home-screen button uses — bulk is a loop, not a second import path.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/storage/storage_contract.dart';
import '../models/dump_mode.dart';
import '../screens/home/home_providers.dart';
import 'audio_file_picker.dart';

/// One file that did not import, and why — surfaced, never swallowed.
class FailedImport {
  const FailedImport({required this.name, required this.reason});

  final String name;
  final String reason;
}

/// What a bulk run accomplished. [imported] counts successes; every
/// failure is listed by name so the user knows exactly what to retry.
class BulkImportSummary {
  const BulkImportSummary({required this.imported, required this.failed});

  final int imported;
  final List<FailedImport> failed;
}

/// Called before each file: (1-based position, total, display name).
typedef BulkImportProgress = void Function(int done, int total, String name);

/// Imports [files] sequentially through [runner].
///
/// Sequential on purpose: imports probe duration and write the catalog,
/// and running them concurrently would interleave database writes for no
/// user-visible win — the bottleneck is the copy/probe, not the queue.
///
/// One bad file NEVER aborts the rest: a [Fail] outcome or a thrown
/// error is recorded against that file and the loop continues.
Future<BulkImportSummary> runBulkImport({
  required List<PickedAudio> files,
  required AudioImportRunner runner,
  required BulkImportProgress onProgress,
}) async {
  var imported = 0;
  final failed = <FailedImport>[];

  for (var i = 0; i < files.length; i++) {
    final file = files[i];
    onProgress(i + 1, files.length, file.name);
    try {
      final outcome = await runner.run(
        sourcePath: file.path,
        // Imported recordings are ordinary brain dumps: same transcription
        // path, same catalog shape as a recording made in the app.
        mode: DumpMode.brainDump.wireValue,
        title: file.name,
      );
      switch (outcome) {
        case Ok<String>():
          imported++;
        case Fail<String>(:final problem):
          failed.add(FailedImport(name: file.name, reason: problem.message));
      }
    } catch (error) {
      failed.add(FailedImport(name: file.name, reason: '$error'));
    }
  }

  return BulkImportSummary(imported: imported, failed: failed);
}

/// Opens the multi-select system picker. Every chosen file arrives as an
/// app-private cache copy (same contract as the single-file picker: a
/// transient content:// grant cannot expire mid-import).
class BulkAudioFilePicker {
  BulkAudioFilePicker({AudioFilePicker? single}) : _single = single;

  final AudioFilePicker? _single;

  Future<List<PickedAudio>> pickMany() async {
    final picker = _single ?? AudioFilePicker();
    return picker.pickMultiple();
  }
}

final bulkAudioFilePickerProvider = Provider<BulkAudioFilePicker>((ref) {
  return BulkAudioFilePicker();
});
