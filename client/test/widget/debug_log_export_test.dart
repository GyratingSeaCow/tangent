// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/screens/settings/diagnostics_section.dart';
import 'package:tangent/services/debug_log_export.dart';

class _FakeExporter implements DebugLogExporter {
  _FakeExporter({
    this.result = const DebugLogExportResult(DebugLogExportRoute.attachedEmail),
  });

  final DebugLogExportResult result;
  int calls = 0;

  @override
  Future<DebugLogExportResult> export() async {
    calls++;
    return result;
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

  testWidgets('desktop fallback reports the saved path without claiming open', (
    WidgetTester tester,
  ) async {
    if (!(Platform.isLinux || Platform.isWindows)) return;
    const String savedPath =
        r'C:\Users\tester\Documents\Tangent\Exports\tangent-debug-logs.txt';
    final _FakeExporter exporter = _FakeExporter(
      result: const DebugLogExportResult(
        DebugLogExportRoute.sharedFile,
        filePath: savedPath,
      ),
    );
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

    expect(find.text('Saved debug logs to $savedPath'), findsOneWidget);
    expect(find.textContaining('opened'), findsNothing);
  });
}
