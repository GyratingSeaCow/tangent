// SPDX-License-Identifier: AGPL-3.0-or-later
/// Settings section for server-side handwriting search (OCR).
///
/// The feature is OFF by default and this toggle is the ONLY way it turns
/// on, because enabling it installs a multi-gigabyte ML environment onto
/// the user's server. The flow is deliberately ceremonial:
///
///   toggle ON → GET capability → confirm dialog (flavour-specific wording)
///   → POST install → poll progress every 2 s while visible, mirrored to a
///   local notification → completion notification → toggle rests ON.
///
/// Cancelling at the confirm stage calls NOTHING and leaves the toggle OFF.
/// Toggling OFF is destructive server-side (the venv AND the search index
/// are deleted), so it gets its own confirm that names that consequence.
///
/// The installing state has THREE doors, because the server install outlives
/// this widget (leaving Settings only stops the WATCHING):
///   1. fresh confirm — the wizard above;
///   2. re-entry rehydration — init sees capability.install_running=true and
///      resumes progress + polling + the notification mirror, POSTing nothing;
///   3. 409 attach — POST install says one is already running (a race the
///      capability check missed), so we attach and watch it like our own.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/api_exception.dart';
import '../../services/android_transcription_notification_port.dart';
import '../../services/ocr_settings_client.dart';
import '../../services/transcription_notifications.dart';
import '../server/server_connection_screen.dart'
    show secureStoreProvider, transcriptionClientProvider;
import 'settings_screen.dart' show settingsStoreProvider;

/// Whether handwriting search is enabled on THIS device.
///
/// Task 6's search icons hang off this: they appear only when it is true
/// (and the server reports capability.installed). Seeded from the persisted
/// setting; the wizard below is the only writer.
final handwritingSearchEnabledProvider = StateProvider<bool>(
  (ref) => ref.watch(settingsStoreProvider).handwritingSearchEnabled,
);

/// Client for /v1/ocr/*. Async because the server URL and bearer token live
/// in secure storage, same as the transcription client built in main().
///
/// WATCHES [transcriptionClientProvider] so that reconnecting to a different
/// server rebuilds this client too. Both places that call
/// `SecureStore.setServerUrl` set that provider immediately afterwards, so
/// depending on it is equivalent to depending on the stored URL — which a
/// FutureProvider cannot do directly, because secure storage is not
/// observable. Without this the section keeps talking to the OLD host after
/// a server change: the toggle sits inert and NOTHING appears in the
/// server's log, because no request is being sent anywhere reachable.
final ocrSettingsClientProvider = FutureProvider<OcrSettingsClient>(
  (ref) async {
    // The value is deliberately unused: this is a dependency edge, not data.
    // The transcription client carries the same base URL, but reading it
    // here and trusting its fields would couple two clients' construction;
    // secure storage stays the single source of truth below.
    ref.watch(transcriptionClientProvider);
    final store = ref.watch(secureStoreProvider);
    String? url;
    String? token;
    try {
      url = await store.getServerUrl();
      token = await store.getToken();
    } catch (_) {
      // Linux without a Secret Service: reads throw. Fall through to the
      // localhost default — the first call fails with a message the section
      // can show, which beats dying before the section even builds.
    }
    return OcrSettingsClient(
      baseUrl: url ?? 'http://10.0.2.2:8000',
      token: token,
    );
  },
);

/// The install-progress notification's platform sink. Same plumbing as the
/// transcription notice, under its own id + channel so the two features
/// never overwrite each other in the shade. Overridden in tests.
final ocrInstallNotificationPortProvider =
    Provider<TranscriptionNotificationPort>((ref) {
  // Guarded construction: if the plugin cannot be had at all, the section
  // still works — silently, without a shade mirror — rather than throwing
  // out of a provider read on the init path.
  try {
    return AndroidTranscriptionNotificationPort(
      notificationId: 1002,
      channelId: 'ocr_install_progress',
      channelName: 'Handwriting search install',
      channelDescription:
          'Shows while the OCR environment installs on your server.',
    );
  } catch (e, stack) {
    debugPrint('tangent.ocr-install notifications unavailable: $e');
    debugPrintStack(stackTrace: stack, label: 'tangent.ocr-install');
    return const NullTranscriptionNotificationPort();
  }
});

/// Jeff's wording for a GPU-visible server, verbatim.
const String kRtxInstallWording =
    'Are you sure you want to install the RTX 50 Series OCR ability?';

/// CPU counterpart. The honest speed note lives in the dialog body.
const String kCpuInstallWording =
    'Are you sure you want to install the CPU OCR ability?';

class HandwritingSearchSection extends ConsumerStatefulWidget {
  const HandwritingSearchSection({super.key});

  @override
  ConsumerState<HandwritingSearchSection> createState() =>
      _HandwritingSearchSectionState();
}

class _HandwritingSearchSectionState
    extends ConsumerState<HandwritingSearchSection> {
  /// Non-null while an install is running or has failed; drives the inline
  /// progress/error UI.
  OcrInstallProgress? _progress;
  bool _installFailed = false;

  /// Wizard-stage failures (capability unreachable, uninstall refused).
  String? _error;

  /// A dialog or request is in flight; the toggle must not start a second
  /// wizard underneath it.
  bool _busy = false;

  /// Remembered across a failure so Retry re-posts the SAME flavour the
  /// user confirmed — retrying must not re-ask.
  String? _flavour;

  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    // Door 2: the install outlives this widget. If one is still running on
    // the server, resume watching it — without this, re-entering Settings
    // shows a resting OFF toggle whose tap 409s into a dead-end error.
    _rehydrate();
  }

  @override
  void dispose() {
    // The pairing screen leaked a poll timer once; never again. The server
    // install keeps running — only the WATCHING stops with the widget.
    _pollTimer?.cancel();
    super.dispose();
  }

  bool get _installing => _progress != null && !_installFailed;

  /// Door 2: re-entry rehydration. If the server says an install is still
  /// running (it survived our last dispose — only the watching stopped),
  /// pick the progress UI, the 2 s poll, and the notification mirror back
  /// up exactly where they were. POSTs nothing.
  Future<void> _rehydrate() async {
    final OcrSettingsClient client;
    final OcrCapability capability;
    try {
      client = await ref.read(ocrSettingsClientProvider.future);
      capability = await client.getCapability();
    } catch (_) {
      // Unreachable server at init is not an error banner — the user did
      // nothing yet. The toggle stays interactive and complains on use.
      return;
    }
    if (!mounted || !capability.installRunning || _installing) return;
    _flavour ??= capability.gpuVisible ? 'gpu' : 'cpu';
    setState(() {
      _installFailed = false;
      _progress = const OcrInstallProgress(
        phase: 'venv',
        percent: 0,
        detail: 'Resuming install…',
      );
    });
    await _watch(client);
  }

  Future<void> _onToggle(bool requested) async {
    if (_busy || _installing) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (requested) {
        await _beginEnable();
      } else {
        await _beginDisable();
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---- enable: capability → confirm → install → poll -----------------------

  Future<void> _beginEnable() async {
    final OcrSettingsClient client;
    final OcrCapability capability;
    try {
      client = await ref.read(ocrSettingsClientProvider.future);
      capability = await client.getCapability();
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'Could not check the server: $e');
      }
      return;
    }
    if (!mounted) return;

    if (capability.installed) {
      // The environment already exists (installed from another device, or
      // toggled off locally without uninstalling): nothing to download.
      // This is exactly the upgraded-device path, so ask the server to
      // re-announce the index before resting the toggle: this device's
      // checkpoint may have advanced past every ink_index change while it
      // was running a pre-1.7.0 build (the server filters the entity for
      // legacy pulls but still moves head_seq), and without the backfill
      // its search stays empty forever. Best-effort: a failure here must
      // not block enabling — the next enable retries it.
      try {
        await client.backfillIndex();
      } catch (e) {
        debugPrint('tangent.ocr ink-index backfill failed: $e');
      }
      await _restToggle(true);
      return;
    }

    final String flavour = capability.gpuVisible ? 'gpu' : 'cpu';
    final bool confirmed = await showDialog<bool>(
          context: context,
          builder: (BuildContext context) =>
              _InstallConfirmDialog(gpu: capability.gpuVisible),
        ) ??
        false;
    // Cancel is a full stop: the toggle stays OFF and nothing is posted.
    if (!mounted || !confirmed) return;
    await _startInstall(client, flavour);
  }

  Future<void> _startInstall(OcrSettingsClient client, String flavour) async {
    _flavour = flavour;
    setState(() {
      _installFailed = false;
      _progress = const OcrInstallProgress(
        phase: 'venv',
        percent: 0,
        detail: 'Starting install…',
      );
    });
    try {
      await client.startInstall(flavour: flavour);
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.statusCode == 409) {
        // Door 3: an install is ALREADY running (a race the capability check
        // missed, or our own from a previous visit). That is not a failure —
        // it is the thing we wanted. Attach and watch it.
        setState(() {
          _progress = const OcrInstallProgress(
            phase: 'venv',
            percent: 0,
            detail: 'Resuming install…',
          );
        });
        await _watch(client);
        return;
      }
      await _failInstall('$e');
      return;
    } catch (e) {
      if (!mounted) return;
      await _failInstall('$e');
      return;
    }
    if (!mounted) return;
    await _watch(client);
  }

  Future<void> _failInstall(String detail) async {
    setState(() {
      _installFailed = true;
      _progress = OcrInstallProgress(
        phase: 'failed',
        percent: 0,
        detail: detail,
      );
    });
    await _notify('Handwriting search install failed', detail);
  }

  /// The single watcher behind all three doors: poll immediately (whoever
  /// just arrived is looking at the screen), then every 2 s for as long as
  /// the section stays visible.
  Future<void> _watch(OcrSettingsClient client) async {
    await _poll(client);
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _poll(client),
    );
  }

  Future<void> _poll(OcrSettingsClient client) async {
    if (!mounted) return;
    final OcrInstallProgress progress;
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
        await _restToggle(true);
        await _notify(
          'Handwriting search ready',
          'Your notebooks are being indexed. Search will fill in as it runs.',
        );
      case 'failed':
        _stopPolling();
        setState(() {
          _progress = progress;
          _installFailed = true;
        });
        await _notify('Handwriting search install failed', progress.detail);
      default:
        setState(() => _progress = progress);
        await _notify(
          'Installing handwriting search',
          '${progress.phase} — ${progress.percent}% — ${progress.detail}',
        );
    }
  }

  Future<void> _retryInstall() async {
    if (_busy || _installing) return;
    final String? flavour = _flavour;
    if (flavour == null) return;
    final OcrSettingsClient client;
    try {
      client = await ref.read(ocrSettingsClientProvider.future);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not reach the server: $e');
      return;
    }
    // The user already confirmed this flavour; retry goes straight back to
    // POST install rather than re-running the wizard.
    await _startInstall(client, flavour);
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  // ---- disable: destructive confirm → uninstall ----------------------------

  Future<void> _beginDisable() async {
    final bool confirmed = await showDialog<bool>(
          context: context,
          builder: (BuildContext context) => const _UninstallConfirmDialog(),
        ) ??
        false;
    if (!mounted || !confirmed) return;
    try {
      final OcrSettingsClient client =
          await ref.read(ocrSettingsClientProvider.future);
      await client.uninstall();
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not uninstall: $e');
      return;
    }
    if (!mounted) return;
    await _restToggle(false);
  }

  // ---- shared --------------------------------------------------------------

  /// Lands the toggle in its final position: persisted AND live for every
  /// watcher (Task 6's search icons hang off the provider).
  Future<void> _restToggle(bool value) async {
    await ref.read(settingsStoreProvider).setHandwritingSearchEnabled(value);
    if (!mounted) return;
    ref.read(handwritingSearchEnabledProvider.notifier).state = value;
  }

  /// Mirrors a wizard state into the shade. Never throws: a notification is
  /// a convenience, and the install/rehydrate paths that call this must
  /// survive a notification plugin that is broken or unavailable (the
  /// release build once shipped without the plugin's R8 keep rules, and the
  /// resulting throw travelled up the init path and stopped sync).
  Future<void> _notify(String title, String body) async {
    if (!mounted) return;
    try {
      await ref
          .read(ocrInstallNotificationPortProvider)
          .show(TranscriptionNotice(title: title, body: body));
    } catch (e, stack) {
      debugPrint('tangent.ocr-install notification failed: $e');
      debugPrintStack(stackTrace: stack, label: 'tangent.ocr-install');
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool enabled = ref.watch(handwritingSearchEnabledProvider);
    final OcrInstallProgress? progress = _progress;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(
            'Handwriting search',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
        SwitchListTile(
          key: const ValueKey<String>('settings-handwriting-search-toggle'),
          title: const Text('Search your handwriting'),
          subtitle: const Text(
            'Your server reads your notebooks and builds a text search '
            'over them. Requires a one-time install on the server.',
          ),
          value: enabled,
          onChanged: _busy || _installing ? null : _onToggle,
        ),
        if (progress != null && !_installFailed)
          ListTile(
            key: const ValueKey<String>('handwriting-install-progress'),
            title: Text('${progress.phase} — ${progress.percent}%'),
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
                  style:
                      TextStyle(color: Theme.of(context).colorScheme.error),
                ),
                const SizedBox(height: 8),
                FilledButton.tonal(
                  key: const ValueKey<String>('handwriting-install-retry'),
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
              key: const ValueKey<String>('handwriting-search-error'),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
      ],
    );
  }
}

class _InstallConfirmDialog extends StatelessWidget {
  const _InstallConfirmDialog({required this.gpu});

  final bool gpu;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Install handwriting search?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(gpu ? kRtxInstallWording : kCpuInstallWording),
          const SizedBox(height: 12),
          Text(
            gpu
                // Same model either way; the GPU buys indexing speed.
                ? 'This downloads a few gigabytes onto your server. Your '
                    'GPU makes the initial indexing of existing notebooks '
                    'fast.'
                : 'This downloads a few gigabytes onto your server. Without '
                    'a GPU, indexing runs on the CPU and is slower — but it '
                    'uses the same recognition model, so accuracy is '
                    'identical.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          key: const ValueKey<String>('handwriting-install-cancel'),
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey<String>('handwriting-install-confirm'),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Install'),
        ),
      ],
    );
  }
}

class _UninstallConfirmDialog extends StatelessWidget {
  const _UninstallConfirmDialog();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Turn off handwriting search?'),
      // The consequence, named: this is not a local switch, the server
      // deletes real state that took hours to build.
      content: const Text(
        'Your server will delete the OCR environment and the handwriting '
        'search index built from your notebooks. Turning this back on later '
        'reinstalls everything and re-indexes from scratch.',
      ),
      actions: <Widget>[
        TextButton(
          key: const ValueKey<String>('handwriting-uninstall-cancel'),
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Keep it'),
        ),
        FilledButton(
          key: const ValueKey<String>('handwriting-uninstall-confirm'),
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
            foregroundColor: Theme.of(context).colorScheme.onError,
          ),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Delete it all'),
        ),
      ],
    );
  }
}
