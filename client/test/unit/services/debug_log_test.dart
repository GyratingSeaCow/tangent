// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/services/debug_log.dart';

void main() {
  group('DebugLogBuffer', () {
    test('keeps at most 200 entries, newest last', () async {
      expect(kDebugLogMaxEntries, 200);
      expect(kDebugLogMaxBytes, 1024 * 1024);
      final DebugLogBuffer buffer = DebugLogBuffer.inMemory();
      await buffer.initialize();
      for (int i = 0; i < 205; i++) {
        buffer.record(
          source: 'zone',
          error: 'error-$i',
          stackTrace: StackTrace.fromString('stack-$i'),
          timestamp: DateTime.utc(2026, 10, 5, 12, 0, i % 60),
        );
      }
      await buffer.flush();

      expect(buffer.entries, hasLength(200));
      expect(buffer.entries.first.error, 'error-5');
      expect(buffer.entries.last.error, 'error-204');
    });

    test(
      'enforces the UTF-8 byte cap while preserving newest-last order',
      () async {
        final DebugLogBuffer buffer = DebugLogBuffer.inMemory(maxBytes: 430);
        await buffer.initialize();
        for (int i = 0; i < 8; i++) {
          buffer.record(
            source: 'platform',
            error: 'error-$i-${'é' * 25}',
            stackTrace: StackTrace.fromString('stack-$i-${'界' * 20}'),
            timestamp: DateTime.utc(2026, 10, 5, 12, 0, i),
          );
        }
        await buffer.flush();

        expect(buffer.encodedByteLength, lessThanOrEqualTo(430));
        expect(buffer.entries.last.error, contains('error-7'));
        expect(
          buffer.entries.map((DebugLogEntry e) => e.timestamp).toList(),
          orderedEquals(
            buffer.entries.map((DebugLogEntry e) => e.timestamp).toList()
              ..sort(),
          ),
        );
      },
    );

    test('persists entries atomically and reloads them in order', () async {
      final Directory dir = await Directory.systemTemp.createTemp(
        'tangent-log-test-',
      );
      addTearDown(() => dir.delete(recursive: true));
      final File file = File('${dir.path}/errors.json');
      final DebugLogBuffer first = DebugLogBuffer.file(file);
      await first.initialize();
      first.record(
        source: 'flutter',
        error: 'first',
        stackTrace: StackTrace.fromString('stack-first'),
        timestamp: DateTime.utc(2026, 10, 5, 1),
      );
      first.record(
        source: 'zone',
        error: 'second',
        stackTrace: StackTrace.fromString('stack-second'),
        timestamp: DateTime.utc(2026, 10, 5, 2),
      );
      await first.flush();

      final DebugLogBuffer reloaded = DebugLogBuffer.file(file);
      await reloaded.initialize();
      expect(reloaded.entries.map((DebugLogEntry e) => e.error), <String>[
        'first',
        'second',
      ]);
      expect(await File('${file.path}.next').exists(), isFalse);
    });
  });

  group('report', () {
    const DebugLogMetadata metadata = DebugLogMetadata(
      version: '1.49.0',
      buildNumber: '68',
      deviceModel: 'Pixel 9',
      operatingSystem: 'Android 16',
    );

    test(
      'empty export has header, device/build info, and explicit empty state',
      () {
        final String report = renderDebugLogReport(
          entries: const <DebugLogEntry>[],
          metadata: metadata,
          generatedAt: DateTime.utc(2026, 10, 5, 14, 30),
        );

        expect(report, contains('Tangent debug logs'));
        expect(report, contains('App: 1.49.0 (build 68)'));
        expect(report, contains('Device: Pixel 9'));
        expect(report, contains('OS: Android 16'));
        expect(report, contains('No recent errors'));
        expect(report, contains('does not intentionally collect transcripts'));
      },
    );

    test('entries render oldest to newest with timestamps and stacks', () {
      final String report = renderDebugLogReport(
        entries: <DebugLogEntry>[
          DebugLogEntry(
            timestamp: DateTime.utc(2026, 10, 5, 1),
            source: 'flutter',
            error: 'older',
            stack: 'older-stack',
          ),
          DebugLogEntry(
            timestamp: DateTime.utc(2026, 10, 5, 2),
            source: 'zone',
            error: 'newer',
            stack: 'newer-stack',
          ),
        ],
        metadata: metadata,
        generatedAt: DateTime.utc(2026, 10, 5, 3),
      );
      expect(report.indexOf('older'), lessThan(report.indexOf('newer')));
      expect(report, contains('2026-10-05T01:00:00.000Z'));
      expect(report, contains('older-stack'));
      expect(report, contains('newer-stack'));
    });
  });

  test(
    'capture hooks preserve Flutter, platform, and zone reporting chains',
    () async {
      final DebugLogBuffer buffer = DebugLogBuffer.inMemory();
      await buffer.initialize();
      final List<String> forwarded = <String>[];
      final FlutterExceptionHandler? original = FlutterError.onError;
      FlutterError.onError = (FlutterErrorDetails details) {
        forwarded.add('flutter:${details.exceptionAsString()}');
      };
      final DebugErrorCapture capture = DebugErrorCapture(buffer);
      final VoidCallback restore = capture.installFlutterHandler();
      addTearDown(() {
        restore();
        FlutterError.onError = original;
      });

      FlutterError.reportError(
        FlutterErrorDetails(
          exception: StateError('framework boom'),
          stack: StackTrace.fromString('framework-stack'),
        ),
      );
      final bool handled =
          capture.platformHandler(
            previous: (Object error, StackTrace stack) {
              forwarded.add('platform:$error');
              return true;
            },
          )(
            ArgumentError('dispatcher boom'),
            StackTrace.fromString('platform-stack'),
          );
      capture.handleZoneError(
        Exception('zone boom'),
        StackTrace.fromString('zone-stack'),
        forward: (Object error, StackTrace stack) =>
            forwarded.add('zone:$error'),
      );
      await buffer.flush();

      expect(handled, isTrue);
      expect(forwarded, hasLength(3));
      expect(buffer.entries.map((DebugLogEntry e) => e.source), <String>[
        'flutter',
        'platform',
        'zone',
      ]);
      expect(
        buffer.entries.every((DebugLogEntry e) => e.stack.isNotEmpty),
        isTrue,
      );
    },
  );
}
