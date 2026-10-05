// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/services/debug_log.dart';
import 'package:tangent/services/debug_log_export.dart';

class _FakePlatform implements DebugLogExportPlatform {
  final List<String> calls = <String>[];
  DebugLogAttachmentRequest? attachment;
  Uri? mailto;
  bool attachedResult = false;
  bool mailtoResult = false;
  bool shareResult = false;

  @override
  Future<bool> sendAttachedEmail(DebugLogAttachmentRequest request) async {
    calls.add('attached');
    attachment = request;
    return attachedResult;
  }

  @override
  Future<bool> openMailto(Uri uri) async {
    calls.add('mailto');
    mailto = uri;
    return mailtoResult;
  }

  @override
  Future<bool> shareFile(String path) async {
    calls.add('share');
    return shareResult;
  }
}

const DebugLogMetadata _metadata = DebugLogMetadata(
  version: '1.49.0',
  buildNumber: '68',
  deviceModel: 'Pixel 9 Pro',
  operatingSystem: 'Android 16',
);

Future<DebugLogExportService> _service(
  _FakePlatform platform, {
  int maxMailtoUriLength = 16000,
}) async {
  final DebugLogBuffer buffer = DebugLogBuffer.inMemory();
  await buffer.initialize();
  buffer.record(
    source: 'zone',
    error: 'fixture-error',
    stackTrace: StackTrace.fromString('fixture-stack'),
    timestamp: DateTime.utc(2026, 10, 5, 1),
  );
  await buffer.flush();
  return DebugLogExportService(
    buffer: buffer,
    platform: platform,
    loadMetadata: () async => _metadata,
    writeReport: (String report) async =>
        '/cache/debug_logs/tangent-debug-logs.txt',
    clock: () => DateTime.utc(2026, 10, 5, 2),
    maxMailtoUriLength: maxMailtoUriLength,
  );
}

void main() {
  test(
    'primary request is an addressed email with the txt attachment',
    () async {
      final _FakePlatform platform = _FakePlatform()..attachedResult = true;
      final DebugLogExportResult result = await (await _service(
        platform,
      )).export();

      expect(result.route, DebugLogExportRoute.attachedEmail);
      expect(platform.calls, <String>['attached']);
      expect(platform.attachment!.recipient, 'support@westtalkstech.com');
      expect(
        platform.attachment!.subject,
        'Tangent debug logs v1.49.0 (Pixel 9 Pro, Android 16)',
      );
      expect(platform.attachment!.filePath, endsWith('.txt'));
      expect(platform.attachment!.body, contains('attached debug log'));
    },
  );

  test(
    'falls back in strict attached-email, mailto, share-file order',
    () async {
      final _FakePlatform platform = _FakePlatform()..shareResult = true;
      final DebugLogExportResult result = await (await _service(
        platform,
      )).export();

      expect(result.route, DebugLogExportRoute.sharedFile);
      expect(platform.calls, <String>['attached', 'mailto', 'share']);
      expect(
        platform.mailto.toString(),
        startsWith('mailto:support@westtalkstech.com'),
      );
    },
  );

  test('stops at mailto when attached email has no resolver', () async {
    final _FakePlatform platform = _FakePlatform()..mailtoResult = true;
    final DebugLogExportResult result = await (await _service(
      platform,
    )).export();

    expect(result.route, DebugLogExportRoute.mailto);
    expect(platform.calls, <String>['attached', 'mailto']);
  });

  test('mailto URI truncates safely, stays parseable, and keeps recipient', () {
    final String report = 'start\n${'界🙂' * 2000}\nsecret-tail';
    final Uri uri = buildDebugLogMailtoUri(
      recipient: 'support@westtalkstech.com',
      subject: 'Tangent debug logs v1.49.0 (Pixel 9 Pro, Android 16)',
      report: report,
      maxUriLength: 620,
    );

    expect(uri.toString().length, lessThanOrEqualTo(620));
    expect(uri.scheme, 'mailto');
    expect(uri.path, 'support@westtalkstech.com');
    expect(uri.queryParameters['body'], contains('[log truncated for email]'));
    expect(uri.queryParameters['body'], isNot(contains('secret-tail')));
  });

  test(
    'platform-channel exceptions are captured and still advance fallback',
    () async {
      final DebugLogBuffer buffer = DebugLogBuffer.inMemory();
      await buffer.initialize();
      final MethodChannelDebugLogExportPlatform platform =
          MethodChannelDebugLogExportPlatform(
            buffer: buffer,
            invoke: (String method, Map<String, Object?> arguments) async {
              if (method == 'sendAttachedEmail') {
                throw StateError('channel failed');
              }
              return method == 'openMailto';
            },
          );
      final DebugLogExportService service = DebugLogExportService(
        buffer: buffer,
        platform: platform,
        loadMetadata: () async => _metadata,
        writeReport: (String report) async => '/cache/debug_logs/file.txt',
      );

      final DebugLogExportResult result = await service.export();
      await buffer.flush();
      expect(result.route, DebugLogExportRoute.mailto);
      expect(buffer.entries.single.source, 'platform-channel');
      expect(buffer.entries.single.error, contains('channel failed'));
    },
  );
}
