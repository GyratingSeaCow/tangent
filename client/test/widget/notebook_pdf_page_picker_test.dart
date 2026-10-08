// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/services/notebook_pdf_import.dart';
import 'package:tangent/widgets/notebook_pdf_page_picker.dart';

const String _tinyPngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk'
    'YPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';

class _RecordingPreviewLoader implements PdfPageRasterLoader {
  _RecordingPreviewLoader(this.directory);

  final Directory directory;
  final List<int> pages = <int>[];
  final List<(int, int)> sizes = <(int, int)>[];

  @override
  Future<File> loadPage({
    required String documentId,
    required String sourceData,
    required int pageNumber,
    required int width,
    required int height,
  }) async {
    pages.add(pageNumber);
    sizes.add((width, height));
    final File file = File('${directory.path}/preview-$pageNumber.png');
    if (!file.existsSync()) {
      file.writeAsBytesSync(base64Decode(_tinyPngBase64));
    }
    return file;
  }
}

class _PendingPreviewLoader implements CancellablePdfPageRasterLoader {
  final Map<int, Completer<File>> pending = <int, Completer<File>>{};
  final List<int> cancelledPages = <int>[];

  @override
  Future<File> loadPage({
    required String documentId,
    required String sourceData,
    required int pageNumber,
    required int width,
    required int height,
  }) => pending.putIfAbsent(pageNumber, Completer<File>.new).future;

  @override
  void cancelPage({
    required String documentId,
    required int pageNumber,
    required int width,
    required int height,
  }) {
    cancelledPages.add(pageNumber);
    final Completer<File>? request = pending[pageNumber];
    if (request != null && !request.isCompleted) {
      request.completeError(const PdfRenderCancelledException());
    }
  }

  @override
  Future<void> dispose() async {}
}

PickedPdf _picked(int pageCount) => PickedPdf(
  bytes: Uint8List.fromList(<int>[1, 2, 3, 4]),
  documentId: 'picker-doc',
  pageSizes: List<Size>.generate(
    pageCount,
    (int index) => index.isEven ? const Size(612, 792) : const Size(792, 612),
  ),
  name: 'selection.pdf',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;
  late _RecordingPreviewLoader loader;
  late List<NotebookPdfPageSelection?> results;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('pdf-picker-preview-');
    loader = _RecordingPreviewLoader(temp);
    results = <NotebookPdfPageSelection?>[];
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  Future<void> openPicker(
    WidgetTester tester, {
    int pageCount = 4,
    PdfPageRasterLoader? previewLoader,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: TextButton(
              key: const ValueKey('open-picker'),
              onPressed: () => unawaited(
                NotebookPdfPagePicker.show(
                  context,
                  picked: _picked(pageCount),
                  loader: previewLoader ?? loader,
                ).then(results.add),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open-picker')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  Future<bool?> checkboxValue(WidgetTester tester, int page) async {
    final Finder checkbox = find.byKey(
      ValueKey<String>('pdf-page-checkbox-$page'),
    );
    await tester.scrollUntilVisible(
      checkbox,
      180,
      scrollable: find.descendant(
        of: find.byKey(const ValueKey('pdf-page-list')),
        matching: find.byType(Scrollable),
      ),
    );
    return tester.widget<Checkbox>(checkbox).value;
  }

  Future<void> tapThumbnail(WidgetTester tester, int page) async {
    final Finder thumbnail = find.byKey(
      ValueKey<String>('pdf-page-thumbnail-$page'),
    );
    await tester.scrollUntilVisible(
      thumbnail,
      180,
      scrollable: find.descendant(
        of: find.byKey(const ValueKey('pdf-page-list')),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.tap(thumbnail);
  }

  testWidgets('starts with every page selected and thumbnail taps toggle it', (
    WidgetTester tester,
  ) async {
    await openPicker(tester);

    expect(find.text('4 of 4 pages selected'), findsOneWidget);
    expect(await checkboxValue(tester, 1), isTrue);

    await tapThumbnail(tester, 1);
    await tester.pump();

    expect(find.text('3 of 4 pages selected'), findsOneWidget);
    expect(await checkboxValue(tester, 1), isFalse);
  });

  testWidgets('Apply replaces the selection with the entered page range', (
    WidgetTester tester,
  ) async {
    await openPicker(tester);

    await tester.enterText(find.byKey(const ValueKey('pdf-page-range')), '2-3');
    await tester.tap(find.byKey(const ValueKey('pdf-page-range-apply')));
    await tester.pump();

    expect(find.text('2 of 4 pages selected'), findsOneWidget);
    expect(await checkboxValue(tester, 1), isFalse);
    expect(await checkboxValue(tester, 2), isTrue);
    expect(await checkboxValue(tester, 3), isTrue);
    expect(await checkboxValue(tester, 4), isFalse);
  });

  testWidgets('Import applies valid dirty range text without an Apply tap', (
    WidgetTester tester,
  ) async {
    await openPicker(tester);

    await tester.enterText(find.byKey(const ValueKey('pdf-page-range')), '2-3');
    await tester.tap(find.byKey(const ValueKey('pdf-page-import')));
    await tester.pumpAndSettle();

    expect(results.single!.pages, <int>{2, 3});
    expect(results.single!.sourceData, base64Encode(<int>[1, 2, 3, 4]));
  });

  testWidgets('checkbox toggle after a dirty range applies the range first', (
    WidgetTester tester,
  ) async {
    await openPicker(tester);

    // Vera round-2 Important #1: type a range without Apply, then refine by
    // checkbox. The most recent gesture must win and the header must match
    // what Import returns.
    await tester.enterText(find.byKey(const ValueKey('pdf-page-range')), '1-2');
    await tapThumbnail(tester, 1);
    await tester.pump();

    expect(find.text('1 of 4 pages selected'), findsOneWidget);
    expect(await checkboxValue(tester, 1), isFalse);
    expect(await checkboxValue(tester, 2), isTrue);

    await tester.tap(find.byKey(const ValueKey('pdf-page-import')));
    await tester.pumpAndSettle();
    expect(results.single!.pages, <int>{2});
  });

  testWidgets('whitespace-only edit of an applied range is not dirty', (
    WidgetTester tester,
  ) async {
    await openPicker(tester);

    await tester.enterText(find.byKey(const ValueKey('pdf-page-range')), '1-4');
    await tester.tap(find.byKey(const ValueKey('pdf-page-range-apply')));
    await tester.pump();
    await tapThumbnail(tester, 1);
    await tester.pump();
    // Trailing space must not resurrect the applied "1-4" over the toggle.
    await tester.enterText(
      find.byKey(const ValueKey('pdf-page-range')),
      '1-4 ',
    );
    await tester.pump();

    expect(find.text('3 of 4 pages selected'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('pdf-page-import')));
    await tester.pumpAndSettle();
    expect(results.single!.pages, <int>{2, 3, 4});
  });

  testWidgets('empty range leaves checkbox selection in control of Import', (
    WidgetTester tester,
  ) async {
    await openPicker(tester);

    await tester.enterText(find.byKey(const ValueKey('pdf-page-range')), '   ');
    await tapThumbnail(tester, 1);
    await tester.pump();

    expect(find.text('3 of 4 pages selected'), findsOneWidget);
    expect(
      find.text('Enter page numbers and ranges like 1-3,7.'),
      findsNothing,
    );
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('pdf-page-import')))
          .onPressed,
      isNotNull,
    );

    await tester.tap(find.byKey(const ValueKey('pdf-page-import')));
    await tester.pumpAndSettle();
    expect(results.single!.pages, <int>{2, 3, 4});
  });

  testWidgets('invalid ranges show inline errors and disable Import', (
    WidgetTester tester,
  ) async {
    await openPicker(tester);
    final Finder range = find.byKey(const ValueKey('pdf-page-range'));

    await tester.enterText(range, '0');
    await tester.pump();
    expect(find.textContaining('1 to 4'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('pdf-page-import')))
          .onPressed,
      isNull,
    );

    await tester.enterText(range, 'abc');
    await tester.pump();
    expect(
      find.text('Enter page numbers and ranges like 1-3,7.'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('pdf-page-import')))
          .onPressed,
      isNull,
    );
    expect(results, isEmpty, reason: 'invalid input must not import anything');
  });

  testWidgets('Cancel returns no selected pages', (WidgetTester tester) async {
    await openPicker(tester);

    await tester.tap(find.byKey(const ValueKey('pdf-page-cancel')));
    await tester.pumpAndSettle();

    expect(results, <NotebookPdfPageSelection?>[null]);
  });

  testWidgets('closing the picker cancels in-flight thumbnail renders', (
    WidgetTester tester,
  ) async {
    final _PendingPreviewLoader pending = _PendingPreviewLoader();
    await openPicker(tester, previewLoader: pending);
    expect(pending.pending, isNotEmpty);

    await tester.tap(find.byKey(const ValueKey('pdf-page-cancel')));
    await tester.pumpAndSettle();

    expect(pending.cancelledPages, isNotEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('large PDFs render only lazy low-resolution thumbnails', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await openPicker(tester, pageCount: 100);

    expect(loader.pages, isNotEmpty);
    expect(
      loader.pages.length,
      lessThan(100),
      reason: 'ListView.builder must not render every preview up front',
    );
    expect(
      loader.sizes,
      everyElement(
        predicate<(int, int)>(
          ((int, int) size) => size.$1 <= 144 && size.$2 <= 192,
          'at most a 144x192 low-DPI raster',
        ),
      ),
    );
  });
}
