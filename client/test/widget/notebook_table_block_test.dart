// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/models/notebook.dart';
import 'package:tangent/widgets/notebook_table_block.dart';

void main() {
  test('100x100 paint window visits only visible rows and columns', () {
    final NotebookTableCellRange range = visibleNotebookTableCells(
      clip: const Rect.fromLTWH(0, 0, 600, 352),
      rows: 100,
      columns: 100,
    );
    final int painted =
        (range.lastRow - range.firstRow + 1) *
        (range.lastColumn - range.firstColumn + 1);

    expect(range.firstRow, 0);
    expect(range.lastRow, 7);
    expect(range.firstColumn, 0);
    expect(range.lastColumn, 4);
    expect(painted, 40);
    expect(painted, lessThan(10000));
  });

  testWidgets('100x100 table mounts at most the active cell TextField', (
    WidgetTester tester,
  ) async {
    NotebookTableBlock table = const NotebookTableBlock(
      id: 'large-table',
      rows: 100,
      columns: 100,
      x: 0,
      y: 0,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (BuildContext context, StateSetter setState) =>
                NotebookTableBlockWidget(
                  block: table,
                  onCellChanged: (int row, int column, String value) {
                    setState(
                      () => table = table.copyWithCell(row, column, value),
                    );
                  },
                ),
          ),
        ),
      ),
    );

    expect(find.byType(TextField), findsNothing);
    expect(find.byType(CustomPaint), findsWidgets);

    final Finder grid = find.byKey(
      const ValueKey('notebook-table-grid-large-table'),
    );
    await tester.tapAt(tester.getTopLeft(grid) + const Offset(20, 20));
    await tester.pump();

    expect(find.byType(TextField), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'visible cell');
    await tester.pump();

    expect(table.cellAt(0, 0), 'visible cell');
    expect(find.byType(TextField), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
