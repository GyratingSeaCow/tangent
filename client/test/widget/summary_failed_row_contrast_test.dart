import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/theme/tangent_theme.dart';
import 'package:tangent/widgets/summary_failed_row.dart';

import '../support/dump_view_fixture.dart';

/// Pins the v1.19.0 device finding: under the REAL app theme the Retry
/// label must be legible on the red banner. `ColorScheme.error` and
/// `errorContainer` are near-identical on the M3 dark scheme, so a label
/// painted with `error` disappears. Measured, not eyeballed: the label's
/// resolved colour must sit far from the banner fill.
void main() {
  testWidgets('Retry and dismiss contrast with the failed banner under tangentTheme',
      (tester) async {
    final DumpRow row = viewRow('fail-1').copyWith(
      summaryStatus: const Value<String?>('failed'),
      summaryError: const Value<String?>('RuntimeError: summarize_infer exited -9'),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: tangentTheme(),
        home: Scaffold(
          body: SummaryFailedRow(
            row: row,
            onRetry: () {},
            onDismiss: () {},
          ),
        ),
      ),
    );

    final BuildContext ctx =
        tester.element(find.byKey(const ValueKey<String>('summary-retry-fail-1')));
    final ColorScheme colors = Theme.of(ctx).colorScheme;
    final Color banner = colors.errorContainer;

    final TextButton retry =
        tester.widget(find.byKey(const ValueKey<String>('summary-retry-fail-1')));
    final Color label = retry.style!.foregroundColor!.resolve(<WidgetState>{})!;

    // Distance in RGB space; the two reds that hid the button are ~0.03 apart.
    double dist(Color a, Color b) =>
        ((a.r - b.r).abs() + (a.g - b.g).abs() + (a.b - b.b).abs());
    expect(
      dist(label, banner),
      greaterThan(0.6),
      reason: 'Retry label $label is not legible on banner $banner',
    );
    expect(find.text('Retry'), findsOneWidget);

    final IconButton dismiss =
        tester.widget(find.byKey(const ValueKey<String>('summary-dismiss-fail-1')));
    expect(dist(dismiss.color!, banner), greaterThan(0.6));
  });
}
