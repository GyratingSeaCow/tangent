// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/data/storage/storage_providers.dart';
import 'package:tangent/screens/dump/dump_detail_screen.dart';
import 'package:tangent/screens/home/home_providers.dart';
import 'package:tangent/screens/home/home_screen.dart' show localDbProvider;
import 'package:tangent/screens/note/note_compose_screen.dart';
import 'package:tangent/services/note_persistence.dart';
import 'package:tangent/services/recording_playback.dart';
import '../support/bound_widget_lifetime.dart';
import '../support/scripted_storage_backend.dart';

/// Task 7: NoteComposeScreen — explicit Save gated on non-blank text, a
/// discard confirmation on back with typed text, pushReplacement to the
/// detail screen on save, and SnackBar + text preservation on failure.

final class _StubEngine implements RecordingPlaybackEngine {
  @override
  Stream<Duration> get positionStream => const Stream.empty();
  @override
  Stream<Duration?> get durationStream => const Stream.empty();
  @override
  Stream<bool> get playingStream => const Stream.empty();
  @override
  Stream<bool> get completedStream => const Stream.empty();
  @override
  Future<Duration?> load(AudioLocator source) async => Duration.zero;
  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> seek(Duration position) async {}
  @override
  Future<void> dispose() async {}
}

/// Delegates to the REAL pipeline while recording the exact text handed to
/// saveNote and the committed row (for navigation assertions).
final class _SpyNotes extends NotePersistence {
  _SpyNotes(CatalogHarness h)
      : super(
          db: h.f.db,
          backend: h.backend,
          mutations: h.mutations,
          catalog: h.catalog,
        );
  final texts = <String>[];
  DumpRow? lastRow;

  @override
  Future<DumpRow> saveNote({
    required String text,
    required DateTime now,
  }) async {
    texts.add(text);
    return lastRow = await super.saveNote(text: text, now: now);
  }
}

/// Fault injection: every save dies with a storage problem.
final class _FaultingNotes extends NotePersistence {
  _FaultingNotes(CatalogHarness h)
      : super(
          db: h.f.db,
          backend: h.backend,
          mutations: h.mutations,
          catalog: h.catalog,
        );
  int calls = 0;

  @override
  Future<DumpRow> saveNote({
    required String text,
    required DateTime now,
  }) async {
    calls++;
    throw const StorageFault(
      (code: ProblemCode.io, message: 'fixture note save died'),
    );
  }
}

void main() {
  setUp(() => EditableText.debugDeterministicCursor = true);
  tearDown(() => EditableText.debugDeterministicCursor = false);

  void useHandsetViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  /// Harness whose teardown survives mid-test failures: unmount the tree,
  /// drain the coordinator, then close the fixture (real I/O under runAsync).
  CatalogHarness harnessFor(WidgetTester tester) {
    final h = CatalogHarness();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      var drained = false;
      await tester.runAsync(() async {
        unawaited(h.mutations.drain().then((_) => drained = true));
      });
      await pumpBoundUntil(tester, () => drained);
      // The coordinator is already drained above; a second drain() from
      // inside runAsync deadlocks. Close the fixture pieces directly.
      await tester.runAsync(() async {
        await h.backend.drain();
        await h.f.backend.drain();
        await h.f.db.close();
        await h.f.root.delete(recursive: true);
      });
    });
    return h;
  }

  /// Real catalog bootstrap: OS futures settle under runAsync while the
  /// fake zone keeps pumping (bound-lifetime pattern).
  Future<void> bootstrapPumped(WidgetTester tester, CatalogHarness h) async {
    Object? bootError;
    var booted = false;
    await tester.runAsync(() async {
      unawaited(
        h.bootstrap().then(
          (_) => booted = true,
          onError: (Object e) {
            bootError = e;
            booted = true;
          },
        ),
      );
    });
    await pumpBoundUntil(tester, () => booted);
    if (bootError != null) throw bootError!;
  }

  Future<void> mountCompose(
    WidgetTester tester,
    CatalogHarness h,
    NotePersistence notes,
    GlobalKey<NavigatorState> navigator,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localDbProvider.overrideWithValue(h.f.db),
          storageBackendProvider.overrideWithValue(h.backend),
          recordingMutationsProvider.overrideWithValue(h.mutations),
          storageCatalogProvider.overrideWithValue(h.catalog),
          captureReadyProvider.overrideWith((ref) async {}),
          catalogSyncProvider.overrideWith((ref) async {}),
          notePersistenceProvider.overrideWithValue(notes),
          recordingPlaybackEngineFactoryProvider
              .overrideWithValue(_StubEngine.new),
        ],
        child: MaterialApp(
          navigatorKey: navigator,
          home: const Scaffold(body: Text('Host')),
        ),
      ),
    );
    unawaited(
      navigator.currentState!.push<void>(
        MaterialPageRoute<void>(builder: (_) => const NoteComposeScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  TextButton saveButton(WidgetTester tester) =>
      tester.widget<TextButton>(find.widgetWithText(TextButton, 'Save'));

  testWidgets('Save stays disabled while the note is blank or whitespace',
      (tester) async {
    useHandsetViewport(tester);
    final h = harnessFor(tester);
    final navigator = GlobalKey<NavigatorState>();
    await mountCompose(tester, h, _SpyNotes(h), navigator);

    expect(find.text('Text Note'), findsOneWidget);
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.maxLines, isNull);
    expect(field.autofocus, isTrue);
    expect(saveButton(tester).onPressed, isNull);

    await tester.enterText(find.byType(TextField), '   \n\t ');
    await tester.pump();
    expect(
      saveButton(tester).onPressed,
      isNull,
      reason: 'whitespace-only text must not enable Save',
    );

    await tester.enterText(find.byType(TextField), 'now it has words');
    await tester.pump();
    expect(saveButton(tester).onPressed, isNotNull);
  });

  testWidgets(
      'Save hands the exact text to saveNote and pushReplacement lands the '
      'detail screen', (tester) async {
    useHandsetViewport(tester);
    final h = harnessFor(tester);
    await bootstrapPumped(tester, h);
    final spy = _SpyNotes(h);
    final navigator = GlobalKey<NavigatorState>();
    await mountCompose(tester, h, spy, navigator);

    const text = 'note body typed by test';
    await tester.enterText(find.byType(TextField), text);
    await tester.pump();
    await tester.tap(find.widgetWithText(TextButton, 'Save'));
    // pushReplacement keeps the outgoing compose route in the tree until the
    // transition animation completes — wait for the swap to fully finish.
    await pumpBoundUntil(
      tester,
      () =>
          find.byType(DumpDetailScreen).evaluate().isNotEmpty &&
          find.byType(NoteComposeScreen).evaluate().isEmpty,
    );

    expect(spy.texts, [text], reason: 'saveNote must receive the exact text');
    final row = spy.lastRow!;
    final detail = tester.widget<DumpDetailScreen>(
      find.byType(DumpDetailScreen),
    );
    expect(detail.dumpId, row.id);
    expect(detail.audioPath, row.audioPath);
    expect(detail.durationSeconds, 0);
    expect(
      find.byType(NoteComposeScreen),
      findsNothing,
      reason: 'pushReplacement must remove the compose route',
    );
    // Unmount the detail screen so its Drift stream subscriptions close
    // before the framework's pending-timer teardown check (same pattern as
    // dump_detail_local_transcription_test.dart).
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets(
      'back with typed text confirms discard: Keep editing retains, Discard '
      'pops without saving', (tester) async {
    useHandsetViewport(tester);
    final h = harnessFor(tester);
    final spy = _SpyNotes(h);
    final navigator = GlobalKey<NavigatorState>();
    await mountCompose(tester, h, spy, navigator);

    const text = 'draft worth confirming';
    await tester.enterText(find.byType(TextField), text);
    await tester.pump();

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Discard note?'), findsOneWidget);
    expect(find.text('Keep editing'), findsOneWidget);
    expect(find.text('Discard'), findsOneWidget);

    await tester.tap(find.text('Keep editing'));
    await tester.pumpAndSettle();
    expect(find.text('Discard note?'), findsNothing);
    expect(find.byType(NoteComposeScreen), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      text,
      reason: 'Keep editing must retain the typed text',
    );

    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Discard'));
    await tester.pumpAndSettle();
    expect(find.byType(NoteComposeScreen), findsNothing);
    expect(find.text('Host'), findsOneWidget);
    expect(spy.texts, isEmpty, reason: 'Discard must never save');
  });

  testWidgets('save failure shows the exact SnackBar and preserves the text',
      (tester) async {
    useHandsetViewport(tester);
    final h = harnessFor(tester);
    final faulting = _FaultingNotes(h);
    final navigator = GlobalKey<NavigatorState>();
    await mountCompose(tester, h, faulting, navigator);

    const text = 'text that must survive the failure';
    await tester.enterText(find.byType(TextField), text);
    await tester.pump();
    await tester.tap(find.widgetWithText(TextButton, 'Save'));
    await tester.pumpAndSettle();

    expect(faulting.calls, 1);
    expect(
      find.text('Note save failed: fixture note save died'),
      findsOneWidget,
    );
    expect(find.byType(NoteComposeScreen), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      text,
      reason: 'a failed save must preserve the typed text',
    );
  });
}
