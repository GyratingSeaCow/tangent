// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Local PDF import and on-demand page rasterisation.
//
// PDFium comes from pdfrx. We use only its document/page API — never its
// viewer — because imported pages belong to the notebook canvas and the ink
// layer must remain the topmost interaction surface. Source bytes live once in
// notebook JSON; rendered pages live in the OS cache and are decoded only while
// their canvas rectangles are near the viewport.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';

import '../models/notebook.dart';
import 'notebook_import.dart';

/// Canonical notebook width used for every imported PDF page.
///
/// The page fills the readable typed column while retaining a 16 px inset on
/// both sides. Raster output is generated at 2x this logical geometry.
const double kNotebookPdfPageWidth = 688;

/// Blank canvas between consecutive imported PDF pages.
const double kNotebookPdfPageSpacing = kNotebookImportSpacing;

class PickedPdf {
  const PickedPdf({
    required this.bytes,
    required this.documentId,
    required this.pageSizes,
    required this.name,
  });

  final Uint8List bytes;
  final String documentId;
  final List<Size> pageSizes;
  final String name;
}

/// Testable entry point for choosing and inspecting one local PDF.
abstract interface class NotebookPdfPicker {
  Future<PickedPdf?> pick();
}

abstract interface class PdfDocumentInspector {
  Future<List<Size>> inspect(Uint8List bytes);
}

/// PDFium metadata reader. Page dimensions are loaded, page pixels are not.
class PdfrxDocumentInspector implements PdfDocumentInspector {
  const PdfrxDocumentInspector();

  @override
  Future<List<Size>> inspect(Uint8List bytes) async {
    await pdfrxFlutterInitialize();
    final PdfDocument document = await PdfDocument.openData(
      bytes,
      sourceName: 'notebook-import.pdf',
      maxSizeToCacheOnMemory: 16 * 1024 * 1024,
    );
    try {
      if (document.pages.isEmpty) {
        throw const FormatException('The PDF has no pages');
      }
      return List<Size>.unmodifiable(<Size>[
        for (final PdfPage page in document.pages)
          Size(page.width, page.height),
      ]);
    } finally {
      await document.dispose();
    }
  }
}

/// System file chooser plus local PDF metadata inspection.
class SystemNotebookPdfPicker implements NotebookPdfPicker {
  SystemNotebookPdfPicker({
    PdfDocumentInspector inspector = const PdfrxDocumentInspector(),
    Future<XFile?> Function()? chooseFile,
  }) : _inspector = inspector,
       _chooseFile = chooseFile ?? _pickSystemFile;

  final PdfDocumentInspector _inspector;
  final Future<XFile?> Function() _chooseFile;

  static Future<XFile?> _pickSystemFile() => openFile(
    acceptedTypeGroups: const <XTypeGroup>[
      XTypeGroup(
        label: 'PDF documents',
        extensions: <String>['pdf'],
        mimeTypes: <String>['application/pdf'],
      ),
    ],
  );

  @override
  Future<PickedPdf?> pick() async {
    final XFile? file = await _chooseFile();
    if (file == null) return null;
    final Uint8List bytes = await file.readAsBytes();
    if (bytes.isEmpty) throw const FormatException('The PDF is empty');
    final List<Size> pageSizes = await _inspector.inspect(bytes);
    return PickedPdf(
      bytes: bytes,
      documentId: sha256.convert(bytes).toString(),
      pageSizes: pageSizes,
      name: p.basename(file.path.replaceAll('\\', '/')),
    );
  }
}

/// Builds ordered, content-aware page blocks for [picked].
///
/// Source bytes are base64-encoded on page 1 only. Every other page references
/// them by document id, so a 100-page PDF does not become 100 copies in sync.
List<NotebookPdfPageBlock> buildImportedPdfPageBlocks({
  required PickedPdf picked,
  required List<NotebookBlock> existing,
  required List<InkStroke> strokes,
  required String Function() newId,
}) {
  if (picked.pageSizes.isEmpty) return const <NotebookPdfPageBlock>[];
  final String encoded = base64Encode(picked.bytes);
  double y = notebookContentBottom(existing, strokes) + kNotebookImportSpacing;
  final List<NotebookPdfPageBlock> pages = <NotebookPdfPageBlock>[];
  for (int index = 0; index < picked.pageSizes.length; index++) {
    final Size source = picked.pageSizes[index];
    if (source.width <= 0 || source.height <= 0) {
      throw FormatException('PDF page ${index + 1} has invalid dimensions');
    }
    final double height = kNotebookPdfPageWidth * source.height / source.width;
    pages.add(
      NotebookPdfPageBlock(
        id: newId(),
        documentId: picked.documentId,
        pageNumber: index + 1,
        pageCount: picked.pageSizes.length,
        data: index == 0 ? encoded : null,
        x: kNotebookImportX,
        y: y,
        width: kNotebookPdfPageWidth,
        height: height,
      ),
    );
    y += height + kNotebookPdfPageSpacing;
  }
  return List<NotebookPdfPageBlock>.unmodifiable(pages);
}

/// Resolves the one source-bearing sibling for [page].
String? pdfSourceDataFor(
  NotebookPdfPageBlock page,
  Iterable<NotebookBlock> blocks,
) {
  if (page.data != null) return page.data;
  for (final NotebookBlock block in blocks) {
    if (block is NotebookPdfPageBlock &&
        block.documentId == page.documentId &&
        block.data != null) {
      return block.data;
    }
  }
  return null;
}

/// Page-raster seam used by the editor and exporter.
abstract interface class PdfPageRasterLoader {
  Future<File> loadPage({
    required String sourceData,
    required int pageNumber,
    required int width,
    required int height,
  });
}

/// Low-level renderer seam: production uses PDFium; cache tests count calls.
abstract interface class PdfPagePngRenderer {
  Future<Uint8List> renderPage({
    required File source,
    required int pageNumber,
    required int width,
    required int height,
  });
}

class PdfrxPagePngRenderer implements PdfPagePngRenderer {
  const PdfrxPagePngRenderer();

  @override
  Future<Uint8List> renderPage({
    required File source,
    required int pageNumber,
    required int width,
    required int height,
  }) async {
    await pdfrxFlutterInitialize();
    final PdfDocument document = await PdfDocument.openFile(source.path);
    PdfImage? rendered;
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.Image? image;
    try {
      if (pageNumber < 1 || pageNumber > document.pages.length) {
        throw RangeError.range(
          pageNumber,
          1,
          document.pages.length,
          'pageNumber',
        );
      }
      rendered = await document.pages[pageNumber - 1].render(
        width: width,
        height: height,
        fullWidth: width.toDouble(),
        fullHeight: height.toDouble(),
        backgroundColor: 0xFFFFFFFF,
      );
      if (rendered == null) {
        throw StateError('PDF page $pageNumber could not be rendered');
      }
      buffer = await ui.ImmutableBuffer.fromUint8List(rendered.pixels);
      descriptor = ui.ImageDescriptor.raw(
        buffer,
        width: rendered.width,
        height: rendered.height,
        rowBytes: rendered.width * 4,
        pixelFormat: ui.PixelFormat.bgra8888,
      );
      codec = await descriptor.instantiateCodec();
      final ui.FrameInfo frame = await codec.getNextFrame();
      image = frame.image;
      final ByteData? png = await image.toByteData(
        format: ui.ImageByteFormat.png,
      );
      if (png == null) {
        throw StateError('Could not encode PDF page $pageNumber');
      }
      return png.buffer.asUint8List();
    } finally {
      image?.dispose();
      codec?.dispose();
      descriptor?.dispose();
      buffer?.dispose();
      rendered?.dispose();
      await document.dispose();
    }
  }
}

/// Disk-backed, render-once page cache.
///
/// No decoded page image is retained here. The caller controls the small set of
/// visible FileImages; off-screen pages remain compressed PNG files on disk.
class NotebookPdfPageCache implements PdfPageRasterLoader {
  NotebookPdfPageCache({
    PdfPagePngRenderer renderer = const PdfrxPagePngRenderer(),
    Future<Directory> Function()? cacheDirectory,
  }) : _renderer = renderer,
       _cacheDirectory = cacheDirectory ?? getTemporaryDirectory;

  final PdfPagePngRenderer _renderer;
  final Future<Directory> Function() _cacheDirectory;
  final Map<String, Future<File>> _inFlight = <String, Future<File>>{};
  final Map<String, Future<File>> _sourceWrites = <String, Future<File>>{};

  @override
  Future<File> loadPage({
    required String sourceData,
    required int pageNumber,
    required int width,
    required int height,
  }) {
    if (pageNumber < 1 || width < 1 || height < 1) {
      throw ArgumentError('Invalid PDF render request');
    }
    final Uint8List bytes;
    try {
      bytes = base64Decode(sourceData);
    } on FormatException {
      throw const FormatException('Stored PDF source is not valid base64');
    }
    final String hash = sha256.convert(bytes).toString();
    final String key = '$hash-p$pageNumber-${width}x$height';
    return _inFlight.putIfAbsent(
      key,
      () =>
          _loadOrRender(
            key: key,
            sourceHash: hash,
            sourceBytes: bytes,
            pageNumber: pageNumber,
            width: width,
            height: height,
          ).whenComplete(() {
            _inFlight.remove(key);
          }),
    );
  }

  Future<File> _loadOrRender({
    required String key,
    required String sourceHash,
    required Uint8List sourceBytes,
    required int pageNumber,
    required int width,
    required int height,
  }) async {
    final Directory root = Directory(
      p.join((await _cacheDirectory()).path, 'notebook_pdf_pages'),
    );
    await root.create(recursive: true);
    final File target = File(p.join(root.path, '$key.png'));
    if (await target.exists() && await target.length() > 0) return target;

    final File source = await _sourceWrites.putIfAbsent(
      sourceHash,
      () => _materializeSource(root, sourceHash, sourceBytes).whenComplete(() {
        _sourceWrites.remove(sourceHash);
      }),
    );
    final Uint8List png = await _renderer.renderPage(
      source: source,
      pageNumber: pageNumber,
      width: width,
      height: height,
    );
    if (png.isEmpty) throw StateError('PDF renderer returned an empty page');
    final File temporary = File('${target.path}.partial');
    await temporary.writeAsBytes(png, flush: true);
    if (await target.exists()) await target.delete();
    return temporary.rename(target.path);
  }

  Future<File> _materializeSource(
    Directory root,
    String sourceHash,
    Uint8List sourceBytes,
  ) async {
    final File source = File(p.join(root.path, '$sourceHash.pdf'));
    if (await source.exists() && await source.length() == sourceBytes.length) {
      return source;
    }
    final File temporary = File('${source.path}.partial');
    await temporary.writeAsBytes(sourceBytes, flush: true);
    if (await source.exists()) await source.delete();
    return temporary.rename(source.path);
  }
}
