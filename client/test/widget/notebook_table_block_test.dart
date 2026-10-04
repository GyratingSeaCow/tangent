// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
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

  testWidgets('vertical scrollbar thumb stays inside the rendered viewport', (
    WidgetTester tester,
  ) async {
    const NotebookTableBlock table = NotebookTableBlock(
      id: 'scrollbar-probe',
      rows: 100,
      columns: 100,
      x: 0,
      y: 0,
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.windows),
        home: const Scaffold(
          body: NotebookTableBlockWidget(
            block: table,
            onCellChanged: _ignoreCellChange,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final Finder viewport = find.byKey(
      const ValueKey<String>('notebook-table-viewport-scrollbar-probe'),
    );
    final Finder verticalScrollbar = find.byKey(
      const ValueKey<String>(
        'notebook-table-vertical-scrollbar-scrollbar-probe',
      ),
    );
    final Rect viewportRect = tester.getRect(viewport);
    final Rect scrollbarRect = tester.getRect(verticalScrollbar);
    expect(scrollbarRect, viewportRect);

    final Finder rawVerticalScrollbar = find
        .descendant(
          of: verticalScrollbar,
          matching: find.byWidgetPredicate(
            (Widget widget) => widget is RawScrollbar,
          ),
        )
        .first;
    final dynamic scrollbarState = tester.state(rawVerticalScrollbar);
    final ScrollbarPainter thumbPainter =
        scrollbarState.scrollbarPainter as ScrollbarPainter;
    Offset? thumbPoint;
    for (double y = 0; y < scrollbarRect.height; y++) {
      final Offset candidate = Offset(scrollbarRect.width - 4, y);
      if (thumbPainter.hitTestOnlyThumbInteractive(
        candidate,
        PointerDeviceKind.mouse,
      )) {
        thumbPoint = scrollbarRect.topLeft + candidate;
        break;
      }
    }
    expect(thumbPoint, isNotNull);
    expect(
      viewportRect.contains(thumbPoint!),
      isTrue,
      reason: 'the visible vertical thumb must paint inside the table window',
    );
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

void _ignoreCellChange(int row, int column, String value) {}
