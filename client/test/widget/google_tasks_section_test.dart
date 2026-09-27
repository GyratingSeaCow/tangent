// SPDX-License-Identifier: AGPL-3.0-or-later
/// The Google Tasks Settings section renders one of five server states
/// from the status payload and exposes exactly one verb per state. Pinned
/// here: each state's widgets + keys, Save posting credentials, Connect
/// launching the server's auth_url in the browser, and the post-Connect
/// poll flipping to connected.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:tangent/screens/settings/ai_summaries_section.dart'
    show summariesClientProvider;
import 'package:tangent/screens/settings/google_tasks_section.dart';
import 'package:tangent/services/summaries_client.dart';
import 'package:url_launcher_platform_interface/link.dart' show LinkDelegate;
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

/// Records every launch instead of opening a browser.
class _FakeUrlLauncher extends UrlLauncherPlatform
    with MockPlatformInterfaceMixin {
  final List<String> launched = <String>[];
  bool result = true;

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> canLaunch(String url) async => true;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    launched.add(url);
    return result;
  }

  @override
  Future<bool> launch(
    String url, {
    required bool useSafariVC,
    required bool useWebView,
    required bool enableJavaScript,
    required bool enableDomStorage,
    required bool universalLinksOnly,
    required Map<String, String> headers,
    String? webOnlyWindowName,
  }) async {
    launched.add(url);
    return result;
  }
}

class _FakeClient extends SummariesClient {
  _FakeClient(this.payloads) : super(baseUrl: 'http://unused.invalid');

  /// Status payloads handed out in order; the last one repeats. Tests
  /// mutate this list to stage a transition (e.g. connect → connected).
  List<Map<String, dynamic>> payloads;

  int statusCalls = 0;
  int connectCalls = 0;
  int disconnectCalls = 0;
  int syncNowCalls = 0;
  final List<Map<String, String>> credentialCalls = <Map<String, String>>[];
  Object? statusError;

  Map<String, dynamic> get _current =>
      payloads.length > 1 ? payloads.removeAt(0) : payloads.first;

  @override
  Future<GoogleTasksStatus> getGoogleTasksStatus() async {
    statusCalls += 1;
    final Object? err = statusError;
    if (err != null) throw err;
    return GoogleTasksStatus.fromJson(_current);
  }

  @override
  Future<void> saveGoogleTasksCredentials({
    required String clientId,
    required String clientSecret,
  }) async {
    credentialCalls.add(<String, String>{
      'client_id': clientId,
      'client_secret': clientSecret,
    });
    payloads = <Map<String, dynamic>>[_disconnected(hasCredentials: true)];
  }

  @override
  Future<Uri> connectGoogleTasks() async {
    connectCalls += 1;
    return Uri.parse(
      'https://accounts.google.com/o/oauth2/v2/auth?client_id=fake-id.apps'
      '&state=fake-state-nonce',
    );
  }

  @override
  Future<void> disconnectGoogleTasks() async {
    disconnectCalls += 1;
    payloads = <Map<String, dynamic>>[_disconnected(hasCredentials: true)];
  }

  @override
  Future<GoogleTasksStatus> syncGoogleTasksNow() async {
    syncNowCalls += 1;
    return GoogleTasksStatus.fromJson(_connected(pushed: 5, pulled: 2));
  }
}

Map<String, dynamic> _disconnected({bool hasCredentials = false}) =>
    <String, dynamic>{
      'status': 'disconnected',
      'google_email': null,
      'last_sync_at': null,
      'last_error': null,
      'pushed': 0,
      'pulled': 0,
      'credentials_configured': hasCredentials,
    };

Map<String, dynamic> _connected({int pushed = 3, int pulled = 1}) =>
    <String, dynamic>{
      'status': 'connected',
      'google_email': 'jeff@example.invalid',
      'last_sync_at': '2026-09-27T11:58:00Z',
      'last_error': null,
      'pushed': pushed,
      'pulled': pulled,
      'credentials_configured': true,
    };

Map<String, dynamic> _reauth() => <String, dynamic>{
      ..._connected(),
      'status': 'reauth_required',
      'last_error': 'invalid_grant',
    };

Map<String, dynamic> _error() => <String, dynamic>{
      ..._connected(),
      'status': 'error',
      'last_error': 'HTTP 503 from tasks.googleapis.com',
    };

Finder _k(String key) => find.byKey(ValueKey<String>(key));

Future<_FakeClient> _mount(
  WidgetTester tester,
  List<Map<String, dynamic>> payloads, {
  Object? statusError,
}) async {
  final _FakeClient client = _FakeClient(payloads)..statusError = statusError;
  final ProviderContainer container = ProviderContainer(
    overrides: <Override>[
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
          body: SingleChildScrollView(child: GoogleTasksSection()),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return client;
}

void main() {
  late _FakeUrlLauncher launcher;

  setUp(() {
    launcher = _FakeUrlLauncher();
    UrlLauncherPlatform.instance = launcher;
    // 12:00 on the day of the connected payload's 11:58 sync → "2 min ago".
    googleTasksClock = () => DateTime.utc(2026, 9, 27, 12, 0);
  });

  tearDown(() {
    googleTasksClock = DateTime.now;
  });

  group('five states', () {
    testWidgets(
        'disconnected without credentials: fields + Save + help, '
        'no Connect', (tester) async {
      await _mount(tester, <Map<String, dynamic>>[_disconnected()]);

      expect(_k('google-tasks-client-id'), findsOneWidget);
      expect(_k('google-tasks-client-secret'), findsOneWidget);
      expect(_k('google-tasks-save'), findsOneWidget);
      expect(_k('google-tasks-help'), findsOneWidget);
      expect(
        find.textContaining('Free. Create a Google Cloud project'),
        findsOneWidget,
      );
      expect(_k('google-tasks-connect'), findsNothing);
      expect(_k('google-tasks-sync-now'), findsNothing);
      expect(_k('google-tasks-disconnect'), findsNothing);
      expect(_k('google-tasks-reconnect'), findsNothing);
      expect(
        tester.widget<Text>(_k('google-tasks-status')).data,
        'Not connected',
      );
    });

    testWidgets('disconnected with credentials: Connect Google, fields hidden',
        (tester) async {
      await _mount(
        tester,
        <Map<String, dynamic>>[_disconnected(hasCredentials: true)],
      );

      expect(_k('google-tasks-connect'), findsOneWidget);
      expect(_k('google-tasks-client-id'), findsNothing);
      expect(_k('google-tasks-save'), findsNothing);
      expect(_k('google-tasks-sync-now'), findsNothing);
      expect(_k('google-tasks-reconnect'), findsNothing);
      expect(
        tester.widget<Text>(_k('google-tasks-status')).data,
        'Not connected — credentials saved',
      );
    });

    testWidgets('connected: email, last-sync summary, Sync now, Disconnect',
        (tester) async {
      await _mount(tester, <Map<String, dynamic>>[_connected()]);

      expect(
        tester.widget<Text>(_k('google-tasks-status')).data,
        'Connected as jeff@example.invalid',
      );
      expect(
        tester.widget<Text>(_k('google-tasks-summary')).data,
        'Last sync 2 min ago · 3 pushed · 1 pulled',
      );
      expect(_k('google-tasks-sync-now'), findsOneWidget);
      expect(_k('google-tasks-disconnect'), findsOneWidget);
      expect(_k('google-tasks-connect'), findsNothing);
      expect(_k('google-tasks-reconnect'), findsNothing);
      expect(_k('google-tasks-client-id'), findsNothing);
    });

    testWidgets('reauth_required: amber banner + Reconnect', (tester) async {
      await _mount(tester, <Map<String, dynamic>>[_reauth()]);

      expect(_k('google-tasks-reauth-banner'), findsOneWidget);
      expect(find.text(kGoogleTasksReauthText), findsOneWidget);
      expect(_k('google-tasks-reconnect'), findsOneWidget);
      expect(_k('google-tasks-sync-now'), findsNothing);
      expect(_k('google-tasks-connect'), findsNothing);
    });

    testWidgets('error: red last_error line + Retry', (tester) async {
      await _mount(tester, <Map<String, dynamic>>[_error()]);

      final Text line = tester.widget<Text>(_k('google-tasks-last-error'));
      expect(line.data, 'HTTP 503 from tasks.googleapis.com');
      expect(line.style?.color, isNotNull);
      expect(_k('google-tasks-retry'), findsOneWidget);
      expect(_k('google-tasks-sync-now'), findsNothing);
      expect(_k('google-tasks-reconnect'), findsNothing);
    });
  });

  group('verbs', () {
    testWidgets(
        'Save posts both credentials, clears the fields, and moves '
        'to the Connect state', (tester) async {
      final _FakeClient client =
          await _mount(tester, <Map<String, dynamic>>[_disconnected()]);

      await tester.enterText(_k('google-tasks-client-id'), 'fake-id.apps');
      await tester.enterText(_k('google-tasks-client-secret'), 'fake-secret');
      await tester.tap(_k('google-tasks-save'));
      await tester.pumpAndSettle();

      expect(client.credentialCalls, <Map<String, String>>[
        <String, String>{
          'client_id': 'fake-id.apps',
          'client_secret': 'fake-secret',
        },
      ]);
      expect(_k('google-tasks-connect'), findsOneWidget);
      expect(_k('google-tasks-client-secret'), findsNothing);
    });

    testWidgets('Save with an empty field posts nothing and explains',
        (tester) async {
      final _FakeClient client =
          await _mount(tester, <Map<String, dynamic>>[_disconnected()]);

      await tester.enterText(_k('google-tasks-client-id'), 'fake-id.apps');
      await tester.tap(_k('google-tasks-save'));
      await tester.pumpAndSettle();

      expect(client.credentialCalls, isEmpty);
      expect(_k('google-tasks-error'), findsOneWidget);
    });

    testWidgets(
        'Connect launches the server auth_url in the browser and the '
        'poll flips the section to connected', (tester) async {
      final _FakeClient client = await _mount(
        tester,
        <Map<String, dynamic>>[_disconnected(hasCredentials: true)],
      );

      await tester.tap(_k('google-tasks-connect'));
      await tester.pump();
      await tester.pump();

      expect(client.connectCalls, 1);
      expect(launcher.launched, hasLength(1));
      expect(
        launcher.launched.single,
        startsWith('https://accounts.google.com/'),
      );
      expect(launcher.launched.single, contains('state=fake-state-nonce'));
      expect(
        tester.widget<Text>(_k('google-tasks-status')).data,
        'Waiting for Google sign-in…',
      );

      // Google's consent page finished in the browser: the next poll sees
      // connected and the section re-renders; polling then stops.
      client.payloads = <Map<String, dynamic>>[_connected()];
      final int callsBefore = client.statusCalls;
      await tester.pump(kGoogleTasksConnectPoll);
      await tester.pump();
      expect(client.statusCalls, callsBefore + 1);
      expect(_k('google-tasks-sync-now'), findsOneWidget);
      expect(_k('google-tasks-connect'), findsNothing);

      await tester.pump(kGoogleTasksConnectPoll * 3);
      expect(
        client.statusCalls,
        callsBefore + 1,
        reason: 'the poll must stop once connected',
      );
    });

    testWidgets('a browser that refuses to open is an error, not a poll',
        (tester) async {
      launcher.result = false;
      final _FakeClient client = await _mount(
        tester,
        <Map<String, dynamic>>[_disconnected(hasCredentials: true)],
      );

      await tester.tap(_k('google-tasks-connect'));
      await tester.pumpAndSettle();

      expect(client.connectCalls, 1);
      expect(_k('google-tasks-error'), findsOneWidget);
      expect(_k('google-tasks-connect'), findsOneWidget);
    });

    testWidgets('Reconnect is Connect: launches the auth_url', (tester) async {
      final _FakeClient client =
          await _mount(tester, <Map<String, dynamic>>[_reauth()]);

      await tester.tap(_k('google-tasks-reconnect'));
      await tester.pump();
      await tester.pump();

      expect(client.connectCalls, 1);
      expect(launcher.launched, hasLength(1));

      // Unmount: the post-Connect poll must die with the widget.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    });

    testWidgets('Sync now posts and adopts the returned counts',
        (tester) async {
      final _FakeClient client =
          await _mount(tester, <Map<String, dynamic>>[_connected()]);

      await tester.tap(_k('google-tasks-sync-now'));
      await tester.pumpAndSettle();

      expect(client.syncNowCalls, 1);
      expect(
        tester.widget<Text>(_k('google-tasks-summary')).data,
        'Last sync 2 min ago · 5 pushed · 2 pulled',
      );
    });

    testWidgets('Retry in the error state is a sync-now', (tester) async {
      final _FakeClient client =
          await _mount(tester, <Map<String, dynamic>>[_error()]);

      await tester.tap(_k('google-tasks-retry'));
      await tester.pumpAndSettle();

      expect(client.syncNowCalls, 1);
      expect(_k('google-tasks-sync-now'), findsOneWidget);
      expect(_k('google-tasks-last-error'), findsNothing);
    });

    testWidgets('Disconnect posts and lands on Connect with credentials kept',
        (tester) async {
      final _FakeClient client =
          await _mount(tester, <Map<String, dynamic>>[_connected()]);

      await tester.tap(_k('google-tasks-disconnect'));
      await tester.pumpAndSettle();

      expect(client.disconnectCalls, 1);
      expect(_k('google-tasks-connect'), findsOneWidget);
      expect(_k('google-tasks-client-id'), findsNothing);
    });

    testWidgets(
        'an unreachable server shows the failure with a Retry that '
        're-reads status', (tester) async {
      final _FakeClient client = await _mount(
        tester,
        <Map<String, dynamic>>[_connected()],
        statusError: Exception('connection refused'),
      );

      expect(_k('google-tasks-error'), findsOneWidget);
      expect(_k('google-tasks-retry'), findsOneWidget);
      expect(_k('google-tasks-sync-now'), findsNothing);

      client.statusError = null;
      await tester.tap(_k('google-tasks-retry'));
      await tester.pumpAndSettle();
      expect(_k('google-tasks-sync-now'), findsOneWidget);
      expect(_k('google-tasks-error'), findsNothing);
    });
  });

  group('status model', () {
    test('parses every wire status and defaults unknown to disconnected', () {
      expect(
        GoogleTasksLinkStatus.parse('pending'),
        GoogleTasksLinkStatus.pending,
      );
      expect(
        GoogleTasksLinkStatus.parse('connected'),
        GoogleTasksLinkStatus.connected,
      );
      expect(
        GoogleTasksLinkStatus.parse('reauth_required'),
        GoogleTasksLinkStatus.reauthRequired,
      );
      expect(GoogleTasksLinkStatus.parse('error'), GoogleTasksLinkStatus.error);
      expect(
        GoogleTasksLinkStatus.parse('disconnected'),
        GoogleTasksLinkStatus.disconnected,
      );
      expect(
        GoogleTasksLinkStatus.parse('bogus'),
        GoogleTasksLinkStatus.disconnected,
      );
      expect(
        GoogleTasksLinkStatus.parse(null),
        GoogleTasksLinkStatus.disconnected,
      );
    });

    test('fromJson tolerates a bare payload', () {
      final GoogleTasksStatus s =
          GoogleTasksStatus.fromJson(const <String, dynamic>{});
      expect(s.status, GoogleTasksLinkStatus.disconnected);
      expect(s.hasCredentials, isFalse);
      expect(s.pushed, 0);
      expect(s.lastSyncAt, isNull);
    });

    test('formatSyncAgo buckets', () {
      final DateTime now = DateTime.utc(2026, 9, 27, 12);
      expect(
        formatSyncAgo(now.subtract(const Duration(seconds: 20)), now),
        'just now',
      );
      expect(
        formatSyncAgo(now.subtract(const Duration(minutes: 2)), now),
        '2 min ago',
      );
      expect(
        formatSyncAgo(now.subtract(const Duration(hours: 3)), now),
        '3 h ago',
      );
      expect(
        formatSyncAgo(now.subtract(const Duration(days: 4)), now),
        '4 d ago',
      );
    });
  });
}
