// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The PDF exporter is a pure function from notebook content to bytes; these
// tests assert on the REAL bytes (magic number, non-trivial size, title in
// the document) rather than mocking the pdf package away. The colour tests
// go further: they decode the page's embedded raster (raw RGB behind
// FlateDecode — the shape `pdf`'s PdfImage always writes) and assert on the
// PIXELS, because "the shared painter is used" does not by itself prove a
// coloured mark survives to the exported page.
import 'dart:convert';
import 'dart:io' show zlib;
import 'dart:typed_data';
import 'dart:ui' show Color;

import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/models/notebook.dart';
import 'package:tangent/services/notebook_pdf_exporter.dart';
import 'package:tangent/widgets/notebook_ink_canvas.dart';

InkStroke stroke(String id, List<(double, double)> pts) => InkStroke(
      id: id,
      width: 3,
      points: <InkPoint>[
        for (final (double x, double y) in pts) InkPoint(x: x, y: y),
      ],
    );

/// The exported page's raster, recovered from the PDF's own bytes.
class _PageRaster {
  const _PageRaster(this.width, this.height, this.rgb);

  final int width;
  final int height;

  /// Raw RGB, three bytes per pixel, rows top to bottom.
  final Uint8List rgb;

  /// The pixel at raster coordinates ([x], [y]) as (r, g, b).
  (int, int, int) at(int x, int y) {
    final int i = (y * width + x) * 3;
    return (rgb[i], rgb[i + 1], rgb[i + 2]);
  }
}

int _indexOf(Uint8List haystack, List<int> needle, int from) {
  outer:
  for (int i = from; i <= haystack.length - needle.length; i++) {
    for (int j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) continue outer;
    }
    return i;
  }
  return -1;
}

int _lastIndexOf(Uint8List haystack, List<int> needle, int before) {
  outer:
  for (int i = before - needle.length; i >= 0; i--) {
    for (int j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) continue outer;
    }
    return i;
  }
  return -1;
}

/// Pulls the page image back out of [pdf].
///
/// The exporter embeds exactly one DeviceRGB image (the rasterised page), so
/// its object is found by its `/DeviceRGB` colour space; `/Width`, `/Height`
/// and `/Length` come from the same dictionary (delimited by the `<<`
/// nearest before its `stream` keyword) and the stream payload is
/// zlib-deflated raw RGB. Decoding it here — rather than trusting a bounds
/// calculation — is what makes these tests observe the real exported page.
_PageRaster _pageRasterOf(Uint8List pdf) {
  final int colourSpace = _indexOf(pdf, ascii.encode('/DeviceRGB'), 0);
  expect(
    colourSpace,
    greaterThanOrEqualTo(0),
    reason: 'no DeviceRGB image object in the PDF',
  );
  final int streamStart = _indexOf(pdf, ascii.encode('stream\n'), colourSpace);
  expect(
    streamStart,
    greaterThanOrEqualTo(0),
    reason: 'DeviceRGB object has no stream',
  );
  final int dictStart = _lastIndexOf(pdf, ascii.encode('<<'), streamStart);
  expect(
    dictStart,
    greaterThanOrEqualTo(0),
    reason: 'DeviceRGB stream has no dictionary',
  );
  final String dict = latin1.decode(
    pdf.sublist(dictStart, streamStart),
    allowInvalid: true,
  );
  final int width = int.parse(RegExp(r'/Width\s*(\d+)').firstMatch(dict)![1]!);
  final int height =
      int.parse(RegExp(r'/Height\s*(\d+)').firstMatch(dict)![1]!);
  final int length =
      int.parse(RegExp(r'/Length\s*(\d+)').firstMatch(dict)![1]!);
  final int dataStart = streamStart + 'stream\n'.length;
  final Uint8List rgb = Uint8List.fromList(
    zlib.decode(pdf.sublist(dataStart, dataStart + length)),
  );
  expect(
    rgb.length,
    width * height * 3,
    reason: 'decoded stream is not raw ${width}x$height RGB',
  );
  return _PageRaster(width, height, rgb);
}

/// Raster x for a canvas-space [x], given symmetric content bounds.
///
/// The exporter pads the content box equally on every side and rasterises at
/// 2x, so with a fixture whose ink is symmetric about its own bounding box
/// the mapping needs only the raster size and the content box: pad falls out
/// as (rasterWidth/2 - contentWidth) / 2 per side.
int _rx(_PageRaster raster, double x, double contentLeft, double contentRight) {
  final double pad =
      (raster.width / 2 - (contentRight - contentLeft)) / 2;
  return ((x - contentLeft + pad) * 2).round();
}

int _ry(_PageRaster raster, double y, double contentTop, double contentBottom) {
  final double pad =
      (raster.height / 2 - (contentBottom - contentTop)) / 2;
  return ((y - contentTop + pad) * 2).round();
}

(double, double, double) _opaqueRgb(InkColor colour) {
  final int argb = colour.argb;
  return (
    ((argb >> 16) & 0xFF).toDouble(),
    ((argb >> 8) & 0xFF).toDouble(),
    (argb & 0xFF).toDouble(),
  );
}

(double, double, double) _blendOverBackground(InkColor colour) {
  final int argb = colour.argb;
  final double a = ((argb >> 24) & 0xFF) / 255;
  final Color bg = NotebookInkCanvas.backgroundColor;
  double channel(int ink, double bg) => ink * a + bg * 255 * (1 - a);
  return (
    channel((argb >> 16) & 0xFF, bg.r),
    channel((argb >> 8) & 0xFF, bg.g),
    channel(argb & 0xFF, bg.b),
  );
}

(double, double, double) _bgRgb() {
  final Color bg = NotebookInkCanvas.backgroundColor;
  return (bg.r * 255, bg.g * 255, bg.b * 255);
}

void _expectPixel(
  (int, int, int) actual,
  (double, double, double) wanted, {
  double delta = 10,
  String? reason,
}) {
  // Per-channel with tolerance, never an exact colour comparison: the raster
  // has been through scaling and PNG+re-raster round trips, and antialiasing
  // may shade a channel by a few counts.
  expect(actual.$1.toDouble(), closeTo(wanted.$1, delta), reason: reason);
  expect(actual.$2.toDouble(), closeTo(wanted.$2, delta), reason: reason);
  expect(actual.$3.toDouble(), closeTo(wanted.$3, delta), reason: reason);
}


void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a notebook with ink and blocks renders a real PDF', () async {
    final bytes = await renderNotebookPdf(
      NotebookExportSource(
        title: 'Sprint ideas',
        document: NotebookDocument(<NotebookBlock>[
          const NotebookTextBlock(id: 'b-1', text: 'hello', x: 10, y: 200),
          const NotebookCheckboxBlock(
            id: 'b-2',
            text: 'ship it',
            checked: true,
            x: 10,
            y: 300,
          ),
        ]),
        strokes: <InkStroke>[
          stroke('s-1', [(0, 0), (50, 50), (100, 0)]),
          stroke('s-2', [(200, 200), (250, 250)]),
        ],
      ),
    );

    // %PDF- magic and a plausible payload: a rasterised page with content
    // cannot be a few hundred bytes.
    expect(utf8.decode(bytes.sublist(0, 5)), '%PDF-');
    expect(bytes.length, greaterThan(5000));
    // The title travels in the PDF's metadata, uncompressed.
    expect(latin1.decode(bytes, allowInvalid: true), contains('Sprint ideas'));
  });

  test('an empty notebook still exports a page', () async {
    final bytes = await renderNotebookPdf(
      const NotebookExportSource(
        title: '',
        document: NotebookDocument.empty(),
        strokes: <InkStroke>[],
      ),
    );
    expect(utf8.decode(bytes.sublist(0, 5)), '%PDF-');
  });

  test('legacy blocks with no position never collide at the origin', () async {
    // Two unplaced blocks must stack, not overprint each other.
    final bytes = await renderNotebookPdf(
      NotebookExportSource(
        title: 'legacy',
        document: NotebookDocument(<NotebookBlock>[
          const NotebookTextBlock(id: 'b-1', text: 'first'),
          const NotebookTextBlock(id: 'b-2', text: 'second'),
        ]),
        strokes: const <InkStroke>[],
      ),
    );
    expect(utf8.decode(bytes.sublist(0, 5)), '%PDF-');
    expect(bytes.length, greaterThan(3000));
  });

  test('a coloured pen stroke renders its colour into the page raster',
      () async {
    // A red line across the page: content box x 10..90, y 20..20.
    final bytes = await renderNotebookPdf(
      const NotebookExportSource(
        title: 'red ink',
        document: NotebookDocument.empty(),
        strokes: <InkStroke>[
          InkStroke(
            id: 'pen-red',
            width: 6,
            colour: InkColor.red,
            points: <InkPoint>[InkPoint(x: 10, y: 20), InkPoint(x: 90, y: 20)],
          ),
        ],
      ),
    );

    final _PageRaster raster = _pageRasterOf(Uint8List.fromList(bytes));
    // Mid-stroke: the pen's own opaque red, not white and not background.
    _expectPixel(
      raster.at(_rx(raster, 50, 10, 90), _ry(raster, 20, 20, 20)),
      _opaqueRgb(InkColor.red),
      reason: 'mid-stroke pixel should be InkColor.red',
    );
    // Well clear of the stroke: the page background, proving the sample
    // mapping is not just reading a page flooded with one colour.
    _expectPixel(
      raster.at(_rx(raster, 50, 10, 90), _ry(raster, 34, 20, 20)),
      _bgRgb(),
      reason: 'off-stroke pixel should be the page background',
    );
  });

  test('handwriting shows through a translucent highlighter band', () async {
    // The pen stroke is stored FIRST and the highlighter SECOND: only the
    // painter's highlighters-beneath ordering keeps the ink on top, so this
    // exercises the paint-order contract through the real exporter.
    final bytes = await renderNotebookPdf(
      const NotebookExportSource(
        title: 'highlight over ink',
        document: NotebookDocument.empty(),
        strokes: <InkStroke>[
          InkStroke(
            id: 'pen-blue',
            width: 4,
            colour: InkColor.blue,
            points: <InkPoint>[InkPoint(x: 10, y: 40), InkPoint(x: 90, y: 40)],
          ),
          InkStroke(
            id: 'mark',
            width: 6,
            tool: InkTool.highlighter,
            colour: InkColor.yellow,
            points: <InkPoint>[InkPoint(x: 10, y: 40), InkPoint(x: 90, y: 40)],
          ),
        ],
      ),
    );

    final _PageRaster raster = _pageRasterOf(Uint8List.fromList(bytes));
    // On the pen line, inside the band: pure opaque blue. Were the later-
    // stored highlighter painted on top, this pixel would be yellow-shifted
    // (blue's b channel pulled down ~37 counts), far outside the tolerance.
    _expectPixel(
      raster.at(_rx(raster, 50, 10, 90), _ry(raster, 40, 40, 40)),
      _opaqueRgb(InkColor.blue),
      reason: 'pen ink must stay on top of the band',
    );
    // Inside the band but clear of the pen line: yellow blended over the
    // background at its stored alpha — the band really is translucent.
    _expectPixel(
      raster.at(_rx(raster, 50, 10, 90), _ry(raster, 48, 40, 40)),
      _blendOverBackground(InkColor.yellow),
      reason: 'the band beside the ink must be translucent yellow over bg',
    );
  });

  test('a wide highlighter at the content edge keeps its whole band',
      () async {
    // Width 12 -> a 48-logical-px band, whose half (24) overhangs the old
    // fixed inflate(20) padding: the page came out too short and sliced
    // 4 logical px off each side of the mark.
    const double penWidth = 12;
    const double bandHeight = penWidth * kHighlighterWidthFactor;
    final bytes = await renderNotebookPdf(
      const NotebookExportSource(
        title: 'edge band',
        document: NotebookDocument.empty(),
        strokes: <InkStroke>[
          InkStroke(
            id: 'wide-mark',
            width: penWidth,
            tool: InkTool.highlighter,
            colour: InkColor.pink,
            points: <InkPoint>[InkPoint(x: 10, y: 50), InkPoint(x: 90, y: 50)],
          ),
        ],
      ),
    );

    final _PageRaster raster = _pageRasterOf(Uint8List.fromList(bytes));
    // The page must be at least the band tall (at 2x), or part of the mark
    // was cropped away before it ever reached the PDF.
    expect(
      raster.height,
      greaterThanOrEqualTo((bandHeight * 2).round()),
      reason: 'page too short for the band: the padding does not cover '
          'width * kHighlighterWidthFactor / 2',
    );
    // A pixel near the band's top edge — canvas y 29, INSIDE the band
    // (50 - 24 = 26) but OUTSIDE the old inflate(20) box (top was 30) — is
    // exactly the ink the old padding cut off.
    _expectPixel(
      raster.at(_rx(raster, 50, 10, 90), _ry(raster, 29, 50, 50)),
      _blendOverBackground(InkColor.pink),
      reason: 'band edge beyond the old inflate(20) box must survive',
    );
    // And the band's centre is there too.
    _expectPixel(
      raster.at(_rx(raster, 50, 10, 90), _ry(raster, 50, 50, 50)),
      _blendOverBackground(InkColor.pink),
      reason: 'band centre must be translucent pink over the background',
    );
  });
}
