// SPDX-License-Identifier: AGPL-3.0-or-later
/// Settings section for server-side AI summaries of meeting recordings.
///
/// The feature is OFF by default and this toggle is the ONLY way it turns
/// on, because enabling it downloads the ~2.5 GB Qwen summarizer model onto
/// the user's server. The flow mirrors the handwriting-search wizard:
///
///   toggle ON → GET settings → confirm dialog (GPU/CPU-specific wording)
///   → POST install → poll progress every 2 s while visible, mirrored to a
///   local notification → completion notification → toggle rests ON.
///
/// Cancelling at the confirm stage calls NOTHING and leaves the toggle OFF.
/// Toggling OFF deletes the summarizer environment server-side but KEEPS
/// every summary already generated — the confirm dialog names both facts.
///
/// The installing state has THREE doors, because the server install outlives
/// this widget (leaving Settings only stops the WATCHING):
///   1. fresh confirm — the wizard above;
///   2. re-entry rehydration — init sees settings.install_running=true and
///      resumes progress + polling + the notification mirror, POSTing nothing;
///   3. 409 attach — POST install says one is already running (a race the
///      settings check missed), so we attach and watch it like our own.
///
/// An install that COMPLETES while the user is away is deliberately
/// different: rehydration sees install_running=false and does nothing, so
/// the toggle rests OFF until the user flips it — which takes the
/// already-installed fast path (no second download). OCR precedent.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/api_exception.dart';
import '../../services/android_transcription_notification_port.dart';
import '../../services/summaries_client.dart';
import '../../services/transcription_notifications.dart';
import '../server/server_connection_screen.dart'
    show secureStoreProvider, transcriptionClientProvider;
import 'settings_screen.dart' show settingsStoreProvider;
import 'package:tangent/services/server_defaults.dart';

/// Whether AI summaries are enabled per THIS device's local mirror.
///
/// Task 4's regenerate action and summary rendering hang off this plus the
/// server capability. Seeded from the persisted setting; the wizard below
/// is the only writer. The auto-summarize gate itself is SERVER-side (one
/// toggle for every device) — this provider mirrors the last state this
/// device confirmed.
final summariesEnabledProvider = StateProvider<bool>(
  (ref) => ref.watch(settingsStoreProvider).aiSummariesEnabled,
);

/// Client for /v1/summaries/*. Async because the server URL and bearer token
/// live in secure storage, same as the transcription client built in main().
///
/// WATCHES [transcriptionClientProvider] so that reconnecting to a different
/// server rebuilds this client too — never a secure-storage latch. Both
/// places that call `SecureStore.setServerUrl` set that provider immediately
/// afterwards, so depending on it is equivalent to depending on the stored
/// URL, which a FutureProvider cannot do directly (secure storage is not
/// observable). Without this the section keeps talking to the OLD host after
/// a server change: the toggle sits inert and NOTHING appears in the
/// server's log, because no request is being sent anywhere reachable.
final summariesClientProvider = FutureProvider<SummariesClient>(
  (ref) async {
    // The value is deliberately unused: this is a dependency edge, not data.
    // Secure storage stays the single source of truth below.
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
    return SummariesClient(
      baseUrl: url ?? defaultServerBaseUrl(),
      token: token,
    );
  },
);

/// The install-progress notification's platform sink. Same plumbing as the
/// transcription (1001) and OCR-install (1002) notices, under its own id +
/// channel so the three features never overwrite each other in the shade.
/// Overridden in tests.
final summaryInstallNotificationPortProvider =
    Provider<TranscriptionNotificationPort>((ref) {
  // Guarded construction: if the plugin cannot be had at all, the section
  // still works — silently, without a shade mirror — rather than throwing
  // out of a provider read on the init path (the R8 lesson).
  try {
    return AndroidTranscriptionNotificationPort(
      notificationId: 1003,
      channelId: 'summary_install_progress',
      channelName: 'AI summaries install',
      channelDescription:
          'Shows while the summarizer installs on your server.',
    );
  } catch (e, stack) {
    debugPrint('tangent.summary-install notifications unavailable: $e');
    debugPrintStack(stackTrace: stack, label: 'tangent.summary-install');
    return const NullTranscriptionNotificationPort();
  }
});

/// Confirm wording for a GPU-visible server.
const String kGpuSummariesInstallWording =
    'Are you sure you want to install the GPU AI summaries ability?';

/// CPU counterpart. The honest speed note lives in the dialog body — and
/// BOTH bodies claim identical accuracy, because it is true: the two
/// runtimes load the same model.
const String kCpuSummariesInstallWording =
    'Are you sure you want to install the CPU AI summaries ability?';

class AiSummariesSection extends ConsumerStatefulWidget {
  const AiSummariesSection({super.key});

  @override
  ConsumerState<AiSummariesSection> createState() =>
      _AiSummariesSectionState();
}

class _AiSummariesSectionState extends ConsumerState<AiSummariesSection> {
  /// Non-null while an install is running or has failed; drives the inline
  /// progress/error UI.
  SummaryInstallProgress? _progress;
  bool _installFailed = false;

  /// Wizard-stage failures (settings unreachable, uninstall refused).
  String? _error;

  /// A dialog or request is in flight; the toggle must not start a second
  /// wizard underneath it.
  bool _busy = false;

  /// The user already confirmed the ~2.5 GB download this session, so a
  /// Retry after a failure re-posts the install without re-asking.
  bool _installConfirmed = false;

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
    // The server install keeps running — only the WATCHING stops with the
    // widget. A leaked periodic timer would keep polling a dead section.
    _pollTimer?.cancel();
    super.dispose();
  }

  bool get _installing => _progress != null && !_installFailed;

  /// Door 2: re-entry rehydration. If the server says an install is still
  /// running (it survived our last dispose — only the watching stopped),
  /// pick the progress UI, the 2 s poll, and the notification mirror back
  /// up exactly where they were. POSTs nothing.
  Future<void> _rehydrate() async {
    final SummariesClient client;
    final SummarySettings settings;
    try {
      client = await ref.read(summariesClientProvider.future);
      settings = await client.getSettings();
    } catch (_) {
      // Unreachable server at init is not an error banner — the user did
      // nothing yet. The toggle stays interactive and complains on use.
      return;
    }
    if (!mounted || !settings.installRunning || _installing) return;
    _installConfirmed = true;
    setState(() {
      _installFailed = false;
      _progress = const SummaryInstallProgress(
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

  // ---- enable: settings → confirm → install → poll --------------------------

  Future<void> _beginEnable() async {
    final SummariesClient client;
    final SummarySettings settings;
    try {
      client = await ref.read(summariesClientProvider.future);
      settings = await client.getSettings();
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'Could not check the server: $e');
      }
      return;
    }
    if (!mounted) return;

    if (settings.installed) {
      // The environment already exists (installed from another device, or
      // completed while this device was away — the deliberate rests-OFF
      // path): nothing to download, just turn the server gate on.
      await _enableServerToggleAndRest(client);
      return;
    }

    final bool confirmed = await showDialog<bool>(
          context: context,
          builder: (BuildContext context) =>
              _InstallConfirmDialog(gpu: settings.gpuVisible),
        ) ??
        false;
    // Cancel is a full stop: the toggle stays OFF and nothing is posted.
    if (!mounted || !confirmed) return;
    _installConfirmed = true;
    await _startInstall(client);
  }

  Future<void> _startInstall(SummariesClient client) async {
    setState(() {
      _installFailed = false;
      _progress = const SummaryInstallProgress(
        phase: 'venv',
        percent: 0,
        detail: 'Starting install…',
      );
    });
    try {
      await client.startInstall();
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.statusCode == 409) {
        // Door 3: an install is ALREADY running (a race the settings check
        // missed, or our own from a previous visit). That is not a failure —
        // it is the thing we wanted. Attach and watch it.
        setState(() {
          _progress = const SummaryInstallProgress(
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
      _progress = SummaryInstallProgress(
        phase: 'failed',
        percent: 0,
        detail: detail,
      );
    });
    await _notify('AI summaries install failed', detail);
  }

  /// The single watcher behind all three doors: poll immediately (whoever
  /// just arrived is looking at the screen), then every 2 s for as long as
  /// the section stays visible.
  Future<void> _watch(SummariesClient client) async {
    await _poll(client);
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _poll(client),
    );
  }

  Future<void> _poll(SummariesClient client) async {
    if (!mounted) return;
    final SummaryInstallProgress progress;
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
        await _enableServerToggleAndRest(client);
        await _notify(
          'AI summaries ready',
          'Meeting recordings will be summarized after transcription.',
        );
      case 'failed':
        _stopPolling();
        setState(() {
          _progress = progress;
          _installFailed = true;
        });
        await _notify('AI summaries install failed', progress.detail);
      default:
        setState(() => _progress = progress);
        await _notify(
          'Installing AI summaries',
          '${progress.phase} — ${progress.percent}% — ${progress.detail}',
        );
    }
  }

  Future<void> _retryInstall() async {
    if (_busy || _installing || !_installConfirmed) return;
    final SummariesClient client;
    try {
      client = await ref.read(summariesClientProvider.future);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not reach the server: $e');
      return;
    }
    // The user already confirmed the download; retry goes straight back to
    // POST install rather than re-running the wizard.
    await _startInstall(client);
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  // ---- disable: both-facts confirm → uninstall ------------------------------

  Future<void> _beginDisable() async {
    final bool confirmed = await showDialog<bool>(
          context: context,
          builder: (BuildContext context) => const _UninstallConfirmDialog(),
        ) ??
        false;
    if (!mounted || !confirmed) return;
    final SummariesClient client;
    try {
      client = await ref.read(summariesClientProvider.future);
      await client.uninstall();
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not uninstall: $e');
      return;
    }
    if (!mounted) return;
    // Best-effort: the auto-trigger already cannot run without the env, so
    // a failed toggle write here must not undo a successful uninstall.
    try {
      await client.setEnabled(false);
    } catch (e) {
      debugPrint('tangent.summaries disable-toggle failed: $e');
    }
    if (!mounted) return;
    await _restToggle(false);
  }

  // ---- shared ---------------------------------------------------------------

  /// Turns the SERVER-side auto-summarize gate on, then lands the toggle.
  ///
  /// The server toggle is the real feature gate (it changes behavior for
  /// every device), so failing to set it fails the enable: resting the
  /// local toggle ON over a dead server gate would show a lie. The env
  /// stays installed either way — the next flip retries just the gate.
  Future<void> _enableServerToggleAndRest(SummariesClient client) async {
    try {
      await client.setEnabled(true);
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'Could not enable summaries: $e');
      }
      return;
    }
    await _restToggle(true);
  }

  /// Lands the toggle in its final position: persisted AND live for every
  /// watcher (Task 4's regenerate action hangs off the provider).
  Future<void> _restToggle(bool value) async {
    await ref.read(settingsStoreProvider).setAiSummariesEnabled(value);
    if (!mounted) return;
    ref.read(summariesEnabledProvider.notifier).state = value;
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
          .read(summaryInstallNotificationPortProvider)
          .show(TranscriptionNotice(title: title, body: body));
    } catch (e, stack) {
      debugPrint('tangent.summary-install notification failed: $e');
      debugPrintStack(stackTrace: stack, label: 'tangent.summary-install');
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool enabled = ref.watch(summariesEnabledProvider);
    final SummaryInstallProgress? progress = _progress;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(
            'AI summaries',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
        SwitchListTile(
          key: const ValueKey<String>('settings-ai-summaries-toggle'),
          title: const Text('Summarize meeting recordings'),
          subtitle: const Text(
            'After a meeting is transcribed, your server writes a short '
            'summary with key decisions and action items. Requires a '
            'one-time install on the server.',
          ),
          value: enabled,
          onChanged: _busy || _installing ? null : _onToggle,
        ),
        if (progress != null && !_installFailed)
          ListTile(
            key: const ValueKey<String>('ai-summaries-install-progress'),
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
                  key: const ValueKey<String>('ai-summaries-install-retry'),
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
              key: const ValueKey<String>('ai-summaries-error'),
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
      title: const Text('Install AI summaries?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(gpu ? kGpuSummariesInstallWording : kCpuSummariesInstallWording),
          const SizedBox(height: 12),
          Text(
            gpu
                // BINDING: identical accuracy either way — the GPU changes
                // generation speed only. Both runtimes load the same model.
                ? 'This downloads the summarizer model (about 2.5 GB) onto '
                    'your server. Your GPU makes generating each summary '
                    'fast; accuracy is identical either way — the GPU only '
                    'changes speed.'
                : 'This downloads the summarizer model (about 2.5 GB) onto '
                    'your server. Without a GPU, generation runs on the CPU '
                    'and is slower — but it uses the same model, so accuracy '
                    'is identical.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          key: const ValueKey<String>('ai-summaries-install-cancel'),
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey<String>('ai-summaries-install-confirm'),
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
      title: const Text('Turn off AI summaries?'),
      // BOTH consequences, named: the environment is deleted, and the
      // summaries the user already has are NOT — they are user data and
      // uninstall only removes the ability to generate new ones.
      content: const Text(
        'Your server will delete the summarizer environment and its model '
        'download. Summaries already written stay on your recordings on '
        'every device — nothing you have is lost. Turning this back on '
        'later downloads everything again.',
      ),
      actions: <Widget>[
        TextButton(
          key: const ValueKey<String>('ai-summaries-uninstall-cancel'),
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Keep it'),
        ),
        FilledButton(
          key: const ValueKey<String>('ai-summaries-uninstall-confirm'),
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
            foregroundColor: Theme.of(context).colorScheme.onError,
          ),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Delete the environment'),
        ),
      ],
    );
  }
}
