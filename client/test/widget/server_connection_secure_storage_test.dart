// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:tangent/data/secure_storage.dart';
import 'package:tangent/screens/server/server_connection_screen.dart';

class _ThrowingSecureStorage extends Mock implements FlutterSecureStorage {}

/// On Linux flutter_secure_storage needs a running Secret Service
/// (KWallet/gnome-keyring). Where none is available every read throws a
/// PlatformException. The connect screen is the front door to pairing: it
/// must render and tell the user what is wrong — a crash or a silently
/// empty form both read as a broken app.
void main() {
  testWidgets('connect screen survives a dead Secret Service and says so',
      (tester) async {
    final storage = _ThrowingSecureStorage();
    when(() => storage.read(key: any(named: 'key'))).thenThrow(
      PlatformException(
        code: 'Libsecret error',
        message: 'Cannot autolaunch D-Bus without X11 \$DISPLAY',
      ),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          secureStoreProvider.overrideWithValue(SecureStore(storage: storage)),
        ],
        child: const MaterialApp(home: ServerConnectionScreen()),
      ),
    );
    await tester.pump();

    // The screen must still stand.
    expect(find.text('Connect to Server'), findsOneWidget);
    expect(find.text('Test & Connect'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // And the failure must be surfaced, not swallowed: the user needs to
    // know saved credentials could not be loaded and why.
    expect(
      find.textContaining('secure storage', findRichText: true),
      findsOneWidget,
    );
  });
}
