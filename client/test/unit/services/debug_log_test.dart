// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:tangent/services/debug_log.dart';

class _ThrowingError {
  @override
  String toString() => throw StateError('error toString failed');
}

class _ThrowingStackTrace implements StackTrace {
  @override
  String toString() => throw StateError('stack toString failed');
}

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

    test(
      'drops an impossible new entry without evicting prior records',
      () async {
        final DebugLogBuffer buffer = DebugLogBuffer.inMemory(maxBytes: 180);
        await buffer.initialize();
        buffer.record(
          source: 'zone',
          error: 'prior',
          stackTrace: StackTrace.fromString(''),
          timestamp: DateTime.utc(2026, 10, 5),
        );

        buffer.record(
          source: 'source-${'x' * 1000}',
          error: 'oversized',
          stackTrace: StackTrace.fromString('stack'),
          timestamp: DateTime.utc(2026, 10, 5, 1),
        );
        await buffer.flush();

        expect(buffer.entries, hasLength(1));
        expect(buffer.entries.single.error, 'prior');
        expect(buffer.encodedByteLength, lessThanOrEqualTo(180));
      },
    );

    test('caps fields before fitting and terminates on a tiny byte budget', () {
      final DebugLogBuffer capped = DebugLogBuffer.inMemory();
      capped.record(
        source: 'zone',
        error: 'é' * (kDebugLogMaxErrorBytes + 100),
        stackTrace: StackTrace.fromString('界' * (kDebugLogMaxStackBytes + 100)),
      );
      expect(
        utf8.encode(capped.entries.single.error).length,
        lessThanOrEqualTo(kDebugLogMaxErrorBytes),
      );
      expect(
        utf8.encode(capped.entries.single.stack).length,
        lessThanOrEqualTo(kDebugLogMaxStackBytes),
      );

      final Stopwatch stopwatch = Stopwatch()..start();
      final DebugLogBuffer tiny = DebugLogBuffer.inMemory(maxBytes: 300);
      tiny.record(
        source: 'zone',
        error: 'E' * 1000,
        stackTrace: StackTrace.fromString('S' * 100),
      );
      stopwatch.stop();

      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 1)));
      expect(tiny.entries, hasLength(1));
      expect(tiny.encodedByteLength, lessThanOrEqualTo(300));
    });

    test('multi-megabyte regex inputs are nonthrowing and bounded', () {
      final DebugLogBuffer buffer = DebugLogBuffer.inMemory();
      buffer.record(
        source: 'zone',
        error: 'prior',
        stackTrace: StackTrace.fromString('prior-stack'),
      );

      int expectedEntries = 1;
      for (final String error in <String>[
        'A' * (5 * 1024 * 1024),
        '"${'Q' * (5 * 1024 * 1024)}"',
      ]) {
        expectedEntries++;
        expect(
          () => buffer.record(
            source: 'zone',
            error: error,
            stackTrace: StackTrace.fromString(error),
          ),
          returnsNormally,
        );
        expect(buffer.entries, hasLength(expectedEntries));
        expect(
          utf8.encode(buffer.entries.last.error).length,
          lessThanOrEqualTo(kDebugLogMaxErrorBytes),
        );
        expect(
          utf8.encode(buffer.entries.last.stack).length,
          lessThanOrEqualTo(kDebugLogMaxStackBytes),
        );
        expect(buffer.entries.first.error, 'prior');
      }
    });

    test('record drops conversion failures and retains prior entries', () {
      final DebugLogBuffer buffer = DebugLogBuffer.inMemory();
      buffer.record(
        source: 'zone',
        error: 'prior',
        stackTrace: StackTrace.fromString('prior-stack'),
      );

      expect(
        () => buffer.record(
          source: 'zone',
          error: _ThrowingError(),
          stackTrace: StackTrace.fromString('unused'),
        ),
        returnsNormally,
      );
      expect(
        () => buffer.record(
          source: 'zone',
          error: 'unused',
          stackTrace: _ThrowingStackTrace(),
        ),
        returnsNormally,
      );

      expect(buffer.entries, hasLength(1));
      expect(buffer.entries.single.error, 'prior');
    });

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

    test('recovers from a corrupt main file using the atomic backup', () async {
      final Directory dir = await Directory.systemTemp.createTemp(
        'tangent-log-recovery-test-',
      );
      addTearDown(() => dir.delete(recursive: true));
      final File file = File('${dir.path}/errors.json')
        ..writeAsStringSync('{corrupt');
      File('${file.path}.backup').writeAsStringSync(
        jsonEncode(<Object?>[
          DebugLogEntry(
            timestamp: DateTime.utc(2026, 10, 5),
            source: 'zone',
            error: 'recovered',
            stack: 'safe-stack',
          ).toJson(),
        ]),
      );

      final DebugLogBuffer recovered = DebugLogBuffer.file(file);
      await recovered.initialize();

      expect(recovered.entries.single.error, 'recovered');
      expect(jsonDecode(await file.readAsString()), isA<List<Object?>>());
    });

    test('starts empty when both main and backup are corrupt', () async {
      final Directory dir = await Directory.systemTemp.createTemp(
        'tangent-log-corrupt-test-',
      );
      addTearDown(() => dir.delete(recursive: true));
      final File file = File('${dir.path}/errors.json')
        ..writeAsStringSync('{corrupt-main');
      File('${file.path}.backup').writeAsStringSync('{corrupt-backup');

      final DebugLogBuffer recovered = DebugLogBuffer.file(file);
      await recovered.initialize();

      expect(recovered.entries, isEmpty);
      expect(jsonDecode(await file.readAsString()), isA<List<Object?>>());
    });

    test('sanitizes real SQLite statement parameters before storage', () async {
      const String parameterSentinel = 'TRANSCRIPT-PARAMETER-SENTINEL';
      final DebugLogBuffer buffer = DebugLogBuffer.inMemory();
      await buffer.initialize();

      buffer.record(
        source: 'zone',
        error: SqliteException(
          extendedResultCode: 2067,
          message: 'constraint failed',
          operation: 'executing statement',
          causingStatement: 'INSERT INTO notes(content) VALUES (?)',
          parametersToStatement: const <Object?>[parameterSentinel],
        ),
        stackTrace: StackTrace.fromString('safe-stack'),
        timestamp: DateTime.utc(2026, 10, 5),
      );
      await buffer.flush();

      final String stored = buffer.entries.single.error;
      final String report = renderDebugLogReport(
        entries: buffer.entries,
        metadata: const DebugLogMetadata(
          version: '1.49.0',
          buildNumber: '68',
          deviceModel: 'test',
          operatingSystem: 'test',
        ),
        generatedAt: DateTime.utc(2026, 10, 5, 1),
      );
      expect(stored, contains('SqliteException(2067)'));
      expect(stored, contains('executing statement'));
      expect(stored, contains('constraint failed'));
      expect(stored, isNot(contains('Causing statement')));
      expect(stored, isNot(contains(parameterSentinel)));
      expect(report, isNot(contains(parameterSentinel)));
    });

    test('FormatException keeps only its sanitized message', () {
      const String sourceSentinel = 'TRANSCRIPT-SOURCE-SENTINEL';
      final DebugLogBuffer buffer = DebugLogBuffer.inMemory();
      buffer.record(
        source: 'flutter',
        error: const FormatException('invalid payload', sourceSentinel, 3),
        stackTrace: StackTrace.fromString(
          'password_hash=HASH-SENTINEL\n'
          'password_salt=SALT-SENTINEL\n'
          'password_hash_prev=PREV-HASH-SENTINEL\n'
          'bound values: ${'v' * 600}',
        ),
      );

      expect(buffer.entries.single.error, contains('invalid payload'));
      expect(buffer.entries.single.error, isNot(contains(sourceSentinel)));
      expect(buffer.entries.single.stack, isNot(contains('HASH-SENTINEL')));
      expect(buffer.entries.single.stack, isNot(contains('SALT-SENTINEL')));
      expect(
        buffer.entries.single.stack,
        isNot(contains('PREV-HASH-SENTINEL')),
      );
      expect(buffer.entries.single.stack, isNot(contains('v' * 600)));
    });

    test('generic errors redact SQL, prior secrets, and content fields', () {
      final DebugLogBuffer buffer = DebugLogBuffer.inMemory();
      const List<String> sentinels = <String>[
        'SQL-SENTINEL',
        'PARAM-SENTINEL',
        'PREV-SENTINEL',
        'TRANSCRIPT-SENTINEL',
        'NOTE-SENTINEL',
      ];
      buffer.record(
        source: 'zone',
        error: Exception(
          'sql: SELECT SQL-SENTINEL\n'
          'parameters: [PARAM-SENTINEL]\n'
          'prev=PREV-SENTINEL\n'
          'transcript: TRANSCRIPT-SENTINEL\n'
          'note_content=NOTE-SENTINEL',
        ),
        stackTrace: StackTrace.fromString('safe-stack'),
      );

      for (final String sentinel in sentinels) {
        expect(buffer.entries.single.error, isNot(contains(sentinel)));
      }
    });

    test('causing-statement redaction retains the diagnostic prefix', () {
      final DebugLogBuffer buffer = DebugLogBuffer.inMemory();
      buffer.record(
        source: 'zone',
        error:
            'SqliteException: useful diagnostic prefix\n'
            'Causing statement: SELECT secret FROM notes',
        stackTrace: StackTrace.fromString('safe-stack'),
      );

      expect(
        buffer.entries.single.error,
        'SqliteException: useful diagnostic prefix\n'
        '[REDACTED SQL STATEMENT AND PARAMETERS]',
      );
    });

    test(
      'storm coalesces writes and bounds persistence to one in flight',
      () async {
        int saves = 0;
        int inFlight = 0;
        int maxInFlight = 0;
        bool observe = false;
        final Completer<void> firstWrite = Completer<void>();
        final DebugLogBuffer buffer = DebugLogBuffer.testing(
          load: () async => <DebugLogEntry>[],
          save: (List<DebugLogEntry> entries) async {
            if (!observe) return;
            saves++;
            inFlight++;
            maxInFlight = maxInFlight < inFlight ? inFlight : maxInFlight;
            if (saves == 1) await firstWrite.future;
            inFlight--;
          },
          maxBytes: 4096,
          saveDebounce: const Duration(milliseconds: 10),
        );
        await buffer.initialize();
        observe = true;

        for (int i = 0; i < 100; i++) {
          buffer.record(
            source: 'storm',
            error: 'first-$i-${'x' * 20}',
            stackTrace: StackTrace.fromString('stack-$i'),
          );
        }
        expect(saves, 0);

        final Future<void> flushing = buffer.flush();
        await Future<void>.delayed(Duration.zero);
        expect(saves, 1);
        for (int i = 0; i < 50; i++) {
          buffer.record(
            source: 'storm',
            error: 'follow-up-$i',
            stackTrace: StackTrace.fromString('follow-up-stack-$i'),
          );
        }
        expect(saves, 1);
        firstWrite.complete();
        await flushing;

        expect(saves, 2);
        expect(maxInFlight, 1);
        expect(buffer.encodedByteLength, lessThanOrEqualTo(4096));
      },
    );

    test(
      'replays errors recorded while persistent load is in flight',
      () async {
        final Completer<List<DebugLogEntry>> loaded =
            Completer<List<DebugLogEntry>>();
        final DebugLogBuffer buffer = DebugLogBuffer.testing(
          load: () => loaded.future,
          save: (_) async {},
        );

        final Future<void> initializing = buffer.initialize();
        buffer.record(
          source: 'zone',
          error: 'during-load',
          stackTrace: StackTrace.fromString('safe-stack'),
        );
        loaded.complete(<DebugLogEntry>[]);
        await initializing;

        expect(buffer.entries.single.error, 'during-load');
      },
    );

    test(
      'incremental encoded byte count stays JSON-exact through trimming',
      () {
        final DebugLogBuffer buffer = DebugLogBuffer.inMemory(maxBytes: 700);
        for (int i = 0; i < 80; i++) {
          buffer.record(
            source: 'zone',
            error: 'error-$i-${'é' * 12}',
            stackTrace: StackTrace.fromString('stack-$i-${'界' * 8}'),
            timestamp: DateTime.utc(2026, 10, 5, 0, 0, i % 60),
          );
          final int exact = utf8
              .encode(
                jsonEncode(
                  buffer.entries
                      .map((DebugLogEntry entry) => entry.toJson())
                      .toList(),
                ),
              )
              .length;
          expect(buffer.encodedByteLength, exact);
          expect(buffer.encodedByteLength, lessThanOrEqualTo(700));
        }
      },
    );
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
        expect(report, contains('transcript or note content are removed'));
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
