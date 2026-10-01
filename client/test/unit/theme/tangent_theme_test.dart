// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/theme/tangent_theme.dart';
import 'package:tangent/theme/tangent_tokens.dart';

double _contrast(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  group('Instrument palettes', () {
    const palettes = <String, TangentPalette>{
      'aluminium': TangentPalette.aluminium,
      'anodized': TangentPalette.anodized,
    };

    test('select is #C4EC42 lime in BOTH themes, hot is distinct', () {
      for (final p in palettes.values) {
        expect(p.select, const Color(0xFFC4EC42));
        expect(p.hot, const Color(0xFFFF4F1F));
        expect(p.select, isNot(p.hot));
      }
    });

    test('text and icons on a lime fill are always near-black', () {
      for (final entry in palettes.entries) {
        final p = entry.value;
        expect(p.onSelect, const Color(0xFF111111));
        expect(
          _contrast(p.onSelect, p.select),
          greaterThanOrEqualTo(4.5),
          reason: '${entry.key}: onSelect must clear AA on the select fill',
        );
      }
    });

    test('primary ink clears WCAG AA on chassis and panel in both themes',
        () {
      for (final entry in palettes.entries) {
        final p = entry.value;
        expect(
          _contrast(p.ink, p.chassis),
          greaterThanOrEqualTo(4.5),
          reason: '${entry.key}: ink on chassis',
        );
        expect(
          _contrast(p.ink, p.panel),
          greaterThanOrEqualTo(4.5),
          reason: '${entry.key}: ink on panel',
        );
      }
    });

    test('the display window is near-black in both themes', () {
      for (final p in palettes.values) {
        expect(p.display.computeLuminance(), lessThan(0.01));
        expect(_contrast(p.displayDot, p.display), greaterThanOrEqualTo(7));
      }
    });

    test('aluminium is light, anodized is dark', () {
      expect(TangentPalette.aluminium.brightness, Brightness.light);
      expect(TangentPalette.anodized.brightness, Brightness.dark);
      expect(
        TangentPalette.aluminium.chassis.computeLuminance(),
        greaterThan(TangentPalette.anodized.chassis.computeLuminance()),
      );
    });

    test('variant() maps the enum to the matching palette', () {
      expect(
        TangentPalette.variant(TangentVariant.aluminium),
        same(TangentPalette.aluminium),
      );
      expect(
        TangentPalette.variant(TangentVariant.anodized),
        same(TangentPalette.anodized),
      );
    });
  });

  group('Instrument shapes', () {
    test('radius scale is the approved 4 / 8 / 12 / 18', () {
      expect(TangentShapes.radiusTag, 4.0);
      expect(TangentShapes.radiusControl, 8.0);
      expect(TangentShapes.radiusPanel, 12.0);
      expect(TangentShapes.radiusSheet, 18.0);
    });

    test('legacy aliases resolve inside the approved scale (no pills)', () {
      expect(TangentShapes.panelRadius, TangentShapes.radiusControl);
      expect(TangentShapes.sheetRadius, TangentShapes.radiusSheet);
    });

    test('elevation is a hard drop with no blur', () {
      for (final shadow in TangentShapes.hardDrop) {
        expect(
          shadow.blurRadius,
          0,
          reason: 'blurred shadows read as Material cards, not hardware',
        );
      }
    });
  });

  group('tangentTheme', () {
    test('defaults to Anodized', () {
      final theme = tangentTheme();
      expect(theme.brightness, Brightness.dark);
      expect(
        theme.scaffoldBackgroundColor,
        TangentPalette.anodized.chassis,
      );
    });

    for (final variant in TangentVariant.values) {
      final p = TangentPalette.variant(variant);

      group(variant.name, () {
        final theme = tangentTheme(variant);

        test('registers its palette as a theme extension', () {
          expect(theme.extension<TangentPalette>(), same(p));
        });

        test('is built on the chassis with lime as primary', () {
          expect(theme.brightness, p.brightness);
          expect(theme.scaffoldBackgroundColor, p.chassis);
          expect(theme.colorScheme.primary, p.select);
          expect(theme.colorScheme.onPrimary, p.onSelect);
          expect(theme.useMaterial3, isTrue);
        });

        test('cards use the panel colour and the panel radius', () {
          expect(theme.cardTheme.color, p.panel);
          final shape = theme.cardTheme.shape as RoundedRectangleBorder;
          expect(
            shape.borderRadius,
            BorderRadius.circular(TangentShapes.radiusPanel),
          );
        });

        test('the FAB is the CREATE key: lime select, dark content, rounded',
            () {
          // Instrument Console v2: red is reserved for recording and
          // destruction; the Capture screen's record key is bespoke.
          expect(theme.floatingActionButtonTheme.backgroundColor, p.select);
          expect(theme.floatingActionButtonTheme.foregroundColor, p.onSelect);
          final shape =
              theme.floatingActionButtonTheme.shape as RoundedRectangleBorder;
          expect(
            shape.borderRadius,
            BorderRadius.circular(TangentShapes.radiusPanel),
          );
        });

        test('error colour is hot so destructive reads as live', () {
          expect(theme.colorScheme.error, p.hot);
        });

        test('selected chips fill lime with black content, 4px radius', () {
          expect(theme.chipTheme.selectedColor, p.select);
          expect(theme.chipTheme.backgroundColor, Colors.transparent);
          expect(theme.chipTheme.secondaryLabelStyle?.color, p.onSelect);
          final shape = theme.chipTheme.shape as RoundedRectangleBorder;
          expect(
            shape.borderRadius,
            BorderRadius.circular(TangentShapes.radiusTag),
            reason: 'never square, never pills',
          );
        });

        test('filled buttons put black on lime', () {
          final style = theme.filledButtonTheme.style!;
          expect(
            style.backgroundColor!.resolve(const <WidgetState>{}),
            p.select,
          );
          expect(
            style.foregroundColor!.resolve(const <WidgetState>{}),
            p.onSelect,
          );
        });
      });
    }
  });

  group('applied to a real widget tree', () {
    for (final variant in TangentVariant.values) {
      testWidgets('scaffold paints the ${variant.name} chassis',
          (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: tangentTheme(variant),
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
        expect(scaffold.color, TangentPalette.variant(variant).chassis);
      });

      testWidgets('TangentPalette.of resolves the ${variant.name} palette',
          (tester) async {
        late TangentPalette resolved;
        await tester.pumpWidget(
          MaterialApp(
            theme: tangentTheme(variant),
            home: Builder(
              builder: (context) {
                resolved = TangentPalette.of(context);
                return const SizedBox.shrink();
              },
            ),
          ),
        );
        expect(resolved, same(TangentPalette.variant(variant)));
      });
    }
  });
}
