// SPDX-License-Identifier: AGPL-3.0-or-later
/// Instrument Console v2: Settings is nine category drills instead of one
/// endless list. Every existing section/control survives, just one level
/// down — the category pages render the SAME section widgets.
library;

import 'package:flutter/material.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/secure_storage.dart';
import 'package:tangent/data/settings_store.dart';
import 'package:tangent/models/pair_pending.dart';
import 'package:tangent/screens/server/server_connection_screen.dart'
    show secureStoreProvider, transcriptionClientProvider;
import 'package:tangent/screens/home/home_screen.dart' show localDbProvider;
import 'package:tangent/screens/settings/settings_screen.dart';
import 'package:tangent/screens/settings/trash_screen.dart';
import 'package:tangent/services/transcription_client.dart';
import 'package:tangent/widgets/top_nav_rail.dart';

import '../support/settings_categories.dart';

class _FakeSecureStore implements SecureStore {
  @override
  Future<String?> getDeviceId() async => null;
  @override
  Future<void> setDeviceId(String id) async {}
  @override
  Future<String?> getServerUrl() async => null;
  @override
  Future<String?> getToken() async => null;
  @override
  Future<void> setServerUrl(String url) async {}
  @override
  Future<void> setToken(String token) async {}
  @override
  Future<void> clear() async {}
}

class _FakeClient extends TranscriptionClient {
  _FakeClient() : super(baseUrl: 'http://unused.invalid');

  @override
  Future<List<PairPendingEntry>> pairPending() async => <PairPendingEntry>[];
}

Future<void> _mount(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1080, 2340);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final LocalDb db = LocalDb.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        settingsStoreProvider.overrideWithValue(SettingsStore()),
        secureStoreProvider.overrideWithValue(_FakeSecureStore()),
        transcriptionClientProvider.overrideWith((ref) => _FakeClient()),
        localDbProvider.overrideWithValue(db),
      ],
      child: const MaterialApp(home: SettingsScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the overview lists all ten categories in fixed order', (
    tester,
  ) async {
    await _mount(tester);

    final List<String> titles = SettingsCategory.values
        .map((SettingsCategory c) => c.title)
        .toList();
    expect(titles, <String>[
      'Storage',
      'Import & export',
      'Recording input',
      'Server & devices',
      'Transcription',
      'Intelligence',
      'Integrations',
      'Reminders',
      'Maintenance & about',
      'Support the Dev',
    ]);
    for (final SettingsCategory c in SettingsCategory.values) {
      expect(
        find.byKey(SettingsScreen.categoryKey(c)),
        findsOneWidget,
        reason: '${c.title} row is on the overview',
      );
    }
    // The overview is a jump page: the rail is lit on Settings and no
    // section control is rendered at this level.
    expect(find.byType(TopNavRail), findsOneWidget);
    expect(find.text('Keep recordings on this device'), findsNothing);
  });

  testWidgets('a category drill renders exactly its slice of the controls', (
    tester,
  ) async {
    await _mount(tester);

    await openSettingsCategory(tester, SettingsCategory.storage);

    // Storage owns the storage policy switches that used to sit at the
    // bottom of the flat list — same widgets, same labels.
    expect(find.text('Keep recordings on this device'), findsOneWidget);
    expect(find.text('Upload recordings only on Wi-Fi'), findsOneWidget);
    // …and NOT the Recording-input controls.
    expect(find.text('Keep screen awake while recording'), findsNothing);
    expect(find.text('Tap to toggle'), findsNothing);
    // SAVE is still on every page: the state owner is the screen itself.
    expect(find.text('SAVE'), findsOneWidget);

    // Back arrow returns to the overview IN PLACE: same State, so an edit
    // made in Storage would survive this trip.
    await closeSettingsCategory(tester);
    expect(
      find.byKey(SettingsScreen.categoryKey(SettingsCategory.recording)),
      findsOneWidget,
    );

    await openSettingsCategory(tester, SettingsCategory.recording);
    expect(find.text('Keep screen awake while recording'), findsOneWidget);
    expect(find.text('Tap to toggle'), findsOneWidget);
    expect(find.text('Hold to record'), findsOneWidget);
    expect(find.text('Keep recordings on this device'), findsNothing);
  });

  testWidgets('an edit in one drill survives visiting another (one State)', (
    tester,
  ) async {
    await _mount(tester);

    await openSettingsCategory(tester, SettingsCategory.recording);
    await tester.tap(find.text('Hold to record'));
    await tester.pump();
    await closeSettingsCategory(tester);
    await openSettingsCategory(tester, SettingsCategory.storage);
    await closeSettingsCategory(tester);
    await openSettingsCategory(tester, SettingsCategory.recording);

    final RadioGroup<TriggerMode> triggerGroup = tester.widget(
      find.ancestor(
        of: find.text('Hold to record'),
        matching: find.byType(RadioGroup<TriggerMode>),
      ),
    );
    expect(triggerGroup.groupValue, TriggerMode.hold);
  });

  testWidgets('top-level Trash entry opens the seven-day notebook trash', (
    tester,
  ) async {
    await _mount(tester);

    final Finder trash = find.byKey(
      const ValueKey<String>('settings-trash-top-level'),
    );
    await tester.scrollUntilVisible(
      trash,
      80,
      scrollable: find.byType(Scrollable).first,
    );
    expect(trash, findsOneWidget);
    final ListTile tile = tester.widget<ListTile>(trash);
    expect(tile.leading, isA<Icon>());
    expect(
      find.descendant(of: trash, matching: find.text('Trash')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: trash,
        matching: find.text('Deleted notebooks — kept 7 days, then emptied'),
      ),
      findsOneWidget,
    );

    await tester.tap(trash);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(TrashScreen), findsOneWidget);
    expect(
      find.textContaining('Deleted notebooks stay here for 7 days'),
      findsOneWidget,
    );
  });

  testWidgets('Maintenance & about keeps Licenses and the version line', (
    tester,
  ) async {
    await _mount(tester);

    await openSettingsCategory(tester, SettingsCategory.maintenance);

    expect(find.text('Licenses'), findsOneWidget);
    expect(find.textContaining('AGPL-3.0'), findsWidgets);
  });
}
