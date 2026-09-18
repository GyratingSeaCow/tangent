// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/audio_storage.dart';
import 'package:tangent/data/storage/storage_providers.dart';
import 'package:tangent/screens/home/home_screen.dart' show localDbProvider;
import '../../support/scripted_storage_backend.dart';

/// Legacy restore is a ONE-SHOT migration: it adopts whatever pre-existing
/// files a newly authorized folder already holds. Nothing ever cleared
/// `legacy_restore`, so the sweep re-enumerated the user's folder on EVERY
/// launch forever. On device that meant re-previewing a 65-file SAF directory
/// and re-adopting 39 recordings at every cold start.
class _FixtureAudioStorage implements AudioStorage {
  _FixtureAudioStorage(this.stagingDir, this.audioDirPath);
  @override
  final Directory stagingDir;
  @override
  final String audioDirPath;
}

/// A launch: fresh providers over the harness's current database handle.
ProviderContainer launch(CatalogHarness h) => ProviderContainer(
      overrides: [
        localDbProvider.overrideWithValue(h.f.db),
        storageBackendProvider.overrideWithValue(h.backend),
        recordingMutationsProvider.overrideWithValue(h.mutations),
        storageAudioStorageProvider.overrideWithValue(
          _FixtureAudioStorage(
            Directory(h.f.directory('stage')),
            h.f.directory('A'),
          ),
        ),
        storageCatalogProvider.overrideWithValue(h.catalog),
      ],
    );

Future<List<bool>> legacyFlags(CatalogHarness h) async =>
    (await h.f.db.select(h.f.db.storageLocations).get())
        .map((l) => l.legacyRestore)
        .toList();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a fully adopted legacy folder is swept once, not on every launch',
      () async {
    final h = CatalogHarness();
    addTearDown(h.close);
    for (var i = 0; i < 3; i++) {
      await h.f.audio('A', 'fixture-once-$i').writeAsBytes([1, 2, 3]);
    }

    final first = launch(h);
    await first.read(storageBootstrapProvider.future);
    first.dispose();

    for (var i = 0; i < 3; i++) {
      expect(
        await h.f.db.getDump('fixture-once-$i'),
        isNotNull,
        reason: 'The first sweep must still adopt every pre-existing file.',
      );
    }
    expect(
      await legacyFlags(h),
      everyElement(isFalse),
      reason: 'A sweep that adopted everything has nothing left to restore.',
    );

    await h.reopen();
    h.backend.listed.clear();
    final second = launch(h);
    addTearDown(second.dispose);
    await second.read(storageBootstrapProvider.future);

    expect(
      h.backend.listed,
      isEmpty,
      reason: 'The second launch must not re-enumerate the folder: '
          '${h.backend.listed.length} enumerations happened.',
    );
  });

  test('an empty legacy folder is still swept only once', () async {
    // Nothing to adopt is a COMPLETED sweep, not a failed one: leaving the
    // flag set here would re-scan an empty folder on every launch forever.
    final h = CatalogHarness();
    addTearDown(h.close);

    final first = launch(h);
    await first.read(storageBootstrapProvider.future);
    first.dispose();

    expect(await legacyFlags(h), everyElement(isFalse));

    await h.reopen();
    h.backend.listed.clear();
    final second = launch(h);
    addTearDown(second.dispose);
    await second.read(storageBootstrapProvider.future);

    expect(h.backend.listed, isEmpty);
  });

  test('a sweep that could not adopt everything stays armed for a retry',
      () async {
    // Partial success must NOT spend the one-shot authorization: if a file
    // failed to adopt this launch, the next launch has to try again or it is
    // stranded in the user's folder with no row, invisible in the app.
    final h = CatalogHarness();
    addTearDown(h.close);
    await h.f.audio('A', 'fixture-retry-ok').writeAsBytes([1, 2, 3]);
    await h.f.audio('A', 'fixture-retry-blocked').writeAsBytes([4, 5, 6]);

    // Block one entry by making its adoption fail: a live capture reservation
    // on that id makes adoptConfirmed report a collision rather than adopted.
    await h.f.db.customStatement(
      'CREATE TRIGGER legacy_retry_block BEFORE INSERT ON dumps '
      "WHEN NEW.id='fixture-retry-blocked' "
      "BEGIN SELECT RAISE(ABORT, 'synthetic adoption failure'); END",
    );

    final first = launch(h);
    await first.read(storageBootstrapProvider.future);
    first.dispose();

    expect(
      await h.f.db.getDump('fixture-retry-ok'),
      isNotNull,
      reason: 'The entries that could be adopted still are.',
    );
    expect(
      await legacyFlags(h),
      contains(isTrue),
      reason: 'An incomplete sweep must stay armed so the blocked file gets '
          'another chance instead of being stranded.',
    );

    // With the blocker removed the retry completes and spends the flag.
    await h.f.db.customStatement('DROP TRIGGER legacy_retry_block');
    await h.reopen();
    final second = launch(h);
    addTearDown(second.dispose);
    await second.read(storageBootstrapProvider.future);

    expect(await h.f.db.getDump('fixture-retry-blocked'), isNotNull);
    expect(await legacyFlags(h), everyElement(isFalse));
  });
}
