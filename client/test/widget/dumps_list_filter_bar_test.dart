// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The collapsed filter bar: one row, two dropdowns (Mode, Transcript).
//
// The contract:
//  * Both dropdowns live in a SINGLE row — the two stacked chip rows are
//    gone; vertical space belongs to the list.
//  * A closed dropdown shows its active selection, so filter state stays
//    readable without opening anything.
//  * Menu items keep the historical chip keys (mode-filter-<name>,
//    transcript-filter-<name>) so every existing selector still works after
//    adding one open step.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/dump_selection_fixture.dart';

Future<void> openMenu(WidgetTester t, String anchorKey) async {
  await t.tap(find.byKey(ValueKey<String>(anchorKey)));
  await pumpSelection(t);
}

void main() {
  testWidgets('one bar, two dropdowns; closed state names the selection',
      (WidgetTester t) async {
    await mountSelection(t, CountingDeletion());

    final Finder modeAnchor = find.byKey(const ValueKey('mode-filter-menu'));
    final Finder transcriptAnchor =
        find.byKey(const ValueKey('transcript-filter-menu'));
    expect(modeAnchor, findsOneWidget);
    expect(transcriptAnchor, findsOneWidget);

    // Same row: their vertical extents overlap.
    final Rect mode = t.getRect(modeAnchor);
    final Rect transcript = t.getRect(transcriptAnchor);
    expect(
      mode.top < transcript.bottom && transcript.top < mode.bottom,
      isTrue,
      reason: 'Mode and Transcript must share one bar, not stack',
    );

    // Closed dropdowns read as their active selection.
    expect(
      find.descendant(
        of: modeAnchor,
        matching: find.text('Mode · All'),
      ),
      findsOneWidget,
    );

    // Chip-era items are NOT in the tree while the menu is closed — the
    // whole point is reclaiming that space.
    expect(find.byKey(const ValueKey('mode-filter-textNote')), findsNothing);
  });

  testWidgets('selecting from the mode menu filters and updates the label',
      (WidgetTester t) async {
    await mountSelection(t, CountingDeletion());

    await openMenu(t, 'mode-filter-menu');
    expect(find.byKey(const ValueKey('mode-filter-textNote')), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('mode-filter-textNote')));
    await pumpSelection(t);

    // Menu closed, label follows the selection.
    expect(find.byKey(const ValueKey('mode-filter-all')), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('mode-filter-menu')),
        matching: find.text('Mode · Text Note'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('transcript menu carries all five states', (WidgetTester t) async {
    await mountSelection(t, CountingDeletion());

    await openMenu(t, 'transcript-filter-menu');
    for (final String name in <String>[
      'all',
      'needsTranscript',
      'inProgress',
      'transcribed',
      'failed',
    ]) {
      expect(
        find.byKey(ValueKey<String>('transcript-filter-$name')),
        findsOneWidget,
        reason: 'transcript-filter-$name belongs in the menu',
      );
    }
  });
}
