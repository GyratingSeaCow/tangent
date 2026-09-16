// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'bound_service_fixture.dart';

// Bound acquisition includes real filesystem I/O. Pump fake-zone callbacks
// while permitting the original OS futures to settle; never replace the I/O.
Future<void> pumpBoundUntil(
  WidgetTester tester,
  FutureOr<bool> Function() predicate,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (true) {
    bool? ready;
    Object? error;
    StackTrace? stack;
    await tester.runAsync(() async {
      unawaited(
        Future<bool>.sync(predicate).then<void>(
          (value) {
            ready = value;
          },
          onError: (Object e, StackTrace s) {
            error = e;
            stack = s;
          },
        ),
      );
    });
    do {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump(const Duration(milliseconds: 10));
      if (DateTime.now().isAfter(deadline)) {
        fail('Bound widget lifetime did not settle');
      }
    } while (ready == null && error == null);
    if (error != null) Error.throwWithStackTrace(error!, stack!);
    if (ready == true) return;
  }
}

Future<void> disposeBoundWidget(
  WidgetTester tester,
  BoundServiceFixture bound,
) async {
  await tester.pumpWidget(const SizedBox.shrink());
  var drained = false;
  await tester.runAsync(() async {
    unawaited(bound.mutations.drain().then((_) => drained = true));
  });
  await pumpBoundUntil(tester, () => drained);
}
