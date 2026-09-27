// SPDX-License-Identifier: AGPL-3.0-or-later
/// Settings section for the household's Google Tasks link (v1.25.0).
///
/// The link is SERVER-side (one Google sign-in, tokens in the server DB —
/// design G3), so this section is a thin view over
/// `GET /v1/google-tasks/status` with five verbs, one per state:
///
///   disconnected, no credentials → Client ID / Client secret + Save
///   disconnected, credentials    → Connect Google (opens `auth_url`)
///   connected                    → "Connected as …", Sync now, Disconnect
///   reauth_required              → amber banner + Reconnect
///   error                        → red `last_error` + Retry (= sync-now)
///
/// Polling is deliberate: ONE status read on mount, then a 5 s poll only
/// while a Connect is outstanding (Google's consent page finishes in the
/// browser; the next poll sees `connected`). The poll stops on any
/// terminal state, after the 10-minute state-nonce window, or with the
/// widget — never a periodic timer at rest, so hosting screens can settle.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/summaries_client.dart';
import '../../theme/tangent_tokens.dart';
import 'ai_summaries_section.dart' show summariesClientProvider;

/// Clock behind "Last sync 2 min ago". Tests pin it.
DateTime Function() googleTasksClock = DateTime.now;

/// Four-line help under the credential fields (design: "Free. …").
const String kGoogleTasksHelpText =
    'Free. Create a Google Cloud project, enable the Tasks API, add an OAuth '
    'client (Desktop app), paste both here. While the consent screen is in '
    'Testing, Google expires the sign-in weekly — move it to In production '
    '(unverified is fine for one household) to stop that.';

/// The setup walkthrough the help link opens.
const String kGoogleTasksDocUrl =
    'https://developers.google.com/tasks/get_started';

/// Amber banner wording for `reauth_required`.
const String kGoogleTasksReauthText =
    'Google needs you to sign in again (test-mode tokens expire weekly)';

/// Cadence and ceiling of the post-Connect poll. The ceiling matches the
/// server's 10-minute `state` nonce: past it the callback would be
/// rejected anyway, so watching longer is pointless.
const Duration kGoogleTasksConnectPoll = Duration(seconds: 5);
const Duration kGoogleTasksConnectWindow = Duration(minutes: 10);

/// "just now" / "2 min ago" / "3 h ago" / "4 d ago" for the summary line.
String formatSyncAgo(DateTime then, DateTime now) {
  final Duration d = now.difference(then);
  if (d.inMinutes < 1) return 'just now';
  if (d.inHours < 1) return '${d.inMinutes} min ago';
  if (d.inDays < 1) return '${d.inHours} h ago';
  return '${d.inDays} d ago';
}

class GoogleTasksSection extends ConsumerStatefulWidget {
  const GoogleTasksSection({super.key});

  @override
  ConsumerState<GoogleTasksSection> createState() =>
      _GoogleTasksSectionState();
}

class _GoogleTasksSectionState extends ConsumerState<GoogleTasksSection> {
  /// Last status the server returned; null until the first read lands.
  GoogleTasksStatus? _status;

  /// A request failed on THIS device (unreachable server, rejected save).
  /// Distinct from the server's own `last_error`, which is sync state.
  String? _error;

  /// A verb is in flight; every button disables so it cannot double-fire.
  bool _busy = false;

  /// Connect was tapped and the browser opened; we are polling for the flip.
  bool _awaitingConnect = false;

  /// "Change credentials" re-opens the fields although some are saved.
  bool _editingCredentials = false;

  final TextEditingController _clientId = TextEditingController();
  final TextEditingController _clientSecret = TextEditingController();

  Timer? _pollTimer;
  DateTime? _pollStarted;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _stopPolling();
    _clientId.dispose();
    _clientSecret.dispose();
    super.dispose();
  }

  Future<SummariesClient> _client() => ref.read(summariesClientProvider.future);

  /// One status read. A failure is shown (with Retry) rather than swallowed:
  /// unlike the summaries toggle, every verb here needs the status first.
  Future<void> _refresh() async {
    final GoogleTasksStatus status;
    try {
      status = await (await _client()).getGoogleTasksStatus();
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not reach the server: $e');
      return;
    }
    if (!mounted) return;
    _adopt(status);
  }

  void _adopt(GoogleTasksStatus status) {
    setState(() {
      _status = status;
      _error = null;
      if (status.hasCredentials) _editingCredentials = false;
      if (status.status != GoogleTasksLinkStatus.disconnected &&
          status.status != GoogleTasksLinkStatus.pending) {
        _awaitingConnect = false;
      }
    });
    if (!_awaitingConnect) _stopPolling();
  }

  Future<void> _run(Future<void> Function(SummariesClient client) verb) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await verb(await _client());
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---- verbs ----------------------------------------------------------------

  Future<void> _save() async {
    final String id = _clientId.text.trim();
    final String secret = _clientSecret.text.trim();
    if (id.isEmpty || secret.isEmpty) {
      setState(() => _error = 'Both the client ID and the client secret are needed');
      return;
    }
    await _run((client) async {
      await client.saveGoogleTasksCredentials(clientId: id, clientSecret: secret);
      // The secret is server-side now; it must not linger in a text field.
      _clientId.clear();
      _clientSecret.clear();
      _adopt(await client.getGoogleTasksStatus());
    });
  }

  /// Connect and Reconnect are the same verb: the server mints a fresh
  /// consent URL either way and the browser does the rest.
  Future<void> _connect() async {
    await _run((client) async {
      final Uri url = await client.connectGoogleTasks();
      final bool opened =
          await launchUrl(url, mode: LaunchMode.externalApplication);
      if (!opened) {
        throw Exception('Could not open the browser for Google sign-in');
      }
      if (!mounted) return;
      setState(() => _awaitingConnect = true);
      _startPolling(client);
    });
  }

  Future<void> _syncNow() async {
    await _run((client) async => _adopt(await client.syncGoogleTasksNow()));
  }

  Future<void> _disconnect() async {
    await _run((client) async {
      await client.disconnectGoogleTasks();
      _adopt(await client.getGoogleTasksStatus());
    });
  }

  // ---- post-Connect poll ----------------------------------------------------

  void _startPolling(SummariesClient client) {
    _pollTimer?.cancel();
    _pollStarted = googleTasksClock();
    _pollTimer = Timer.periodic(kGoogleTasksConnectPoll, (_) => _poll(client));
  }

  Future<void> _poll(SummariesClient client) async {
    if (!mounted) return;
    final DateTime? started = _pollStarted;
    if (started != null &&
        googleTasksClock().difference(started) > kGoogleTasksConnectWindow) {
      setState(() => _awaitingConnect = false);
      _stopPolling();
      return;
    }
    final GoogleTasksStatus status;
    try {
      status = await client.getGoogleTasksStatus();
    } catch (_) {
      return; // transient; the next tick retries
    }
    if (!mounted) return;
    _adopt(status);
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _pollStarted = null;
  }

  // ---- render ---------------------------------------------------------------

  String _statusLine(GoogleTasksStatus? s) {
    if (s == null) return _error == null ? 'Checking…' : 'Server unreachable';
    if (_awaitingConnect) return 'Waiting for Google sign-in…';
    return switch (s.status) {
      GoogleTasksLinkStatus.disconnected =>
        s.hasCredentials ? 'Not connected — credentials saved' : 'Not connected',
      GoogleTasksLinkStatus.pending => 'Waiting for Google sign-in…',
      GoogleTasksLinkStatus.connected =>
        'Connected as ${s.googleEmail ?? 'Google'}',
      GoogleTasksLinkStatus.reauthRequired => 'Signed out by Google',
      GoogleTasksLinkStatus.error => 'Sync error',
    };
  }

  String _summaryLine(GoogleTasksStatus s) {
    final DateTime? at = s.lastSyncAt;
    final String when = at == null
        ? 'Not synced yet'
        : 'Last sync ${formatSyncAgo(at, googleTasksClock())}';
    return '$when · ${s.pushed} pushed · ${s.pulled} pulled';
  }

  @override
  Widget build(BuildContext context) {
    final GoogleTasksStatus? s = _status;
    final ThemeData theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(
            'Google Tasks',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Text(
            _statusLine(s),
            key: const ValueKey<String>('google-tasks-status'),
          ),
        ),
        if (s != null) ..._stateBody(context, s, theme),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: Text(
              _error!,
              key: const ValueKey<String>('google-tasks-error'),
              style: TextStyle(color: theme.colorScheme.error, fontSize: 12),
            ),
          ),
        if (s == null && _error != null)
          _buttonRow(<Widget>[
            OutlinedButton(
              key: const ValueKey<String>('google-tasks-retry'),
              onPressed: _busy ? null : _refresh,
              child: const Text('Retry'),
            ),
          ]),
      ],
    );
  }

  List<Widget> _stateBody(
    BuildContext context,
    GoogleTasksStatus s,
    ThemeData theme,
  ) {
    switch (s.status) {
      case GoogleTasksLinkStatus.disconnected:
      case GoogleTasksLinkStatus.pending:
        final bool showFields = !s.hasCredentials || _editingCredentials;
        return <Widget>[
          if (showFields) ..._credentialFields(),
          if (s.hasCredentials)
            _buttonRow(<Widget>[
              FilledButton.icon(
                key: const ValueKey<String>('google-tasks-connect'),
                onPressed: _busy ? null : _connect,
                icon: const Icon(Icons.login),
                label: const Text('Connect Google'),
              ),
              if (!_editingCredentials)
                TextButton(
                  key: const ValueKey<String>('google-tasks-edit-credentials'),
                  onPressed: _busy
                      ? null
                      : () => setState(() => _editingCredentials = true),
                  child: const Text('Change credentials'),
                ),
            ]),
        ];
      case GoogleTasksLinkStatus.connected:
        return <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Text(
              _summaryLine(s),
              key: const ValueKey<String>('google-tasks-summary'),
              style: const TextStyle(fontSize: 12, color: TangentColors.textDim),
            ),
          ),
          _buttonRow(<Widget>[
            FilledButton.tonal(
              key: const ValueKey<String>('google-tasks-sync-now'),
              onPressed: _busy ? null : _syncNow,
              child: const Text('Sync now'),
            ),
            TextButton(
              key: const ValueKey<String>('google-tasks-disconnect'),
              onPressed: _busy ? null : _disconnect,
              child: const Text('Disconnect'),
            ),
          ]),
        ];
      case GoogleTasksLinkStatus.reauthRequired:
        return <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: Container(
              key: const ValueKey<String>('google-tasks-reauth-banner'),
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.amber.withValues(alpha: 0.18),
                border: Border.all(color: Colors.amber.shade700),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text(kGoogleTasksReauthText),
            ),
          ),
          _buttonRow(<Widget>[
            FilledButton.icon(
              key: const ValueKey<String>('google-tasks-reconnect'),
              onPressed: _busy ? null : _connect,
              icon: const Icon(Icons.refresh),
              label: const Text('Reconnect'),
            ),
            TextButton(
              key: const ValueKey<String>('google-tasks-disconnect'),
              onPressed: _busy ? null : _disconnect,
              child: const Text('Disconnect'),
            ),
          ]),
        ];
      case GoogleTasksLinkStatus.error:
        return <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Text(
              s.lastError ?? 'Sync failed',
              key: const ValueKey<String>('google-tasks-last-error'),
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ),
          _buttonRow(<Widget>[
            FilledButton.tonal(
              key: const ValueKey<String>('google-tasks-retry'),
              onPressed: _busy ? null : _syncNow,
              child: const Text('Retry'),
            ),
            TextButton(
              key: const ValueKey<String>('google-tasks-disconnect'),
              onPressed: _busy ? null : _disconnect,
              child: const Text('Disconnect'),
            ),
          ]),
        ];
    }
  }

  List<Widget> _credentialFields() => <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
          child: TextField(
            key: const ValueKey<String>('google-tasks-client-id'),
            controller: _clientId,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              labelText: 'Client ID',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
          child: TextField(
            key: const ValueKey<String>('google-tasks-client-secret'),
            controller: _clientSecret,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              labelText: 'Client secret',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
        ),
        _buttonRow(<Widget>[
          FilledButton(
            key: const ValueKey<String>('google-tasks-save'),
            onPressed: _busy ? null : _save,
            child: const Text('Save'),
          ),
          TextButton(
            key: const ValueKey<String>('google-tasks-help-link'),
            onPressed: () => launchUrl(
              Uri.parse(kGoogleTasksDocUrl),
              mode: LaunchMode.externalApplication,
            ),
            child: const Text('Setup guide'),
          ),
        ]),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            kGoogleTasksHelpText,
            key: ValueKey<String>('google-tasks-help'),
            style: TextStyle(fontSize: 12, color: TangentColors.textDim),
          ),
        ),
      ];

  Widget _buttonRow(List<Widget> children) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
        child: Wrap(spacing: 8, runSpacing: 4, children: children),
      );
}
