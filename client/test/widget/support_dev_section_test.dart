// SPDX-License-Identifier: AGPL-3.0-or-later
/// Settings → Support the Dev (last overview row): a thank-you note with
/// the PayPal donation link below it. The drill is static content; the
/// donate button opens PayPal's hosted-button payment page EXTERNALLY —
/// the app embeds no payment JS and no WebView.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:tangent/data/secure_storage.dart';
import 'package:tangent/data/settings_store.dart';
import 'package:tangent/models/pair_pending.dart';
import 'package:tangent/screens/server/server_connection_screen.dart'
    show secureStoreProvider, transcriptionClientProvider;
import 'package:tangent/screens/settings/settings_screen.dart';
import 'package:tangent/screens/settings/support_dev_section.dart';
import 'package:tangent/services/transcription_client.dart';
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

Future<void> _mount(WidgetTester tester, {SettingsCategory? category}) async {
  tester.view.physicalSize = const Size(1080, 2340);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        settingsStoreProvider.overrideWithValue(SettingsStore()),
        secureStoreProvider.overrideWithValue(_FakeSecureStore()),
        transcriptionClientProvider.overrideWith((ref) => _FakeClient()),
      ],
      child: MaterialApp(home: SettingsScreen(category: category)),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  late _FakeUrlLauncher launcher;

  setUp(() {
    launcher = _FakeUrlLauncher();
    UrlLauncherPlatform.instance = launcher;
  });

  testWidgets('the drill renders the thank-you message above the donate link',
      (tester) async {
    await _mount(tester, category: SettingsCategory.supportDev);

    // App bar carries the category title.
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.text('Support the Dev'),
      ),
      findsOneWidget,
    );
    // Jeff's message, verbatim, with the donate button BELOW it.
    final Finder message = find.text(SupportDevSection.message);
    final Finder donate = find.byKey(SupportDevSection.donateKey);
    expect(message, findsOneWidget);
    expect(donate, findsOneWidget);
    expect(
      tester.getTopLeft(donate).dy,
      greaterThan(tester.getBottomLeft(message).dy),
      reason: 'the donation link sits below the message',
    );

    expect(tester.takeException(), isNull);
  });

  testWidgets('the overview row is the LAST one and opens the drill',
      (tester) async {
    await _mount(tester);

    expect(
      SettingsCategory.values.last,
      SettingsCategory.supportDev,
      reason: 'Support the Dev is the very end of the settings menu',
    );
    final Finder row =
        find.byKey(SettingsScreen.categoryKey(SettingsCategory.supportDev));
    await tester.scrollUntilVisible(
      row,
      80,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(row);
    await tester.pump();
    await tester.tap(row);
    await tester.pumpAndSettle();

    expect(find.text(SupportDevSection.message), findsOneWidget);
  });

  testWidgets('donate opens the PayPal hosted-button page externally',
      (tester) async {
    await _mount(tester, category: SettingsCategory.supportDev);

    await tester.tap(find.byKey(SupportDevSection.donateKey));
    await tester.pump();

    expect(launcher.launched, <String>[SupportDevSection.donateUrl]);
    expect(
      SupportDevSection.donateUrl,
      'https://www.paypal.com/ncp/payment/3L6QWSULPF4WS',
      reason: 'the hosted-button id must match the PayPal dashboard',
    );
  });

  testWidgets('a failed launch surfaces a SnackBar instead of silence',
      (tester) async {
    launcher.result = false;
    await _mount(tester, category: SettingsCategory.supportDev);

    await tester.tap(find.byKey(SupportDevSection.donateKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      find.textContaining('Could not open the donation page'),
      findsOneWidget,
    );
  });
}
