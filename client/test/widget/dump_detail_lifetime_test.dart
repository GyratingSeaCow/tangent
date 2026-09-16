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
  int plays = 0;
  Completer<void>? loadGate;
  bool loadEntered = false;
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
    loadEntered = true;
    await loadGate?.future;
    loaded = true;
    return const Duration(seconds: 3);
  }

  @override
  Future<void> play() async { plays++; }
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
    {StorageBackend? backend, RecordingPlaybackEngine Function()? factory,}) async {
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
        recordingPlaybackEngineFactoryProvider.overrideWithValue(factory ?? () => player),
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
  for (final unmount in [false,true]) {
    testWidgets('B1-M1 same route fresh playback retry; unmount=$unmount', (tester) async {
      final f=StorageFixture.create();final backend=ScriptedStorageBackend();
      final bound=await createBoundServiceFixture(f.db,backend:backend,registerDrain:false);
      final first=GatePlayer()..release.complete();
      final fresh=GatePlayer()..release.complete()..loadGate=Completer<void>();
      final otherPlayer=GatePlayer()..release.complete();PlaybackLease? other;
      final navigator=GlobalKey<NavigatorState>();var creates=0;
      addTearDown(() async {
        if(!fresh.loadGate!.isCompleted)fresh.loadGate!.complete();
        if(other!=null){var closed=false;unawaited(other!.close().then((_)=>closed=true));await pumpBoundUntil(tester,()=>closed);other=null;}
        await disposeBoundWidget(tester,bound);await tester.runAsync(f.close);
      });
      final a=(await tester.runAsync(()=>f.seed('fixture-retry-playback')))!;
      final originalRow=(await f.db.getDump(a.key.dumpId))!.toJson();
      final originalMeta=await tester.runAsync(()=>f.metadata('A',a.key.dumpId).readAsString());
      await mount(tester,f,bound,first,navigator,a,backend:backend,factory:()=>creates++==0 ? first : fresh);
      final routeState=tester.state(find.byType(DumpDetailScreen));
      unawaited(bound.access.openPlayback(a.key,otherPlayer).then((r)=>other=requireOk(r)));
      await pumpBoundUntil(tester,()=>other!=null);
      await tester.tap(find.byTooltip('Delete'));await tester.pumpAndSettle();
      await tester.tap(find.text('Delete').last);await tester.pumpAndSettle();
      await pumpBoundUntil(tester,()=>find.textContaining('Delete failed:').evaluate().isNotEmpty);
      expect(backend.componentCalls,0);expect(first.closes,1);
      expect((await f.db.getDump(a.key.dumpId))!.toJson(),originalRow);
      expect(await tester.runAsync(()=>f.audio('A',a.key.dumpId).readAsBytes()),[1,2,3]);
      expect(await tester.runAsync(()=>f.metadata('A',a.key.dumpId).readAsString()),originalMeta);
      expect(find.text('Retry playback'),findsOneWidget);
      await other!.close();other=null;
      final retry=tester.widget<TextButton>(find.byKey(const ValueKey('retry-playback'))).onPressed!;
      retry();retry();await pumpBoundUntil(tester,()=>fresh.loadEntered);
      expect(creates,2);expect(first.plays,0);
      if(unmount){navigator.currentState!.pop();await tester.pump();}
      fresh.loadGate!.complete();await pumpBoundUntil(tester,()=>fresh.loaded);
      if(!unmount){
        expect(identical(tester.state(find.byType(DumpDetailScreen)),routeState),isTrue);
        await tester.tap(find.byTooltip('Play recording'));await tester.pump();expect(fresh.plays,1);expect(first.plays,0);
      }
      await disposeBoundWidget(tester,bound);expect(fresh.closes,1);expect(tester.takeException(),isNull);
    });
  }
  testWidgets('B1-M1 partial deletion shows retry-only guidance, never reopens playback',(tester) async {
    final f=StorageFixture.create();final backend=ScriptedStorageBackend()..metadataDeleteFails=true;
    final bound=await createBoundServiceFixture(f.db,backend:backend,registerDrain:false);
    final first=GatePlayer()..release.complete();var creates=0;
    addTearDown(() async {await disposeBoundWidget(tester,bound);await tester.runAsync(f.close);});
    final a=(await tester.runAsync(()=>f.seed('fixture-partial-playback')))!;
    await mount(tester,f,bound,first,GlobalKey<NavigatorState>(),a,backend:backend,factory:(){creates++;return first;});
    await tester.tap(find.byTooltip('Delete'));await tester.pumpAndSettle();await tester.tap(find.text('Delete').last);await tester.pumpAndSettle();
    await pumpBoundUntil(tester,()=>find.textContaining('Delete failed:').evaluate().isNotEmpty);
    expect(find.textContaining('Playback unavailable while local deletion is pending'),findsOneWidget);
    expect(find.text('Retry playback'),findsNothing);expect(find.byKey(const ValueKey('local-delete-retry')),findsOneWidget);
    expect(creates,1);expect(await f.db.getDump(a.key.dumpId),isNotNull);
    await disposeBoundWidget(tester,bound);
  });

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
      expect(tester.widget<IconButton>(find.byWidgetPredicate((w)=>w is IconButton && w.tooltip=='Play recording')).onPressed,isNull,
          reason:'the old disposed controller must not remain an enabled UI callback',);
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
