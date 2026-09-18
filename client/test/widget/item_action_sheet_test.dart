// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/widgets/item_action_sheet.dart';

// One long-press menu for every list in the app.
//
// Long-press on a notebook used to delete it outright — a destructive action
// with no menu in between, and a different gesture contract from the dumps
// list, where long-press starts multi-select. This sheet is the shared
// vocabulary: the same actions, in the same order, with the same wording,
// wherever a list item is long-pressed.

void main() {
  // Mount a button that opens the sheet, then tap it. Driving it through a
  // real tap keeps every tester call awaited — calling showItemActionSheet
  // directly and holding its Future trips "Guarded function conflict".
  late ItemAction? chosen;
  bool resolved = false;

  Future<void> open(
    WidgetTester tester, {
    required String title,
    String? subtitle,
    required List<ItemAction> actions,
  }) async {
    chosen = null;
    resolved = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => Center(
              child: ElevatedButton(
                onPressed: () async {
                  final ItemAction? value = await showItemActionSheet(
                    context,
                    title: title,
                    subtitle: subtitle,
                    actions: actions,
                  );
                  chosen = value;
                  resolved = true;
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  group('item action sheet', () {
    testWidgets('shows the item name as the heading', (tester) async {
      await open(
        tester,
        title: 'Meeting notes',
        subtitle: 'Edited 2 hours ago',
        actions: const <ItemAction>[ItemAction.rename, ItemAction.delete],
      );

      expect(find.text('Meeting notes'), findsOneWidget);
      expect(find.text('Edited 2 hours ago'), findsOneWidget);

      await tester.tap(find.byKey(ItemActionSheet.keyFor(ItemAction.delete)));
      await tester.pumpAndSettle();
      expect(resolved, isTrue);
      expect(chosen, ItemAction.delete);
    });

    testWidgets('renders only the actions it was given', (tester) async {
      await open(
        tester,
        title: 'A dump',
        actions: const <ItemAction>[ItemAction.rename, ItemAction.select],
      );
      await tester.pumpAndSettle();

      expect(find.text('Rename'), findsOneWidget);
      expect(find.text('Select'), findsOneWidget);
      expect(find.text('Delete'), findsNothing);
      expect(find.text('Move to folder'), findsNothing);

      await tester.tap(find.byKey(ItemActionSheet.keyFor(ItemAction.rename)));
      await tester.pumpAndSettle();
      expect(resolved, isTrue);
      expect(chosen, ItemAction.rename);
    });

    testWidgets('dismissing returns null rather than an action',
        (tester) async {
      await open(
        tester,
        title: 'A notebook',
        actions: const <ItemAction>[ItemAction.rename, ItemAction.delete],
      );
      await tester.pumpAndSettle();

      // Tap the scrim above the sheet.
      await tester.tapAt(const Offset(200, 20));
      await tester.pumpAndSettle();
      expect(resolved, isTrue);
      expect(chosen, isNull);
    });

    testWidgets('delete is styled as destructive and ordered last',
        (tester) async {
      await open(
        tester,
        title: 'A notebook',
        actions: const <ItemAction>[
          ItemAction.delete,
          ItemAction.rename,
          ItemAction.move,
        ],
      );
      await tester.pumpAndSettle();

      // Regardless of the order requested, destructive actions sink to the
      // bottom so a long-press never lands on Delete by muscle memory.
      final double renameY =
          tester.getCenter(find.byKey(ItemActionSheet.keyFor(ItemAction.rename))).dy;
      final double moveY =
          tester.getCenter(find.byKey(ItemActionSheet.keyFor(ItemAction.move))).dy;
      final double deleteY =
          tester.getCenter(find.byKey(ItemActionSheet.keyFor(ItemAction.delete))).dy;
      expect(renameY, lessThan(deleteY));
      expect(moveY, lessThan(deleteY));

      final Text deleteLabel = tester.widget<Text>(
        find.descendant(
          of: find.byKey(ItemActionSheet.keyFor(ItemAction.delete)),
          matching: find.text('Delete'),
        ),
      );
      expect(
        deleteLabel.style?.color,
        Colors.red.shade400,
        reason: 'destructive actions must read as destructive',
      );

      await tester.tapAt(const Offset(200, 20));
      await tester.pumpAndSettle();
      expect(resolved, isTrue);
      expect(chosen, isNull);
    });

    testWidgets('every action has a stable key and a label', (tester) async {
      await open(
        tester,
        title: 'Everything',
        actions: ItemAction.values,
      );
      await tester.pumpAndSettle();

      for (final ItemAction action in ItemAction.values) {
        // The full list scrolls on a short screen, so bring each row into view
        // before asserting on it.
        await tester.scrollUntilVisible(
          find.byKey(ItemActionSheet.keyFor(action)),
          80,
          scrollable: find.byType(Scrollable).last,
        );
        expect(
          find.byKey(ItemActionSheet.keyFor(action)),
          findsOneWidget,
          reason: '$action must render',
        );
        expect(
          find.text(ItemActionSheet.labelFor(action)),
          findsOneWidget,
          reason: '$action needs a human label',
        );
      }

      await tester.tapAt(const Offset(200, 20));
      await tester.pumpAndSettle();
      expect(resolved, isTrue);
      expect(chosen, isNull);
    });
  });
}
