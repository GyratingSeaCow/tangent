// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Notebook -> PDF.
//
// The page is a raster of exactly what the editor shows — ink drawn by the
// SAME NotebookInkPainter the canvas uses (so pen styles, fountain taper and
// the italic nib export pixel-true), text and dump blocks drawn at their
// canvas positions. Vectorising the strokes separately would inevitably
// drift from the on-screen renderer; fidelity beats file size here.
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../models/notebook.dart';
import '../widgets/notebook_ink_canvas.dart';

/// Everything the exporter needs to know about one notebook.
class NotebookExportSource {
  const NotebookExportSource({
    required this.title,
    required this.document,
    required this.strokes,
  });

  final String title;
  final NotebookDocument document;
  final List<InkStroke> strokes;
}

/// Nominal footprint used for blocks without a measured size — the same
/// numbers the lasso uses for block hit-testing.
const Size _kBlockFallbackSize = Size(300, 90);

/// Renders [source] to a single-page PDF and returns its bytes.
///
/// The content bounding box (ink + blocks, plus padding) decides the page
/// size, so a small sketch exports small and a sprawling canvas exports
/// whole — nothing is cropped to a viewport the exporter cannot see.
Future<Uint8List> renderNotebookPdf(NotebookExportSource source) async {
  final ui.Rect bounds = _contentBounds(source);
  // Rasterise at 2x for crisp print; PDF page keeps logical size.
  const double scale = 2;
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final ui.Canvas canvas = ui.Canvas(recorder);
  canvas.scale(scale);
  canvas.translate(-bounds.left, -bounds.top);

  // The editor's background: the notebook look IS white ink on black.
  canvas.drawRect(
    bounds.inflate(1),
    ui.Paint()..color = NotebookInkCanvas.backgroundColor,
  );

  NotebookInkPainter(
    strokes: source.strokes,
    activeStroke: null,
    revision: 0,
  ).paint(canvas, bounds.size);

  _paintBlocks(canvas, source.document);

  final ui.Picture picture = recorder.endRecording();
  final ui.Image image = await picture.toImage(
    (bounds.width * scale).ceil().clamp(1, 8000),
    (bounds.height * scale).ceil().clamp(1, 8000),
  );
  final ByteData? png = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  if (png == null) {
    throw StateError('Could not encode the notebook image');
  }

  final pw.Document pdf = pw.Document(title: source.title);
  final pw.MemoryImage pageImage = pw.MemoryImage(png.buffer.asUint8List());
  pdf.addPage(
    pw.Page(
      pageFormat: PdfPageFormat(
        bounds.width + 2 * _kPagePad,
        bounds.height + 2 * _kPagePad + _kTitleBand,
      ),
      build: (pw.Context context) => pw.Padding(
        padding: const pw.EdgeInsets.all(_kPagePad),
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: <pw.Widget>[
            pw.Text(
              source.title.isEmpty ? '(untitled)' : source.title,
              style: pw.TextStyle(
                fontSize: 14,
                fontWeight: pw.FontWeight.bold,
              ),
            ),
            pw.SizedBox(height: 8),
            pw.Expanded(
              child: pw.Image(pageImage, fit: pw.BoxFit.contain),
            ),
          ],
        ),
      ),
    ),
  );
  return pdf.save();
}

const double _kPagePad = 24;
const double _kTitleBand = 30;

/// Union of every stroke point and block footprint, padded, never empty.
ui.Rect _contentBounds(NotebookExportSource source) {
  double? left, top, right, bottom;
  void include(double x, double y) {
    left = left == null ? x : (x < left! ? x : left);
    top = top == null ? y : (y < top! ? y : top);
    right = right == null ? x : (x > right! ? x : right);
    bottom = bottom == null ? y : (y > bottom! ? y : bottom);
  }

  for (final InkStroke stroke in source.strokes) {
    for (final InkPoint point in stroke.points) {
      include(point.x, point.y);
    }
  }
  double fallbackY = 0;
  for (final NotebookBlock block in source.document.blocks) {
    final (double x, double y) = switch (block) {
      NotebookTextBlock(:final double? x, :final double? y) => (
          x ?? 16,
          y ?? fallbackY
        ),
      NotebookCheckboxBlock(:final double? x, :final double? y) => (
          x ?? 16,
          y ?? fallbackY
        ),
      NotebookDumpCardBlock(:final double x, :final double y) => (x, y),
      NotebookImageBlock(:final double x, :final double y) => (x, y),
      NotebookUnknownBlock() => (16, fallbackY),
    };
    fallbackY += _kBlockFallbackSize.height + 12;
    include(x, y);
    include(x + _kBlockFallbackSize.width, y + _kBlockFallbackSize.height);
    // An image's real footprint can exceed the nominal block size.
    if (block is NotebookImageBlock) {
      include(block.x + block.width, block.y + block.height);
    }
  }

  if (left == null) {
    // An empty notebook still exports: one blank card-sized page.
    return const ui.Rect.fromLTWH(0, 0, 400, 300);
  }
  return ui.Rect.fromLTRB(left!, top!, right!, bottom!).inflate(20);
}

/// Text and dump blocks, drawn like the editor draws them: a rounded card
/// with the block's text (or the dump's title line) inside.
void _paintBlocks(ui.Canvas canvas, NotebookDocument document) {
  double fallbackY = 0;
  for (final NotebookBlock block in document.blocks) {
    final (String text, double? bx, double? by) = switch (block) {
      NotebookTextBlock(
        :final String text,
        :final double? x,
        :final double? y
      ) =>
        (text, x, y),
      NotebookCheckboxBlock(
        :final String text,
        :final bool checked,
        :final double? x,
        :final double? y
      ) =>
        ('${checked ? '\u2611' : '\u2610'} $text', x, y),
      // The dump's title lives in another table; the export marks the spot.
      NotebookDumpCardBlock(:final double x, :final double y) => (
          '\u{1F399} Recording',
          x,
          y
        ),
      // Decoding bytes to a ui.Image is async and this painter is not;
      // the export marks the picture's place and true footprint for now.
      NotebookImageBlock(:final double x, :final double y) => (
          '\u{1F5BC} Picture',
          x,
          y
        ),
      NotebookUnknownBlock() => ('', null, null),
    };
    if (block is NotebookUnknownBlock) continue;
    final double x = bx ?? 16;
    final double y = by ?? fallbackY;
    fallbackY += _kBlockFallbackSize.height + 12;

    final TextPainter painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: NotebookInkCanvas.inkColor,
          fontSize: 14,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 4,
      ellipsis: '\u2026',
    )..layout(maxWidth: _kBlockFallbackSize.width - 24);

    final ui.Rect card = ui.Rect.fromLTWH(
      x,
      y,
      _kBlockFallbackSize.width,
      (painter.height + 24).clamp(48, _kBlockFallbackSize.height).toDouble(),
    );
    canvas.drawRRect(
      ui.RRect.fromRectAndRadius(card, const ui.Radius.circular(8)),
      ui.Paint()
        ..color = NotebookInkCanvas.inkColor.withValues(alpha: 0.4)
        ..style = ui.PaintingStyle.stroke
        ..strokeWidth = 1,
    );
    painter.paint(canvas, ui.Offset(x + 12, y + 12));
    painter.dispose();
  }
}
