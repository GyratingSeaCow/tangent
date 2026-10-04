// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/models/notebook.dart';
import 'package:tangent/services/notebook_pdf_import.dart';
import 'package:tangent/widgets/notebook_pdf_page_block.dart';

class _RecordingLoader implements PdfPageRasterLoader {
  _RecordingLoader(this.directory, this.png);

  final Directory directory;
  final Uint8List png;
  final List<int> pages = <int>[];

  @override
  Future<File> loadPage({
    required String sourceData,
    required int pageNumber,
    required int width,
    required int height,
  }) {
    pages.add(pageNumber);
    final File file = File('${directory.path}/page-$pageNumber.png');
    if (!file.existsSync()) file.writeAsBytesSync(png);
    return Future<File>.value(file);
  }
}

const String _tinyPngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk'
    'YPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('100 page blocks raster only pages near the viewport', (
    WidgetTester tester,
  ) async {
    final Directory temp = Directory.systemTemp.createTempSync('pdf-lazy-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final Uint8List png = base64Decode(_tinyPngBase64);
    final _RecordingLoader loader = _RecordingLoader(temp, png);
    final ValueNotifier<Rect> visible = ValueNotifier<Rect>(
      const Rect.fromLTWH(0, 0, 720, 800),
    );
    addTearDown(visible.dispose);
    const double step = 1024;
    final List<NotebookPdfPageBlock> pages = <NotebookPdfPageBlock>[
      for (int index = 0; index < 100; index++)
        NotebookPdfPageBlock(
          id: 'page-$index',
          documentId: 'doc',
          pageNumber: index + 1,
          pageCount: 100,
          data: index == 0 ? 'cGRm' : null,
          x: 16,
          y: index * step,
          width: 688,
          height: 1000,
        ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 720,
          height: 800,
          child: Stack(
            children: <Widget>[
              for (final NotebookPdfPageBlock page in pages)
                Positioned(
                  left: page.x,
                  top: page.y,
                  child: NotebookPdfPageBlockWidget(
                    block: page,
                    sourceData: 'cGRm',
                    loader: loader,
                    visiblePageRect: visible,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(loader.pages, <int>[
      1,
    ], reason: 'mounting 100 blocks must not decode 100 pages into RAM');

    visible.value = const Rect.fromLTWH(0, 50 * step, 720, 800);
    await tester.pump();
    await tester.pump();

    expect(loader.pages, <int>[1, 50, 51]);
    expect(
      loader.pages.length,
      lessThanOrEqualTo(3),
      reason: 'render calls follow visible pages, not total page count',
    );
    expect(find.byType(Image), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });
}
