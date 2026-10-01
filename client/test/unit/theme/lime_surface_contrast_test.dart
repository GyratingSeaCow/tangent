// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/theme/tangent_theme.dart';
import 'package:tangent/theme/tangent_tokens.dart';

/// Blackout: a filled lime panel must state its own text colour.
///
/// Found on the device — the transcription-failure banner painted its title
/// and body in the default light `onSurface` over a lime `secondaryContainer`,
/// which is very nearly invisible. Anything sitting ON the signal colour has
/// to use the dark `onSecondary`/`onSecondaryContainer` pair.
void main() {
  double contrast(Color a, Color b) {
    final la = a.computeLuminance(), lb = b.computeLuminance();
    final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
    return (hi + 0.05) / (lo + 0.05);
  }

  group('text on a lime surface', () {
    test('the scheme pins a dark on-colour for both lime containers', () {
      final scheme = tangentTheme().colorScheme;

      expect(scheme.secondaryContainer, TangentColors.signal);
      expect(scheme.onSecondaryContainer, TangentColors.sunken);
      expect(scheme.onPrimary, TangentColors.sunken);
    });

    test('body text on lime clears WCAG AA', () {
      final scheme = tangentTheme().colorScheme;

      expect(
        contrast(scheme.onSecondaryContainer, scheme.secondaryContainer),
        greaterThanOrEqualTo(4.5),
      );
    });

    test('the default light text colour would have failed on lime', () {
      // Guards the regression itself: if someone reverts to onSurface here,
      // this documents why that is unreadable.
      final scheme = tangentTheme().colorScheme;

      expect(
        contrast(scheme.onSurface, scheme.secondaryContainer),
        lessThan(4.5),
        reason: 'light-on-lime is the bug this fix exists to prevent',
      );
    });

    test('error text must NOT sit directly on lime — use onSelect instead',
        () {
      // Instrument rule: text and icons on a lime fill are ALWAYS black
      // (onSecondaryContainer). The Blackout-era red-on-lime error code is
      // retired because the Instrument hot (#FF4F1F) only measures ~2.4:1
      // on the lime — illegible. A failure banner on lime renders its code
      // in the dark on-colour like everything else on that surface.
      final scheme = tangentTheme().colorScheme;

      expect(scheme.error, TangentColors.record);
      expect(
        contrast(scheme.error, scheme.secondaryContainer),
        lessThan(4.5),
        reason: 'documents WHY hot text is banned on lime fills',
      );
      expect(
        contrast(scheme.onSecondaryContainer, scheme.secondaryContainer),
        greaterThanOrEqualTo(4.5),
        reason: 'the on-colour is what error text on lime must use',
      );
    });
  });
}
