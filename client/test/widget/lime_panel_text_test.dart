// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/theme/tangent_theme.dart';
import 'package:tangent/theme/tangent_tokens.dart';

/// Blackout: text drawn ON the lime panel must be dark.
///
/// Found on the device — the transcription-failure banner inherited the app's
/// light text colour (correct on the near-black chassis) and painted it over a
/// filled lime card, which was very nearly invisible. The error code stays red
/// on purpose: it is the one thing that should stand out there.
///
/// This reproduces the panel's colour contract rather than mounting the whole
/// detail screen, so it fails for exactly one reason.
void main() {
  double contrast(Color a, Color b) {
    final la = a.computeLuminance(), lb = b.computeLuminance();
    final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
    return (hi + 0.05) / (lo + 0.05);
  }

  Widget panel(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final onPanel = scheme.onSecondaryContainer;
    return Card(
      color: scheme.secondaryContainer,
      child: Column(
        children: [
          Text(
            'Server transcription failed',
            style:
                Theme.of(context).textTheme.titleMedium?.copyWith(color: onPanel),
          ),
          Text(
            'The previous transcript and raw recording are preserved on this device.',
            style: TextStyle(color: onPanel),
          ),
          Text(
            'LocalTranscriptionServerError: Server returned an empty transcript',
            style: TextStyle(color: scheme.error),
          ),
        ],
      ),
    );
  }

  testWidgets('title and body are dark on the lime panel', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: tangentTheme(),
        home: Scaffold(body: Builder(builder: panel)),
      ),
    );

    for (final label in const [
      'Server transcription failed',
      'The previous transcript and raw recording are preserved on this device.',
    ]) {
      final text = tester.widget<Text>(find.text(label));
      expect(
        text.style?.color,
        TangentColors.sunken,
        reason: '"$label" must be dark on lime, not the light chassis colour',
      );
      expect(
        contrast(text.style!.color!, TangentColors.signal),
        greaterThanOrEqualTo(4.5),
      );
    }
  });

  testWidgets('the error code stays red', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: tangentTheme(),
        home: Scaffold(body: Builder(builder: panel)),
      ),
    );

    final error = tester.widget<Text>(
      find.text(
        'LocalTranscriptionServerError: Server returned an empty transcript',
      ),
    );
    expect(error.style?.color, TangentColors.record);
  });

  testWidgets('the panel is filled with the signal colour', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: tangentTheme(),
        home: Scaffold(body: Builder(builder: panel)),
      ),
    );

    expect(tester.widget<Card>(find.byType(Card)).color, TangentColors.signal);
  });
}
