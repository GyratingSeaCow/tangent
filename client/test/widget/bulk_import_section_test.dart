// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Settings → Import audio files… — the bulk door (item 1.4). Pins:
// the tile exists with its explanation, a batch reports success count,
// and a batch with failures NAMES the failed files (a silent skip would
// look like the import worked).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/screens/home/home_providers.dart';
import 'package:tangent/screens/settings/bulk_import_section.dart';
import 'package:tangent/services/audio_file_picker.dart';
import 'package:tangent/services/bulk_audio_import.dart';

final class _FakeBulkPicker implements BulkAudioFilePicker {
  _FakeBulkPicker(this.files);
  final List<PickedAudio> files;

  @override
  Future<List<PickedAudio>> pickMany() async => files;
}

final class _ScriptedRunner implements AudioImportRunner {
  _ScriptedRunner({this.failures = const <String, String>{}});
  final Map<String, String> failures;

  @override
  Future<Outcome<String>> run({
    required String sourcePath,
    required String mode,
    String? title,
  }) async {
    final failure = failures[sourcePath];
    if (failure != null) {
      return Fail<String>((code: ProblemCode.io, message: failure));
    }
    return const Ok<String>('dump-id');
  }
}

Future<void> pump(
  WidgetTester tester, {
  required List<PickedAudio> files,
  Map<String, String> failures = const <String, String>{},
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        bulkAudioFilePickerProvider.overrideWithValue(_FakeBulkPicker(files)),
        audioImportRunnerProvider
            .overrideWithValue(_ScriptedRunner(failures: failures)),
      ],
      child: const MaterialApp(
        home: Scaffold(body: BulkImportSection()),
      ),
    ),
  );
}

void main() {
  testWidgets('offers the import tile with its explanation', (tester) async {
    await pump(tester, files: const []);

    expect(find.text('Import audio files…'), findsOneWidget);
    expect(
      find.textContaining('Each file becomes a normal brain dump'),
      findsOneWidget,
      reason: 'the tile needs its explanation underneath',
    );
  });

  testWidgets('a clean batch reports how many files imported', (tester) async {
    await pump(
      tester,
      files: const [
        PickedAudio(path: '/c/a.opus', name: 'a.opus'),
        PickedAudio(path: '/c/b.mp3', name: 'b.mp3'),
      ],
    );

    await tester.tap(find.text('Import audio files…'));
    await tester.pumpAndSettle();

    expect(find.text('Imported 2 files'), findsOneWidget);
  });

  testWidgets('failures are named, never silently skipped', (tester) async {
    await pump(
      tester,
      files: const [
        PickedAudio(path: '/c/a.opus', name: 'a.opus'),
        PickedAudio(path: '/c/bad.mp3', name: 'bad.mp3'),
      ],
      failures: const {'/c/bad.mp3': 'unsupported codec'},
    );

    await tester.tap(find.text('Import audio files…'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('bad.mp3'),
      findsOneWidget,
      reason: 'the user must know exactly which file to retry',
    );
    expect(find.textContaining('Imported 1'), findsOneWidget);
  });

  testWidgets('cancelling the picker changes nothing', (tester) async {
    await pump(tester, files: const []);

    await tester.tap(find.text('Import audio files…'));
    await tester.pumpAndSettle();

    expect(find.byType(SnackBar), findsNothing);
  });
}
