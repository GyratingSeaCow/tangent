// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Reproduces the finalise hang seen on the Galaxy Tab S10 FE.
//
// With gain above unity the capture streams PCM, and stop() waited for the
// stream to drain with `subscription.asFuture()`. package:record hands out a
// BROADCAST stream (record-5.2.1 record.dart:81,
// `_recordStreamCtrl = StreamController.broadcast()`), and a broadcast
// subscription's asFuture() never completes when the stream closes — only on
// an explicit error. So stop() awaited forever: the spinner stayed up, the
// audio sat in staging, nothing published, and nothing appeared in the log
// because nothing had failed.
//
// The fix must satisfy two constraints at once:
//   * never hang, even on a broadcast stream, and
//   * never truncate the tail — cancel() discards chunks the platform has
//     already emitted but not yet delivered, which is why the naive
//     "just cancel it" fix is wrong.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/services/recording_service.dart';

void main() {
  group('draining a PCM stream at stop', () {
    test('completes on a broadcast stream', () async {
      // The exact shape package:record returns.
      final StreamController<Uint8List> controller =
          StreamController<Uint8List>.broadcast();
      final List<int> seen = <int>[];
      final StreamSubscription<Uint8List> sub =
          controller.stream.listen((Uint8List c) => seen.addAll(c));

      controller.add(Uint8List.fromList(<int>[1, 2]));
      unawaited(
        Future<void>.delayed(
          const Duration(milliseconds: 10),
          controller.close,
        ),
      );

      // A generous limit that the drain must NOT need: before the fix this
      // only returned by timing out, which is a hang wearing a hat. Measuring
      // the elapsed time is what distinguishes "noticed the close" from
      // "waited out the clock".
      final Stopwatch clock = Stopwatch()..start();
      await drainPcmSubscription(
        sub,
        controller.stream,
        limit: const Duration(seconds: 30),
      );
      clock.stop();

      expect(seen, <int>[1, 2]);
      expect(
        clock.elapsed,
        lessThan(const Duration(seconds: 5)),
        reason: 'the drain must return on the close event, not on its timeout',
      );
    });

    test('still delivers chunks emitted just before stop', () async {
      // The tail matters: cancelling instead of draining silently truncates
      // the end of every amplified recording.
      final StreamController<Uint8List> controller =
          StreamController<Uint8List>.broadcast();
      final List<int> seen = <int>[];
      final StreamSubscription<Uint8List> sub =
          controller.stream.listen((Uint8List c) => seen.addAll(c));

      controller.add(Uint8List.fromList(<int>[1, 2, 3]));
      controller.add(Uint8List.fromList(<int>[4, 5]));
      unawaited(Future<void>.microtask(controller.close));

      await drainPcmSubscription(sub, controller.stream);

      expect(
        seen,
        <int>[1, 2, 3, 4, 5],
        reason: 'the tail of the recording must survive finalisation',
      );
    });

    test('completes on a single-subscription stream too', () async {
      // Fakes in the suite hand out ordinary controllers; the drain must not
      // depend on which flavour it was given.
      final StreamController<Uint8List> controller =
          StreamController<Uint8List>();
      final List<int> seen = <int>[];
      final StreamSubscription<Uint8List> sub =
          controller.stream.listen((Uint8List c) => seen.addAll(c));

      controller.add(Uint8List.fromList(<int>[7]));
      unawaited(Future<void>.microtask(controller.close));

      await drainPcmSubscription(sub, controller.stream);

      expect(seen, <int>[7]);
    });

    test('returns promptly when the stream never closes, keeping the tail',
        () async {
      // THE device case. On a Galaxy Tab S10 FE package:record's PCM stream
      // does not close when the recorder stops, so this is the normal path,
      // not an edge case: the drain must return on its own bound AND still
      // have written everything the platform delivered.
      final StreamController<Uint8List> controller =
          StreamController<Uint8List>.broadcast();
      addTearDown(controller.close);
      final List<int> seen = <int>[];
      final StreamSubscription<Uint8List> sub =
          controller.stream.listen((Uint8List c) => seen.addAll(c));

      controller.add(Uint8List.fromList(<int>[9, 8, 7]));

      final Stopwatch clock = Stopwatch()..start();
      await drainPcmSubscription(
        sub,
        controller.stream,
        limit: const Duration(milliseconds: 100),
      ).timeout(
        const Duration(seconds: 5),
        onTimeout: () => fail('finalisation must not hang on an open stream'),
      );
      clock.stop();

      expect(seen, <int>[9, 8, 7], reason: 'delivered audio must be kept');
      expect(clock.elapsed, lessThan(const Duration(seconds: 3)));
    });

    test('gives up rather than hanging if the stream never closes', () async {
      // A platform that stops emitting without closing must not wedge the
      // app. Losing a finalise is bad; never returning is worse, because the
      // recorder stays locked until the process restarts.
      final StreamController<Uint8List> controller =
          StreamController<Uint8List>.broadcast();
      final StreamSubscription<Uint8List> sub =
          controller.stream.listen((_) {});
      addTearDown(controller.close);

      await drainPcmSubscription(
        sub,
        controller.stream,
        limit: const Duration(milliseconds: 50),
      ).timeout(
        const Duration(seconds: 2),
        onTimeout: () => fail('drain must bound its own wait'),
      );
    });
  });
}
