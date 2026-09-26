// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Name-speakers sheet (docs/design/2026-09-26-speaker-naming.md §3, §6).
//
// Real LocalDb through StorageFixture: Save goes through the same edit
// lease + updateDumpTranscript + sidecar publication path the detail
// editor uses, so a stale revision is a real StateError, not a stub.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/storage/storage_providers.dart';
import 'package:tangent/screens/dump/name_speakers_sheet.dart';
import 'package:tangent/screens/home/home_screen.dart' show localDbProvider;

import '../support/bound_service_fixture.dart';
import '../support/bound_widget_lifetime.dart';
import '../support/storage_fixture.dart';

const String twoSpeakers = '## Speaker 1\n'
    '\n'
    'Ended up getting fired and then moved to Austin.\n'
    '\n'
    '## Speaker 2\n'
    '\n'
    'I told Speaker 1 to wait.\n'
    '\n'
    '## [unattributed]\n'
    '\n'
    'mumble';

int _seedOrder = 0;

/// Every seeded row shares the fixture's fixed updated_at; bump it by a
/// running counter so "newest first" is a real ordering under test.
Future<void> setTranscript(LocalDb db, String id, String transcript) =>
    db.customStatement(
      'UPDATE dumps SET transcript = ?, updated_at = updated_at + ? '
      'WHERE id = ?',
      [transcript, ++_seedOrder, id],
    );

final class Harness {
  Harness(this.fixture, this.bound);
  final StorageFixture fixture;
  final BoundServiceFixture bound;
  LocalDb get db => fixture.db;
  final List<bool> results = <bool>[];
}

Future<Harness> createHarness(WidgetTester tester) async {
  final StorageFixture fixture = StorageFixture.create();
  final BoundServiceFixture bound = (await tester.runAsync(
    () => createBoundServiceFixture(fixture.db, registerDrain: false),
  ))!;
  final Harness h = Harness(fixture, bound);
  addTearDown(() async {
    await disposeBoundWidget(tester, bound);
    await tester.runAsync(fixture.close);
  });
  return h;
}

/// Seeds a completed dump with [transcript] and returns its row.
Future<DumpRow> seedDiarized(
  WidgetTester tester,
  Harness h,
  String id,
  String transcript,
) async {
  return (await tester.runAsync(() async {
    await h.fixture.seed(id, status: 'completed');
    await setTranscript(h.db, id, transcript);
    return (await h.db.getDump(id))!;
  }))!;
}

Future<DumpRow> current(WidgetTester tester, Harness h, String id) async =>
    (await tester.runAsync(() => h.db.getDump(id)))!;

/// Mounts a screen with an 'open' button that shows the sheet for [row].
Future<void> mount(WidgetTester tester, Harness h, DumpRow row) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        localDbProvider.overrideWithValue(h.db),
        recordingMutationsProvider.overrideWithValue(h.bound.mutations),
        recordingAccessProvider.overrideWithValue(h.bound.access),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Consumer(
            builder: (BuildContext context, WidgetRef ref, _) => Center(
              child: TextButton(
                key: const ValueKey<String>('open'),
                onPressed: () async {
                  h.results.add(await showNameSpeakersSheet(context, ref, row));
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const ValueKey<String>('open')));
  // The sheet loads chip suggestions from the real DB before it opens.
  await pumpBoundUntil(
    tester,
    () =>
        find.byKey(const ValueKey<String>('name-speakers-sheet')).evaluate().isNotEmpty ||
        h.results.isNotEmpty,
  );
  await tester.pumpAndSettle();
}

Finder get saveButton => find.byKey(const ValueKey<String>('speakers-save'));
Finder field(int n) => find.byKey(ValueKey<String>('speaker-name-$n'));

bool saveEnabled(WidgetTester tester) =>
    tester.widget<FilledButton>(saveButton).onPressed != null;

void main() {
  testWidgets('rows and hints come from the transcript; no chips when no '
      'names were ever typed', (tester) async {
    final Harness h = await createHarness(tester);
    final DumpRow row = await seedDiarized(tester, h, 'fixture-two', twoSpeakers);
    await mount(tester, h, row);

    expect(find.text('Name speakers'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('speaker-label-1')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('speaker-label-2')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('speaker-label-3')), findsNothing);
    expect(field(1), findsOneWidget);
    expect(field(2), findsOneWidget);
    expect(tester.widget<TextField>(field(1)).controller!.text, isEmpty);
    expect(tester.widget<TextField>(field(1)).decoration!.hintText, 'Speaker 1');
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey<String>('speaker-hint-1')))
          .data,
      'Ended up getting fired and then moved to Austin.',
    );
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey<String>('speaker-hint-2')))
          .data,
      'I told Speaker 1 to wait.',
    );
    // [unattributed] is never a speaker row.
    expect(find.text('[unattributed]'), findsNothing);
    expect(find.byKey(const ValueKey<String>('speaker-suggestions')), findsNothing);
    expect(saveEnabled(tester), isFalse);
  });

  testWidgets('chips come from other transcripts newest first and fill the '
      'focused field, else the first empty one', (tester) async {
    final Harness h = await createHarness(tester);
    await seedDiarized(tester, h, 'fixture-older', '## Alice\n\nhi\n\n## Speaker 2\n\nyo');
    await seedDiarized(tester, h, 'fixture-newer', '## Bob\n\nhey\n\n## Meeting Summary\n\nx');
    final DumpRow row = await seedDiarized(tester, h, 'fixture-two', twoSpeakers);
    await mount(tester, h, row);

    final Finder chips = find.descendant(
      of: find.byKey(const ValueKey<String>('speaker-suggestions')),
      matching: find.byType(ActionChip),
    );
    expect(chips, findsNWidgets(2));
    expect(
      tester.widgetList<ActionChip>(chips).map((c) => (c.label as Text).data),
      <String>['Bob', 'Alice'],
    );

    // Nothing focused: first empty field.
    await tester.tap(find.byKey(const ValueKey<String>('speaker-suggestion-Bob')));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(field(1)).controller!.text, 'Bob');
    expect(tester.widget<TextField>(field(2)).controller!.text, isEmpty);

    // Focused field wins even though field 2 is the first empty one.
    await tester.tap(field(1));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('speaker-suggestion-Alice')));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(field(1)).controller!.text, 'Alice');
    expect(tester.widget<TextField>(field(2)).controller!.text, isEmpty);
    expect(saveEnabled(tester), isTrue);
  });

  testWidgets('Save is disabled until a field is filled; a collision shows '
      '"Already used" and disables Save again', (tester) async {
    final Harness h = await createHarness(tester);
    final DumpRow row = await seedDiarized(tester, h, 'fixture-two', twoSpeakers);
    await mount(tester, h, row);

    expect(saveEnabled(tester), isFalse);
    await tester.enterText(field(1), 'Alice');
    await tester.pumpAndSettle();
    expect(saveEnabled(tester), isTrue);
    expect(find.text('Already used'), findsNothing);

    // Same name twice: the SECOND field is the one refused.
    await tester.enterText(field(2), ' Alice ');
    await tester.pumpAndSettle();
    expect(find.text('Already used'), findsOneWidget);
    expect(
      tester.widget<TextField>(field(2)).decoration!.errorText,
      'Already used',
    );
    expect(tester.widget<TextField>(field(1)).decoration!.errorText, isNull);
    expect(saveEnabled(tester), isFalse);

    // An existing heading is refused too.
    await tester.enterText(field(2), 'Speaker 1');
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(field(2)).decoration!.errorText,
      'Already used',
    );
    expect(saveEnabled(tester), isFalse);

    await tester.enterText(field(2), 'Bob');
    await tester.pumpAndSettle();
    expect(find.text('Already used'), findsNothing);
    expect(saveEnabled(tester), isTrue);
  });

  testWidgets('Save rewrites the transcript through the real LocalDb and '
      'pops true', (tester) async {
    final Harness h = await createHarness(tester);
    final DumpRow row = await seedDiarized(tester, h, 'fixture-two', twoSpeakers);
    await mount(tester, h, row);

    await tester.enterText(field(1), 'Alice');
    await tester.pumpAndSettle();
    await tester.tap(saveButton);
    await pumpBoundUntil(tester, () => h.results.isNotEmpty);
    await tester.pumpAndSettle();

    expect(h.results, <bool>[true]);
    expect(find.byKey(const ValueKey<String>('name-speakers-sheet')), findsNothing);
    expect(find.text('Speakers named'), findsOneWidget);
    final DumpRow after = await current(tester, h, row.id);
    expect(after.transcript, startsWith('## Alice\n'));
    expect(after.transcript, contains('## Speaker 2\n'));
    // Prose untouched.
    expect(after.transcript, contains('I told Speaker 1 to wait.'));
    expect(after.transcript, isNot(contains('I told Alice to wait.')));
    expect(after.syncDirty, isTrue);
  });

  testWidgets('a stale transcript shows the conflict snackbar and keeps the '
      'sheet open', (tester) async {
    final Harness h = await createHarness(tester);
    final DumpRow row = await seedDiarized(tester, h, 'fixture-two', twoSpeakers);
    await mount(tester, h, row);

    await tester.enterText(field(1), 'Alice');
    await tester.pumpAndSettle();
    // Someone else edits underneath the open sheet.
    await tester.runAsync(
      () => setTranscript(h.db, row.id, '$twoSpeakers\n\nlate addition'),
    );

    await tester.tap(saveButton);
    await pumpBoundUntil(
      tester,
      () => find.text(staleTranscriptMessage).evaluate().isNotEmpty,
    );
    await tester.pump();

    expect(h.results, isEmpty);
    expect(find.byKey(const ValueKey<String>('name-speakers-sheet')), findsOneWidget);
    expect(tester.widget<TextField>(field(1)).controller!.text, 'Alice');
    expect(saveEnabled(tester), isTrue);
    final DumpRow after = await current(tester, h, row.id);
    expect(after.transcript, '$twoSpeakers\n\nlate addition');

    // Cancel pops false.
    await tester.tap(find.byKey(const ValueKey<String>('speakers-cancel')));
    await tester.pumpAndSettle();
    expect(h.results, <bool>[false]);
  });

  testWidgets('no speakers: nothing is shown and the call resolves false',
      (tester) async {
    final Harness h = await createHarness(tester);
    final DumpRow row = await seedDiarized(tester, h, 'fixture-plain', 'just words');
    await mount(tester, h, row);

    expect(find.byKey(const ValueKey<String>('name-speakers-sheet')), findsNothing);
    expect(h.results, <bool>[false]);
  });
}
