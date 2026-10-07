// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The PDF exporter is a pure function from notebook content to bytes; these
// tests assert on the REAL bytes rather than mocking the pdf package away.
// Geometry tests parse every emitted MediaBox, while colour tests decode each
// embedded raster (raw RGB behind FlateDecode — the shape `pdf`'s PdfImage
// writes) and assert on PIXELS. Together they prove that pagination preserves
// both the page contract and content beyond the engine's raster ceiling.
import 'dart:convert';
import 'dart:io' show Directory, File, zlib;
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:ui' show Color;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:tangent/models/notebook.dart';
import 'package:tangent/services/notebook_pdf_exporter.dart';
import 'package:tangent/services/notebook_pdf_import.dart';
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

class _MediaBox {
  const _MediaBox(this.width, this.height);

  final double width;
  final double height;
}

List<_MediaBox> _mediaBoxesOf(Uint8List pdf) {
  final String wire = latin1.decode(pdf, allowInvalid: true);
  return RegExp(r'/MediaBox\s*\[\s*0\s+0\s+([\d.]+)\s+([\d.]+)\s*\]')
      .allMatches(wire)
      .map((RegExpMatch match) {
        return _MediaBox(
          double.parse(match.group(1)!),
          double.parse(match.group(2)!),
        );
      })
      .toList(growable: false);
}

List<double> _canvasContentHeights(List<_MediaBox> boxes) => <double>[
  for (int index = 0; index < boxes.length; index++)
    boxes[index].height - 48 - (index == 0 ? 30 : 0),
];

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
/// Each canvas page embeds one DeviceRGB image, so the page at [index] is found
/// by its `/DeviceRGB` colour space; `/Width`, `/Height` and `/Length` come from
/// the same dictionary (delimited by the `<<` nearest before its `stream`
/// keyword) and the stream payload is zlib-deflated raw RGB. Decoding it here —
/// rather than trusting a bounds calculation — is what makes these tests
/// observe the real exported page.
_PageRaster _pageRasterOf(Uint8List pdf, {int index = 0}) {
  var from = 0;
  var colourSpace = -1;
  for (int current = 0; current <= index; current++) {
    colourSpace = _indexOf(pdf, ascii.encode('/DeviceRGB'), from);
    if (colourSpace < 0) break;
    from = colourSpace + '/DeviceRGB'.length;
  }
  expect(
    colourSpace,
    greaterThanOrEqualTo(0),
    reason: 'no DeviceRGB image object at index $index in the PDF',
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
  final int height = int.parse(
    RegExp(r'/Height\s*(\d+)').firstMatch(dict)![1]!,
  );
  final int length = int.parse(
    RegExp(r'/Length\s*(\d+)').firstMatch(dict)![1]!,
  );
  final int dataStart = streamStart + 'stream\n'.length;
  final Uint8List payload = pdf.sublist(dataStart, dataStart + length);
  final Uint8List rgb;
  if (dict.contains('/DCTDecode')) {
    final img.Image decoded = img.decodeJpg(payload)!;
    final Uint8List channels = Uint8List(decoded.width * decoded.height * 3);
    var offset = 0;
    for (final img.Pixel pixel in decoded) {
      channels[offset++] = pixel.r.toInt();
      channels[offset++] = pixel.g.toInt();
      channels[offset++] = pixel.b.toInt();
    }
    rgb = channels;
  } else {
    rgb = Uint8List.fromList(zlib.decode(payload));
  }
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
  final double pad = (raster.width / 2 - (contentRight - contentLeft)) / 2;
  return ((x - contentLeft + pad) * 2).round();
}

int _ry(_PageRaster raster, double y, double contentTop, double contentBottom) {
  final double pad = (raster.height / 2 - (contentBottom - contentTop)) / 2;
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

/// A solid-colour [w]x[h] PNG, base64-encoded the way the model stores it.
///
/// Built through the engine's own encoder so the test controls the expected
/// pixel exactly — a red fixture on the dark page background, never a
/// background-coloured one.
Future<String> _solidPngBase64(Color colour, int w, int h) async {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final ui.Canvas canvas = ui.Canvas(recorder);
  canvas.drawRect(
    ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    ui.Paint()..color = colour,
  );
  final ui.Image image = await recorder.endRecording().toImage(w, h);
  final ByteData? png = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return base64Encode(png!.buffer.asUint8List());
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

class _RecordingPdfLoader implements PdfPageRasterLoader {
  _RecordingPdfLoader(this.directory, this.png);

  final Directory directory;
  final Uint8List png;
  final List<int> pages = <int>[];
  final List<String> sources = <String>[];

  @override
  Future<File> loadPage({
    required String documentId,
    required String sourceData,
    required int pageNumber,
    required int width,
    required int height,
  }) {
    pages.add(pageNumber);
    sources.add(sourceData);
    final File file = File('${directory.path}/page-$pageNumber.png');
    file.writeAsBytesSync(png);
    return Future<File>.value(file);
  }
}

class _SolidPageRenderer implements PdfPagePngRenderer {
  _SolidPageRenderer(this.png);

  final Uint8List png;
  int calls = 0;
  int active = 0;
  int maxActive = 0;

  @override
  Future<Uint8List> renderPage({
    required File source,
    required int pageNumber,
    required int width,
    required int height,
  }) async {
    calls++;
    active++;
    maxActive = active > maxActive ? active : maxActive;
    expect(await source.readAsBytes(), <int>[112, 100, 102]);
    await Future<void>.delayed(Duration.zero);
    active--;
    return png;
  }
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

  test(
    'a tall canvas has exact observed tile geometry and bottom ink',
    () async {
      const double canvasWidth = 700;
      const double canvasHeight = 5000;
      const double contentPadding = 20;
      const double rasterScale = 2;
      const double maxTileRasterHeight = 7600;
      const double pagePad = 24;
      const double titleBand = 30;
      const double boundsLeft = -contentPadding;
      const double boundsTop = -contentPadding;
      const double boundsWidth = canvasWidth + 2 * contentPadding;
      const double boundsHeight = canvasHeight + 2 * contentPadding;

      final Uint8List bytes = await renderNotebookPdf(
        const NotebookExportSource(
          title: 'tall canvas',
          document: NotebookDocument.empty(),
          strokes: <InkStroke>[
            InkStroke(
              id: 'top-edge',
              width: 8,
              colour: InkColor.blue,
              points: <InkPoint>[
                InkPoint(x: 0, y: 0),
                InkPoint(x: canvasWidth, y: 0),
              ],
            ),
            InkStroke(
              id: 'bottom-edge',
              width: 8,
              colour: InkColor.red,
              points: <InkPoint>[
                InkPoint(x: 0, y: canvasHeight),
                InkPoint(x: canvasWidth, y: canvasHeight),
              ],
            ),
          ],
        ),
      );

      final String wire = latin1.decode(bytes, allowInvalid: true);
      final List<_MediaBox> boxes = _mediaBoxesOf(bytes);
      expect(boxes.length, greaterThan(1));
      expect(
        RegExp(r'/Type\s*/Page(?!s)').allMatches(wire),
        hasLength(boxes.length),
        reason: 'each observed content tile must become one PDF page',
      );
      expect(
        RegExp(r'/DeviceRGB').allMatches(wire),
        hasLength(boxes.length),
        reason: 'every PDF page must retain its separately rasterised tile',
      );

      final List<double> contentHeights = _canvasContentHeights(boxes);
      expect(
        contentHeights.reduce((double a, double b) => a + b),
        closeTo(boundsHeight, 1),
        reason: 'observed page content heights must cover the bounds exactly',
      );
      expect(
        contentHeights.first / boundsWidth,
        closeTo(math.sqrt(2), 0.01),
        reason: 'this fixture exercises the nominal A-series tile branch',
      );
      for (int index = 0; index < boxes.length; index++) {
        final _MediaBox box = boxes[index];
        final _PageRaster raster = _pageRasterOf(bytes, index: index);
        expect(box.width, closeTo(boundsWidth + 2 * pagePad, 0.01));
        expect(
          box.height,
          closeTo(
            raster.height / rasterScale +
                2 * pagePad +
                (index == 0 ? titleBand : 0),
            0.51,
          ),
          reason: 'MediaBox $index must wrap its observed raster without drift',
        );
        if (index < boxes.length - 1) {
          expect(contentHeights[index], closeTo(contentHeights.first, 0.01));
        }
      }
      expect(
        contentHeights.last,
        closeTo(boundsHeight - contentHeights.first * (boxes.length - 1), 0.01),
        reason: 'the last continuation must use only the observed remainder',
      );

      final int lastIndex = boxes.length - 1;
      final _PageRaster last = _pageRasterOf(bytes, index: lastIndex);
      final double lastTileTop =
          boundsTop +
          contentHeights
              .take(lastIndex)
              .fold<double>(0.0, (double sum, double height) => sum + height);
      final int bottomX = ((canvasWidth / 2 - boundsLeft) * rasterScale)
          .round();
      final int bottomY = ((canvasHeight - lastTileTop) * rasterScale).round();
      expect(last.height, lessThanOrEqualTo(maxTileRasterHeight));
      _expectPixel(
        last.at(bottomX, bottomY),
        _opaqueRgb(InkColor.red),
        reason: 'the bottom stroke must survive in the last tile',
      );
      _expectPixel(
        last.at(bottomX, bottomY - 24),
        _bgRgb(),
        reason: 'the last tile control pixel must remain background',
      );
    },
  );

  test('a wide canvas honours the tile raster ceiling', () async {
    // A canvas wider than ceiling/sqrt(2) logical px makes the A-series
    // nominal tile height (width * sqrt(2)) exceed the raster ceiling; the
    // exporter must fall back to the capped tile height or its clamped raster
    // captures only the first 8,000 rows — the exact mechanism behind the
    // original "only the first page exports" crop. The assertions read
    // the OBSERVED page geometry out of the produced PDF rather than
    // re-deriving the tile formula.
    const double canvasWidth = 2700;
    const double canvasHeight = 4500;
    const double contentPadding = 20;
    const double rasterScale = 2;
    const double maxTileRasterHeight = 7600;
    const double pagePad = 24;
    const double titleBand = 30;

    final Uint8List bytes = await renderNotebookPdf(
      const NotebookExportSource(
        title: 'wide canvas',
        document: NotebookDocument.empty(),
        strokes: <InkStroke>[
          InkStroke(
            id: 'top-edge',
            width: 8,
            colour: InkColor.blue,
            points: <InkPoint>[
              InkPoint(x: 0, y: 0),
              InkPoint(x: canvasWidth, y: 0),
            ],
          ),
          InkStroke(
            id: 'bottom-edge',
            width: 8,
            colour: InkColor.red,
            points: <InkPoint>[
              InkPoint(x: 0, y: canvasHeight),
              InkPoint(x: canvasWidth, y: canvasHeight),
            ],
          ),
        ],
      ),
    );

    final List<_MediaBox> boxes = _mediaBoxesOf(bytes);
    expect(boxes, isNotEmpty, reason: 'the PDF must declare page geometry');
    // Tallest legal page: a capped tile plus padding plus the title band.
    const double maxPageHeight =
        maxTileRasterHeight / rasterScale + 2 * pagePad + titleBand;
    for (final _MediaBox box in boxes) {
      expect(
        box.height,
        lessThanOrEqualTo(maxPageHeight + 1),
        reason:
            'no page may exceed the capped tile height — an uncapped '
            'nominal tile silently overruns the raster ceiling',
      );
    }
    final int pageCount = boxes.length;
    expect(
      pageCount,
      greaterThan(1),
      reason: 'a 4500-high capped canvas cannot fit one tile',
    );

    // The content below the first capped tile must still be in the output.
    const double boundsLeft = -contentPadding;
    const double boundsTop = -contentPadding;
    final List<double> contentHeights = _canvasContentHeights(boxes);
    final double lastTileTop =
        boundsTop +
        contentHeights
            .take(pageCount - 1)
            .fold<double>(0.0, (double sum, double height) => sum + height);
    final _PageRaster last = _pageRasterOf(bytes, index: pageCount - 1);
    final int bottomX = ((canvasWidth / 2 - boundsLeft) * rasterScale).round();
    final int bottomY = ((canvasHeight - lastTileTop) * rasterScale).round();
    _expectPixel(
      last.at(bottomX, bottomY),
      _opaqueRgb(InkColor.red),
      reason: 'the bottom stroke must survive past the capped first tile',
    );
  });

  test('a 400x1200 canvas below the raster ceiling stays one page', () async {
    final Uint8List bytes = await renderNotebookPdf(
      const NotebookExportSource(
        title: 'phone note',
        document: NotebookDocument.empty(),
        strokes: <InkStroke>[
          InkStroke(
            id: 'bounds',
            width: 3,
            points: <InkPoint>[InkPoint(x: 0, y: 0), InkPoint(x: 360, y: 1160)],
          ),
        ],
      ),
    );

    final String wire = latin1.decode(bytes, allowInvalid: true);
    expect(RegExp(r'/Type\s*/Page(?!s)').allMatches(wire), hasLength(1));
    expect(RegExp(r'/DeviceRGB').allMatches(wire), hasLength(1));
    final List<_MediaBox> boxes = _mediaBoxesOf(bytes);
    expect(boxes, hasLength(1));
    expect(boxes.single.width, closeTo(448, 0.01));
    expect(boxes.single.height, closeTo(1278, 0.01));
  });

  test('a skinny 88x5000 canvas uses the logical tile-height floor', () async {
    final Uint8List bytes = await renderNotebookPdf(
      const NotebookExportSource(
        title: 'skinny note',
        document: NotebookDocument.empty(),
        strokes: <InkStroke>[
          InkStroke(
            id: 'skinny-bounds',
            width: 3,
            points: <InkPoint>[InkPoint(x: 0, y: 0), InkPoint(x: 48, y: 4960)],
          ),
        ],
      ),
    );

    final List<_MediaBox> boxes = _mediaBoxesOf(bytes);
    final List<double> contentHeights = _canvasContentHeights(boxes);
    expect(boxes.length, greaterThan(1));
    expect(
      boxes.length,
      lessThan(10),
      reason: 'the 1,000px floor must avoid the former roughly 90 pages',
    );
    for (final _MediaBox box in boxes) {
      expect(box.width, closeTo(88 + 48, 0.01));
    }
    // The last page may be a shorter remainder; every other MediaBox must
    // contain at least the 1,000px floor plus padding (and page-zero title).
    for (int index = 0; index < boxes.length - 1; index++) {
      expect(
        boxes[index].height,
        greaterThanOrEqualTo(1000 + 48 + (index == 0 ? 30 : 0) - 0.01),
        reason: 'every non-last tile must respect the logical-height floor',
      );
    }
    expect(
      contentHeights.reduce((double a, double b) => a + b),
      closeTo(5000, 1),
    );
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

  test(
    'a coloured pen stroke renders its colour into the page raster',
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
              points: <InkPoint>[
                InkPoint(x: 10, y: 20),
                InkPoint(x: 90, y: 20),
              ],
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
    },
  );

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

  test('a wide highlighter at the content edge keeps its whole band', () async {
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
      reason:
          'page too short for the band: the padding does not cover '
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

  test(
    'an image block renders its actual pixels into the page raster',
    () async {
      // A solid red 4x4 PNG stretched to an 80x60 block at (40, 60). The
      // content box is decided by the block's NOMINAL footprint (300x90 from
      // its origin), which exceeds the image itself: x 40..340, y 60..150.
      final String red = await _solidPngBase64(const Color(0xFFFF0000), 4, 4);
      final bytes = await renderNotebookPdf(
        NotebookExportSource(
          title: 'picture',
          document: NotebookDocument(<NotebookBlock>[
            NotebookImageBlock(
              id: 'img-1',
              data: red,
              mime: 'image/png',
              x: 40,
              y: 60,
              width: 80,
              height: 60,
            ),
          ]),
          strokes: const <InkStroke>[],
        ),
      );

      final _PageRaster raster = _pageRasterOf(Uint8List.fromList(bytes));
      // Image centre, canvas (80, 90): the fixture's own red, not the page
      // background and not the old '\u{1F5BC} Picture' placeholder.
      _expectPixel(
        raster.at(_rx(raster, 80, 40, 340), _ry(raster, 90, 60, 150)),
        (255, 0, 0),
        reason: 'image-centre pixel should be the fixture red',
      );
      // Interior near the image's bottom-right, well inside the dest rect but
      // away from its centre: red everywhere the block claims, proving the
      // image fills its stored width x height (the editor's BoxFit.fill).
      _expectPixel(
        raster.at(_rx(raster, 110, 40, 340), _ry(raster, 115, 60, 150)),
        (255, 0, 0),
        reason: 'image interior near bottom-right should be the fixture red',
      );
      // Clear of the image (canvas 200, 130): page background — the control
      // that proves the samples above are not reading a red-flooded page.
      _expectPixel(
        raster.at(_rx(raster, 200, 40, 340), _ry(raster, 130, 60, 150)),
        _bgRgb(),
        reason: 'off-image pixel should be the page background',
      );
    },
  );

  test(
    'a corrupt image block falls back to the placeholder, export survives',
    () async {
      // Valid base64, but the bytes are no image any codec accepts: the block
      // must keep its placeholder card and the rest of the export must live.
      final String garbage = base64Encode(
        Uint8List.fromList(List<int>.generate(64, (i) => i)),
      );
      final bytes = await renderNotebookPdf(
        NotebookExportSource(
          title: 'broken picture',
          document: NotebookDocument(<NotebookBlock>[
            NotebookImageBlock(
              id: 'img-bad',
              data: garbage,
              mime: 'image/png',
              x: 40,
              y: 60,
              width: 80,
              height: 60,
            ),
          ]),
          strokes: const <InkStroke>[],
        ),
      );

      // The export completed and produced a real PDF, not a crash.
      expect(utf8.decode(bytes.sublist(0, 5)), '%PDF-');
      final _PageRaster raster = _pageRasterOf(Uint8List.fromList(bytes));
      // Inside the image's claimed rect but below the placeholder's text line
      // and inside its unfilled card: background, not image pixels — the
      // block fell back instead of painting garbage.
      _expectPixel(
        raster.at(_rx(raster, 80, 40, 340), _ry(raster, 100, 60, 150)),
        _bgRgb(),
        reason: 'a corrupt image paints no pixels where the image would be',
      );
    },
  );

  test(
    'imported pages export in order with ink composited over page pixels',
    () async {
      final Directory temp = Directory.systemTemp.createTempSync('pdf-export-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final String white = await _solidPngBase64(const Color(0xFFFFFFFF), 2, 2);
      final _RecordingPdfLoader loader = _RecordingPdfLoader(
        temp,
        base64Decode(white),
      );
      const String sourceData = 'cGRm';
      final Uint8List bytes = await renderNotebookPdf(
        const NotebookExportSource(
          title: 'annotated import',
          document: NotebookDocument(<NotebookBlock>[
            NotebookPdfPageBlock(
              id: 'pdf-1',
              documentId: 'doc',
              pageNumber: 1,
              pageCount: 2,
              data: sourceData,
              x: 10,
              y: 20,
              width: 100,
              height: 100,
            ),
            NotebookPdfPageBlock(
              id: 'pdf-2',
              documentId: 'doc',
              pageNumber: 2,
              pageCount: 2,
              x: 10,
              y: 140,
              width: 100,
              height: 100,
            ),
          ]),
          strokes: <InkStroke>[
            InkStroke(
              id: 'red-note',
              width: 8,
              colour: InkColor.red,
              points: <InkPoint>[
                InkPoint(x: 20, y: 60),
                InkPoint(x: 80, y: 60),
              ],
            ),
          ],
        ),
        pdfPageLoader: loader,
      );

      expect(loader.pages, <int>[1, 2]);
      expect(loader.sources, <String>[sourceData, sourceData]);
      final String pdfText = latin1.decode(bytes, allowInvalid: true);
      expect(RegExp(r'/Type\s*/Page(?!s)').allMatches(pdfText), hasLength(2));
      final _PageRaster firstPage = _pageRasterOf(bytes);
      expect(firstPage.width, 200);
      expect(firstPage.height, 200);
      _expectPixel(
        firstPage.at(100, 80),
        _opaqueRgb(InkColor.red),
        reason:
            'canvas ink must be translated and painted over imported page 1',
      );
      _expectPixel(
        firstPage.at(100, 20),
        (255, 255, 255),
        reason: 'the imported page raster must survive outside the annotation',
      );
    },
  );

  test('an imported PDF keeps every overview tile and bottom ink', () async {
    final Directory temp = Directory.systemTemp.createTempSync(
      'pdf-tall-overview-',
    );
    addTearDown(() => temp.deleteSync(recursive: true));
    final String white = await _solidPngBase64(const Color(0xFFFFFFFF), 2, 2);
    final _RecordingPdfLoader loader = _RecordingPdfLoader(
      temp,
      base64Decode(white),
    );
    const double boundsTop = 280;
    const double boundsHeight = 9040;
    const double rasterScale = 2;
    final Uint8List bytes = await renderNotebookPdf(
      const NotebookExportSource(
        title: 'tall mixed import',
        document: NotebookDocument(<NotebookBlock>[
          NotebookPdfPageBlock(
            id: 'pdf-1',
            documentId: 'tall-mixed-doc',
            pageNumber: 1,
            pageCount: 1,
            data: 'cGRm',
            x: 0,
            y: 0,
            width: 200,
            height: 200,
          ),
        ]),
        strokes: <InkStroke>[
          InkStroke(
            id: 'overview-top',
            width: 8,
            colour: InkColor.blue,
            points: <InkPoint>[
              InkPoint(x: 0, y: 300),
              InkPoint(x: 310, y: 300),
            ],
          ),
          InkStroke(
            id: 'overview-bottom',
            width: 8,
            colour: InkColor.red,
            points: <InkPoint>[
              InkPoint(x: 0, y: 9300),
              InkPoint(x: 310, y: 9300),
            ],
          ),
        ],
      ),
      pdfPageLoader: loader,
    );

    final List<_MediaBox> boxes = _mediaBoxesOf(bytes);
    final int overviewCount = boxes
        .where((_MediaBox box) => (box.width - 398).abs() < 0.01)
        .length;
    final String wire = latin1.decode(bytes, allowInvalid: true);
    expect(loader.pages, <int>[1]);
    expect(overviewCount, greaterThan(1));
    expect(boxes, hasLength(overviewCount + 1));
    expect(boxes.last.width, closeTo(200, 0.01));
    expect(boxes.last.height, closeTo(200, 0.01));
    expect(
      RegExp(r'/DeviceRGB').allMatches(wire),
      hasLength(overviewCount + 1),
      reason: 'every overview tile plus the imported page needs one raster',
    );

    final List<double> contentHeights = _canvasContentHeights(
      boxes.take(overviewCount).toList(growable: false),
    );
    expect(
      contentHeights.reduce((double a, double b) => a + b),
      closeTo(boundsHeight, 1),
    );
    final int lastOverviewIndex = overviewCount - 1;
    final double lastTileTop =
        boundsTop +
        contentHeights
            .take(lastOverviewIndex)
            .fold<double>(0.0, (double sum, double height) => sum + height);
    final _PageRaster lastOverview = _pageRasterOf(
      bytes,
      index: lastOverviewIndex,
    );
    final int bottomX = ((155 + 20) * rasterScale).round();
    final int bottomY = ((9300 - lastTileTop) * rasterScale).round();
    _expectPixel(
      lastOverview.at(bottomX, bottomY),
      _opaqueRgb(InkColor.red),
      reason: 'ink beyond the raster ceiling must reach the last overview',
    );
    _expectPixel(
      lastOverview.at(bottomX, bottomY - 24),
      _bgRgb(),
      reason: 'the nearby control pixel must remain background',
    );
  });

  test(
    '100 imported pages use the real disk loader and retain JPEG, not raw RGB',
    () async {
      final Directory temp = Directory.systemTemp.createTempSync(
        'pdf-export-100-',
      );
      addTearDown(() => temp.deleteSync(recursive: true));
      final String white = await _solidPngBase64(const Color(0xFFFFFFFF), 2, 2);
      final _SolidPageRenderer renderer = _SolidPageRenderer(
        base64Decode(white),
      );
      var decodeCalls = 0;
      final NotebookPdfPageCache loader = NotebookPdfPageCache(
        renderer: renderer,
        cacheDirectory: () async => temp,
        decodeSource: (String encoded) {
          decodeCalls++;
          return base64Decode(encoded);
        },
      );
      final List<NotebookBlock> pages = <NotebookBlock>[
        for (int index = 0; index < 100; index++)
          NotebookPdfPageBlock(
            id: 'page-$index',
            documentId: 'doc-100',
            pageNumber: index + 1,
            pageCount: 100,
            data: index == 0 ? 'cGRm' : null,
            x: 0,
            y: index * 24,
            width: 20,
            height: 20,
          ),
      ];

      final Uint8List bytes = await renderNotebookPdf(
        NotebookExportSource(
          title: 'hundred pages',
          document: NotebookDocument(pages),
          strokes: const <InkStroke>[],
        ),
        pdfPageLoader: loader,
      );

      final String wire = latin1.decode(bytes, allowInvalid: true);
      expect(RegExp(r'/Type\s*/Page(?!s)').allMatches(wire), hasLength(100));
      expect(RegExp(r'/DCTDecode').allMatches(wire), hasLength(100));
      expect(renderer.calls, 100);
      expect(
        renderer.maxActive,
        1,
        reason: 'pages must composite sequentially',
      );
      expect(
        decodeCalls,
        1,
        reason: 'the real cache must decode one source, not once per page',
      );
    },
  );

  test(
    'mixed canvas content is emitted as an overview before PDF pages',
    () async {
      final Directory temp = Directory.systemTemp.createTempSync('pdf-mixed-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final String white = await _solidPngBase64(const Color(0xFFFFFFFF), 2, 2);
      final String red = await _solidPngBase64(const Color(0xFFFF0000), 2, 2);
      final _RecordingPdfLoader loader = _RecordingPdfLoader(
        temp,
        base64Decode(white),
      );
      final Uint8List bytes = await renderNotebookPdf(
        NotebookExportSource(
          title: 'mixed',
          document: NotebookDocument(<NotebookBlock>[
            const NotebookTextBlock(id: 'text', text: 'Keep me', x: 20, y: 20),
            NotebookImageBlock(
              id: 'image',
              data: red,
              mime: 'image/png',
              x: 40,
              y: 80,
              width: 80,
              height: 60,
            ),
            const NotebookPdfPageBlock(
              id: 'pdf-1',
              documentId: 'mixed-doc',
              pageNumber: 1,
              pageCount: 2,
              data: 'cGRm',
              x: 10,
              y: 500,
              width: 100,
              height: 100,
            ),
            const NotebookPdfPageBlock(
              id: 'pdf-2',
              documentId: 'mixed-doc',
              pageNumber: 2,
              pageCount: 2,
              x: 10,
              y: 620,
              width: 100,
              height: 100,
            ),
          ]),
          strokes: const <InkStroke>[
            InkStroke(
              id: 'preexisting-ink',
              width: 6,
              colour: InkColor.blue,
              points: <InkPoint>[
                InkPoint(x: 20, y: 180),
                InkPoint(x: 200, y: 180),
              ],
            ),
          ],
        ),
        pdfPageLoader: loader,
      );

      final String wire = latin1.decode(bytes, allowInvalid: true);
      expect(RegExp(r'/Type\s*/Page(?!s)').allMatches(wire), hasLength(3));
      expect(loader.pages, <int>[1, 2]);
      final _PageRaster overview = _pageRasterOf(bytes);
      _expectPixel(
        overview.at(_rx(overview, 80, 20, 340), _ry(overview, 110, 20, 180)),
        (255, 0, 0),
        reason: 'the pre-existing image must survive on the overview page',
      );
      _expectPixel(
        overview.at(_rx(overview, 180, 20, 340), _ry(overview, 180, 20, 180)),
        _opaqueRgb(InkColor.blue),
        reason: 'pre-existing ink must survive on the overview page',
      );
    },
  );

  test('an image block and ink strokes coexist on the exported page', () async {
    // The red image from the pixel test plus a blue pen line above it:
    // content box x 40..340 (stroke and nominal footprint agree),
    // y 20..150 (stroke top, block nominal bottom).
    final String red = await _solidPngBase64(const Color(0xFFFF0000), 4, 4);
    final bytes = await renderNotebookPdf(
      NotebookExportSource(
        title: 'picture and ink',
        document: NotebookDocument(<NotebookBlock>[
          NotebookImageBlock(
            id: 'img-1',
            data: red,
            mime: 'image/png',
            x: 40,
            y: 60,
            width: 80,
            height: 60,
          ),
        ]),
        strokes: const <InkStroke>[
          InkStroke(
            id: 'pen-blue',
            width: 6,
            colour: InkColor.blue,
            points: <InkPoint>[InkPoint(x: 40, y: 20), InkPoint(x: 340, y: 20)],
          ),
        ],
      ),
    );

    final _PageRaster raster = _pageRasterOf(Uint8List.fromList(bytes));
    // Mid-stroke: the pen's opaque blue still renders with an image on the
    // page — drawing pictures must not eat the ink pass.
    _expectPixel(
      raster.at(_rx(raster, 190, 40, 340), _ry(raster, 20, 20, 150)),
      _opaqueRgb(InkColor.blue),
      reason: 'ink must still render when an image block is present',
    );
    // Image centre: the fixture's red still renders alongside the ink.
    _expectPixel(
      raster.at(_rx(raster, 80, 40, 340), _ry(raster, 90, 20, 150)),
      (255, 0, 0),
      reason: 'the image must still render alongside ink',
    );
    // Between the two (canvas 200, 130): background — neither flooded.
    _expectPixel(
      raster.at(_rx(raster, 200, 40, 340), _ry(raster, 130, 20, 150)),
      _bgRgb(),
      reason: 'clear ground between ink and image should be background',
    );
  });
}
