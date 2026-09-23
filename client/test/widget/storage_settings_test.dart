// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/data/storage/storage_providers.dart';
import 'package:tangent/screens/settings/storage_settings_section.dart';
import 'package:tangent/screens/settings/settings_screen.dart';
import 'package:tangent/screens/server/server_connection_screen.dart';
import 'package:tangent/data/settings_store.dart';
import 'package:tangent/data/secure_storage.dart';
import 'package:tangent/services/transcription_client.dart';
import 'package:tangent/models/server_info.dart';

const oldLocation = (
  id: 'old',
  label: 'Original recordings',
  directory: (
    kind: 'file',
    path: r'C:\synthetic\old',
    treeUri: '',
    authority: '',
    documentId: ''
  )
);
DefaultFolderState folder(
        {bool canChoose = true,
        bool available = true,
        StorageLocation? location = oldLocation,
        int revision = 7,
        StorageProblem? problem,}) =>
    (
      location: location,
      revision: revision,
      available: available,
      canChooseDefault: canChoose,
      problem: problem
    );

class TestCatalog extends Fake implements StorageCatalog {
  TestCatalog(this.state);
  DefaultFolderState state;
  final changes = StreamController<DefaultFolderState>.broadcast();
  int picks = 0;
  final commits = <({FolderCandidate candidate, int revision})>[];
  Future<Outcome<FolderCandidate?>>? pickResult;
  Future<Outcome<DefaultFolderState>>? commitResult;
  Completer<Outcome<FolderCandidate?>>? pickGate;
  Completer<Outcome<DefaultFolderState>>? commitGate;
  @override
  Stream<DefaultFolderState> watchDefault() async* {
    yield state;
    yield* changes.stream;
  }

  void emit(DefaultFolderState value) {
    state = value;
    changes.add(value);
  }

  @override
  Future<Outcome<FolderCandidate?>> chooseFolderCandidate() async {
    picks++;
    return await (pickGate?.future ??
        pickResult ??
        Future.value(const Ok<FolderCandidate?>(null)));
  }

  @override
  Future<Outcome<DefaultFolderState>> commitDefault(FolderCandidate candidate,
      {required int expectedRevision,}) async {
    commits.add((candidate: candidate, revision: expectedRevision));
    return await (commitGate?.future ??
        commitResult ??
        Future.value(const Fail<DefaultFolderState>(
            (code: ProblemCode.invalid, message: 'Unexpected commit'),),));
  }

  Future<void> close() async {
    if (pickGate != null && !pickGate!.isCompleted) {
      pickGate!.complete(const Ok(null));
    }
    if (commitGate != null && !commitGate!.isCompleted) {
      commitGate!.complete(const Fail(
          (code: ProblemCode.interrupted, message: 'Synthetic cleanup'),),);
    }
    await changes.close();
  }
}

Future<void> pumpStorage(WidgetTester t) async {
  await t.pump();
  await t.pump(const Duration(milliseconds: 1));
}

Future<void> mountStorage(WidgetTester t, TestCatalog catalog) async {
  addTearDown(() async {
    await t.pumpWidget(const SizedBox.shrink());
    await t.pump();
    await catalog.close();
  });
  await t.pumpWidget(ProviderScope(overrides: [
    storageCatalogProvider.overrideWithValue(catalog),
    defaultFolderProvider.overrideWith((_) => catalog.watchDefault()),
  ], child: const MaterialApp(home: Scaffold(body: StorageSettingsSection())),),);
  await pumpStorage(t);
}

const syntheticInfo = ServerInfo(
    version: 'fixture',
    setupComplete: true,
    defaultModel: 'large-v3',
    availableModels: ['large-v3'],
    storageUsedBytes: 0,
    dumpCount: 2,);

class HeldClient extends Fake implements TranscriptionClient {
  final info = Completer<ServerInfo>();
  int calls = 0;
  @override
  Future<ServerInfo> getServerInfo() {
    calls++;
    return info.future;
  }
}

class SyntheticSecureStore extends Fake implements SecureStore {
  static const url = 'http://synthetic.invalid:8000';
  int writes = 0;
  Completer<String?>? urlGate;
  @override
  Future<String?> getServerUrl() => urlGate?.future ?? Future.value(url);
  @override
  Future<String?> getToken() async => 'synthetic-fixture-only';
  @override
  Future<void> setServerUrl(String url) async {
    writes++;
  }

  @override
  Future<void> setToken(String token) async {
    writes++;
  }

  @override
  Future<void> clear() async {
    writes++;
  }
}

class ObservedSettings extends SettingsStore {
  ObservedSettings()
      : super(
            triggerMode: TriggerMode.hold,
            wifiOnlySync: true,
            autoSync: false,
            keepScreenAwakeWhileRecording: false,);
  final saves = <String>[];
  @override
  Future<void> setTriggerMode(TriggerMode value) async {
    saves.add('trigger');
    await super.setTriggerMode(value);
  }

  @override
  Future<void> setWifiOnlySync(bool value) async {
    saves.add('wifi');
    await super.setWifiOnlySync(value);
  }

  @override
  Future<void> setKeepScreenAwakeWhileRecording(bool value) async {
    saves.add('awake');
    await super.setKeepScreenAwakeWhileRecording(value);
  }

  @override
  Future<void> setAutoSync(bool value) async {
    saves.add('auto');
    await super.setAutoSync(value);
  }
}

Future<void> mountHost(WidgetTester t, TestCatalog catalog, HeldClient client,
    ObservedSettings settings, SyntheticSecureStore secure,) async {
  // The real Settings screen is ~1400 logical pixels of ListView content, far
  // taller than the 800x600 default test surface. That matters for assertions,
  // not just for looks: a SliverList reports children outside its *paint*
  // extent as offstage (SliverMultiBoxAdaptorElement.debugVisitOnstageChildren
  // only visits the visible band, never the cache band), and every find.* here
  // skips offstage by default. Rows below the fold — Server, Transcription,
  // the trigger radios, the sync switches — are then built but invisible to
  // finders, and tap() derives centres below the bottom edge and misses.
  // Give the host a surface that shows the whole screen so these tests assert
  // against genuinely visible widgets instead of accidentally-in-viewport ones.
  t.view.physicalSize = const Size(800, 2000);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
  addTearDown(() async {
    if (secure.urlGate != null && !secure.urlGate!.isCompleted) {
      secure.urlGate!.complete(SyntheticSecureStore.url);
    }
    if (!client.info.isCompleted) client.info.complete(syntheticInfo);
    await pumpStorage(t);
    await t.pumpWidget(const SizedBox.shrink());
    await t.pump();
    await catalog.close();
  });
  await t.pumpWidget(ProviderScope(overrides: [
    storageCatalogProvider.overrideWithValue(catalog),
    defaultFolderProvider.overrideWith((_) => catalog.watchDefault()),
    settingsStoreProvider.overrideWithValue(settings),
    secureStoreProvider.overrideWithValue(secure),
    transcriptionClientProvider.overrideWith((_) => client),
  ], child: const MaterialApp(home: SettingsScreen()),),);
  await pumpStorage(t);
}

const newLocation = (
  id: 'new',
  label: 'Chosen recordings',
  directory: (
    kind: 'saf',
    path: '',
    treeUri: 'content://synthetic/tree/new',
    authority: 'synthetic',
    documentId: 'new'
  )
);
const chosenCandidate = (token: 'synthetic-candidate', location: newLocation);
void main() {
  for (final stage in ['secure-url', 'server-info']) {
    testWidgets(
        'host unmount during $stage retains independent local section without late follow-up',
        (t) async {
      final catalog = TestCatalog(folder());
      final client = HeldClient();
      final settings = ObservedSettings();
      final secure = SyntheticSecureStore();
      if (stage == 'secure-url') secure.urlGate = Completer<String?>();
      await mountHost(t, catalog, client, settings, secure);
      expect(find.text('Original recordings'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('change-default-folder')));
      await pumpStorage(t);
      expect(catalog.picks, 1);
      expect(settings.saves, isEmpty);
      if (stage == 'secure-url') {
        expect(
            t
                .widget<TextButton>(find.widgetWithText(TextButton, 'SAVE'))
                .onPressed,
            isNull,);
      }
      await t.pumpWidget(const SizedBox.shrink());
      await t.pump();
      if (stage == 'secure-url') {
        secure.urlGate!.complete(SyntheticSecureStore.url);
      } else {
        client.info.complete(syntheticInfo);
      }
      await pumpStorage(t);
      expect(client.calls, stage == 'secure-url' ? 0 : 1);
      expect(catalog.commits, isEmpty);
      expect(secure.writes, 0);
      expect(t.takeException(), isNull);
    });
  }
  testWidgets(
      'storage observation error stays local and disables folder admission',
      (t) async {
    final catalog = TestCatalog(folder());
    final client = HeldClient();
    final settings = ObservedSettings();
    final secure = SyntheticSecureStore();
    await mountHost(t, catalog, client, settings, secure);
    final oldCallback = t
        .widget<TextButton>(find.byKey(const ValueKey('change-default-folder')))
        .onPressed!;
    catalog.changes.addError(StateError('Synthetic storage observation error'));
    await pumpStorage(t);
    expect(find.text('Storage unavailable. Try reopening Settings.'),
        findsOneWidget,);
    expect(find.text('Settings'), findsOneWidget);
    oldCallback();
    await pumpStorage(t);
    expect(catalog.picks, 0);
    expect(t.takeException(), isNull);
  });
  testWidgets(
      'lost picker capability is read-only even for an old captured callback',
      (t) async {
    final catalog = TestCatalog(folder());
    await mountStorage(t, catalog);
    final callback = t
        .widget<TextButton>(find.byKey(const ValueKey('change-default-folder')))
        .onPressed!;
    catalog.emit(folder(canChoose: false, available: false));
    await pumpStorage(t);
    callback();
    await pumpStorage(t);
    expect(find.byKey(const ValueKey('change-default-folder')), findsNothing);
    expect(find.text('Read-only on this platform.'), findsOneWidget);
    expect(find.textContaining('Reconnect storage or restore access'),
        findsOneWidget,);
    expect(catalog.picks, 0);
    expect(catalog.commits, isEmpty);
  });
  for (final typed in [true, false]) {
    testWidgets('thrown picker error is contained; typed=$typed', (t) async {
      final catalog = TestCatalog(folder())
        ..pickGate = Completer<Outcome<FolderCandidate?>>();
      await mountStorage(t, catalog);
      await t.tap(find.byKey(const ValueKey('change-default-folder')));
      await pumpStorage(t);
      catalog.pickGate!.completeError(typed
          ? const StorageFault(
              (code: ProblemCode.denied, message: 'Synthetic denied'),)
          : StateError('Synthetic failure'),);
      await pumpStorage(t);
      expect(
          find.byKey(const ValueKey('storage-change-error')), findsOneWidget,);
      expect(find.text('Original recordings'), findsOneWidget);
      expect(catalog.commits, isEmpty);
      expect(
          t
              .widget<TextButton>(
                  find.byKey(const ValueKey('change-default-folder')),)
              .onPressed,
          isNotNull,);
      expect(t.takeException(), isNull);
    });
  }
  final errorText = {
    ProblemCode.denied:
        'Folder access denied. Choose a folder with read and write permission.',
    ProblemCode.staleRevision:
        'Default folder changed elsewhere. Choose the folder again.',
    ProblemCode.busy:
        'Recording or storage work is still active. Wait for it to finish, then try again.',
    ProblemCode.persistence: 'Could not save the default folder. Try again.',
    ProblemCode.unavailable:
        'Folder unavailable. Reconnect the storage or choose another folder.',
  };
  for (final entry in errorText.entries) {
    for (final stage in ['picker', 'commit']) {
      testWidgets(
          '$stage ${entry.key.name} retains old committed label with actionable error',
          (t) async {
        final problem = (code: entry.key, message: 'Synthetic failure');
        final catalog = TestCatalog(folder())
          ..pickResult = Future.value(stage == 'picker'
              ? Fail<FolderCandidate?>(problem)
              : const Ok<FolderCandidate?>(chosenCandidate),)
          ..commitResult = Future.value(Fail<DefaultFolderState>(problem));
        await mountStorage(t, catalog);
        await t.tap(find.byKey(const ValueKey('change-default-folder')));
        await pumpStorage(t);
        expect(find.text(entry.value), findsOneWidget);
        expect(find.text('Original recordings'), findsOneWidget);
        expect(find.text('Chosen recordings'), findsNothing);
        expect(catalog.commits, hasLength(stage == 'picker' ? 0 : 1));
        if (stage == 'commit') {
          expect(catalog.commits.single,
              (candidate: chosenCandidate, revision: 7),);
        }
        expect(
            t
                .widget<TextButton>(
                    find.byKey(const ValueKey('change-default-folder')),)
                .onPressed,
            isNotNull,);
        expect(t.takeException(), isNull);
      });
    }
  }
  for (final stage in ['picker', 'commit']) {
    testWidgets('unmount during $stage prevents UI-owned follow-up', (t) async {
      final catalog = TestCatalog(folder())
        ..pickGate = Completer<Outcome<FolderCandidate?>>()
        ..commitGate = Completer<Outcome<DefaultFolderState>>();
      await mountStorage(t, catalog);
      final callback = t
          .widget<TextButton>(
              find.byKey(const ValueKey('change-default-folder')),)
          .onPressed!;
      callback();
      await pumpStorage(t);
      if (stage == 'commit') {
        catalog.pickGate!.complete(const Ok(chosenCandidate));
        await pumpStorage(t);
      }
      await t.pumpWidget(const SizedBox.shrink());
      await t.pump();
      callback();
      if (stage == 'picker') {
        catalog.pickGate!.complete(const Ok(chosenCandidate));
      } else {
        catalog.commitGate!.complete(const Fail((
          code: ProblemCode.persistence,
          message: 'Synthetic late failure'
        ),),);
      }
      await pumpStorage(t);
      expect(catalog.picks, 1);
      expect(catalog.commits, hasLength(stage == 'picker' ? 0 : 1));
      expect(t.takeException(), isNull);
    });
  }
  testWidgets(
      'successful folder change does not save or overwrite edited server/local settings',
      (t) async {
    final catalog = TestCatalog(folder())
      ..pickResult = Future.value(const Ok(chosenCandidate))
      ..commitResult =
          Future.value(Ok(folder(location: newLocation, revision: 8)));
    final client = HeldClient();
    final settings = ObservedSettings();
    final secure = SyntheticSecureStore();
    await mountHost(t, catalog, client, settings, secure);
    await t.tap(find.byKey(const ValueKey('change-default-folder')));
    await pumpStorage(t);
    expect(catalog.commits.single, (candidate: chosenCandidate, revision: 7));
    catalog.emit(folder(location: newLocation, revision: 8));
    await pumpStorage(t);
    expect(find.text('Chosen recordings'), findsOneWidget);
    expect(settings.saves, isEmpty);
    expect(secure.writes, 0);
    await t.tap(find.text('Tap to toggle'));
    await pumpStorage(t);
    await t.tap(find.text('Upload recordings only on Wi-Fi'));
    await pumpStorage(t);
    // The bulk-import section (2026-09-23) sits above this switch; the
    // taller page pushes it below the lazy ListView's build window, so it
    // must be scrolled INTO EXISTENCE, not merely into view.
    await t.scrollUntilVisible(
      find.text('Keep screen awake while recording'),
      80,
      scrollable: find.byType(Scrollable).first,
    );
    await t.tap(find.text('Keep screen awake while recording'));
    await pumpStorage(t);
    // Completing server info must not reset edits made while that read was held.
    client.info.complete(syntheticInfo);
    await pumpStorage(t);
    await t.tap(find.text('SAVE'));
    await pumpStorage(t);
    expect(settings.saves, ['trigger', 'wifi', 'awake']);
    expect(settings.triggerMode, TriggerMode.tap);
    expect(settings.wifiOnlySync, isFalse);
    expect(settings.keepScreenAwakeWhileRecording, isTrue);
    expect(settings.autoSync, isFalse);
    expect(secure.writes, 0);
    expect(client.calls, 1);
    expect(t.takeException(), isNull);
  });
  testWidgets(
      'missing default and server failure do not hide Settings or folder action',
      (t) async {
    final catalog = TestCatalog(folder(
        location: null,
        available: false,
        problem: (
          code: ProblemCode.denied,
          message: 'Synthetic revoked grant'
        ),),);
    final client = HeldClient();
    final settings = ObservedSettings();
    final secure = SyntheticSecureStore();
    await mountHost(t, catalog, client, settings, secure);
    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('No default folder'), findsOneWidget);
    expect(find.textContaining('Default folder unavailable'), findsOneWidget);
    client.info.completeError(StateError('Synthetic offline'));
    await pumpStorage(t);
    expect(find.textContaining('Server unreachable:'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('change-default-folder')));
    await pumpStorage(t);
    expect(catalog.picks, 1);
    expect(catalog.commits, isEmpty);
    expect(settings.saves, isEmpty);
    expect(secure.writes, 0);
    expect(t.takeException(), isNull);
  });
  testWidgets(
      'narrow large-text storage wraps long human label without raw editable URI',
      (t) async {
    t.view.physicalSize = const Size(280, 640);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final catalog = TestCatalog(folder(location: (
      id: 'long',
      directory: oldLocation.directory,
      label: 'A long human-readable recordings folder name on removable storage'
    ),),);
    addTearDown(() async {
      await t.pumpWidget(const SizedBox.shrink());
      await t.pump();
      await catalog.close();
    });
    await t.pumpWidget(ProviderScope(
        overrides: [
          storageCatalogProvider.overrideWithValue(catalog),
          defaultFolderProvider.overrideWith((_) => catalog.watchDefault()),
        ],
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(2)),
              child: child!,),
          home: const Scaffold(
              body: SingleChildScrollView(child: StorageSettingsSection()),),
        ),),);
    await pumpStorage(t);
    expect(find.text(catalog.state.location!.label), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    await t.ensureVisible(find.byKey(const ValueKey('change-default-folder')));
    await t.tap(find.byKey(const ValueKey('change-default-folder')));
    await pumpStorage(t);
    expect(catalog.picks, 1);
    expect(t.takeException(), isNull);
  });
  testWidgets(
      'candidate flow locks duplicate admission captures CAS revision and waits for committed stream',
      (t) async {
    final catalog = TestCatalog(folder())
      ..pickGate = Completer<Outcome<FolderCandidate?>>()
      ..commitGate = Completer<Outcome<DefaultFolderState>>();
    await mountStorage(t, catalog);
    final change = find.byKey(const ValueKey('change-default-folder'));
    final callback = t.widget<TextButton>(change).onPressed!;
    callback();
    callback();
    await pumpStorage(t);
    expect(catalog.picks, 1);
    expect(catalog.commits, isEmpty);
    expect(t.widget<TextButton>(change).onPressed, isNull);
    catalog.emit(folder(revision: 8));
    await pumpStorage(t);
    catalog.pickGate!.complete(const Ok(chosenCandidate));
    await pumpStorage(t);
    expect(catalog.commits, [(candidate: chosenCandidate, revision: 7)]);
    callback();
    await pumpStorage(t);
    expect(catalog.picks, 1);
    expect(find.text('Original recordings'), findsOneWidget);
    expect(find.text('Chosen recordings'), findsNothing);
    expect(t.widget<TextButton>(change).onPressed, isNull);
    catalog.commitGate!
        .complete(Ok(folder(location: newLocation, revision: 9)));
    await pumpStorage(t);
    expect(find.text('Original recordings'), findsOneWidget,
        reason: 'commit return is not the committed provider emission',);
    expect(find.text('Chosen recordings'), findsNothing);
    catalog.emit(folder(location: newLocation, revision: 9));
    await pumpStorage(t);
    expect(find.text('Chosen recordings'), findsOneWidget);
    expect(find.text('Original recordings'), findsNothing);
    expect(find.text(newLocation.directory.treeUri), findsNothing);
    expect(t.widget<TextButton>(change).onPressed, isNotNull);
    expect(t.takeException(), isNull);
  });
  for (final available in [true, false]) {
    testWidgets(
        'real Settings host storage usable while server pending; available=$available',
        (t) async {
      final catalog = TestCatalog(folder(available: available));
      final client = HeldClient();
      final settings = ObservedSettings();
      final secure = SyntheticSecureStore();
      await mountHost(t, catalog, client, settings, secure);
      expect(client.calls, 1);
      expect(client.info.isCompleted, isFalse);
      expect(find.text('Original recordings'), findsOneWidget,
          reason:
              'local Storage must not wait behind the whole-screen server-info spinner',);
      if (!available) {
        expect(
            find.textContaining('Default folder unavailable'), findsOneWidget,);
      }
      await t.tap(find.byKey(const ValueKey('change-default-folder')));
      await pumpStorage(t);
      expect(catalog.picks, 1);
      expect(catalog.commits, isEmpty);
      expect(client.info.isCompleted, isFalse);
      expect(settings.saves, isEmpty);
      expect(secure.writes, 0);
      expect(settings.triggerMode, TriggerMode.hold);
      expect(settings.wifiOnlySync, isTrue);
      expect(settings.keepScreenAwakeWhileRecording, isFalse);
      expect(settings.autoSync, isFalse);
      await t.tap(find.text('SAVE'));
      await pumpStorage(t);
      expect(settings.saves, ['trigger', 'wifi', 'awake']);
      expect(settings.triggerMode, TriggerMode.hold);
      expect(settings.wifiOnlySync, isTrue);
      expect(settings.keepScreenAwakeWhileRecording, isFalse);
      expect(secure.writes, 0);
      client.info.complete(syntheticInfo);
      await pumpStorage(t);
      expect(find.text(SyntheticSecureStore.url), findsOneWidget);
      expect(find.textContaining('default model: large-v3'), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  }
  for (final canChoose in [true, false]) {
    testWidgets('committed label survives Cancel; picker capability=$canChoose',
        (t) async {
      final catalog = TestCatalog(folder(canChoose: canChoose));
      await mountStorage(t, catalog);
      expect(find.text('Original recordings'), findsOneWidget);
      if (canChoose) {
        await t.tap(find.byKey(const ValueKey('change-default-folder')));
        await pumpStorage(t);
        expect(catalog.picks, 1);
        expect(catalog.commits, isEmpty);
        expect(find.text('Original recordings'), findsOneWidget);
      } else {
        expect(
            find.byKey(const ValueKey('change-default-folder')), findsNothing,);
        expect(catalog.picks, 0);
      }
      await t.pumpWidget(const SizedBox.shrink());
      await t.pump();
    });
  }
}
