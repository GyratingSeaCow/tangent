// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/notebook.dart';
import 'notebook_ink_canvas.dart';

/// The row/column window intersecting a paint clip.
typedef NotebookTableCellRange = ({
  int firstRow,
  int lastRow,
  int firstColumn,
  int lastColumn,
});

/// Returns only the cells intersecting [clip].
///
/// The table painter uses this directly, so a 100x100 model still visits only
/// the handful of cells visible through the two-dimensional scroll viewport.
NotebookTableCellRange visibleNotebookTableCells({
  required Rect clip,
  required int rows,
  required int columns,
}) {
  final int firstRow = (clip.top / kNotebookTableCellHeight).floor().clamp(
    0,
    rows - 1,
  );
  final int lastRow = ((clip.bottom - 0.001) / kNotebookTableCellHeight)
      .floor()
      .clamp(0, rows - 1);
  final int firstColumn = (clip.left / kNotebookTableCellWidth).floor().clamp(
    0,
    columns - 1,
  );
  final int lastColumn = ((clip.right - 0.001) / kNotebookTableCellWidth)
      .floor()
      .clamp(0, columns - 1);
  return (
    firstRow: firstRow,
    lastRow: lastRow,
    firstColumn: firstColumn,
    lastColumn: lastColumn,
  );
}

/// A two-dimensionally virtualized notebook table.
///
/// The grid is a single [CustomPaint]. Painting is clipped to visible rows and
/// columns, and exactly one [TextField] is mounted while a cell is being edited.
/// Cell data remains in [NotebookTableBlock], not in disposable controllers.
class NotebookTableBlockWidget extends StatefulWidget {
  const NotebookTableBlockWidget({
    required this.block,
    required this.onCellChanged,
    super.key,
  });

  final NotebookTableBlock block;
  final void Function(int row, int column, String value) onCellChanged;

  @override
  State<NotebookTableBlockWidget> createState() =>
      _NotebookTableBlockWidgetState();
}

class _NotebookTableBlockWidgetState extends State<NotebookTableBlockWidget> {
  final ScrollController _horizontal = ScrollController();
  final ScrollController _vertical = ScrollController();
  TextEditingController? _editor;
  FocusNode? _editorFocus;
  int? _editingRow;
  int? _editingColumn;

  @override
  void didUpdateWidget(covariant NotebookTableBlockWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.block.id != widget.block.id ||
        oldWidget.block.rows != widget.block.rows ||
        oldWidget.block.columns != widget.block.columns) {
      _clearEditor();
    }
  }

  @override
  void dispose() {
    _horizontal.dispose();
    _vertical.dispose();
    _editor?.dispose();
    _editorFocus?.dispose();
    super.dispose();
  }

  void _clearEditor() {
    _editor?.dispose();
    _editorFocus?.dispose();
    _editor = null;
    _editorFocus = null;
    _editingRow = null;
    _editingColumn = null;
  }

  void _editCell(Offset position) {
    final int row = (position.dy / kNotebookTableCellHeight).floor().clamp(
      0,
      widget.block.rows - 1,
    );
    final int column = (position.dx / kNotebookTableCellWidth).floor().clamp(
      0,
      widget.block.columns - 1,
    );
    if (_editingRow == row && _editingColumn == column) {
      _editorFocus?.requestFocus();
      return;
    }
    _clearEditor();
    setState(() {
      _editingRow = row;
      _editingColumn = column;
      _editor = TextEditingController(text: widget.block.cellAt(row, column));
      _editorFocus = FocusNode();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _editorFocus?.requestFocus();
    });
  }

  @override
  Widget build(BuildContext context) {
    final NotebookTableBlock block = widget.block;
    final int? editingRow = _editingRow;
    final int? editingColumn = _editingColumn;
    return SizedBox(
      key: ValueKey<String>('notebook-table-${block.id}'),
      width: block.viewportWidth,
      height: block.viewportHeight,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(
            color: NotebookInkCanvas.inkColor.withValues(alpha: 0.65),
          ),
          color: NotebookInkCanvas.backgroundColor,
        ),
        child: ClipRect(
          key: ValueKey<String>('notebook-table-viewport-${block.id}'),
          child: Scrollbar(
            key: ValueKey<String>(
              'notebook-table-vertical-scrollbar-${block.id}',
            ),
            controller: _vertical,
            thumbVisibility: block.contentHeight > block.viewportHeight,
            notificationPredicate: (ScrollNotification notification) =>
                notification.metrics.axis == Axis.vertical,
            child: Scrollbar(
              key: ValueKey<String>(
                'notebook-table-horizontal-scrollbar-${block.id}',
              ),
              controller: _horizontal,
              thumbVisibility: block.contentWidth > block.viewportWidth,
              notificationPredicate: (ScrollNotification notification) =>
                  notification.metrics.axis == Axis.horizontal,
              child: SingleChildScrollView(
                controller: _horizontal,
                scrollDirection: Axis.horizontal,
                child: SizedBox(
                  width: block.contentWidth,
                  height: block.viewportHeight,
                  child: SingleChildScrollView(
                    controller: _vertical,
                    child: SizedBox(
                      width: block.contentWidth,
                      height: block.contentHeight,
                      child: Stack(
                        children: <Widget>[
                          GestureDetector(
                            key: ValueKey<String>(
                              'notebook-table-grid-${block.id}',
                            ),
                            behavior: HitTestBehavior.opaque,
                            onTapDown: (TapDownDetails details) =>
                                _editCell(details.localPosition),
                            child: CustomPaint(
                              size: Size(
                                block.contentWidth,
                                block.contentHeight,
                              ),
                              painter: NotebookTablePainter(
                                block: block,
                                horizontal: _horizontal,
                                vertical: _vertical,
                              ),
                            ),
                          ),
                          if (editingRow != null && editingColumn != null)
                            Positioned(
                              left: editingColumn * kNotebookTableCellWidth,
                              top: editingRow * kNotebookTableCellHeight,
                              width: kNotebookTableCellWidth,
                              height: kNotebookTableCellHeight,
                              child: TextField(
                                key: ValueKey<String>(
                                  'notebook-table-cell-editor-${block.id}-'
                                  '$editingRow-$editingColumn',
                                ),
                                controller: _editor,
                                focusNode: _editorFocus,
                                maxLines: 1,
                                style: const TextStyle(
                                  color: NotebookInkCanvas.inkColor,
                                  fontSize: 14,
                                ),
                                cursorColor: NotebookInkCanvas.inkColor,
                                decoration: InputDecoration(
                                  filled: true,
                                  fillColor: const Color(0xFF181818),
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 10,
                                  ),
                                  enabledBorder: const OutlineInputBorder(
                                    borderSide: BorderSide(
                                      color: NotebookInkCanvas.inkColor,
                                      width: 2,
                                    ),
                                    borderRadius: BorderRadius.zero,
                                  ),
                                  focusedBorder: OutlineInputBorder(
                                    borderSide: BorderSide(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.primary,
                                      width: 2,
                                    ),
                                    borderRadius: BorderRadius.zero,
                                  ),
                                ),
                                onChanged: (String value) =>
                                    widget.onCellChanged(
                                      editingRow,
                                      editingColumn,
                                      value,
                                    ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Paints only the table cells intersecting the scroll viewport.
class NotebookTablePainter extends CustomPainter {
  NotebookTablePainter({
    required this.block,
    required ScrollController horizontal,
    required ScrollController vertical,
  }) : _horizontal = horizontal,
       _vertical = vertical,
       super(repaint: Listenable.merge(<Listenable>[horizontal, vertical]));

  final NotebookTableBlock block;
  final ScrollController _horizontal;
  final ScrollController _vertical;

  NotebookTableCellRange? _debugLastVisibleRange;
  Rect? _debugLastViewport;
  int _debugLastVisitedCellCount = 0;

  /// The row and column window visited by the most recent paint.
  @visibleForTesting
  NotebookTableCellRange? get debugLastVisibleRange => _debugLastVisibleRange;

  /// The actual scroll window used by the most recent paint.
  @visibleForTesting
  Rect? get debugLastViewport => _debugLastViewport;

  /// The number of cells visited by the most recent paint.
  @visibleForTesting
  int get debugLastVisitedCellCount => _debugLastVisitedCellCount;

  @override
  void paint(Canvas canvas, Size size) {
    _debugLastVisibleRange = null;
    _debugLastViewport = null;
    _debugLastVisitedCellCount = 0;
    final ScrollPosition? horizontalPosition = _horizontal.hasClients
        ? _horizontal.position
        : null;
    final ScrollPosition? verticalPosition = _vertical.hasClients
        ? _vertical.position
        : null;
    final double horizontalOffset = horizontalPosition?.pixels ?? 0;
    final double verticalOffset = verticalPosition?.pixels ?? 0;
    final Rect viewport = Rect.fromLTWH(
      horizontalOffset,
      verticalOffset,
      horizontalPosition?.viewportDimension ?? size.width,
      verticalPosition?.viewportDimension ?? size.height,
    ).intersect(Offset.zero & size);
    _debugLastViewport = viewport;
    if (viewport.isEmpty) return;
    final NotebookTableCellRange range = visibleNotebookTableCells(
      clip: viewport,
      rows: block.rows,
      columns: block.columns,
    );
    _debugLastVisibleRange = range;
    final Paint border = Paint()
      ..color = NotebookInkCanvas.inkColor.withValues(alpha: 0.4)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final Paint alternate = Paint()
      ..color = NotebookInkCanvas.inkColor.withValues(alpha: 0.035);

    for (int row = range.firstRow; row <= range.lastRow; row++) {
      for (
        int column = range.firstColumn;
        column <= range.lastColumn;
        column++
      ) {
        _debugLastVisitedCellCount++;
        final Rect cell = Rect.fromLTWH(
          column * kNotebookTableCellWidth,
          row * kNotebookTableCellHeight,
          kNotebookTableCellWidth,
          kNotebookTableCellHeight,
        );
        if (row.isOdd) canvas.drawRect(cell, alternate);
        canvas.drawRect(cell, border);
        final String text = block.cellAt(row, column);
        if (text.isEmpty) continue;
        final TextPainter painter = TextPainter(
          text: TextSpan(
            text: text,
            style: const TextStyle(
              color: NotebookInkCanvas.inkColor,
              fontSize: 14,
            ),
          ),
          textDirection: TextDirection.ltr,
          maxLines: 1,
          ellipsis: '…',
        )..layout(maxWidth: math.max(0, kNotebookTableCellWidth - 16));
        painter.paint(
          canvas,
          Offset(cell.left + 8, cell.top + (cell.height - painter.height) / 2),
        );
        painter.dispose();
      }
    }
  }

  // The paint canvas keeps the full content size while an ancestor can change
  // the scroll viewport (for example when draw mode hides the drag grip).
  // Repaint on rebuild so [paint] samples the post-layout ScrollPositions.
  @override
  bool shouldRepaint(covariant NotebookTablePainter oldDelegate) => true;
}
