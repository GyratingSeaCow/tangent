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

    test('round trips an image block with position, size and bytes', () {
      const source = '{"blocks":['
          '{"kind":"image","id":"img-1","data":"aGVsbG8=",'
          '"mime":"image/jpeg","x":40.0,"y":120.0,'
          '"width":320.0,"height":240.0}'
          ']}';
      final document = NotebookDocument.decode(source);

      final image = document.blocks.single as NotebookImageBlock;
      expect(image.id, 'img-1');
      expect(image.data, 'aGVsbG8=');
      expect(image.mime, 'image/jpeg');
      expect(image.x, 40.0);
      expect(image.y, 120.0);
      expect(image.width, 320.0);
      expect(image.height, 240.0);

      expect(_decode(document.encode()), _decode(source));
    });

    test('image copyWith moves and resizes without touching the bytes', () {
      const image = NotebookImageBlock(
        id: 'img-2',
        data: 'aGVsbG8=',
        mime: 'image/png',
        x: 0,
        y: 0,
        width: 100,
        height: 50,
      );
      final moved = image.copyWith(x: 30, y: 60, width: 200, height: 100);
      expect(moved.id, 'img-2');
      expect(moved.data, 'aGVsbG8=');
      expect(moved.mime, 'image/png');
      expect(moved.x, 30);
      expect(moved.y, 60);
      expect(moved.width, 200);
      expect(moved.height, 100);
    });

    test('a malformed image block is preserved verbatim, not dropped', () {
      // width missing: this build cannot render it, but the bytes and every
      // other field must survive a load/save cycle untouched.
      const source = '{"blocks":['
          '{"kind":"image","id":"img-3","data":"aGVsbG8=",'
          '"mime":"image/jpeg","x":1.0,"y":2.0}'
          ']}';
      final document = NotebookDocument.decode(source);
      expect(document.blocks.single, isA<NotebookUnknownBlock>());
      expect(_decode(document.encode()), _decode(source));
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

    test('round trips per-point pressure and pen style', () {
      // Fountain strokes taper with pressure, so each point may carry `p`
      // and the stroke may carry a style. Both are optional on the wire.
      const source = '{"strokes":['
          '{"id":"s1","width":3.0,"style":"fountain","points":['
          '{"x":1.0,"y":2.0,"p":0.25},{"x":3.0,"y":4.0,"p":0.8}]}'
          ']}';
      final ink = NotebookInk.decode(source);
      final stroke = ink.strokes.single;
      expect(stroke.style, PenStyle.fountain);
      expect(stroke.points.map((p) => p.p).toList(), [0.25, 0.8]);
      expect(_decode(ink.encode()), _decode(source));
    });

    test('legacy strokes without style or pressure load as flat ballpoint', () {
      // Refusing to break existing notebook files is worth more than uniform
      // data: an old file must load, render flat, and re-encode without
      // gaining fields it never had.
      const source = '{"strokes":['
          '{"id":"s1","width":3.0,"points":[{"x":1.0,"y":2.0}]}'
          ']}';
      final ink = NotebookInk.decode(source);
      final stroke = ink.strokes.single;
      expect(stroke.style, PenStyle.ballpoint);
      expect(stroke.points.single.p, isNull);
      expect(_decode(ink.encode()), _decode(source));
    });

    test('an unknown style degrades to ballpoint rather than dropping ink', () {
      final ink = NotebookInk.decode(
        '{"strokes":[{"id":"s","width":2.0,"style":"laser",'
        '"points":[{"x":1,"y":2}]}]}',
      );
      expect(ink.strokes.single.style, PenStyle.ballpoint);
    });

    test('non-numeric pressure is dropped, not fatal', () {
      final ink = NotebookInk.decode(
        '{"strokes":[{"id":"s","width":2.0,'
        '"points":[{"x":1,"y":2,"p":"hard"}]}]}',
      );
      expect(ink.strokes.single.points.single.p, isNull);
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
