// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Notebook -> PDF.
//
// The page is a raster of exactly what the editor shows — ink drawn by the
// SAME NotebookInkPainter the canvas uses (so pen styles, fountain taper and
// the italic nib export pixel-true), text and dump blocks drawn at their
// canvas positions. Vectorising the strokes separately would inevitably
// drift from the on-screen renderer; fidelity beats file size here.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../models/notebook.dart';
import '../widgets/notebook_ink_canvas.dart';
import 'notebook_pdf_import.dart';

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
Future<Uint8List> renderNotebookPdf(
  NotebookExportSource source, {
  PdfPageRasterLoader? pdfPageLoader,
}) async {
  final List<NotebookPdfPageBlock> pdfPages = source.document.blocks
      .whereType<NotebookPdfPageBlock>()
      .toList(growable: false);
  if (pdfPages.isNotEmpty) {
    return _renderImportedPdfPages(
      source,
      pdfPages,
      pdfPageLoader ?? NotebookPdfPageCache(),
    );
  }
  final ui.Rect bounds = _contentBounds(source);
  // Image bytes are decoded UP FRONT (the block painter is synchronous);
  // a block whose bytes fail to decode simply has no entry here and keeps
  // the text placeholder instead of killing the whole export.
  final Map<String, ui.Image> images = await _decodeImages(source.document);
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

  _paintBlocks(canvas, source.document, images);

  final ui.Picture picture = recorder.endRecording();
  final ui.Image image = await picture.toImage(
    (bounds.width * scale).ceil().clamp(1, 8000),
    (bounds.height * scale).ceil().clamp(1, 8000),
  );
  for (final ui.Image decoded in images.values) {
    decoded.dispose();
  }
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

/// Re-exports imported pages as real PDF pages in notebook block order.
///
/// Each source page is read from the disk-backed raster cache one at a time,
/// composited with the shared ink painter clipped to that page's canvas rect,
/// added to the output, then disposed before the next page starts. A 100-page
/// document therefore never holds 100 decoded page images in RAM.
Future<Uint8List> _renderImportedPdfPages(
  NotebookExportSource source,
  List<NotebookPdfPageBlock> pages,
  PdfPageRasterLoader loader,
) async {
  final pw.Document pdf = pw.Document(title: source.title);
  final Map<String, ui.Image> images = await _decodeImages(source.document);
  for (final NotebookPdfPageBlock page in pages) {
    final String? sourceData = pdfSourceDataFor(page, source.document.blocks);
    if (sourceData == null) {
      throw StateError('PDF source is unavailable for page ${page.pageNumber}');
    }
    final int pixelWidth = (page.width * 2).ceil().clamp(1, 8000);
    final int pixelHeight = (page.height * 2).ceil().clamp(1, 8000);
    final File rasterFile = await loader.loadPage(
      sourceData: sourceData,
      pageNumber: page.pageNumber,
      width: pixelWidth,
      height: pixelHeight,
    );
    final Uint8List rasterBytes = await rasterFile.readAsBytes();
    final Uint8List annotated = await _annotatePdfPage(
      source: source,
      page: page,
      rasterBytes: rasterBytes,
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
      images: images,
    );
    final pw.MemoryImage image = pw.MemoryImage(annotated);
    pdf.addPage(
      pw.Page(
        pageFormat: PdfPageFormat(page.width, page.height, marginAll: 0),
        build: (_) => pw.Image(
          image,
          width: page.width,
          height: page.height,
          fit: pw.BoxFit.fill,
        ),
      ),
    );
  }
  for (final ui.Image decoded in images.values) {
    decoded.dispose();
  }
  return pdf.save();
}

Future<Uint8List> _annotatePdfPage({
  required NotebookExportSource source,
  required NotebookPdfPageBlock page,
  required Uint8List rasterBytes,
  required int pixelWidth,
  required int pixelHeight,
  required Map<String, ui.Image> images,
}) async {
  final ui.Codec codec = await ui.instantiateImageCodec(rasterBytes);
  final ui.FrameInfo frame = await codec.getNextFrame();
  codec.dispose();
  final ui.Image sourceImage = frame.image;
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final ui.Canvas canvas = ui.Canvas(recorder);
  canvas.scale(2);
  canvas.drawImageRect(
    sourceImage,
    ui.Rect.fromLTWH(
      0,
      0,
      sourceImage.width.toDouble(),
      sourceImage.height.toDouble(),
    ),
    ui.Rect.fromLTWH(0, 0, page.width, page.height),
    ui.Paint()..filterQuality = ui.FilterQuality.medium,
  );
  sourceImage.dispose();
  canvas.save();
  canvas.clipRect(ui.Rect.fromLTWH(0, 0, page.width, page.height));
  canvas.translate(-page.x, -page.y);
  _paintBlocks(canvas, source.document, images);
  NotebookInkPainter(
    strokes: source.strokes,
    activeStroke: null,
    revision: 0,
  ).paint(canvas, ui.Size(page.width, page.height));
  canvas.restore();
  final ui.Image composed = await recorder.endRecording().toImage(
    pixelWidth,
    pixelHeight,
  );
  final ByteData? png = await composed.toByteData(
    format: ui.ImageByteFormat.png,
  );
  composed.dispose();
  if (png == null) throw StateError('Could not encode annotated PDF page');
  return png.buffer.asUint8List();
}

const double _kPagePad = 24;
const double _kTitleBand = 30;

/// Decodes every image block's bytes to a [ui.Image], keyed by block id.
///
/// Corrupt bytes (a failed base64 or codec) skip the block instead of
/// throwing: one damaged picture must not lose the rest of the page, and
/// [_paintBlocks] keeps the text placeholder for any id missing here.
Future<Map<String, ui.Image>> _decodeImages(NotebookDocument document) async {
  final Map<String, ui.Image> images = <String, ui.Image>{};
  for (final NotebookBlock block in document.blocks) {
    if (block is! NotebookImageBlock) continue;
    try {
      final Uint8List bytes = base64Decode(block.data);
      final ui.Codec codec = await ui.instantiateImageCodec(bytes);
      final ui.FrameInfo frame = await codec.getNextFrame();
      codec.dispose();
      images[block.id] = frame.image;
    } catch (_) {
      // Undecodable: fall back to this block's placeholder.
    }
  }
  return images;
}

/// Union of every stroke point and block footprint, padded, never empty.
ui.Rect _contentBounds(NotebookExportSource source) {
  double? left, top, right, bottom;
  void include(double x, double y) {
    left = left == null ? x : (x < left! ? x : left);
    top = top == null ? y : (y < top! ? y : top);
    right = right == null ? x : (x > right! ? x : right);
    bottom = bottom == null ? y : (y > bottom! ? y : bottom);
  }

  // Base padding. Ample for any pen (the slider tops out at 24, so even a
  // fountain swell stays inside), but a highlighter's band is
  // width * kHighlighterWidthFactor — its half-band overhangs a flat 20 well
  // before the slider's maximum, and a wide mark at the content edge was
  // clipped. Pad for the widest band on the page instead, never less than 20.
  double pad = 20;
  for (final InkStroke stroke in source.strokes) {
    if (stroke.tool == InkTool.highlighter) {
      final double halfBand = stroke.width * kHighlighterWidthFactor / 2;
      if (halfBand + 4 > pad) pad = halfBand + 4;
    }
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
      NotebookPdfPageBlock(:final double x, :final double y) => (x, y),
      // Tables are deliberately omitted until the exporter can paginate a
      // 100x100 grid without rasterising a 12,000px-wide page. See
      // docs/design/notebook-tables.md.
      NotebookTableBlock() => (16, fallbackY),
      NotebookUnknownBlock() => (16, fallbackY),
    };
    fallbackY += _kBlockFallbackSize.height + 12;
    if (block is! NotebookTableBlock) {
      include(x, y);
      include(x + _kBlockFallbackSize.width, y + _kBlockFallbackSize.height);
    }
    // An image's real footprint can exceed the nominal block size.
    if (block is NotebookImageBlock) {
      include(block.x + block.width, block.y + block.height);
    }
    if (block is NotebookPdfPageBlock) {
      include(block.x + block.width, block.y + block.height);
    }
  }

  if (left == null) {
    // An empty notebook still exports: one blank card-sized page.
    return const ui.Rect.fromLTWH(0, 0, 400, 300);
  }
  return ui.Rect.fromLTRB(left!, top!, right!, bottom!).inflate(pad);
}

/// Text and dump blocks, drawn like the editor draws them: a rounded card
/// with the block's text (or the dump's title line) inside. Image blocks
/// draw their decoded pixels from [images], stretched to the block's stored
/// geometry exactly like the editor's BoxFit.fill; a block whose bytes did
/// not decode keeps the text placeholder so the page never loses its spot.
void _paintBlocks(
  ui.Canvas canvas,
  NotebookDocument document,
  Map<String, ui.Image> images,
) {
  double fallbackY = 0;
  for (final NotebookBlock block in document.blocks) {
    if (block is NotebookImageBlock) {
      final ui.Image? decoded = images[block.id];
      if (decoded != null) {
        canvas.drawImageRect(
          decoded,
          ui.Rect.fromLTWH(
            0,
            0,
            decoded.width.toDouble(),
            decoded.height.toDouble(),
          ),
          ui.Rect.fromLTWH(block.x, block.y, block.width, block.height),
          ui.Paint()..filterQuality = ui.FilterQuality.medium,
        );
        fallbackY += _kBlockFallbackSize.height + 12;
        continue;
      }
    }
    final (String text, double? bx, double? by) = switch (block) {
      NotebookTextBlock(
        :final String text,
        :final double? x,
        :final double? y,
      ) =>
        (text, x, y),
      NotebookCheckboxBlock(
        :final String text,
        :final bool checked,
        :final double? x,
        :final double? y,
      ) =>
        ('${checked ? '\u2611' : '\u2610'} $text', x, y),
      // The dump's title lives in another table; the export marks the spot.
      NotebookDumpCardBlock(:final double x, :final double y) => (
          '\u{1F399} Recording',
          x,
          y
        ),
      // Reached only when the block's bytes failed to decode upfront:
      // the placeholder still marks the picture's place and footprint.
      NotebookImageBlock(:final double x, :final double y) => (
          '\u{1F5BC} Picture',
          x,
          y
        ),
      NotebookPdfPageBlock() => ('', null, null),
      NotebookTableBlock() => ('', null, null),
      NotebookUnknownBlock() => ('', null, null),
    };
    if (block is NotebookUnknownBlock ||
        block is NotebookTableBlock ||
        block is NotebookPdfPageBlock) {
      continue;
    }
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
