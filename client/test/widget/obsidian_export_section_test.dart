// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Settings → Export to Obsidian… — pins: the tile with its explanation,
// a clean run reports its count, failures are named (a silent skip would
// look like the export worked). v1.16.0: the two document-shape switches
// (timestamps default OFF, summary default ON) persist in the settings
// store and reach the exporter the run uses.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/notebook_repository.dart';
import 'package:tangent/data/settings_store.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/data/storage/storage_providers.dart';
import 'package:tangent/screens/home/home_screen.dart' show localDbProvider;
import 'package:tangent/screens/settings/obsidian_export_section.dart';
import 'package:tangent/screens/settings/settings_screen.dart'
    show settingsStoreProvider;
import 'package:tangent/services/obsidian_export.dart';
import 'package:tangent/services/transcript_markdown.dart';

final class FakeExporter implements ObsidianExporter {
  FakeExporter(this.summary, {this.options = const TranscriptMarkdownOptions()});
  final ExportSummary summary;
  @override
  final TranscriptMarkdownOptions options;
  int runs = 0;

  @override
  Future<ExportSummary> run({required ExportProgress onProgress}) async {
    runs++;
    onProgress(1, 2, 'a.md');
    onProgress(2, 2, 'b.md');
    return summary;
  }
}

Future<void> pump(
  WidgetTester tester,
  FakeExporter exporter, {
  SettingsStore? store,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        obsidianExporterProvider.overrideWithValue(exporter),
        if (store != null) settingsStoreProvider.overrideWithValue(store),
      ],
      child: const MaterialApp(
        home: Scaffold(body: ObsidianExportSection()),
      ),
    ),
  );
}

class _FakeDb extends Fake implements LocalDb {}

class _FakeNotebooks extends Fake implements NotebookRepository {}

class _FakeBackend extends Fake implements StorageBackend {}

class _FakeCatalog extends Fake implements StorageCatalog {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('document-shape switches', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    testWidgets('default: timestamps off, summary on', (tester) async {
      final store = await SettingsStore.load();
      await pump(
        tester,
        FakeExporter(const ExportSummary(exported: 0, failed: [])),
        store: store,
      );

      final timestamps = tester.widget<SwitchListTile>(
        find.byKey(const ValueKey<String>('obsidian-timestamps')),
      );
      final summary = tester.widget<SwitchListTile>(
        find.byKey(const ValueKey<String>('obsidian-summary')),
      );
      expect(timestamps.value, isFalse);
      expect(summary.value, isTrue);
      expect(find.text('Include timestamps'), findsOneWidget);
      expect(find.text('Include summary'), findsOneWidget);
    });

    testWidgets('both switches persist across a fresh store load',
        (tester) async {
      final store = await SettingsStore.load();
      await pump(
        tester,
        FakeExporter(const ExportSummary(exported: 0, failed: [])),
        store: store,
      );

      await tester.tap(find.byKey(const ValueKey<String>('obsidian-timestamps')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey<String>('obsidian-summary')));
      await tester.pump();

      expect(
        tester
            .widget<SwitchListTile>(
              find.byKey(const ValueKey<String>('obsidian-timestamps')),
            )
            .value,
        isTrue,
      );
      expect(
        tester
            .widget<SwitchListTile>(
              find.byKey(const ValueKey<String>('obsidian-summary')),
            )
            .value,
        isFalse,
      );

      final reloaded = await SettingsStore.load();
      expect(reloaded.obsidianExportTimestamps, isTrue);
      expect(reloaded.obsidianExportSummary, isFalse);
    });

    testWidgets('flipping a switch reaches the exporter the run uses',
        (tester) async {
      final store = await SettingsStore.load();
      final built = <FakeExporter>[];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsStoreProvider.overrideWithValue(store),
            // Mirrors the real provider: rebuilt from the options provider.
            obsidianExporterProvider.overrideWith((ref) {
              final exporter = FakeExporter(
                const ExportSummary(exported: 1, failed: []),
                options: ref.watch(obsidianMarkdownOptionsProvider),
              );
              built.add(exporter);
              return exporter;
            }),
          ],
          child: const MaterialApp(
            home: Scaffold(body: ObsidianExportSection()),
          ),
        ),
      );

      await tester.tap(find.byKey(const ValueKey<String>('obsidian-timestamps')));
      await tester.pump();
      await tester.tap(find.text('Export to Obsidian…'));
      await tester.pumpAndSettle();

      expect(built.last.runs, 1);
      expect(
        built.last.options,
        const TranscriptMarkdownOptions(timestamps: true, includeSummary: true),
      );
    });

    test('the real exporter provider is built from the stored switches', () {
      final container = ProviderContainer(
        overrides: [
          settingsStoreProvider.overrideWithValue(
            SettingsStore(
              obsidianExportTimestamps: true,
              obsidianExportSummary: false,
            ),
          ),
          localDbProvider.overrideWithValue(_FakeDb()),
          notebookRepositoryProvider.overrideWithValue(_FakeNotebooks()),
          storageBackendProvider.overrideWithValue(_FakeBackend()),
          storageCatalogProvider.overrideWithValue(_FakeCatalog()),
        ],
      );
      addTearDown(container.dispose);

      expect(
        container.read(obsidianExporterProvider).options,
        const TranscriptMarkdownOptions(
          timestamps: true,
          includeSummary: false,
        ),
      );
    });
  });

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
