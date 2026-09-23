// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/screens/home/home_providers.dart';
import 'package:tangent/services/audio_file_picker.dart';
import 'package:tangent/services/bulk_audio_import.dart';
import 'package:tangent/data/storage/storage_contract.dart';

/// Bulk import (Settings, item 1.4): pick many files, import each through
/// the SAME runner the home-screen button uses. The governing rule: one
/// bad file never aborts the rest — failures are collected and reported
/// at the end, alongside every success.
final class ScriptedRunner implements AudioImportRunner {
  /// Paths that must fail, mapped to the failure message.
  ScriptedRunner({this.failures = const <String, String>{}});

  final Map<String, String> failures;
  final List<String> imported = <String>[];

  @override
  Future<Outcome<String>> run({
    required String sourcePath,
    required String mode,
    String? title,
  }) async {
    final String? failure = failures[sourcePath];
    if (failure != null) {
      return Fail<String>((code: ProblemCode.io, message: failure));
    }
    imported.add(sourcePath);
    return const Ok<String>('dump-id');
  }
}

PickedAudio picked(String name) =>
    PickedAudio(path: '/cache/$name', name: name);

void main() {
  test('imports every file and reports each step', () async {
    final runner = ScriptedRunner();
    final progress = <String>[];

    final summary = await runBulkImport(
      files: [picked('a.opus'), picked('b.mp3'), picked('c.wav')],
      runner: runner,
      onProgress: (done, total, name) => progress.add('$done/$total $name'),
    );

    expect(runner.imported, ['/cache/a.opus', '/cache/b.mp3', '/cache/c.wav']);
    expect(summary.imported, 3);
    expect(summary.failed, isEmpty);
    expect(progress, ['1/3 a.opus', '2/3 b.mp3', '3/3 c.wav']);
  });

  test('one bad file never aborts the rest', () async {
    final runner = ScriptedRunner(
      failures: {'/cache/b.mp3': 'unsupported codec'},
    );

    final summary = await runBulkImport(
      files: [picked('a.opus'), picked('b.mp3'), picked('c.wav')],
      runner: runner,
      onProgress: (_, __, ___) {},
    );

    expect(
      runner.imported,
      ['/cache/a.opus', '/cache/c.wav'],
      reason: 'c must import even though b failed before it',
    );
    expect(summary.imported, 2);
    expect(summary.failed, hasLength(1));
    expect(summary.failed.single.name, 'b.mp3');
    expect(summary.failed.single.reason, 'unsupported codec');
  });

  test('a runner that throws is a failed file, not a crashed batch', () async {
    final runner = _ThrowingRunner();

    final summary = await runBulkImport(
      files: [picked('a.opus'), picked('b.mp3')],
      runner: runner,
      onProgress: (_, __, ___) {},
    );

    expect(summary.imported, 1, reason: 'b still imports after a threw');
    expect(summary.failed.single.name, 'a.opus');
  });

  test('imports use brain-dump mode with the file name as title', () async {
    final runner = _RecordingRunner();

    await runBulkImport(
      files: [picked('meeting.m4a')],
      runner: runner,
      onProgress: (_, __, ___) {},
    );

    expect(runner.modes, ['brain_dump']);
    expect(runner.titles, ['meeting.m4a']);
  });
}

final class _ThrowingRunner implements AudioImportRunner {
  bool first = true;

  @override
  Future<Outcome<String>> run({
    required String sourcePath,
    required String mode,
    String? title,
  }) async {
    if (first) {
      first = false;
      throw StateError('decoder exploded');
    }
    return const Ok<String>('dump-id');
  }
}

final class _RecordingRunner implements AudioImportRunner {
  final List<String> modes = <String>[];
  final List<String?> titles = <String?>[];

  @override
  Future<Outcome<String>> run({
    required String sourcePath,
    required String mode,
    String? title,
  }) async {
    modes.add(mode);
    titles.add(title);
    return const Ok<String>('dump-id');
  }
}
