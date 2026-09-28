// SPDX-License-Identifier: AGPL-3.0-or-later
/// Turns a server-transcription row that is quietly retrying into a
/// sentence the user can act on.
///
/// The service retries an unreachable server forever, on purpose — a
/// recording must never be marked failed because the network was down
/// for a while. But "forever, silently" is what Jeff saw on cellular with
/// the app paired to the LAN address: `Uploading audio to your server`
/// and a progress bar, for an hour, with nothing wrong on the server. A
/// dead route to a private address neither answers nor refuses; every
/// attempt times out and the row keeps its in-progress status with a
/// `reconciliation_pending:` marker nobody displays.
///
/// This is the display rule: after [stuckAfter] of in-progress with that
/// marker still set, name the address being tried and say what to check.
/// The retries continue underneath; this only changes what the panel says.
library;

/// Marker prefix the transcription service persists in
/// `transcriptionError` while a request is being retried after an
/// ambiguous transport failure (timeout, connection error, socket).
const String kReconciliationPendingMarker = 'reconciliation_pending:';

/// In-progress for this long with the marker still set reads as stuck.
/// Two full connect-timeout cycles (15 s each) plus retry back-off: long
/// enough that a slow-but-alive link never trips it, short enough that
/// a dead one is named within the first minute.
const Duration kUnreachableAfter = Duration(seconds: 45);

/// True when the row's error marker says the service is retrying a
/// transport failure rather than waiting on the server.
bool isReconciliationPending(String? transcriptionError) =>
    transcriptionError?.startsWith(kReconciliationPendingMarker) ?? false;

/// The address part of a base URL for display: `http://192.168.1.206:8765`
/// → `192.168.1.206:8765`. Falls back to the input when it does not parse.
String displayHost(String baseUrl) {
  final Uri? uri = Uri.tryParse(baseUrl);
  if (uri == null || uri.host.isEmpty) return baseUrl;
  return uri.hasPort ? '${uri.host}:${uri.port}' : uri.host;
}

/// True when [baseUrl] points at a private LAN address (RFC 1918) — the
/// kind that only works on the network it was found on.
bool isLanAddress(String baseUrl) {
  final Uri? uri = Uri.tryParse(baseUrl);
  final String host = uri?.host ?? '';
  final List<String> parts = host.split('.');
  if (parts.length != 4) return false;
  final int? a = int.tryParse(parts[0]);
  final int? b = int.tryParse(parts[1]);
  if (a == null || b == null) return false;
  if (a == 192 && b == 168) return true;
  if (a == 10) return true;
  if (a == 172 && b >= 16 && b <= 31) return true;
  return false;
}

/// The sentence to show instead of the elapsed-time line, or null when
/// the in-progress state is still plausibly just slow.
///
/// [inProgress]: the row's status is uploading/queued/running.
/// [transcriptionError]: the row's current marker.
/// [startedAt] / [now]: how long this attempt has been going.
/// [baseUrl]: the server address the client is configured with.
String? unreachableServerNotice({
  required bool inProgress,
  required String? transcriptionError,
  required DateTime? startedAt,
  required DateTime now,
  required String baseUrl,
  Duration stuckAfter = kUnreachableAfter,
}) {
  if (!inProgress) return null;
  if (!isReconciliationPending(transcriptionError)) return null;
  if (startedAt == null) return null;
  if (now.difference(startedAt) < stuckAfter) return null;
  final String host = displayHost(baseUrl);
  final String hint = isLanAddress(baseUrl)
      ? 'That is a Wi-Fi address, which only works on the network it was '
          'found on. Away from home, set Settings → Server to the '
          "server's Tailscale address (http://100.x.x.x:8765)."
      : 'Check that this device and the server are both online and, if '
          'the address is on Tailscale, that Tailscale is connected on '
          'this device.';
  return "Can't reach the server at $host — still retrying. $hint";
}
