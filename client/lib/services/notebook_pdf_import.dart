// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Local PDF import and on-demand page rasterisation.
//
// Android uses the framework PdfRenderer over a platform channel. Desktop uses
// the non-plugin pdfrx_engine package; its vendored native-asset hook is disabled
// for Android. Imported pages belong to the notebook canvas and the ink layer
// remains the topmost interaction surface. Source bytes live once in notebook
// JSON; rendered pages live in the OS cache and are decoded only while their
// canvas rectangles are near the viewport.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx_engine/pdfrx_engine.dart' as pdfrx;

import '../models/notebook.dart';
import 'notebook_import.dart';

/// Canonical notebook width used for every imported PDF page.
///
/// The page fills the readable typed column while retaining a 16 px inset on
/// both sides. Raster output is generated at 2x this logical geometry.
const double kNotebookPdfPageWidth = 688;

/// Blank canvas between consecutive imported PDF pages.
const double kNotebookPdfPageSpacing = kNotebookImportSpacing;

/// Source PDFs are embedded in notebook JSON, so their encoded copy is paid
/// again during saves, sync, and durable-file writes. Keep the same bounded
/// spirit as image import instead of allowing an arbitrary 50-200 MB scan.
const int kNotebookPdfMaxSourceBytes = 20 * 1024 * 1024;

class PdfImportTooLargeException implements Exception {
  const PdfImportTooLargeException(this.bytes);

  final int bytes;

  @override
  String toString() => 'PDF is larger than the 20 MB import limit';
}

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

const String kAndroidPdfRendererChannel = 'dev.tangent.tangent/pdf_renderer';

/// Typed Dart side of the Android PdfRenderer channel.
class AndroidPdfRendererChannel {
  const AndroidPdfRendererChannel({
    MethodChannel channel = const MethodChannel(kAndroidPdfRendererChannel),
  }) : _channel = channel;

  final MethodChannel _channel;

  Future<List<Size>> inspectDocument(String sourcePath) async {
    final Map<Object?, Object?>? response = await _channel
        .invokeMapMethod<Object?, Object?>('inspectDocument', <String, Object?>{
          'sourcePath': sourcePath,
        });
    if (response == null) {
      throw StateError('Android PDF inspector returned no result');
    }
    final Object? rawPages = response['pages'];
    final Object? rawCount = response['pageCount'];
    if (rawPages is! List<Object?> || rawCount is! int) {
      throw const FormatException(
        'Android PDF inspector returned invalid data',
      );
    }
    final List<Size> pages = <Size>[];
    for (final Object? rawPage in rawPages) {
      if (rawPage is! Map<Object?, Object?> ||
          rawPage['width'] is! num ||
          rawPage['height'] is! num) {
        throw const FormatException(
          'Android PDF inspector returned an invalid page',
        );
      }
      final double width = (rawPage['width']! as num).toDouble();
      final double height = (rawPage['height']! as num).toDouble();
      if (width <= 0 || height <= 0) {
        throw const FormatException(
          'Android PDF inspector returned invalid dimensions',
        );
      }
      pages.add(Size(width, height));
    }
    if (pages.isEmpty || pages.length != rawCount) {
      throw const FormatException(
        'Android PDF inspector returned an invalid page count',
      );
    }
    return List<Size>.unmodifiable(pages);
  }

  Future<void> renderPage({
    required String sourcePath,
    required String outputPath,
    required int pageNumber,
    required int width,
    required int height,
  }) => _channel.invokeMethod<void>('renderPage', <String, Object?>{
    'sourcePath': sourcePath,
    'outputPath': outputPath,
    'pageNumber': pageNumber,
    'width': width,
    'height': height,
    'format': 'png',
  });
}

/// Android metadata reader. The framework only accepts seekable file
/// descriptors, so bytes are materialized under the app's private cache.
class AndroidPdfDocumentInspector implements PdfDocumentInspector {
  const AndroidPdfDocumentInspector({
    AndroidPdfRendererChannel channel = const AndroidPdfRendererChannel(),
    Future<Directory> Function()? cacheDirectory,
  }) : _channel = channel,
       _cacheDirectory = cacheDirectory ?? getTemporaryDirectory;

  final AndroidPdfRendererChannel _channel;
  final Future<Directory> Function() _cacheDirectory;

  @override
  Future<List<Size>> inspect(Uint8List bytes) async {
    if (bytes.isEmpty) throw const FormatException('The PDF is empty');
    final Directory root = Directory(
      p.join((await _cacheDirectory()).path, 'notebook_pdf_inspection'),
    );
    await root.create(recursive: true);
    final File source = File(p.join(root.path, '${sha256.convert(bytes)}.pdf'));
    if (!await source.exists() || await source.length() != bytes.length) {
      final File partial = File('${source.path}.partial');
      await partial.writeAsBytes(bytes, flush: true);
      if (await source.exists()) await source.delete();
      await partial.rename(source.path);
    }
    return _channel.inspectDocument(source.path);
  }
}

/// Selects the framework renderer on Android and desktop PDFium elsewhere.
class PlatformPdfDocumentInspector implements PdfDocumentInspector {
  const PlatformPdfDocumentInspector();

  @override
  Future<List<Size>> inspect(Uint8List bytes) => Platform.isAndroid
      ? const AndroidPdfDocumentInspector().inspect(bytes)
      : const DesktopPdfDocumentInspector().inspect(bytes);
}

/// Desktop-only PDFium metadata reader. Page pixels are not loaded.
class DesktopPdfDocumentInspector implements PdfDocumentInspector {
  const DesktopPdfDocumentInspector();

  @override
  Future<List<Size>> inspect(Uint8List bytes) async {
    await pdfrx.pdfrxInitialize();
    final pdfrx.PdfDocument document = await pdfrx.PdfDocument.openData(
      bytes,
      sourceName: 'notebook-import.pdf',
      maxSizeToCacheOnMemory: 16 * 1024 * 1024,
    );
    try {
      if (document.pages.isEmpty) {
        throw const FormatException('The PDF has no pages');
      }
      return List<Size>.unmodifiable(<Size>[
        for (final pdfrx.PdfPage page in document.pages)
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
    PdfDocumentInspector inspector = const PlatformPdfDocumentInspector(),
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
    final int length = await file.length();
    if (length > kNotebookPdfMaxSourceBytes) {
      throw PdfImportTooLargeException(length);
    }
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
    required String documentId,
    required String sourceData,
    required int pageNumber,
    required int width,
    required int height,
  });
}

/// Low-level renderer seam: production selects the platform implementation;
/// cache tests count calls.
abstract interface class PdfPagePngRenderer {
  Future<Uint8List> renderPage({
    required File source,
    required int pageNumber,
    required int width,
    required int height,
  });
}

class PlatformPdfPagePngRenderer implements PdfPagePngRenderer {
  const PlatformPdfPagePngRenderer();

  @override
  Future<Uint8List> renderPage({
    required File source,
    required int pageNumber,
    required int width,
    required int height,
  }) => Platform.isAndroid
      ? const AndroidPdfPagePngRenderer().renderPage(
          source: source,
          pageNumber: pageNumber,
          width: width,
          height: height,
        )
      : const DesktopPdfPagePngRenderer().renderPage(
          source: source,
          pageNumber: pageNumber,
          width: width,
          height: height,
        );
}

/// Android framework renderer. Kotlin writes the PNG below the same private
/// cache root as [source], then Dart returns its bytes to the existing cache
/// transaction so callers keep the same API and atomic-file semantics.
class AndroidPdfPagePngRenderer implements PdfPagePngRenderer {
  const AndroidPdfPagePngRenderer({
    AndroidPdfRendererChannel channel = const AndroidPdfRendererChannel(),
  }) : _channel = channel;

  final AndroidPdfRendererChannel _channel;

  @override
  Future<Uint8List> renderPage({
    required File source,
    required int pageNumber,
    required int width,
    required int height,
  }) async {
    final File output = File(
      p.join(
        source.parent.path,
        '.android-p$pageNumber-${width}x$height-'
        '${DateTime.now().microsecondsSinceEpoch}.png',
      ),
    );
    try {
      await _channel.renderPage(
        sourcePath: source.path,
        outputPath: output.path,
        pageNumber: pageNumber,
        width: width,
        height: height,
      );
      if (!await output.exists() || await output.length() <= 0) {
        throw StateError('Android PDF renderer returned an empty page');
      }
      return await output.readAsBytes();
    } finally {
      try {
        if (await output.exists()) await output.delete();
      } on FileSystemException {
        // Best effort: the app cache is pruned by the OS.
      }
    }
  }
}

class DesktopPdfPagePngRenderer implements PdfPagePngRenderer {
  const DesktopPdfPagePngRenderer();

  @override
  Future<Uint8List> renderPage({
    required File source,
    required int pageNumber,
    required int width,
    required int height,
  }) async {
    await pdfrx.pdfrxInitialize();
    final pdfrx.PdfDocument document = await pdfrx.PdfDocument.openFile(
      source.path,
    );
    pdfrx.PdfImage? rendered;
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
    PdfPagePngRenderer renderer = const PlatformPdfPagePngRenderer(),
    Future<Directory> Function()? cacheDirectory,
    FutureOr<Uint8List> Function(String)? decodeSource,
  }) : _renderer = renderer,
       _cacheDirectory = cacheDirectory ?? getTemporaryDirectory,
       _decodeSource = decodeSource ?? _decodePdfSource;

  final PdfPagePngRenderer _renderer;
  final Future<Directory> Function() _cacheDirectory;
  final FutureOr<Uint8List> Function(String) _decodeSource;
  final Map<String, Future<File>> _inFlight = <String, Future<File>>{};
  final Map<String, Future<File>> _sources = <String, Future<File>>{};
  Future<Directory>? _rootFuture;

  @override
  Future<File> loadPage({
    required String documentId,
    required String sourceData,
    required int pageNumber,
    required int width,
    required int height,
  }) {
    if (pageNumber < 1 || width < 1 || height < 1) {
      throw ArgumentError('Invalid PDF render request');
    }
    if (documentId.isEmpty) throw ArgumentError('Missing PDF document id');
    final String key = '$documentId-p$pageNumber-${width}x$height';
    return _inFlight.putIfAbsent(
      key,
      () =>
          _loadOrRender(
            key: key,
            documentId: documentId,
            sourceData: sourceData,
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
    required String documentId,
    required String sourceData,
    required int pageNumber,
    required int width,
    required int height,
  }) async {
    final Directory root = await _root();
    final File target = File(p.join(root.path, '$key.png'));
    if (await target.exists() && await target.length() > 0) return target;

    final File source = await _sources.putIfAbsent(
      documentId,
      () => _materializeSource(root, documentId, sourceData),
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
    String documentId,
    String sourceData,
  ) async {
    final File source = File(p.join(root.path, '$documentId.pdf'));
    if (await source.exists() && await source.length() > 0) {
      return source;
    }
    final Uint8List sourceBytes;
    try {
      sourceBytes = await _decodeSource(sourceData);
    } on FormatException {
      throw const FormatException('Stored PDF source is not valid base64');
    }
    final File temporary = File('${source.path}.partial');
    await temporary.writeAsBytes(sourceBytes, flush: true);
    if (await source.exists()) await source.delete();
    return temporary.rename(source.path);
  }

  Future<Directory> _root() => _rootFuture ??= _prepareRoot();

  Future<Directory> _prepareRoot() async {
    final Directory root = Directory(
      p.join((await _cacheDirectory()).path, 'notebook_pdf_pages'),
    );
    await root.create(recursive: true);
    final DateTime cutoff = DateTime.now().subtract(const Duration(days: 7));
    await for (final FileSystemEntity entry in root.list()) {
      try {
        if ((await entry.stat()).modified.isBefore(cutoff)) {
          await entry.delete();
        }
      } on FileSystemException {
        // Best-effort cache maintenance must never block page rendering.
      }
    }
    return root;
  }
}

Future<Uint8List> _decodePdfSource(String sourceData) =>
    Isolate.run(() => base64Decode(sourceData));
