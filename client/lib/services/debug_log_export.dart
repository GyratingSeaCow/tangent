// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'debug_log.dart';

const String kDebugLogSupportAddress = 'support@westtalkstech.com';
const String kDebugLogChannelName = 'dev.tangent.tangent/debug_logs';

enum DebugLogExportRoute { attachedEmail, mailto, sharedFile, unavailable }

class DebugLogExportResult {
  const DebugLogExportResult(this.route, {this.filePath});

  final DebugLogExportRoute route;
  final String? filePath;
}

class DebugLogAttachmentRequest {
  const DebugLogAttachmentRequest({
    required this.filePath,
    required this.recipient,
    required this.subject,
    required this.body,
  });

  final String filePath;
  final String recipient;
  final String subject;
  final String body;

  Map<String, Object?> toMap() => <String, Object?>{
    'filePath': filePath,
    'recipient': recipient,
    'subject': subject,
    'body': body,
  };
}

abstract class DebugLogExporter {
  Future<DebugLogExportResult> export();
}

abstract class DebugLogExportPlatform {
  Future<bool> sendAttachedEmail(DebugLogAttachmentRequest request);
  Future<bool> openMailto(Uri uri);
  Future<bool> shareFile(String path);
}

typedef DebugLogChannelInvoke =
    Future<bool> Function(String method, Map<String, Object?> arguments);

/// Android bridge. Any platform-channel failure is itself useful diagnostic
/// information, so it is captured before the flow advances to the next route.
class MethodChannelDebugLogExportPlatform implements DebugLogExportPlatform {
  MethodChannelDebugLogExportPlatform({
    required this.buffer,
    DebugLogChannelInvoke? invoke,
  }) : _invoke = invoke ?? _defaultInvoke;

  final DebugLogBuffer buffer;
  final DebugLogChannelInvoke _invoke;

  static const MethodChannel _channel = MethodChannel(kDebugLogChannelName);

  static Future<bool> _defaultInvoke(
    String method,
    Map<String, Object?> arguments,
  ) async => await _channel.invokeMethod<bool>(method, arguments) ?? false;

  Future<bool> _guarded(String method, Map<String, Object?> arguments) async {
    try {
      return await _invoke(method, arguments);
    } on Object catch (error, stack) {
      buffer.record(
        source: 'platform-channel',
        error: error,
        stackTrace: stack,
      );
      return false;
    }
  }

  @override
  Future<bool> sendAttachedEmail(DebugLogAttachmentRequest request) =>
      _guarded('sendAttachedEmail', request.toMap());

  @override
  Future<bool> openMailto(Uri uri) =>
      _guarded('openMailto', <String, Object?>{'uri': uri.toString()});

  @override
  Future<bool> shareFile(String path) =>
      _guarded('shareFile', <String, Object?>{'filePath': path});
}

/// Deliberately makes no Android channel calls on desktop/Linux CI.
class UnsupportedDebugLogExportPlatform implements DebugLogExportPlatform {
  const UnsupportedDebugLogExportPlatform();

  @override
  Future<bool> openMailto(Uri uri) async => false;

  @override
  Future<bool> sendAttachedEmail(DebugLogAttachmentRequest request) async =>
      false;

  @override
  Future<bool> shareFile(String path) async => false;
}

class DebugLogExportService implements DebugLogExporter {
  DebugLogExportService({
    required this.buffer,
    required this.platform,
    required this.loadMetadata,
    required this.writeReport,
    DateTime Function()? clock,
    this.maxMailtoUriLength = 16000,
  }) : clock = clock ?? DateTime.now;

  final DebugLogBuffer buffer;
  final DebugLogExportPlatform platform;
  final Future<DebugLogMetadata> Function() loadMetadata;
  final Future<String> Function(String report) writeReport;
  final DateTime Function() clock;
  final int maxMailtoUriLength;

  @override
  Future<DebugLogExportResult> export() async {
    final DebugLogMetadata metadata = await loadMetadata();
    final String report = renderDebugLogReport(
      entries: buffer.entries,
      metadata: metadata,
      generatedAt: clock(),
    );
    final String path = await writeReport(report);
    final String subject =
        'Tangent debug logs v${metadata.version} '
        '(${metadata.deviceModel}, ${metadata.operatingSystem})';
    const String body =
        'Please find the attached debug log from Tangent.\n\n'
        'It contains recent runtime errors and stack traces only.';
    final DebugLogAttachmentRequest request = DebugLogAttachmentRequest(
      filePath: path,
      recipient: kDebugLogSupportAddress,
      subject: subject,
      body: body,
    );

    if (await platform.sendAttachedEmail(request)) {
      return DebugLogExportResult(
        DebugLogExportRoute.attachedEmail,
        filePath: path,
      );
    }
    final Uri mailto = buildDebugLogMailtoUri(
      recipient: request.recipient,
      subject: request.subject,
      report: report,
      maxUriLength: maxMailtoUriLength,
    );
    if (await platform.openMailto(mailto)) {
      return DebugLogExportResult(DebugLogExportRoute.mailto, filePath: path);
    }
    if (await platform.shareFile(path)) {
      return DebugLogExportResult(
        DebugLogExportRoute.sharedFile,
        filePath: path,
      );
    }
    return DebugLogExportResult(
      DebugLogExportRoute.unavailable,
      filePath: path,
    );
  }
}

Uri buildDebugLogMailtoUri({
  required String recipient,
  required String subject,
  required String report,
  int maxUriLength = 16000,
}) {
  const String intro =
      'No email app accepted the attached file, so a safely '
      'truncated copy of the log follows.\n\n';
  const String marker = '\n\n[log truncated for email]';

  Uri makeUri(String body) => Uri(
    scheme: 'mailto',
    path: recipient,
    queryParameters: <String, String>{'subject': subject, 'body': body},
  );

  final Uri complete = makeUri('$intro$report');
  if (complete.toString().length <= maxUriLength) return complete;

  final List<int> runes = report.runes.toList();
  int low = 0;
  int high = runes.length;
  while (low < high) {
    final int middle = (low + high + 1) ~/ 2;
    final Uri candidate = makeUri(
      '$intro${String.fromCharCodes(runes.take(middle))}$marker',
    );
    if (candidate.toString().length <= maxUriLength) {
      low = middle;
    } else {
      high = middle - 1;
    }
  }
  return makeUri('$intro${String.fromCharCodes(runes.take(low))}$marker');
}

Future<DebugLogMetadata> loadDebugLogMetadata() async {
  final PackageInfo package = await PackageInfo.fromPlatform();
  String model = 'Unknown device';
  String os = Platform.operatingSystem;
  final DeviceInfoPlugin devices = DeviceInfoPlugin();
  if (Platform.isAndroid) {
    final AndroidDeviceInfo android = await devices.androidInfo;
    model = android.model.trim().isEmpty
        ? 'Android device'
        : android.model.trim();
    os = 'Android ${android.version.release}';
  } else if (Platform.isLinux) {
    final LinuxDeviceInfo linux = await devices.linuxInfo;
    model = linux.prettyName;
    os = 'Linux ${linux.versionId ?? ''}'.trim();
  } else if (Platform.isWindows) {
    final WindowsDeviceInfo windows = await devices.windowsInfo;
    model = windows.computerName;
    os = 'Windows ${windows.displayVersion}';
  }
  return DebugLogMetadata(
    version: package.version,
    buildNumber: package.buildNumber,
    deviceModel: model,
    operatingSystem: os,
  );
}

Future<String> writeDebugLogReport(String report) async {
  final Directory cache = await getTemporaryDirectory();
  final Directory directory = Directory(p.join(cache.path, 'debug_logs'));
  await directory.create(recursive: true);
  final File file = File(p.join(directory.path, 'tangent-debug-logs.txt'));
  await file.writeAsString(report, flush: true);
  return file.path;
}

/// Production overrides this at the root with the initialized persistent
/// buffer. Tests override it with a fake; merely building Settings performs no
/// platform call.
final Provider<DebugLogExporter> debugLogExporterProvider =
    Provider<DebugLogExporter>((Ref ref) {
      throw UnimplementedError('Debug log exporter was not initialized');
    });
