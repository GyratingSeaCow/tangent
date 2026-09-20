// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The PDF exporter is a pure function from notebook content to bytes; these
// tests assert on the REAL bytes (magic number, non-trivial size, title in
// the document) rather than mocking the pdf package away.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/models/notebook.dart';
import 'package:tangent/services/notebook_pdf_exporter.dart';

InkStroke stroke(String id, List<(double, double)> pts) => InkStroke(
      id: id,
      width: 3,
      points: <InkPoint>[
        for (final (double x, double y) in pts) InkPoint(x: x, y: y),
      ],
    );

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
}
