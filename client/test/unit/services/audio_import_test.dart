// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/services/audio_import.dart';

import '../../support/scripted_storage_backend.dart';

/// Jeff: "There also needs to be an Import Audio button which will allow you
/// to import audio into the tangent folder by copying it to the tangent
/// folder and then processing it".
///
/// An import must land in the catalog as a normal recording: the same
/// reserve -> staging -> publish path a live capture uses, so it gets the
/// same ownership checks and the same durability. The source file is COPIED
/// and left untouched -- importing must never consume the user's original.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('audio-import-test');
  });

  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  /// Bytes are opaque to the import path, which copies rather than decodes.
  Future<File> sourceFile({
    String name = 'meeting.m4a',
    int bytes = 4096,
  }) async {
    final File f = File('${tmp.path}/$name');
    await f.writeAsBytes(List<int>.filled(bytes, 7), flush: true);
    return f;
  }

  AudioImporter importerFor(
    CatalogHarness h, {
    int duration = 93,
  }) =>
      AudioImporter(
        catalog: h.catalog,
        backend: h.backend,
        db: h.f.db,
        mutations: h.mutations,
        durationOf: (_) async => duration,
      );

  test('imported audio lands in the catalog as a real recording', () async {
    final h = CatalogHarness();
    addTearDown(h.close);
    await h.bootstrap();

    final File source = await sourceFile();

    final Outcome<String> result = await importerFor(h).import(
      sourcePath: source.path,
      mode: 'meeting',
    );

    expect(result, isA<Ok<String>>(), reason: 'import must succeed');
    final String dumpId = (result as Ok<String>).value;

    final query = h.f.db.select(h.f.db.dumps)
      ..where((t) => t.id.equals(dumpId));
    final row = await query.getSingle();
    expect(row.durationSeconds, 93, reason: 'duration comes from the audio');
    expect(
      row.audioSizeBytes,
      4096,
      reason: 'the whole file must be copied',
    );
    expect(row.mode, 'meeting');
  });

  test('the original file is left untouched', () async {
    final h = CatalogHarness();
    addTearDown(h.close);
    await h.bootstrap();

    final File source = await sourceFile(name: 'keep.m4a', bytes: 2048);

    final Outcome<String> result = await importerFor(h, duration: 10).import(
      sourcePath: source.path,
      mode: 'brain_dump',
    );

    expect(result, isA<Ok<String>>());
    expect(
      source.existsSync(),
      isTrue,
      reason: 'importing copies; it must never consume the original',
    );
    expect(await source.length(), 2048);
  });

  test('a missing source fails without leaving a completed row', () async {
    final h = CatalogHarness();
    addTearDown(h.close);
    await h.bootstrap();

    final Outcome<String> result = await importerFor(h).import(
      sourcePath: '${tmp.path}/does-not-exist.m4a',
      mode: 'brain_dump',
    );

    expect(result, isA<Fail<String>>(), reason: 'a missing file must fail');

    final rows = await h.f.db.select(h.f.db.dumps).get();
    expect(
      rows,
      isEmpty,
      reason: 'a failed import must not leave a recording behind',
    );
  });

  test('zero-length audio is rejected before it reaches the catalog',
      () async {
    final h = CatalogHarness();
    addTearDown(h.close);
    await h.bootstrap();

    final File empty = await sourceFile(name: 'empty.m4a', bytes: 0);

    final Outcome<String> result = await importerFor(h, duration: 0).import(
      sourcePath: empty.path,
      mode: 'brain_dump',
    );

    expect(
      result,
      isA<Fail<String>>(),
      reason: 'an empty file is not a recording',
    );
  });
}
