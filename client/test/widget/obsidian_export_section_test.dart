// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Settings → Export to Obsidian… — pins: the tile with its explanation,
// a clean run reports its count, failures are named (a silent skip would
// look like the export worked).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tangent/screens/settings/obsidian_export_section.dart';
import 'package:tangent/services/obsidian_export.dart';

final class FakeExporter implements ObsidianExporter {
  FakeExporter(this.summary);
  final ExportSummary summary;
  int runs = 0;

  @override
  Future<ExportSummary> run({required ExportProgress onProgress}) async {
    runs++;
    onProgress(1, 2, 'a.md');
    onProgress(2, 2, 'b.md');
    return summary;
  }
}

Future<void> pump(WidgetTester tester, FakeExporter exporter) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [obsidianExporterProvider.overrideWithValue(exporter)],
      child: const MaterialApp(
        home: Scaffold(body: ObsidianExportSection()),
      ),
    ),
  );
}

void main() {
  testWidgets('offers the export tile with its explanation', (tester) async {
    await pump(
      tester,
      FakeExporter(const ExportSummary(exported: 0, failed: [])),
    );

    expect(find.text('Export to Obsidian…'), findsOneWidget);
    expect(
      find.textContaining('markdown file'),
      findsOneWidget,
      reason: 'the tile needs its explanation underneath',
    );
  });

  testWidgets('a clean run reports how many notes exported', (tester) async {
    final exporter =
        FakeExporter(const ExportSummary(exported: 12, failed: []));
    await pump(tester, exporter);

    await tester.tap(find.text('Export to Obsidian…'));
    await tester.pumpAndSettle();

    expect(exporter.runs, 1);
    expect(
      find.textContaining('Exported 12 notes'),
      findsOneWidget,
    );
  });

  testWidgets('failures are named, never silently skipped', (tester) async {
    await pump(
      tester,
      FakeExporter(
        const ExportSummary(
          exported: 3,
          failed: [FailedExport(name: 'bad.md', reason: 'denied')],
        ),
      ),
    );

    await tester.tap(find.text('Export to Obsidian…'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('bad.md'),
      findsOneWidget,
      reason: 'the user must know exactly which note failed',
    );
    expect(find.textContaining('Exported 3'), findsOneWidget);
  });
}
