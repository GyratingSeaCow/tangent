// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Disabled actions in the shared long-press sheet.
//
// Recordings are not always safe to delete: one that is syncing, publishing or
// already being deleted is guarded by the storage layer's eligibility rules.
// The sheet must respect that WITHOUT silently hiding the action, because an
// action that vanishes reads as a bug ("where did Delete go?") while a
// disabled action with a reason teaches the user what the app is doing.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/widgets/item_action_sheet.dart';

void main() {
  Future<ItemAction?> openSheet(
    WidgetTester tester, {
    required List<ItemAction> actions,
    Map<ItemAction, String> disabled = const <ItemAction, String>{},
  }) async {
    ItemAction? chosen;
    bool resolved = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => ElevatedButton(
              onPressed: () async {
                chosen = await showItemActionSheet(
                  context,
                  title: 'Morning notes',
                  actions: actions,
                  disabledActions: disabled,
                );
                resolved = true;
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(resolved, isFalse, reason: 'sheet should still be open');
    return chosen;
  }

  testWidgets('a disabled action is still shown, not hidden', (tester) async {
    await openSheet(
      tester,
      actions: <ItemAction>[ItemAction.open, ItemAction.delete],
      disabled: <ItemAction, String>{ItemAction.delete: 'Syncing'},
    );

    expect(
      find.byKey(ItemActionSheet.keyFor(ItemAction.delete)),
      findsOneWidget,
      reason: 'hiding Delete makes the app look broken; disable it instead',
    );
  });

  testWidgets('a disabled action explains why', (tester) async {
    await openSheet(
      tester,
      actions: <ItemAction>[ItemAction.open, ItemAction.delete],
      disabled: <ItemAction, String>{
        ItemAction.delete: 'Still uploading to the server',
      },
    );

    expect(
      find.text('Still uploading to the server'),
      findsOneWidget,
      reason: 'a greyed-out row with no reason is indistinguishable from a bug',
    );
  });

  testWidgets('tapping a disabled action does nothing', (tester) async {
    // Note on verification: the sheet guards this twice — ListTile(enabled:
    // false) AND a null onTap. Removing either one alone still passes, because
    // either is sufficient on its own; removing BOTH fails this test. That is
    // deliberate redundancy on a destructive action, not an untested path.
    bool resolved = false;
    ItemAction? chosen;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => ElevatedButton(
              onPressed: () async {
                chosen = await showItemActionSheet(
                  context,
                  title: 'Morning notes',
                  actions: <ItemAction>[ItemAction.open, ItemAction.delete],
                  disabledActions: <ItemAction, String>{
                    ItemAction.delete: 'Syncing',
                  },
                );
                resolved = true;
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(ItemActionSheet.keyFor(ItemAction.delete)));
    await tester.pumpAndSettle();

    expect(
      resolved,
      isFalse,
      reason: 'a disabled Delete must not close the sheet or resolve',
    );
    expect(chosen, isNull);

    // The enabled action still works, proving the sheet is not simply inert.
    await tester.tap(find.byKey(ItemActionSheet.keyFor(ItemAction.open)));
    await tester.pumpAndSettle();
    expect(resolved, isTrue);
    expect(chosen, ItemAction.open);
  });

  testWidgets('an enabled action carries no reason text', (tester) async {
    await openSheet(
      tester,
      actions: <ItemAction>[ItemAction.open, ItemAction.delete],
    );

    expect(find.text('Syncing'), findsNothing);
    expect(
      find.byKey(ItemActionSheet.keyFor(ItemAction.delete)),
      findsOneWidget,
    );
  });
}
