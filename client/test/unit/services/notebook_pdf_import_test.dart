// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:tangent/models/notebook.dart';
import 'package:tangent/services/notebook_import.dart';
import 'package:tangent/services/notebook_pdf_import.dart';

class _Inspector implements PdfDocumentInspector {
  _Inspector(this.sizes);

  final List<Size> sizes;
  int calls = 0;

  @override
  Future<List<Size>> inspect(Uint8List bytes) async {
    calls++;
    return sizes;
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
    },
  );

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
        sourceData: source,
        pageNumber: 2,
        width: 200,
        height: 300,
      ),
      cache.loadPage(
        sourceData: source,
        pageNumber: 2,
        width: 200,
        height: 300,
      ),
    ]);
    final File again = await cache.loadPage(
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

  test('pdfrx inspects and renders a real locally generated PDF', () async {
    final Uint8List bytes = await _twoPagePdf();
    final List<Size> sizes = await const PdfrxDocumentInspector().inspect(
      bytes,
    );
    expect(sizes, hasLength(2));
    expect(sizes[0].width, closeTo(200, 0.1));
    expect(sizes[0].height, closeTo(300, 0.1));
    expect(sizes[1].width, closeTo(400, 0.1));
    expect(sizes[1].height, closeTo(200, 0.1));

    final Directory temp = await Directory.systemTemp.createTemp('pdfrx-real-');
    addTearDown(() => temp.delete(recursive: true));
    final File source = File('${temp.path}/source.pdf');
    await source.writeAsBytes(bytes);
    final Uint8List png = await const PdfrxPagePngRenderer().renderPage(
      source: source,
      pageNumber: 2,
      width: 400,
      height: 200,
    );
    expect(png.sublist(0, 8), <int>[137, 80, 78, 71, 13, 10, 26, 10]);
    expect(png.length, greaterThan(500));
  });
}
