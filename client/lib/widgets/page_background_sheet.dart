// SPDX-License-Identifier: AGPL-3.0-or-later
/// The page-background picker: a bottom sheet with one row per
/// [NotebookRuling], each previewed by the REAL painter rather than a bitmap
/// asset that could drift from what the page actually draws.
library;

import 'package:flutter/material.dart';

import '../models/notebook_ruling.dart';
import 'notebook_ink_canvas.dart';

/// Opens the picker. Resolves to the picked ruling, or null when the sheet
/// is dismissed. Dismissal must change NOTHING — the same rule as the ink
/// palette — which is the caller's contract to keep.
Future<NotebookRuling?> showPageBackgroundSheet(
  BuildContext context, {
  required NotebookRuling current,
}) =>
    showModalBottomSheet<NotebookRuling>(
      context: context,
      builder: (BuildContext context) =>
          PageBackgroundSheet(current: current),
    );

/// Five rows: preview swatch + label; the current style carries a check.
class PageBackgroundSheet extends StatelessWidget {
  const PageBackgroundSheet({required this.current, super.key});

  /// The notebook's current ruling, marked selected in the list.
  final NotebookRuling current;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (final NotebookRuling ruling in NotebookRuling.values)
            ListTile(
              key: ValueKey<String>(
                'page-background-option-${ruling.wireValue}',
              ),
              leading: _RulingSwatch(ruling: ruling),
              title: Text(ruling.label),
              trailing: ruling == current ? const Icon(Icons.check) : null,
              selected: ruling == current,
              onTap: () => Navigator.of(context).pop(ruling),
            ),
        ],
      ),
    );
  }
}

/// A miniature of the actual page: the real painter on the real page colour,
/// painted at double size and scaled to half so even a 48 px tall swatch
/// shows a few lines of every style.
class _RulingSwatch extends StatelessWidget {
  const _RulingSwatch({required this.ruling});

  final NotebookRuling ruling;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 72,
      height: 48,
      child: ClipRect(
        child: FittedBox(
          fit: BoxFit.fill,
          child: SizedBox(
            width: 144,
            height: 96,
            child: ColoredBox(
              color: NotebookInkCanvas.backgroundColor,
              child: CustomPaint(
                painter: NotebookRulingPainter(ruling: ruling),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
