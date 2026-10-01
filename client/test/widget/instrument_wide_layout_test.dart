// SPDX-License-Identifier: AGPL-3.0-or-later
/// Instrument Console v2 wide layouts: reading surfaces are centred and
/// capped at [InstrumentScaffold.readingWidth] on a Fold/tablet, and left
/// alone on a phone. Geometry, not widget counts.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/widgets/instrument_scaffold.dart';
import 'package:tangent/widgets/top_nav_rail.dart';

const Key _bodyKey = Key('probe-body');

Future<void> _mount(
  WidgetTester tester,
  double width, {
  double? maxContentWidth,
}) async {
  tester.view.physicalSize = Size(width, 1200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: InstrumentScaffold(
          root: TangentRoot.settings,
          showCreateFab: false,
          maxContentWidth: maxContentWidth,
          body: const SizedBox.expand(key: _bodyKey),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('phone width: a reading surface spans the full width',
      (tester) async {
    await _mount(
      tester,
      412,
      maxContentWidth: InstrumentScaffold.readingWidth,
    );
    expect(tester.getSize(find.byKey(_bodyKey)).width, 412);
    expect(tester.getTopLeft(find.byKey(_bodyKey)).dx, 0);
  });

  testWidgets('fold width: a reading surface is capped and centred',
      (tester) async {
    await _mount(
      tester,
      1000,
      maxContentWidth: InstrumentScaffold.readingWidth,
    );
    final Rect r = tester.getRect(find.byKey(_bodyKey));
    expect(r.width, InstrumentScaffold.readingWidth);
    expect(r.left, (1000 - InstrumentScaffold.readingWidth) / 2);
  });

  testWidgets('fold width: a list root without a cap keeps the full width',
      (tester) async {
    await _mount(tester, 1000);
    expect(tester.getSize(find.byKey(_bodyKey)).width, 1000);
  });

  testWidgets('the rail never overflows, even at 280dp', (tester) async {
    await _mount(tester, 280);
    expect(tester.takeException(), isNull);
    expect(find.byType(TopNavRail), findsOneWidget);
  });
}
