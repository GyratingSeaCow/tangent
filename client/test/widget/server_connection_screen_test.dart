// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tangent/screens/server/server_connection_screen.dart';

void main() {
  testWidgets('ServerConnectionScreen renders expected fields',
      (tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: ServerConnectionScreen()),
      ),
    );
    expect(find.text('Connect to Server'), findsOneWidget);
    expect(find.byType(TextField), findsNWidgets(2));
    expect(find.text('Test & Connect'), findsOneWidget);
  });
}