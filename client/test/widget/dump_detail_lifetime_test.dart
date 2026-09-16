// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/recording_metadata.dart';
import 'package:tangent/data/storage/local_deletion_service.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/data/storage/storage_providers.dart';
import 'package:tangent/screens/dump/dump_detail_screen.dart';
import 'package:tangent/screens/home/home_providers.dart';
import 'package:tangent/screens/home/home_screen.dart' show localDbProvider;
import 'package:tangent/services/recording_playback.dart';
import '../support/bound_service_fixture.dart';
import '../support/bound_widget_lifetime.dart';
import '../support/scripted_storage_backend.dart';
import '../support/storage_fixture.dart';

final class GatePlayer implements RecordingPlaybackEngine {
  final closing = Completer<void>(), release = Completer<void>();
  bool loaded = false;
  int closes = 0;
  @override
  Stream<Duration> get positionStream => const Stream.empty();
  @override
  Stream<Duration?> get durationStream => const Stream.empty();
  @override
  Stream<bool> get playingStream => const Stream.empty();
  @override
  Stream<bool> get completedStream => const Stream.empty();
  @override
  Future<Duration?> load(AudioLocator source) async {
    loaded = true;
    return const Duration(seconds: 3);
  }

  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> seek(Duration position) async {}
  @override
  Future<void> dispose() async {
    closes++;
    if (!closing.isCompleted) closing.complete();
    await release.future;
  }
}

final class GateEditDb extends LocalDb {
  GateEditDb() : super.forTesting(NativeDatabase.memory());
  final committed = Completer<void>(), release = Completer<void>();
  Future<DumpRow> hold(DumpRow row) async {
    committed.complete();
    await release.future;
    return row;
  }

  @override
  Future<DumpRow> updateDumpTitle(String id,
          {required RecordingKey storageKey,
          required String title,
          required DateTime now,}) async =>
      hold(await super
          .updateDumpTitle(id, storageKey: storageKey, title: title, now: now),);
  @override
  Future<DumpRow> updateDumpMeetingNotes(String id,
          {required RecordingKey storageKey,
          required String expectedTitle,
          required String expectedTranscript,
          required int expectedTranscriptionAttempt,
          required String? expectedTranscriptionRequestId,
          required String meetingNotes,
          required DateTime now,}) async =>
      hold(await super.updateDumpMeetingNotes(id,
          storageKey: storageKey,
          expectedTitle: expectedTitle,
          expectedTranscript: expectedTranscript,
          expectedTranscriptionAttempt: expectedTranscriptionAttempt,
          expectedTranscriptionRequestId: expectedTranscriptionRequestId,
          meetingNotes: meetingNotes,
          now: now,),);
}

Future<void> mount(
    WidgetTester tester,
    StorageFixture f,
    BoundServiceFixture bound,
    GatePlayer player,
    GlobalKey<NavigatorState> navigator,
    BoundRecording a,
    {StorageBackend? backend,}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        localDbProvider.overrideWithValue(f.db),
        recordingAccessProvider.overrideWithValue(bound.access),
        recordingMutationsProvider.overrideWithValue(bound.mutations),
        localDeletionServiceProvider.overrideWithValue(
            DefaultLocalDeletionService(
                db: f.db,
                backend: backend ?? f.backend,
                mutations: bound.mutations,),),
        recordingPlaybackEngineFactoryProvider.overrideWithValue(() => player),
      ],
      child: MaterialApp(
          navigatorKey: navigator, home: const Scaffold(body: Text('Library')),),
    ),
  );
  unawaited(navigator.currentState!.push<void>(MaterialPageRoute(
      builder: (_) => DumpDetailScreen(
          dumpId: a.key.dumpId,
          audioPath: a.audio.value,
          durationSeconds: 3,),),),);
  await pumpBoundUntil(tester, () => player.loaded);
  await tester.pumpAndSettle();
}

void main() {
  for (final scenario in [
    'cancel',
    'confirm',
    'other-player',
    'unmount-closing',
  ]) {
    testWidgets('detail deletion $scenario retains exact playback ownership',
        (tester) async {
      final f = StorageFixture.create();
      final backend = ScriptedStorageBackend();
      final bound = await createBoundServiceFixture(f.db,
          backend: backend, registerDrain: false,);
      final player = GatePlayer();
      final otherPlayer = GatePlayer()..release.complete();
      PlaybackLease? other;
      final navigator = GlobalKey<NavigatorState>();
      addTearDown(() async {
        if (!player.release.isCompleted) player.release.complete();
        await other?.close();
        await disposeBoundWidget(tester, bound);
        await tester.runAsync(f.close);
      });
      final a = (await tester.runAsync(() => f.seed('fixture-detail-delete')))!;
      await mount(tester, f, bound, player, navigator, a, backend: backend);
      if (scenario == 'other-player') {
        unawaited(bound.access
            .openPlayback(a.key, otherPlayer)
            .then((result) => other = requireOk(result)),);
        await pumpBoundUntil(tester, () => other != null);
      }
      await tester.tap(find.byTooltip('Delete'));
      await tester.pumpAndSettle();
      expect(backend.componentCalls, 0);
      expect(player.closes, 0);
      await tester
          .tap(find.text(scenario == 'cancel' ? 'Cancel' : 'Delete').last);
      await tester.pumpAndSettle();
      if (scenario == 'cancel') {
        expect(player.closes, 0);
        expect(backend.componentCalls, 0);
        expect(await f.db.getDump(a.key.dumpId), isNotNull);
        expect(await tester.runAsync(() => f.audio('A', a.key.dumpId).exists()),
            isTrue,);
        player.release.complete();
        await disposeBoundWidget(tester, bound);
        return;
      }
      await pumpBoundUntil(tester, () => player.closing.isCompleted);
      expect(backend.componentCalls, 0,
          reason: 'confirmation must await actual raw player close',);
      expect(await f.db.getDump(a.key.dumpId), isNotNull);
      if (scenario == 'unmount-closing') {
        navigator.currentState!.pop();
        await tester.pumpAndSettle();
      }
      player.release.complete();
      if (scenario == 'other-player') {
        await pumpBoundUntil(tester,
            () => find.textContaining('Delete failed:').evaluate().isNotEmpty,);
        expect(backend.componentCalls, 0);
        expect(await f.db.getDump(a.key.dumpId), isNotNull);
      } else {
        await pumpBoundUntil(
            tester, () async => await f.db.getDump(a.key.dumpId) == null,);
        expect(backend.componentCalls, 2);
        expect(await tester.runAsync(() => f.audio('A', a.key.dumpId).exists()),
            isFalse,);
        expect(
            await tester.runAsync(() => f.metadata('A', a.key.dumpId).exists()),
            isFalse,);
      }
      expect(player.closes, 1);
      expect(tester.takeException(), isNull);
      await other?.close();
      other = null;
      await disposeBoundWidget(tester, bound);
    });
  }

  for (final kind in ['title', 'notes']) {
    testWidgets('late $kind DB return publishes after route unmount',
        (tester) async {
      final f = StorageFixture.create();
      await f.db.close();
      final db = GateEditDb();
      f.db = db;
      final bound = await createBoundServiceFixture(db, registerDrain: false);
      final player = GatePlayer()..release.complete();
      final navigator = GlobalKey<NavigatorState>();
      addTearDown(() async {
        if (!db.release.isCompleted) db.release.complete();
        await disposeBoundWidget(tester, bound);
        await tester.runAsync(f.close);
      });
      final a = (await tester
          .runAsync(() => f.seed('fixture-late-edit', status: 'completed')))!;
      await db.customStatement(
          "UPDATE dumps SET mode='meeting' WHERE id=?", [a.key.dumpId],);
      await mount(tester, f, bound, player, navigator, a);
      if (kind == 'title') {
        final field = find.byKey(ValueKey('title-editor-${a.key.dumpId}'));
        await tester.enterText(field, 'Edited after detach');
        tester.widget<TextField>(field).onSubmitted!('Edited after detach');
      } else {
        final button = find.byKey(ValueKey('regenerate-notes-${a.key.dumpId}'));
        await tester.ensureVisible(button);
        await tester.tap(button);
      }
      await pumpBoundUntil(tester, () => db.committed.isCompleted);
      final expected = dumpMetadata((await db.getDump(a.key.dumpId))!);
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      db.release.complete();
      var drained = false;
      unawaited(bound.mutations.drain().then((_) => drained = true));
      await pumpBoundUntil(tester, () => drained);
      final metadata = jsonDecode((await tester
          .runAsync(() => f.metadata('A', a.key.dumpId).readAsString()))!,);
      expect(metadata['title'], expected['title']);
      expect(metadata['meetingNotes'], expected['meetingNotes']);
      expect(tester.takeException(), isNull);
      await disposeBoundWidget(tester, bound);
    });
  }
}
