// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/theme/tangent_theme.dart';
import 'package:tangent/theme/tangent_tokens.dart';

void main() {
  group('Blackout tokens', () {
    test('signal lime is the accent, and record red is distinct from it', () {
      expect(TangentColors.signal, const Color(0xFFD4FF47));
      expect(TangentColors.record, const Color(0xFFFF3B30));
      expect(TangentColors.signal, isNot(TangentColors.record));
    });

    test('handwriting ink is white, never the signal colour', () {
      // Deliberate product decision: lime ink fights the transcript.
      expect(TangentColors.ink, const Color(0xFFEDF1F3));
      expect(TangentColors.ink, isNot(TangentColors.signal));
      final ink = TangentColors.ink;
      expect(ink.r, greaterThan(0.87));
      expect(ink.g, greaterThan(0.87));
      expect(ink.b, greaterThan(0.87));
    });

    test('surfaces step darker from panel to sunken', () {
      double lum(Color c) => c.computeLuminance();
      expect(lum(TangentColors.panel), greaterThan(lum(TangentColors.surface)));
      expect(lum(TangentColors.surface), greaterThan(lum(TangentColors.sunken)));
    });

    test('body text clears WCAG AA on the app surface', () {
      double contrast(Color a, Color b) {
        final la = a.computeLuminance(), lb = b.computeLuminance();
        final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
        return (hi + 0.05) / (lo + 0.05);
      }

      expect(
        contrast(TangentColors.text, TangentColors.surface),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        contrast(TangentColors.signal, TangentColors.surface),
        greaterThanOrEqualTo(4.5),
      );
    });

    test('hardware shapes: panels are squared, pills are round', () {
      expect(TangentShapes.panelRadius, 7.0);
      expect(TangentShapes.sheetRadius, 14.0);
      expect(TangentShapes.pillRadius, greaterThanOrEqualTo(999.0));
    });

    test('elevation is a hard drop with no blur', () {
      final drop = TangentShapes.hardDrop;
      expect(drop, isNotEmpty);
      for (final shadow in drop) {
        expect(
          shadow.blurRadius,
          0,
          reason: 'blurred shadows read as Material cards, not hardware',
        );
      }
    });
  });

  group('tangentTheme', () {
    test('is dark and built on the Blackout surfaces', () {
      final theme = tangentTheme();
      expect(theme.brightness, Brightness.dark);
      expect(theme.scaffoldBackgroundColor, TangentColors.surface);
      expect(theme.colorScheme.primary, TangentColors.signal);
      expect(theme.colorScheme.surface, TangentColors.surface);
      expect(theme.useMaterial3, isTrue);
    });

    test('cards use the panel colour and the panel radius', () {
      final theme = tangentTheme();
      expect(theme.cardTheme.color, TangentColors.panel);
      final shape = theme.cardTheme.shape as RoundedRectangleBorder;
      expect(
        shape.borderRadius,
        BorderRadius.circular(TangentShapes.panelRadius),
      );
    });

    test('the FAB is the record key: record red, fully round', () {
      final theme = tangentTheme();
      expect(
        theme.floatingActionButtonTheme.backgroundColor,
        TangentColors.record,
      );
      final shape =
          theme.floatingActionButtonTheme.shape as RoundedRectangleBorder;
      expect(
        shape.borderRadius,
        BorderRadius.circular(TangentShapes.pillRadius),
      );
    });

    test('error colour is the record red so destructive reads as live', () {
      expect(tangentTheme().colorScheme.error, TangentColors.record);
    });

    test('selected chips fill with signal, unselected stay outlined', () {
      final theme = tangentTheme();
      expect(theme.chipTheme.selectedColor, TangentColors.signal);
      expect(theme.chipTheme.backgroundColor, Colors.transparent);
    });
  });

  group('applied to a real widget tree', () {
    testWidgets('scaffold paints the Blackout surface', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: tangentTheme(),
          home: const Scaffold(body: Text('x')),
        ),
      );
      final scaffold = tester.widget<Material>(
        find
            .descendant(
              of: find.byType(Scaffold),
              matching: find.byType(Material),
            )
            .first,
      );
      expect(scaffold.color, TangentColors.surface);
    });
  });
}
