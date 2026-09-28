// SPDX-License-Identifier: AGPL-3.0-or-later
/// The connection screen's discovery + pairing arc, no sockets involved:
/// scan fills the list live, Pair asks for the code, a wrong code counts
/// down, the right code lands the token in SecureStore and connects.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/secure_storage.dart';
import 'package:tangent/models/server_info.dart';
import 'package:tangent/screens/server/server_connection_screen.dart';
import 'package:tangent/services/pairing_client.dart';
import 'package:tangent/services/server_discovery.dart';
import 'package:tangent/services/transcription_client.dart';

class _MemoryStore implements SecureStore {
  String? url;
  String? token;
  String? deviceId;

  @override
  Future<String?> getServerUrl() async => url;
  @override
  Future<String?> getToken() async => token;
  @override
  Future<String?> getDeviceId() async => deviceId;
  @override
  Future<void> setServerUrl(String value) async => url = value;
  @override
  Future<void> setToken(String value) async => token = value;
  @override
  Future<void> setDeviceId(String id) async => deviceId = id;
  @override
  Future<void> clear() async {
    url = null;
    token = null;
    deviceId = null;
  }
}

class _FakeDiscovery extends ServerDiscovery {
  _FakeDiscovery(this.servers);

  final List<DiscoveredServer> servers;

  @override
  Future<List<DiscoveredServer>> sweep({
    required String selfAddress,
    List<int> ports = kDiscoveryPorts,
    void Function(DiscoveredServer server)? onFound,
  }) async {
    for (final DiscoveredServer server in servers) {
      onFound?.call(server);
    }
    return servers;
  }
}

class _FakePairing extends PairingClient {
  _FakePairing({required this.correctCode})
      : super(baseUrl: 'http://unused.invalid');

  final String correctCode;
  int attemptsLeft = 5;
  String? requestedDeviceId;

  @override
  Future<PairingTicket?> request({
    required String deviceId,
    required String displayName,
    required String platform,
  }) async {
    requestedDeviceId = deviceId;
    return PairingTicket(
      pairId: 'pair-1',
      expiresAt: DateTime.now().add(const Duration(seconds: 120)),
    );
  }

  @override
  Future<PairClaimResult> claim({
    required String pairId,
    required String code,
  }) async {
    if (code == correctCode) {
      return const PairClaimResult(
        status: PairClaimStatus.success,
        token: 'minted-token',
        serverName: 'Homelab',
      );
    }
    attemptsLeft -= 1;
    return PairClaimResult(
      status: PairClaimStatus.wrongCode,
      attemptsRemaining: attemptsLeft,
    );
  }
}

class _FakeClient extends TranscriptionClient {
  _FakeClient() : super(baseUrl: 'http://unused.invalid');

  @override
  Future<ServerInfo> getServerInfo() async => const ServerInfo(
        version: '1.0.0',
        setupComplete: true,
        defaultModel: 'large-v3',
        availableModels: <String>['large-v3'],
        storageUsedBytes: 0,
        dumpCount: 0,
      );
}

const DiscoveredServer _homelab = DiscoveredServer(
  host: '10.0.0.7',
  port: 8765,
  name: 'Homelab',
  version: '1.2.0',
  requiresAuth: true,
);

Future<_MemoryStore> _mount(
  WidgetTester tester, {
  required _FakePairing pairing,
  List<DiscoveredServer> servers = const <DiscoveredServer>[_homelab],
  String? localAddress = '10.0.0.5',
}) async {
  final _MemoryStore store = _MemoryStore();
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        secureStoreProvider.overrideWithValue(store),
      ],
      child: MaterialApp(
        routes: <String, WidgetBuilder>{
          '/home': (_) => const Scaffold(body: Text('HOME')),
        },
        home: ServerConnectionScreen(
          discoveryFactory: () => _FakeDiscovery(servers),
          pairingFactory: (_) => pairing,
          localAddress: () async => localAddress,
          clientFactory: (_, __) => _FakeClient(),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return store;
}

void main() {
  testWidgets('scan lists discovered servers with a Pair button',
      (tester) async {
    await _mount(tester, pairing: _FakePairing(correctCode: '123456'));

    await tester.tap(find.byKey(const ValueKey<String>('discover-servers')));
    await tester.pumpAndSettle();

    expect(find.text('Homelab'), findsOneWidget);
    expect(find.text('http://10.0.0.7:8765 · v1.2.0'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Pair'), findsOneWidget);
  });

  testWidgets('scan with no finds says so instead of showing nothing',
      (tester) async {
    await _mount(
      tester,
      pairing: _FakePairing(correctCode: '123456'),
      servers: const <DiscoveredServer>[],
    );

    await tester.tap(find.byKey(const ValueKey<String>('discover-servers')));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('No servers found on 10.0.0.x'),
      findsOneWidget,
    );
  });

  // Which address the user pairs with decides whether the app works away
  // from home. That fact used to live only in the README; a LAN pairing on
  // cellular then spun forever. The screen must say it, in three places.
  testWidgets('the screen says a found (Wi-Fi) address is home-only and '
      'names the Tailscale shape that works everywhere', (tester) async {
    await _mount(tester, pairing: _FakePairing(correctCode: '123456'));

    final Finder hint =
        find.byKey(const ValueKey<String>('address-scope-hint'));
    expect(hint, findsOneWidget, reason: 'shown before any scan, always');
    final String text = tester.widget<Text>(hint).data!;
    expect(text, contains('only works on this network'));
    expect(text, contains('Tailscale address (http://100.x.x.x:8765)'));

    // The URL field's hint shows both shapes, labelled.
    final TextField url = tester.widget<TextField>(
      find.widgetWithText(TextField, 'Server URL'),
    );
    expect(url.decoration!.hintText, contains('100.x.x.x:8765 (Tailscale)'));
    expect(url.decoration!.hintText, contains('192.168.x.x:8765 (Wi-Fi only)'));
  });

  testWidgets('on cellular (no LAN address) the scan error names the fix',
      (tester) async {
    await _mount(
      tester,
      pairing: _FakePairing(correctCode: '123456'),
      localAddress: null,
    );

    await tester.tap(find.byKey(const ValueKey<String>('discover-servers')));
    await tester.pumpAndSettle();

    final Finder error = find.textContaining('No local network to scan');
    expect(error, findsOneWidget);
    final String text = tester.widget<Text>(error).data!;
    expect(text, contains('cellular'));
    expect(text, contains('http://100.x.x.x:8765'));
    expect(text, contains('works from anywhere'));
  });

  testWidgets('correct code pairs, stores the token, and lands home',
      (tester) async {
    final _FakePairing pairing = _FakePairing(correctCode: '123456');
    final _MemoryStore store = await _mount(tester, pairing: pairing);

    await tester.tap(find.byKey(const ValueKey<String>('discover-servers')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Pair'));
    await tester.pumpAndSettle();

    expect(find.text('Enter pairing code'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey<String>('pairing-code-field')),
      '123456',
    );
    await tester.tap(find.byKey(const ValueKey<String>('pairing-code-submit')));
    await tester.pumpAndSettle();

    expect(find.text('HOME'), findsOneWidget, reason: 'must navigate on');
    expect(store.token, 'minted-token');
    expect(store.url, 'http://10.0.0.7:8765');
    expect(
      store.deviceId,
      pairing.requestedDeviceId,
      reason: 'the id sent to the server must be the one persisted',
    );
  });

  testWidgets('wrong code stays in the dialog and shows attempts left',
      (tester) async {
    final _MemoryStore store = await _mount(
      tester,
      pairing: _FakePairing(correctCode: '123456'),
    );

    await tester.tap(find.byKey(const ValueKey<String>('discover-servers')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Pair'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey<String>('pairing-code-field')),
      '999999',
    );
    await tester.tap(find.byKey(const ValueKey<String>('pairing-code-submit')));
    await tester.pumpAndSettle();

    expect(find.text('Enter pairing code'), findsOneWidget);
    expect(find.textContaining('4 attempts left'), findsOneWidget);
    expect(store.token, isNull, reason: 'no token on a failed claim');
  });
}
