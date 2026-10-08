// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:pdfium_dart/pdfium_dart.dart' as pdfium;
import 'package:tangent/models/notebook.dart';
import 'package:tangent/services/notebook_import.dart';
import 'package:tangent/services/notebook_pdf_import.dart';

class _Inspector implements PdfDocumentInspector {
  _Inspector(this.sizes);

  final List<Size> sizes;
  int calls = 0;
  final List<String> documentIds = <String>[];

  @override
  Future<List<Size>> inspect(
    Uint8List bytes, {
    required String documentId,
  }) async {
    calls++;
    documentIds.add(documentId);
    return sizes;
  }
}

class _LengthOnlyXFile extends XFile {
  _LengthOnlyXFile(this.reportedLength) : super('must-not-be-read.pdf');

  final int reportedLength;
  bool readAttempted = false;

  @override
  Future<int> length() async => reportedLength;

  @override
  Future<Uint8List> readAsBytes() async {
    readAttempted = true;
    throw StateError('oversized PDF bytes were read');
  }
}

class _FlexibleRenderer implements PdfPagePngRenderer {
  final List<int> pages = <int>[];

  @override
  Future<Uint8List> renderPage({
    required File source,
    required int pageNumber,
    required int width,
    required int height,
  }) async {
    expect(await source.readAsBytes(), <int>[1, 2, 3, 4]);
    pages.add(pageNumber);
    return Uint8List.fromList(<int>[0x89, 0x50, 0x4E, 0x47, pageNumber]);
  }
}

class _CountingRenderer implements PdfPagePngRenderer {
  int calls = 0;

  @override
  Future<Uint8List> renderPage({
    required File source,
    required int pageNumber,
    required int width,
    required int height,
  }) async {
    calls++;
    expect(await source.readAsBytes(), <int>[1, 2, 3, 4]);
    expect(pageNumber, 2);
    expect((width, height), (200, 300));
    return Uint8List.fromList(<int>[0x89, 0x50, 0x4E, 0x47, calls]);
  }
}

class _BlockingRenderer implements PdfPagePngRenderer {
  final Completer<void> firstEntered = Completer<void>();
  final Completer<void> releaseFirst = Completer<void>();
  final List<int> pages = <int>[];
  int active = 0;
  int maximumActive = 0;

  @override
  Future<Uint8List> renderPage({
    required File source,
    required int pageNumber,
    required int width,
    required int height,
  }) async {
    pages.add(pageNumber);
    active++;
    maximumActive = active > maximumActive ? active : maximumActive;
    try {
      if (pages.length == 1) {
        firstEntered.complete();
        await releaseFirst.future;
      }
      return Uint8List.fromList(<int>[0x89, 0x50, 0x4e, 0x47, pageNumber]);
    } finally {
      active--;
    }
  }
}

class _BlockingFileRenderer
    implements PdfPagePngRenderer, PdfPageFileRenderer {
  final Completer<void> entered = Completer<void>();
  final Completer<void> release = Completer<void>();
  final List<String> cancelled = <String>[];
  int byteRenderCalls = 0;

  @override
  Future<Uint8List> renderPage({
    required File source,
    required int pageNumber,
    required int width,
    required int height,
  }) async {
    byteRenderCalls++;
    throw StateError('cache must use direct file output');
  }

  @override
  Future<void> renderPageToFile({
    required String requestId,
    required File source,
    required File output,
    required int pageNumber,
    required int width,
    required int height,
  }) async {
    entered.complete();
    await release.future;
    await output.writeAsBytes(<int>[0x89, 0x50, 0x4e, 0x47], flush: true);
  }

  @override
  Future<void> cancelRender(String requestId) async {
    cancelled.add(requestId);
  }
}

Future<Uint8List> _twoPagePdf() async {
  final pw.Document pdf = pw.Document();
  pdf.addPage(
    pw.Page(
      pageFormat: const PdfPageFormat(200, 300),
      build: (_) => pw.Container(color: PdfColors.red),
    ),
  );
  pdf.addPage(
    pw.Page(
      pageFormat: const PdfPageFormat(400, 200),
      build: (_) => pw.Container(color: PdfColors.blue),
    ),
  );
  return pdf.save();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel pathProvider = MethodChannel(
    'plugins.flutter.io/path_provider',
  );
  setUpAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, (MethodCall call) async {
          if (call.method == 'getTemporaryDirectory') {
            return Directory.systemTemp.path;
          }
          return null;
        });
  });
  tearDownAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, null);
  });

  test(
    'system picker hashes bytes and inspects page geometry without rastering',
    () async {
      final Directory temp = await Directory.systemTemp.createTemp('pdf-pick-');
      addTearDown(() => temp.delete(recursive: true));
      final File file = File('${temp.path}/notes.pdf');
      await file.writeAsBytes(<int>[1, 2, 3, 4]);
      final _Inspector inspector = _Inspector(<Size>[
        const Size(612, 792),
        const Size(792, 612),
      ]);
      final SystemNotebookPdfPicker picker = SystemNotebookPdfPicker(
        inspector: inspector,
        chooseFile: () async => XFile(file.path),
      );

      final PickedPdf picked = (await picker.pick())!;
      expect(picked.name, 'notes.pdf');
      expect(picked.pageSizes, <Size>[
        const Size(612, 792),
        const Size(792, 612),
      ]);
      expect(
        picked.documentId,
        '9f64a747e1b97f131fabb6b447296c9b6f0201e79fb3c5356e6c77e89b6a806a',
      );
      expect(
        inspector.calls,
        1,
        reason: 'import must inspect once, not render pages',
      );
      expect(inspector.documentIds, <String>[picked.documentId]);
    },
  );

  test(
    'system picker refuses over-limit PDF before reading any bytes',
    () async {
      final _LengthOnlyXFile file = _LengthOnlyXFile(
        kNotebookPdfMaxSourceBytes + 1,
      );
      final _Inspector inspector = _Inspector(const <Size>[Size(100, 100)]);
      final SystemNotebookPdfPicker picker = SystemNotebookPdfPicker(
        inspector: inspector,
        chooseFile: () async => file,
      );

      await expectLater(
        picker.pick(),
        throwsA(
          isA<PdfImportTooLargeException>().having(
            (PdfImportTooLargeException error) => error.toString(),
            'message',
            contains('20 MB'),
          ),
        ),
      );
      expect(file.readAttempted, isFalse);
      expect(inspector.calls, 0);
    },
  );

  test('system picker accepts the exact source-size boundary', () async {
    final Directory temp = await Directory.systemTemp.createTemp('pdf-limit-');
    addTearDown(() => temp.delete(recursive: true));
    final File file = File('${temp.path}/boundary.pdf');
    file.openSync(mode: FileMode.write)
      ..truncateSync(kNotebookPdfMaxSourceBytes)
      ..closeSync();
    final _Inspector inspector = _Inspector(const <Size>[Size(100, 100)]);
    final SystemNotebookPdfPicker picker = SystemNotebookPdfPicker(
      inspector: inspector,
      chooseFile: () async => XFile(file.path),
    );

    final PickedPdf picked = (await picker.pick())!;
    expect(picked.bytes.length, kNotebookPdfMaxSourceBytes);
    expect(inspector.calls, 1);
  });

  test(
    'PDF pages land below content and ink in source order with one byte copy',
    () {
      final PickedPdf picked = PickedPdf(
        bytes: Uint8List.fromList(<int>[1, 2, 3, 4]),
        documentId: 'doc',
        pageSizes: const <Size>[Size(200, 300), Size(400, 200), Size(100, 100)],
        name: 'three.pdf',
      );
      int id = 0;
      final List<NotebookPdfPageBlock> pages = buildImportedPdfPageBlocks(
        picked: picked,
        existing: const <NotebookBlock>[
          NotebookTextBlock(id: 'old', text: 'old', x: 16, y: 600),
        ],
        strokes: const <InkStroke>[
          InkStroke(
            id: 'ink',
            width: 3,
            points: <InkPoint>[InkPoint(x: 20, y: 740)],
          ),
        ],
        newId: () => 'page-${++id}',
      );

      expect(pages.map((NotebookPdfPageBlock p) => p.pageNumber), <int>[
        1,
        2,
        3,
      ]);
      expect(
        pages.map((NotebookPdfPageBlock p) => p.pageCount),
        everyElement(3),
      );
      expect(pages.first.y, 740 + kNotebookImportSpacing);
      expect(pages.first.x, kNotebookImportX);
      expect(pages.first.width, kNotebookPdfPageWidth);
      expect(pages.first.height, kNotebookPdfPageWidth * 1.5);
      expect(
        pages[1].y,
        pages.first.y + pages.first.height + kNotebookPdfPageSpacing,
      );
      expect(pages[1].height, kNotebookPdfPageWidth * 0.5);
      expect(pages.first.data, base64Encode(picked.bytes));
      expect(
        pages.skip(1).map((NotebookPdfPageBlock p) => p.data),
        everyElement(isNull),
        reason: 'the source PDF must not be duplicated once per page',
      );
      expect(pdfSourceDataFor(pages.last, pages), pages.first.data);
    },
  );

  test('disk cache renders one page once and reuses the PNG', () async {
    final Directory temp = await Directory.systemTemp.createTemp('pdf-cache-');
    addTearDown(() => temp.delete(recursive: true));
    final _CountingRenderer renderer = _CountingRenderer();
    final NotebookPdfPageCache cache = NotebookPdfPageCache(
      renderer: renderer,
      cacheDirectory: () async => temp,
    );
    final String source = base64Encode(<int>[1, 2, 3, 4]);

    final List<File> files = await Future.wait(<Future<File>>[
      cache.loadPage(
        documentId: 'doc',
        sourceData: source,
        pageNumber: 2,
        width: 200,
        height: 300,
      ),
      cache.loadPage(
        documentId: 'doc',
        sourceData: source,
        pageNumber: 2,
        width: 200,
        height: 300,
      ),
    ]);
    final File again = await cache.loadPage(
      documentId: 'doc',
      sourceData: source,
      pageNumber: 2,
      width: 200,
      height: 300,
    );

    expect(
      renderer.calls,
      1,
      reason: 'in-flight and disk hits must not rerender',
    );
    expect(files[0].path, files[1].path);
    expect(again.path, files[0].path);
    expect(await again.readAsBytes(), <int>[0x89, 0x50, 0x4E, 0x47, 1]);
  });

  test('100-page fast fling keeps backend bounded and newest page wins', () async {
    final Directory temp = await Directory.systemTemp.createTemp('pdf-fling-');
    addTearDown(() => temp.delete(recursive: true));
    final _BlockingRenderer renderer = _BlockingRenderer();
    final NotebookPdfPageCache cache = NotebookPdfPageCache(
      renderer: renderer,
      cacheDirectory: () async => temp,
    );
    addTearDown(cache.dispose);
    final String source = base64Encode(<int>[1, 2, 3, 4]);
    final List<Future<Object>> results = <Future<Object>>[];

    Future<Object> request(int page) => cache
        .loadPage(
          documentId: 'doc',
          sourceData: source,
          pageNumber: page,
          width: 100,
          height: 100,
        )
        .then<Object>((File file) => file, onError: (Object error) => error);

    results.add(request(1));
    await renderer.firstEntered.future;
    for (int page = 2; page <= 100; page++) {
      results.add(request(page));
    }
    renderer.releaseFirst.complete();
    final List<Object> settled = await Future.wait(results);

    expect(renderer.pages, <int>[1, 100]);
    expect(renderer.maximumActive, 1);
    expect(settled.whereType<File>(), hasLength(2));
    expect(settled.whereType<PdfRenderCancelledException>(), hasLength(98));
  });

  test('dispose cancels native output and cleans the partial file', () async {
    final Directory temp = await Directory.systemTemp.createTemp('pdf-cancel-');
    addTearDown(() => temp.delete(recursive: true));
    final _BlockingFileRenderer renderer = _BlockingFileRenderer();
    final NotebookPdfPageCache cache = NotebookPdfPageCache(
      renderer: renderer,
      cacheDirectory: () async => temp,
    );
    final Future<Object> result = cache
        .loadPage(
          documentId: 'doc',
          sourceData: base64Encode(<int>[1, 2, 3, 4]),
          pageNumber: 7,
          width: 100,
          height: 100,
        )
        .then<Object>((File file) => file, onError: (Object error) => error);
    await renderer.entered.future;

    await cache.dispose();
    expect(renderer.cancelled, <String>['pdf-1']);
    renderer.release.complete();
    expect(await result, isA<PdfRenderCancelledException>());
    expect(renderer.byteRenderCalls, 0);
    final Directory root = Directory('${temp.path}/notebook_pdf_pages');
    expect(
      await root.list().where((FileSystemEntity entry) => entry.path.endsWith('.partial')).length,
      0,
    );
  });

  test('Android cancellation permits an immediate same-page reload', () async {
    const MethodChannel channel = MethodChannel(kAndroidPdfRendererChannel);
    final Completer<void> firstRenderEntered = Completer<void>();
    final Completer<void> firstRenderCancelled = Completer<void>();
    final Completer<void> secondRenderEntered = Completer<void>();
    final Completer<void> releaseSecondRender = Completer<void>();
    final List<String> cancelledRequestIds = <String>[];
    var renderCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          final Map<Object?, Object?> arguments =
              call.arguments as Map<Object?, Object?>;
          if (call.method == 'cancelRender') {
            cancelledRequestIds.add(arguments['requestId']! as String);
            if (!firstRenderCancelled.isCompleted) {
              firstRenderCancelled.complete();
            }
            return <String, Object?>{'cancelled': true};
          }
          expect(call.method, 'renderPage');
          renderCalls++;
          if (renderCalls == 1) {
            firstRenderEntered.complete();
            await firstRenderCancelled.future;
            throw PlatformException(
              code: 'render_cancelled',
              message: 'PDF page render was superseded',
            );
          }
          secondRenderEntered.complete();
          await releaseSecondRender.future;
          await File(
            arguments['outputPath']! as String,
          ).writeAsBytes(<int>[137, 80, 78, 71], flush: true);
          return <String, Object?>{'outputPath': arguments['outputPath']};
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final Directory temp = await Directory.systemTemp.createTemp(
      'pdf-cancel-reload-',
    );
    addTearDown(() => temp.delete(recursive: true));
    final NotebookPdfPageCache cache = NotebookPdfPageCache(
      renderer: const AndroidPdfPagePngRenderer(
        channel: AndroidPdfRendererChannel(channel: channel),
      ),
      cacheDirectory: () async => temp,
    );
    addTearDown(cache.dispose);
    final String source = base64Encode(<int>[1, 2, 3, 4]);

    final Future<File> first = cache.loadPage(
      documentId: 'doc',
      sourceData: source,
      pageNumber: 7,
      width: 100,
      height: 100,
    );
    final Future<Object> cancelled = first.then<Object>(
      (File file) => file,
      onError: (Object error) => error,
    );
    await firstRenderEntered.future;
    cache.cancelPage(documentId: 'doc', pageNumber: 7, width: 100, height: 100);
    final Future<File> reload = cache.loadPage(
      documentId: 'doc',
      sourceData: source,
      pageNumber: 7,
      width: 100,
      height: 100,
    );
    expect(reload, isNot(same(first)));

    expect(await cancelled, isA<PdfRenderCancelledException>());
    await secondRenderEntered.future;
    final Future<File> deduplicatedReload = cache.loadPage(
      documentId: 'doc',
      sourceData: source,
      pageNumber: 7,
      width: 100,
      height: 100,
    );
    expect(deduplicatedReload, same(reload));
    releaseSecondRender.complete();

    final File file = await reload;
    expect(await deduplicatedReload, same(file));
    expect(await file.readAsBytes(), <int>[137, 80, 78, 71]);
    expect(cancelledRequestIds, <String>['pdf-1']);
    expect(renderCalls, 2);
    expect(
      (await cache.loadPage(
        documentId: 'doc',
        sourceData: source,
        pageNumber: 7,
        width: 100,
        height: 100,
      )).path,
      file.path,
    );
    expect(renderCalls, 2, reason: 'successful reload must remain cached');
  });

  test(
    'disk cache keys by document id and decodes one source for many pages',
    () async {
      final Directory temp = await Directory.systemTemp.createTemp(
        'pdf-source-',
      );
      addTearDown(() => temp.delete(recursive: true));
      final _FlexibleRenderer renderer = _FlexibleRenderer();
      var decodeCalls = 0;
      final NotebookPdfPageCache cache = NotebookPdfPageCache(
        renderer: renderer,
        cacheDirectory: () async => temp,
        decodeSource: (String source) {
          decodeCalls++;
          return base64Decode(source);
        },
      );
      final String source = base64Encode(<int>[1, 2, 3, 4]);

      await cache.loadPage(
        documentId: 'stable-document-id',
        sourceData: source,
        pageNumber: 1,
        width: 100,
        height: 100,
      );
      await cache.loadPage(
        documentId: 'stable-document-id',
        sourceData: source,
        pageNumber: 2,
        width: 100,
        height: 100,
      );

      expect(renderer.pages, <int>[1, 2]);
      expect(
        decodeCalls,
        1,
        reason: 'source base64 must be decoded once, with no per-page hashing',
      );
      expect(
        await Directory('${temp.path}/notebook_pdf_pages')
            .list()
            .where((FileSystemEntity entry) => entry.path.endsWith('.pdf'))
            .length,
        1,
      );
    },
  );

  test('Android inspection cache prunes entries older than seven days', () async {
    const MethodChannel channel = MethodChannel(kAndroidPdfRendererChannel);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async {
          return <String, Object?>{
            'pageCount': 1,
            'pages': <Object?>[
              <String, Object?>{'width': 100, 'height': 200},
            ],
          };
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final Directory temp = await Directory.systemTemp.createTemp('pdf-inspect-');
    addTearDown(() => temp.delete(recursive: true));
    final Directory root = Directory('${temp.path}/notebook_pdf_inspection');
    await root.create();
    final File stale = File('${root.path}/stale.pdf')
      ..writeAsBytesSync(<int>[9]);
    await stale.setLastModified(
      DateTime.now().subtract(const Duration(days: 8)),
    );

    final List<Size> sizes = await AndroidPdfDocumentInspector(
      channel: const AndroidPdfRendererChannel(channel: channel),
      cacheDirectory: () async => temp,
    ).inspect(Uint8List.fromList(<int>[1, 2, 3]), documentId: 'known-id');

    expect(sizes, <Size>[const Size(100, 200)]);
    expect(await stale.exists(), isFalse);
    expect(await File('${root.path}/known-id.pdf').readAsBytes(), <int>[1, 2, 3]);
  });

  test(
    'desktop engine inspects and renders a real locally generated PDF',
    () async {
      final Uint8List bytes = await _twoPagePdf();
      final List<Size> sizes = await const DesktopPdfDocumentInspector()
          .inspect(bytes, documentId: 'generated');
      expect(sizes, hasLength(2));
      expect(sizes[0].width, closeTo(200, 0.1));
      expect(sizes[0].height, closeTo(300, 0.1));
      expect(sizes[1].width, closeTo(400, 0.1));
      expect(sizes[1].height, closeTo(200, 0.1));

      final Directory temp = await Directory.systemTemp.createTemp(
        'pdfrx-real-',
      );
      addTearDown(() => temp.delete(recursive: true));
      final File source = File('${temp.path}/source.pdf');
      await source.writeAsBytes(bytes);
      final Uint8List png = await const DesktopPdfPagePngRenderer().renderPage(
        source: source,
        pageNumber: 2,
        width: 400,
        height: 200,
      );
      expect(png.sublist(0, 8), <int>[137, 80, 78, 71, 13, 10, 26, 10]);
      expect(png.length, greaterThan(500));
    },
    skip: _pdfiumUnavailableReason(),
  );

  test('page ranges accept comma-separated pages and inclusive ranges', () {
    expect(
      parsePdfPageRange('1-3,7,12-14', pageCount: 14).pages,
      <int>{1, 2, 3, 7, 12, 13, 14},
    );
    expect(parsePdfPageRange('0', pageCount: 14).error, contains('1 to 14'));
    expect(
      parsePdfPageRange('abc', pageCount: 14).error,
      contains('1-3,7'),
    );
  });

  test('selected PDF pages import in document order with source on first', () {
    final PickedPdf picked = PickedPdf(
      bytes: Uint8List.fromList(<int>[1, 2, 3, 4]),
      documentId: 'selected-doc',
      pageSizes: const <Size>[
        Size(100, 100),
        Size(200, 300),
        Size(300, 200),
        Size(400, 500),
      ],
      name: 'selected.pdf',
    );
    int id = 0;

    final List<NotebookPdfPageBlock> pages = buildImportedPdfPageBlocks(
      picked: picked,
      selectedPageNumbers: <int>{4, 2},
      existing: const <NotebookBlock>[],
      strokes: const <InkStroke>[],
      newId: () => 'selected-${++id}',
    );

    expect(
      pages.map((NotebookPdfPageBlock page) => page.pageNumber),
      <int>[2, 4],
    );
    expect(pages.map((NotebookPdfPageBlock page) => page.pageCount), <int>[4, 4]);
    expect(pages.first.data, base64Encode(picked.bytes));
    expect(pages.last.data, isNull);
    expect(
      pages.last.y,
      pages.first.y + pages.first.height + kNotebookPdfPageSpacing,
    );
  });

  test(
    'Android channel preserves page geometry and one-based render contract',
    () async {
      const MethodChannel channel = MethodChannel(kAndroidPdfRendererChannel);
      final List<MethodCall> calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            calls.add(call);
            if (call.method == 'inspectDocument') {
              return <String, Object?>{
                'pageCount': 2,
                'pages': <Object?>[
                  <String, Object?>{'width': 612, 'height': 792},
                  <String, Object?>{'width': 400, 'height': 200},
                ],
              };
            }
            final Map<Object?, Object?> args =
                call.arguments as Map<Object?, Object?>;
            await File(
              args['outputPath']! as String,
            ).writeAsBytes(<int>[137, 80, 78, 71]);
            return <String, Object?>{'outputPath': args['outputPath']};
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final Directory temp = await Directory.systemTemp.createTemp(
        'pdf-channel-',
      );
      addTearDown(() => temp.delete(recursive: true));
      final File source = File('${temp.path}/source.pdf')
        ..writeAsBytesSync(<int>[1, 2, 3, 4]);
      const AndroidPdfRendererChannel contract = AndroidPdfRendererChannel(
        channel: channel,
      );

      expect(await contract.inspectDocument(source.path), <Size>[
        const Size(612, 792),
        const Size(400, 200),
      ]);
      final Uint8List png = await const AndroidPdfPagePngRenderer(
        channel: contract,
      ).renderPage(source: source, pageNumber: 2, width: 1376, height: 688);

      expect(png, <int>[137, 80, 78, 71]);
      expect(calls.map((MethodCall call) => call.method), <String>[
        'inspectDocument',
        'renderPage',
      ]);
      final Map<Object?, Object?> render =
          calls.last.arguments as Map<Object?, Object?>;
      expect(render['pageNumber'], 2);
      expect((render['width'], render['height']), (1376, 688));
      expect(render['format'], 'png');
    },
  );

  test('Android channel rejects malformed native page metadata', () async {
    const MethodChannel channel = MethodChannel(kAndroidPdfRendererChannel);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async {
          return <String, Object?>{
            'pageCount': 2,
            'pages': <Object?>[
              <String, Object?>{'width': 100, 'height': 200},
            ],
          };
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    await expectLater(
      const AndroidPdfRendererChannel(channel: channel).inspectDocument('x'),
      throwsA(isA<FormatException>()),
    );
  });
}

/// The desktop engine needs the native PDFium library. Ask the same vendored
/// loader that pdfrx_engine uses rather than guessing one staging path: native
/// assets may supply PDFium even when it is absent beside flutter_tester.
/// Returns `false` (= run the test) whenever the library genuinely loads.
Object _pdfiumUnavailableReason() {
  try {
    pdfium.getPdfium();
    return false;
  } catch (error) {
    return 'PDFium cannot be loaded on ${Platform.operatingSystem}; '
        'skipping only the native render smoke: $error';
  }
}
