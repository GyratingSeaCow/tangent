// SPDX-License-Identifier: AGPL-3.0-or-later
/// The auto-file Settings section: a plain switch over the SERVER-side
/// trigger gate. Pinned here: the ON default, the open-time reconcile with
/// the server's answer (a read, never a write), the silent unreachable
/// server at init, and a failed write leaving the toggle where it was
/// with an error — never resting a lie.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/settings_store.dart';
import 'package:tangent/screens/settings/ai_summaries_section.dart'
    show summariesClientProvider;
import 'package:tangent/screens/settings/auto_file_section.dart';
import 'package:tangent/screens/settings/settings_screen.dart'
    show settingsStoreProvider;
import 'package:tangent/services/summaries_client.dart';

class _FakeAutoFileClient extends SummariesClient {
  _FakeAutoFileClient({required bool serverEnabled})
      : _serverEnabled = serverEnabled,
        super(baseUrl: 'http://unused.invalid');

  bool _serverEnabled;

  /// Every [setAutoFileEnabled] argument, in order.
  final List<bool> setEnabledCalls = <bool>[];
  int getSettingsCalls = 0;

  /// When set, [getAutoFileSettings] throws this — an unreachable server
  /// at init.
  Object? settingsError;

  /// When set, [setAutoFileEnabled] records the call and then throws this.
  Object? setError;

  @override
  Future<AutoFileSettings> getAutoFileSettings() async {
    getSettingsCalls += 1;
    final Object? err = settingsError;
    if (err != null) throw err;
    return AutoFileSettings(enabled: _serverEnabled);
  }

  @override
  Future<AutoFileSettings> setAutoFileEnabled(bool enabled) async {
    setEnabledCalls.add(enabled);
    final Object? err = setError;
    if (err != null) throw err;
    _serverEnabled = enabled;
    return AutoFileSettings(enabled: _serverEnabled);
  }
}

class _Harness {
  _Harness({
    required this.container,
    required this.client,
    required this.store,
  });

  final ProviderContainer container;
  final _FakeAutoFileClient client;
  final SettingsStore store;
}

Future<_Harness> _mount(
  WidgetTester tester, {
  bool enabled = true,
  bool? serverEnabled,
  Object? settingsError,
  Object? setError,
}) async {
  final SettingsStore store = SettingsStore(autoFileEnabled: enabled);
  final _FakeAutoFileClient client = _FakeAutoFileClient(
    // The server's gate normally agrees with this device's mirror; the
    // reconcile tests pull them apart on purpose.
    serverEnabled: serverEnabled ?? enabled,
  );
  client.settingsError = settingsError;
  client.setError = setError;
  final ProviderContainer container = ProviderContainer(
    overrides: <Override>[
      settingsStoreProvider.overrideWithValue(store),
      summariesClientProvider.overrideWith(
        (ref) => Future<SummariesClient>.value(client),
      ),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: AutoFileSection()),
        ),
      ),
    ),
  );
  await tester.pump();
  return _Harness(container: container, client: client, store: store);
}

Finder get _toggle =>
    find.byKey(const ValueKey<String>('settings-auto-file-toggle'));

Finder get _error => find.byKey(const ValueKey<String>('auto-file-error'));

bool _toggleValue(WidgetTester tester) =>
    tester.widget<SwitchListTile>(_toggle).value;

void main() {
  testWidgets('toggle seeds ON from the default setting', (tester) async {
    await _mount(tester);
    expect(_toggleValue(tester), isTrue);
  });

  testWidgets('toggle seeds from the persisted setting', (tester) async {
    await _mount(tester, enabled: false);
    expect(_toggleValue(tester), isFalse);
  });

  testWidgets('open reconciles the toggle with the server: adopts OFF',
      (tester) async {
    final _Harness h =
        await _mount(tester, enabled: true, serverEnabled: false);
    await tester.pumpAndSettle();
    expect(
      _toggleValue(tester),
      isFalse,
      reason: 'another device turned the server gate off',
    );
    expect(
      h.store.autoFileEnabled,
      isFalse,
      reason: 'the adopted answer must persist',
    );
    expect(
      h.client.setEnabledCalls,
      isEmpty,
      reason: 'reconcile is a read, never a write',
    );
  });

  testWidgets('open reconciles the toggle with the server: adopts ON',
      (tester) async {
    final _Harness h =
        await _mount(tester, enabled: false, serverEnabled: true);
    await tester.pumpAndSettle();
    expect(_toggleValue(tester), isTrue);
    expect(h.store.autoFileEnabled, isTrue);
    expect(h.client.setEnabledCalls, isEmpty);
  });

  testWidgets('unreachable server at init keeps the remembered value, silently',
      (tester) async {
    await _mount(
      tester,
      enabled: true,
      settingsError: Exception('connection refused'),
    );
    await tester.pumpAndSettle();
    expect(_toggleValue(tester), isTrue);
    expect(
      _error,
      findsNothing,
      reason: 'the user did nothing yet — no error banner at init',
    );
  });

  testWidgets('switching OFF posts the server gate off and persists',
      (tester) async {
    final _Harness h = await _mount(tester, enabled: true);
    await tester.pumpAndSettle();
    await tester.tap(_toggle);
    await tester.pumpAndSettle();
    expect(h.client.setEnabledCalls, <bool>[false]);
    expect(_toggleValue(tester), isFalse);
    expect(h.store.autoFileEnabled, isFalse);
    expect(_error, findsNothing);
  });

  testWidgets('switching ON posts the server gate on and persists',
      (tester) async {
    final _Harness h = await _mount(tester, enabled: false);
    await tester.pumpAndSettle();
    await tester.tap(_toggle);
    await tester.pumpAndSettle();
    expect(h.client.setEnabledCalls, <bool>[true]);
    expect(_toggleValue(tester), isTrue);
    expect(h.store.autoFileEnabled, isTrue);
  });

  testWidgets('a failed write leaves the toggle where it was and says why',
      (tester) async {
    final _Harness h = await _mount(
      tester,
      enabled: true,
      setError: Exception('connection refused'),
    );
    await tester.pumpAndSettle();
    await tester.tap(_toggle);
    await tester.pumpAndSettle();
    expect(
      h.client.setEnabledCalls,
      <bool>[false],
      reason: 'the write was attempted',
    );
    expect(
      _toggleValue(tester),
      isTrue,
      reason: 'the server gate did not change, so neither may the toggle',
    );
    expect(h.store.autoFileEnabled, isTrue);
    expect(_error, findsOneWidget);
  });
}
