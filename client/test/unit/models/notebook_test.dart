// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/models/notebook.dart';

Map<String, dynamic> _decode(String source) =>
    jsonDecode(source) as Map<String, dynamic>;

void main() {
  group('defaultNotebookTitle', () {
    test('formats the creation instant as Notebook <yyyy-MM-dd HH-mm-ss>', () {
      expect(
        defaultNotebookTitle(DateTime(2026, 9, 17, 14, 5, 9)),
        'Notebook 2026-09-17 14-05-09',
      );
      expect(
        defaultNotebookTitle(DateTime(2026, 12, 31, 23, 59, 59)),
        'Notebook 2026-12-31 23-59-59',
      );
    });
  });

  group('NotebookDocument codec', () {
    test('round trips text, checkbox and dumpCard blocks in order', () {
      const source = '{"blocks":['
          '{"kind":"text","id":"block-1","text":"hello"},'
          '{"kind":"checkbox","id":"block-2","text":"buy milk","checked":true},'
          '{"kind":"dumpCard","id":"block-3","dumpId":"dump-9",'
          '"x":12.0,"y":340.0}'
          ']}';
      final document = NotebookDocument.decode(source);

      expect(document.blocks, hasLength(3));
      final text = document.blocks[0] as NotebookTextBlock;
      expect(text.id, 'block-1');
      expect(text.text, 'hello');
      final checkbox = document.blocks[1] as NotebookCheckboxBlock;
      expect(checkbox.id, 'block-2');
      expect(checkbox.text, 'buy milk');
      expect(checkbox.checked, isTrue);
      final card = document.blocks[2] as NotebookDumpCardBlock;
      expect(card.id, 'block-3');
      expect(card.dumpId, 'dump-9');
      expect(card.x, 12.0);
      expect(card.y, 340.0);

      expect(_decode(document.encode()), _decode(source));
    });

    test('decodes integer coordinates as doubles without losing them', () {
      final document = NotebookDocument.decode(
        '{"blocks":[{"kind":"dumpCard","id":"b","dumpId":"d","x":12,"y":340}]}',
      );
      final card = document.blocks.single as NotebookDumpCardBlock;
      expect(card.x, 12.0);
      expect(card.y, 340.0);
    });

    test('checkbox defaults to unchecked when the flag is absent', () {
      final document = NotebookDocument.decode(
        '{"blocks":[{"kind":"checkbox","id":"b","text":"t"}]}',
      );
      expect((document.blocks.single as NotebookCheckboxBlock).checked, isFalse);
    });

    test('preserves an unknown block kind verbatim across load and save', () {
      const source = '{"blocks":['
          '{"kind":"text","id":"block-1","text":"before"},'
          '{"kind":"futureThing","id":"block-2","payload":{"deep":[1,2,3]},'
          '"extra":"keep me"},'
          '{"kind":"text","id":"block-3","text":"after"}'
          ']}';

      final document = NotebookDocument.decode(source);
      expect(document.blocks, hasLength(3));
      final unknown = document.blocks[1] as NotebookUnknownBlock;
      expect(unknown.id, 'block-2');
      expect(unknown.raw['kind'], 'futureThing');
      expect(unknown.raw['extra'], 'keep me');

      final saved = _decode(document.encode());
      final blocks = saved['blocks'] as List<dynamic>;
      expect(blocks, hasLength(3));
      expect(blocks[1], _decode(source)['blocks'][1]);

      // A second round trip must remain byte-stable.
      expect(
        _decode(NotebookDocument.decode(document.encode()).encode()),
        saved,
      );
    });

    test('treats a malformed known block as unknown instead of dropping it',
        () {
      const source =
          '{"blocks":[{"kind":"text","id":"block-1","text":{"not":"a string"}}]}';
      final document = NotebookDocument.decode(source);
      final block = document.blocks.single;
      expect(block, isA<NotebookUnknownBlock>());
      expect(_decode(document.encode()), _decode(source));
    });

    test('degrades malformed, absent or non-object JSON to an empty document',
        () {
      for (final source in <String?>[
        null,
        '',
        '   ',
        'not json at all',
        '{"blocks": ',
        '[]',
        '"a string"',
        '{"blocks": "not a list"}',
        '{}',
      ]) {
        final document = NotebookDocument.decode(source);
        expect(
          document.blocks,
          isEmpty,
          reason: 'Expected empty document for ${jsonEncode(source)}',
        );
      }
    });

    test('encodes an empty document as an empty block list', () {
      expect(const NotebookDocument.empty().encode(), '{"blocks":[]}');
    });

    test('skips list entries that are not JSON objects', () {
      final document = NotebookDocument.decode(
        '{"blocks":["nope",42,{"kind":"text","id":"b","text":"kept"}]}',
      );
      expect(document.blocks, hasLength(1));
      expect((document.blocks.single as NotebookTextBlock).text, 'kept');
    });
  });

  group('NotebookInk codec', () {
    test('round trips strokes with their width and points', () {
      const source = '{"strokes":['
          '{"id":"stroke-1","width":3.0,"points":[{"x":1.0,"y":2.0},'
          '{"x":3.5,"y":4.25}]}'
          ']}';
      final ink = NotebookInk.decode(source);
      expect(ink.strokes, hasLength(1));
      final stroke = ink.strokes.single;
      expect(stroke.id, 'stroke-1');
      expect(stroke.width, 3.0);
      expect(stroke.points.map((p) => p.x).toList(), [1.0, 3.5]);
      expect(stroke.points.map((p) => p.y).toList(), [2.0, 4.25]);
      expect(_decode(ink.encode()), _decode(source));
    });

    test('accepts integer widths and coordinates', () {
      final ink = NotebookInk.decode(
        '{"strokes":[{"id":"s","width":3,"points":[{"x":1,"y":2}]}]}',
      );
      expect(ink.strokes.single.width, 3.0);
      expect(ink.strokes.single.points.single.x, 1.0);
    });

    test('degrades malformed or absent ink JSON to no strokes', () {
      for (final source in <String?>[
        null,
        '',
        'not json',
        '{"strokes": ',
        '{}',
        '{"strokes": 7}',
        '[]',
      ]) {
        expect(
          NotebookInk.decode(source).strokes,
          isEmpty,
          reason: 'Expected empty ink for ${jsonEncode(source)}',
        );
      }
    });

    test('drops individual malformed strokes and points', () {
      final ink = NotebookInk.decode(
        '{"strokes":[7,{"id":"s1"},'
        '{"id":"s2","width":"wide","points":[]},'
        '{"id":"s3","width":2.0,"points":[{"x":1.0},{"x":1.0,"y":2.0}]}]}',
      );
      expect(ink.strokes.map((s) => s.id).toList(), ['s3']);
      expect(ink.strokes.single.points, hasLength(1));
    });

    test('encodes empty ink as an empty stroke list', () {
      expect(const NotebookInk.empty().encode(), '{"strokes":[]}');
    });
  });

  group('Notebook', () {
    test('copyWith replaces only the requested fields', () {
      final notebook = Notebook(
        id: 'n1',
        title: 'Original',
        createdAt: DateTime.fromMillisecondsSinceEpoch(1000, isUtc: true),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(2000, isUtc: true),
        document: NotebookDocument.decode(
          '{"blocks":[{"kind":"text","id":"b","text":"t"}]}',
        ),
        ink: const NotebookInk.empty(),
      );

      final renamed = notebook.copyWith(title: 'Renamed');
      expect(renamed.title, 'Renamed');
      expect(renamed.id, 'n1');
      expect(renamed.createdAt, notebook.createdAt);
      expect(renamed.document.encode(), notebook.document.encode());
    });
  });
}
