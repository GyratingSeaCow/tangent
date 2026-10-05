// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/screens/settings/diagnostics_section.dart';
import 'package:tangent/services/debug_log_export.dart';

class _FakeExporter implements DebugLogExporter {
  int calls = 0;

  @override
  Future<DebugLogExportResult> export() async {
    calls++;
    return const DebugLogExportResult(DebugLogExportRoute.attachedEmail);
  }
}

void main() {
  testWidgets(
    'Export debug logs button drives the exporter and reports route',
    (WidgetTester tester) async {
      final _FakeExporter exporter = _FakeExporter();
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            debugLogExporterProvider.overrideWithValue(exporter),
          ],
          child: const MaterialApp(home: Scaffold(body: DiagnosticsSection())),
        ),
      );

      await tester.tap(find.byKey(const ValueKey<String>('export-debug-logs')));
      await tester.pumpAndSettle();

      expect(exporter.calls, 1);
      expect(
        find.text('Opening an email with debug logs attached…'),
        findsOneWidget,
      );
    },
  );
}
