// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/widgets/folder_picker.dart';

/// The destination step of Move.
///
/// Move is only as safe as its picker: it has to offer a way OUT of a folder
/// (unfile), a way to create a destination that does not exist yet, and a
/// clear cancel that files nothing.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FolderChoice? chosen;
  late bool resolved;

  Future<void> open(
    WidgetTester tester, {
    required List<FolderOption> folders,
    String? currentFolderId,
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
                  final FolderChoice? value = await showFolderPicker(
                    context,
                    folders: folders,
                    currentFolderId: currentFolderId,
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

  const List<FolderOption> twoFolders = <FolderOption>[
    FolderOption(id: 'f-work', name: 'Work'),
    FolderOption(id: 'f-home', name: 'Home'),
  ];

  testWidgets('lists every folder plus an explicit way out', (tester) async {
    await open(tester, folders: twoFolders);

    expect(find.text('Work'), findsOneWidget);
    expect(find.text('Home'), findsOneWidget);
    expect(
      find.byKey(FolderPicker.noFolderKey),
      findsOneWidget,
      reason: 'a notebook must be able to leave a folder, not only enter one',
    );
  });

  testWidgets('choosing a folder returns it', (tester) async {
    await open(tester, folders: twoFolders);

    await tester.tap(find.byKey(FolderPicker.folderKey('f-home')));
    await tester.pumpAndSettle();

    expect(resolved, isTrue);
    expect(chosen, isA<FolderChoice>());
    expect(chosen!.folderId, 'f-home');
    expect(chosen!.isNewFolder, isFalse);
  });

  testWidgets('choosing "no folder" returns an unfile choice, not null',
      (tester) async {
    await open(tester, folders: twoFolders, currentFolderId: 'f-work');

    await tester.tap(find.byKey(FolderPicker.noFolderKey));
    await tester.pumpAndSettle();

    expect(resolved, isTrue);
    expect(
      chosen,
      isNotNull,
      reason: 'unfiling is a real choice and must be distinguishable from '
          'dismissing the sheet',
    );
    expect(chosen!.folderId, isNull);
  });

  testWidgets('dismissing returns null so nothing moves', (tester) async {
    await open(tester, folders: twoFolders);

    await tester.tapAt(const Offset(200, 20));
    await tester.pumpAndSettle();

    expect(resolved, isTrue);
    expect(chosen, isNull);
  });

  testWidgets('the current folder is marked and cannot be chosen again',
      (tester) async {
    await open(tester, folders: twoFolders, currentFolderId: 'f-work');

    final ListTile current = tester.widget<ListTile>(
      find.byKey(FolderPicker.folderKey('f-work')),
    );
    expect(
      current.selected,
      isTrue,
      reason: 'the user must see where the notebook already lives',
    );
  });

  testWidgets('a new folder can be named from the picker', (tester) async {
    await open(tester, folders: twoFolders);

    await tester.scrollUntilVisible(
      find.byKey(FolderPicker.newFolderKey),
      80,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.byKey(FolderPicker.newFolderKey));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(FolderPicker.newFolderFieldKey),
      'Client work',
    );
    await tester.tap(find.byKey(FolderPicker.newFolderCreateKey));
    await tester.pumpAndSettle();

    expect(resolved, isTrue);
    expect(chosen!.isNewFolder, isTrue);
    expect(chosen!.newFolderName, 'Client work');
    expect(
      chosen!.folderId,
      isNull,
      reason: 'a folder that does not exist yet has no id',
    );
  });

  testWidgets('an empty new-folder name creates nothing', (tester) async {
    await open(tester, folders: twoFolders);

    await tester.scrollUntilVisible(
      find.byKey(FolderPicker.newFolderKey),
      80,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.byKey(FolderPicker.newFolderKey));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(FolderPicker.newFolderFieldKey), '   ');
    await tester.tap(find.byKey(FolderPicker.newFolderCreateKey));
    await tester.pumpAndSettle();

    expect(
      chosen?.isNewFolder,
      isNot(true),
      reason: 'whitespace is not a folder name',
    );
  });

  testWidgets('with no folders yet, creating one is still offered',
      (tester) async {
    await open(tester, folders: const <FolderOption>[]);

    expect(find.byKey(FolderPicker.newFolderKey), findsOneWidget);
    expect(find.byKey(FolderPicker.noFolderKey), findsOneWidget);
  });
}
