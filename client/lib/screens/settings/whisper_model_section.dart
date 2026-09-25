// SPDX-License-Identifier: AGPL-3.0-or-later
/// Settings section for choosing which Whisper model the server transcribes
/// with, and for installing the weights that choice needs.
///
/// Before this existed the model was frozen by `TANGENT_WHISPER_MODEL` at
/// container start, Settings listed the names like a menu that did nothing,
/// and the multi-gigabyte weight download happened silently on first use.
/// Here the list is real:
///
///   installed model tapped  → PUT immediately → "Now transcribing with X"
///   uninstalled model tapped → confirm naming the download size
///                            → POST install → inline progress + shade
///                            → on `done`, PUT the selection automatically
///
/// The server deliberately does NOT switch the active model when an install
/// finishes (selection is an explicit second step), so the chaining above is
/// this widget's job: without it the user waits out a 3 GB download and is
/// still transcribing with the old model.
///
/// Three doors into the installing state, exactly like the summaries wizard:
///   1. fresh confirm — the flow above;
///   2. re-entry rehydration — init sees a running install and re-attaches,
///      POSTing nothing (requirement 12);
///   3. 409 attach — POST install says one is already running, which is the
///      outcome we wanted, so watch it rather than fail.
///
/// An unreachable server (requirement 13) still renders all five rows,
/// disabled, selected on the last model this device saw, with a line saying
/// why — never an empty list and never a crash.
///
/// Copy rule (requirement 11, Jeff's standing preference): every row leads
/// with ACCURACY. No row may suggest a smaller model is the better pick.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/android_transcription_notification_port.dart';
import '../../services/transcription_notifications.dart';
import '../../services/whisper_model_client.dart';
import '../server/server_connection_screen.dart'
    show secureStoreProvider, transcriptionClientProvider;
import 'settings_screen.dart' show settingsStoreProvider;
import 'package:tangent/services/server_defaults.dart';

/// Client for /v1/transcription/models*. Async because the server URL and
/// bearer token live in secure storage.
///
/// WATCHES [transcriptionClientProvider] so reconnecting to a different
/// server rebuilds this client too — never a secure-storage latch. Without
/// it the section keeps talking to the OLD host after a server change and
/// the picker sits inert with nothing in either server's log.
final whisperModelClientProvider = FutureProvider<WhisperModelClient>(
  (ref) async {
    // Deliberately unused: a dependency edge, not data.
    ref.watch(transcriptionClientProvider);
    final store = ref.watch(secureStoreProvider);
    String? url;
    String? token;
    try {
      url = await store.getServerUrl();
      token = await store.getToken();
    } catch (_) {
      // Linux without a Secret Service: reads throw. Fall through to the
      // localhost default — the first call then fails into the section's
      // offline state, which beats dying before the section builds.
    }
    return WhisperModelClient(
      baseUrl: url ?? defaultServerBaseUrl(),
      token: token,
    );
  },
);

/// The install-progress notification's platform sink. Same plumbing as the
/// transcription (1001), OCR-install (1002) and summaries-install (1003)
/// notices, under its own id + channel so none of them overwrite each other
/// in the shade. Overridden in tests.
final whisperModelInstallNotificationPortProvider =
    Provider<TranscriptionNotificationPort>((ref) {
  // Guarded construction: if the plugin cannot be had at all, the section
  // still works — silently, without a shade mirror — rather than throwing
  // out of a provider read on the init path (the R8 lesson).
  try {
    return AndroidTranscriptionNotificationPort(
      notificationId: 1004,
      channelId: 'whisper_model_install',
      channelName: 'Transcription model install',
      channelDescription:
          'Shows while a Whisper model downloads onto your server.',
    );
  } catch (e, stack) {
    debugPrint('tangent.whisper-model notifications unavailable: $e');
    debugPrintStack(stackTrace: stack, label: 'tangent.whisper-model');
    return const NullTranscriptionNotificationPort();
  }
});

/// What this build knows about the stock models: the accuracy-first line for
/// each, and a size to show when the server cannot be reached.
///
/// The SERVER's catalogue wins whenever there is one — this table exists for
/// requirement 13's offline rows and for the copy, which is ours, not the
/// server's. A server offering a name that is not here still renders (the
/// list is built from the server's rows, not from this table).
@immutable
class _KnownModel {
  const _KnownModel(this.name, this.blurb, this.approxBytes);

  final String name;
  final String blurb;
  final int approxBytes;
}

const List<_KnownModel> _kKnownModels = <_KnownModel>[
  _KnownModel('large-v3', 'Most accurate — recommended', 3100000000),
  _KnownModel('medium', 'Almost as accurate, a little faster', 1500000000),
  _KnownModel('small', 'Less accurate, noticeably faster', 484000000),
  _KnownModel('base', 'Much less accurate, very fast', 145000000),
  _KnownModel('tiny', 'Fastest, least accurate', 75000000),
];

_KnownModel? _known(String name) {
  for (final _KnownModel model in _kKnownModels) {
    if (model.name == name) return model;
  }
  return null;
}

/// Decimal sizes, matching how the weights are advertised everywhere else
/// (3.1 GB, 484 MB) rather than the binary units a file manager shows.
String formatWhisperSize(int bytes) {
  if (bytes >= 1000000000) {
    final double gb = bytes / 1000000000;
    return '${gb.toStringAsFixed(1)} GB';
  }
  if (bytes >= 1000000) return '${(bytes / 1000000).round()} MB';
  if (bytes > 0) return '${(bytes / 1000).round()} KB';
  return 'unknown size';
}

/// One row as rendered: server truth where we have it, the local table where
/// we do not.
@immutable
class _Row {
  const _Row({
    required this.name,
    required this.installed,
    required this.approxBytes,
    required this.blurb,
  });

  final String name;

  /// Null when the server could not be reached: unknown is NOT "no badge
  /// means installed", so the badge is omitted rather than guessed.
  final bool? installed;
  final int approxBytes;
  final String blurb;

  String get subtitle => blurb.isEmpty
      ? '~${formatWhisperSize(approxBytes)}'
      : '$blurb · ~${formatWhisperSize(approxBytes)}';
}

class WhisperModelSection extends ConsumerStatefulWidget {
  const WhisperModelSection({super.key});

  @override
  ConsumerState<WhisperModelSection> createState() =>
      _WhisperModelSectionState();
}

class _WhisperModelSectionState extends ConsumerState<WhisperModelSection> {
  /// The server's catalogue, or null while unreachable (requirement 13).
  WhisperModelCatalog? _catalog;
  bool _offline = false;

  /// Non-null while an install runs or has failed; drives the inline UI.
  WhisperInstallProgress? _progress;
  bool _installFailed = false;

  /// Which model the running install is FOR — the selection to chain into
  /// when it lands (requirement 10).
  String? _installTarget;

  /// A request or dialog is in flight; a second tap must not race it.
  bool _busy = false;

  String? _error;

  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    // Door 2: an install outlives this widget, so re-entry re-attaches.
    _rehydrate();
  }

  @override
  void dispose() {
    // The server install keeps running — only the WATCHING stops here.
    _pollTimer?.cancel();
    super.dispose();
  }

  bool get _installing => _progress != null && !_installFailed;

  /// The radio's group value: the server's active model when we have the
  /// catalogue, otherwise the last one this device saw. Moved only by a
  /// CONFIRMED server change, so a failed install leaves the radio where it
  /// was (requirement 10's fallback).
  String get _active =>
      _catalog?.active ?? ref.read(settingsStoreProvider).whisperModel;

  Future<WhisperModelClient?> _client() async {
    try {
      return await ref.read(whisperModelClientProvider.future);
    } catch (_) {
      return null;
    }
  }

  /// Load the catalogue and, if an install is already running on the server,
  /// re-attach to it (requirement 12). POSTs nothing.
  Future<void> _rehydrate() async {
    final WhisperModelClient? client = await _client();
    if (!mounted) return;
    if (client == null) {
      setState(() => _offline = true);
      return;
    }
    WhisperModelCatalog? catalog;
    try {
      catalog = await client.getModels();
    } catch (_) {
      // Unreachable at init is not an error banner — the user did nothing
      // yet. The rows render disabled with an explanation instead.
      if (mounted) setState(() => _offline = true);
      return;
    }
    if (!mounted) return;
    setState(() {
      _catalog = catalog;
      _offline = false;
    });
    // Keep the offline mirror honest for the next cold open.
    await ref.read(settingsStoreProvider).setWhisperModel(catalog.active);

    final WhisperInstallProgress progress;
    try {
      progress = await client.getInstallProgress();
    } catch (_) {
      return;
    }
    if (!mounted) return;
    if (progress.phase == 'downloading' || progress.phase == 'verifying') {
      _installTarget = progress.model;
      setState(() {
        _installFailed = false;
        _progress = progress;
      });
      await _notifyProgress(progress);
      // The fetch above already IS this tick's poll; polling again here
      // would burn a second request before the 2 s cadence starts.
      _startPolling(client);
    }
  }

  // ---- selecting ------------------------------------------------------------

  Future<void> _onSelect(String? name) async {
    if (name == null || _busy || _installing) return;
    if (name == _active) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final WhisperModelClient? client = await _client();
      if (client == null) {
        if (mounted) setState(() => _offline = true);
        return;
      }
      final WhisperModelInfo? info = _catalog?.byName(name);
      if (info != null && !info.installed) {
        await _confirmAndInstall(client, name);
        return;
      }
      await _select(client, name);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// PUT the selection. A 409 means the weights are gone (deleted out from
  /// under a stale catalogue) — that is the install flow, not a dead end.
  Future<void> _select(WhisperModelClient client, String name) async {
    final WhisperModelCatalog catalog;
    try {
      catalog = await client.selectModel(name);
    } on WhisperModelNotInstalledException {
      if (!mounted) return;
      await _confirmAndInstall(client, name);
      return;
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not switch model: $e');
      return;
    }
    if (!mounted) return;
    setState(() {
      _catalog = catalog;
      _offline = false;
      _error = null;
    });
    await ref.read(settingsStoreProvider).setWhisperModel(catalog.active);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Now transcribing with $name')),
    );
  }

  // ---- installing -----------------------------------------------------------

  /// Name the download size BEFORE anything starts — on a phone on cellular
  /// this can be 3.1 GB landing on a server the user is not looking at.
  Future<void> _confirmAndInstall(
    WhisperModelClient client,
    String name,
  ) async {
    final int bytes =
        _catalog?.byName(name)?.approxDownloadBytes ?? _known(name)?.approxBytes ?? 0;
    final bool confirmed = await showDialog<bool>(
          context: context,
          builder: (BuildContext context) =>
              _InstallConfirmDialog(model: name, approxBytes: bytes),
        ) ??
        false;
    // Cancel is a full stop: nothing posted, the radio stays put.
    if (!mounted || !confirmed) return;
    _installTarget = name;
    await _startInstall(client, name);
  }

  Future<void> _startInstall(WhisperModelClient client, String name) async {
    setState(() {
      _installFailed = false;
      _error = null;
      _progress = WhisperInstallProgress(
        phase: 'downloading',
        percent: 0,
        detail: 'Starting install…',
        model: name,
      );
    });
    try {
      await client.startInstall(name);
    } on WhisperInstallAlreadyRunningException {
      // Door 3: one is already running. That is what we wanted — attach.
      if (!mounted) return;
      setState(() {
        _progress = WhisperInstallProgress(
          phase: 'downloading',
          percent: 0,
          detail: 'Resuming install…',
          model: name,
        );
      });
      await _watch(client);
      return;
    } catch (e) {
      await _failInstall('$e');
      return;
    }
    if (!mounted) return;
    await _watch(client);
  }

  Future<void> _failInstall(String detail) async {
    if (!mounted) return;
    setState(() {
      _installFailed = true;
      _progress = WhisperInstallProgress(
        phase: 'failed',
        percent: 0,
        detail: detail,
        model: _installTarget,
      );
    });
    await _notify('Model install failed', detail);
  }

  /// Poll immediately (whoever just arrived is looking at the screen), then
  /// every 2 s for as long as the section stays visible.
  Future<void> _watch(WhisperModelClient client) async {
    await _poll(client);
    _startPolling(client);
  }

  void _startPolling(WhisperModelClient client) {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _poll(client),
    );
  }

  Future<void> _poll(WhisperModelClient client) async {
    if (!mounted) return;
    final WhisperInstallProgress progress;
    try {
      progress = await client.getInstallProgress();
    } catch (_) {
      return; // transient; the next tick retries
    }
    if (!mounted) return;

    switch (progress.phase) {
      case 'done':
        _stopPolling();
        setState(() {
          _progress = null;
          _installFailed = false;
        });
        await _finishInstall(client, progress.model ?? _installTarget);
      case 'failed':
        _stopPolling();
        setState(() {
          _progress = progress;
          _installFailed = true;
        });
        await _notify(
          'Model install failed',
          progress.detail.isEmpty ? 'The server could not install it.' : progress.detail,
        );
      default:
        setState(() => _progress = progress);
        await _notifyProgress(progress);
    }
  }

  /// Requirement 10's second half: installing does NOT select, so the moment
  /// the weights land we PUT the selection the user actually asked for.
  Future<void> _finishInstall(WhisperModelClient client, String? name) async {
    if (name == null || name.isEmpty) {
      await _refreshCatalog(client);
      return;
    }
    await _select(client, name);
    if (!mounted) return;
    await _notify(
      'Whisper model $name installed',
      'Now transcribing with $name.',
    );
  }

  Future<void> _refreshCatalog(WhisperModelClient client) async {
    try {
      final WhisperModelCatalog catalog = await client.getModels();
      if (!mounted) return;
      setState(() {
        _catalog = catalog;
        _offline = false;
      });
    } catch (_) {
      // Leave the last known state; the next open re-reads it.
    }
  }

  Future<void> _retryInstall() async {
    final String? target = _installTarget;
    if (_busy || _installing || target == null) return;
    final WhisperModelClient? client = await _client();
    if (client == null) {
      if (mounted) setState(() => _offline = true);
      return;
    }
    // The size was already agreed to; retry goes straight back to POST.
    await _startInstall(client, target);
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  // ---- deleting -------------------------------------------------------------

  /// Manual eviction (spec requirement 6). Offered only on an installed,
  /// NON-active model: the server refuses to delete what it transcribes
  /// with, and offering a button that always 409s would be a lie. The typed
  /// refusal is still handled, because a catalogue can go stale.
  Future<void> _onDelete(String name) async {
    if (_busy || _installing) return;
    final int bytes = _catalog?.byName(name)?.sizeBytesOnDisk ?? 0;
    final bool confirmed = await showDialog<bool>(
          context: context,
          builder: (BuildContext context) =>
              _DeleteConfirmDialog(model: name, bytesOnDisk: bytes),
        ) ??
        false;
    if (!mounted || !confirmed) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final WhisperModelClient? client = await _client();
      if (client == null) {
        if (mounted) setState(() => _offline = true);
        return;
      }
      final WhisperModelCatalog catalog = await client.deleteModel(name);
      if (!mounted) return;
      setState(() => _catalog = catalog);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Deleted $name from the server')),
      );
    } on CannotDeleteActiveModelException {
      if (mounted) {
        setState(
          () => _error = 'That is the model your server transcribes with. '
              'Select a different one first.',
        );
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not delete $name: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---- shared ---------------------------------------------------------------

  Future<void> _notifyProgress(WhisperInstallProgress progress) async {
    final String name = progress.model ?? _installTarget ?? 'model';
    await _notify(
      'Installing $name',
      '${progress.phase} — ${progress.percent}% — ${progress.detail}',
    );
  }

  /// Mirrors a state into the shade. Never throws: a notification is a
  /// convenience, and the install path must survive a plugin that is broken
  /// or unavailable (the R8 lesson).
  Future<void> _notify(String title, String body) async {
    if (!mounted) return;
    try {
      await ref
          .read(whisperModelInstallNotificationPortProvider)
          .show(TranscriptionNotice(title: title, body: body));
    } catch (e, stack) {
      debugPrint('tangent.whisper-model notification failed: $e');
      debugPrintStack(stackTrace: stack, label: 'tangent.whisper-model');
    }
  }

  List<_Row> _rows() {
    final WhisperModelCatalog? catalog = _catalog;
    if (catalog == null || catalog.models.isEmpty) {
      // Requirement 13: never an empty list. The local table stands in, with
      // installed left UNKNOWN rather than guessed.
      return _kKnownModels
          .map(
            (_KnownModel m) => _Row(
              name: m.name,
              installed: null,
              approxBytes: m.approxBytes,
              blurb: m.blurb,
            ),
          )
          .toList(growable: false);
    }
    return catalog.models
        .map(
          (WhisperModelInfo m) => _Row(
            name: m.name,
            installed: m.installed,
            approxBytes: m.approxDownloadBytes > 0
                ? m.approxDownloadBytes
                : _known(m.name)?.approxBytes ?? 0,
            blurb: _known(m.name)?.blurb ?? '',
          ),
        )
        .toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    final List<_Row> rows = _rows();
    final String active = _active;
    final WhisperInstallProgress? progress = _progress;
    final bool locked = _offline || _busy || _installing;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Text(
            'Transcription model',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 4, 16, 4),
          child: Text(
            'Your server transcribes with the model selected here. Bigger '
            'models are more accurate and take longer to download and run.',
            style: TextStyle(fontSize: 12),
          ),
        ),
        if (_offline)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              'Your server is unreachable, so this list cannot be changed '
              'right now. Showing the model this device last saw it using.',
              key: const ValueKey<String>('whisper-model-offline'),
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          ),
        for (final _Row row in rows)
          RadioListTile<String>(
            key: ValueKey<String>('whisper-model-row-${row.name}'),
            value: row.name,
            groupValue: active,
            onChanged: locked ? null : _onSelect,
            title: Row(
              children: <Widget>[
                Expanded(child: Text(row.name)),
                if (row.installed != null)
                  _InstalledBadge(installed: row.installed!),
              ],
            ),
            subtitle: Text(row.subtitle),
            secondary: row.installed == true && row.name != active
                ? IconButton(
                    key: ValueKey<String>('whisper-model-delete-${row.name}'),
                    tooltip: 'Delete ${row.name} from the server',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: locked ? null : () => _onDelete(row.name),
                  )
                : null,
          ),
        if (progress != null && !_installFailed)
          ListTile(
            key: const ValueKey<String>('whisper-model-install-progress'),
            title: Text(
              'Installing ${progress.model ?? _installTarget ?? ''} — '
              '${progress.percent}%',
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                if (progress.detail.isNotEmpty) Text(progress.detail),
                const SizedBox(height: 8),
                LinearProgressIndicator(
                  value: progress.percent.clamp(0, 100) / 100,
                ),
              ],
            ),
          ),
        if (_installFailed && progress != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  'Install failed: ${progress.detail}',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
                const SizedBox(height: 8),
                FilledButton.tonal(
                  key: const ValueKey<String>('whisper-model-install-retry'),
                  onPressed: _retryInstall,
                  child: const Text('Retry install'),
                ),
              ],
            ),
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              _error!,
              key: const ValueKey<String>('whisper-model-error'),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
      ],
    );
  }
}

/// The per-row fact the picker turns on: weights present, or a download
/// away. Deliberately a plain label, not a colour-only cue.
class _InstalledBadge extends StatelessWidget {
  const _InstalledBadge({required this.installed});

  final bool installed;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: installed
            ? scheme.secondaryContainer
            : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        installed ? 'Installed' : 'Not installed',
        style: TextStyle(
          fontSize: 11,
          color: installed
              ? scheme.onSecondaryContainer
              : scheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _InstallConfirmDialog extends StatelessWidget {
  const _InstallConfirmDialog({required this.model, required this.approxBytes});

  final String model;
  final int approxBytes;

  @override
  Widget build(BuildContext context) {
    final String size = formatWhisperSize(approxBytes);
    return AlertDialog(
      title: Text('Install $model?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          // The size is the whole point of asking: this lands on the user's
          // server, over their connection, before anything else happens.
          Text(
            'Your server will download the $model model — about ~$size — '
            'and keep it on disk.',
          ),
          const SizedBox(height: 12),
          Text(
            'Transcription keeps using the current model until the download '
            'finishes; then Tangent switches to $model.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          key: const ValueKey<String>('whisper-model-install-cancel'),
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey<String>('whisper-model-install-confirm'),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Download and use'),
        ),
      ],
    );
  }
}

class _DeleteConfirmDialog extends StatelessWidget {
  const _DeleteConfirmDialog({required this.model, required this.bytesOnDisk});

  final String model;
  final int bytesOnDisk;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Delete $model?'),
      content: Text(
        'Your server frees about ~${formatWhisperSize(bytesOnDisk)} of disk. '
        'Nothing already transcribed changes, and you can download $model '
        'again later.',
      ),
      actions: <Widget>[
        TextButton(
          key: const ValueKey<String>('whisper-model-delete-cancel'),
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Keep it'),
        ),
        FilledButton(
          key: const ValueKey<String>('whisper-model-delete-confirm'),
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
            foregroundColor: Theme.of(context).colorScheme.onError,
          ),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Delete the weights'),
        ),
      ],
    );
  }
}
