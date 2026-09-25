// SPDX-License-Identifier: AGPL-3.0-or-later
/// The AI-summaries Settings section is the ONLY way the feature gets
/// turned on, and turning it on downloads ~2.5 GB onto the user's server —
/// so the wizard's wording (identical accuracy, GPU changes speed only),
/// its cancel path, its rehydration/409-attach doors, and the
/// both-facts uninstall confirmation are all pinned here.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/settings_store.dart';
import 'package:tangent/models/api_exception.dart';
import 'package:tangent/screens/settings/ai_summaries_section.dart';
import 'package:tangent/screens/settings/settings_screen.dart'
    show settingsStoreProvider;
import 'package:tangent/services/summaries_client.dart';
import 'package:tangent/services/transcription_notifications.dart';

/// A GPU-visible server MUST ask exactly this.
const String gpuWording =
    'Are you sure you want to install the GPU AI summaries ability?';

/// The CPU counterpart — same shape, honest about what changes (speed) and
/// what does not (accuracy: both runtimes load the same model).
const String cpuWording =
    'Are you sure you want to install the CPU AI summaries ability?';

class _FakeSummariesClient extends SummariesClient {
  _FakeSummariesClient({required SummarySettings settings})
      : _settings = settings,
        super(baseUrl: 'http://unused.invalid');

  final SummarySettings _settings;
  int installCalls = 0;
  int uninstallCalls = 0;
  int progressCalls = 0;
  final List<bool> setEnabledCalls = <bool>[];

  /// Progress responses handed out in order; the last one repeats.
  List<SummaryInstallProgress> script = <SummaryInstallProgress>[];

  /// When set, [startInstall] records the call and then throws this —
  /// how the 409 'install already running' race is staged.
  ApiException? installError;

  /// When set, [getSettings] throws this — an unreachable server at init.
  Object? settingsError;

  @override
  Future<SummarySettings> getSettings() async {
    final Object? err = settingsError;
    if (err != null) throw err;
    return _settings;
  }

  @override
  Future<SummarySettings> setEnabled(bool enabled) async {
    setEnabledCalls.add(enabled);
    return _settings;
  }

  @override
  Future<void> startInstall() async {
    installCalls += 1;
    final ApiException? err = installError;
    if (err != null) throw err;
  }

  @override
  Future<SummaryInstallProgress> getInstallProgress() async {
    progressCalls += 1;
    if (script.isEmpty) {
      return const SummaryInstallProgress(phase: 'idle', percent: 0, detail: '');
    }
    return script.length > 1 ? script.removeAt(0) : script.first;
  }

  @override
  Future<void> uninstall() async {
    uninstallCalls += 1;
  }
}

class _RecordingPort implements TranscriptionNotificationPort {
  final List<TranscriptionNotice> shown = <TranscriptionNotice>[];
  int cancels = 0;

  @override
  Future<void> show(TranscriptionNotice notice) async {
    shown.add(notice);
  }

  @override
  Future<void> cancel() async {
    cancels += 1;
  }
}

/// The notification plugin, broken exactly as the release build broke it:
/// R8 stripped the gson generic signatures and every call into the plugin
/// threw a PlatformException. Init must survive it.
class _ThrowingPort implements TranscriptionNotificationPort {
  int showAttempts = 0;

  @override
  Future<void> show(TranscriptionNotice notice) async {
    showAttempts += 1;
    throw PlatformException(
      code: 'error',
      message: 'TypeToken must be created with a type argument: '
          'new TypeToken<...>() {}; When using code shrinkers (ProGuard, R8, '
          '...) make sure that generic signatures are preserved.',
    );
  }

  @override
  Future<void> cancel() async {
    throw PlatformException(code: 'error', message: 'TypeToken');
  }
}

class _Harness {
  _Harness({
    required this.container,
    required this.client,
    required this.port,
    required this.store,
  });

  final ProviderContainer container;
  final _FakeSummariesClient client;
  final TranscriptionNotificationPort port;
  final SettingsStore store;

  /// The recording double, for the tests that assert on what was shown.
  _RecordingPort get recorded => port as _RecordingPort;
}

Future<_Harness> _mount(
  WidgetTester tester, {
  bool gpuVisible = true,
  bool installed = false,
  bool enabled = false,
  bool? serverEnabled,
  bool installRunning = false,
  Object? settingsError,
  List<SummaryInstallProgress>? script,
  TranscriptionNotificationPort? port,
}) async {
  final SettingsStore store = SettingsStore(aiSummariesEnabled: enabled);
  final _FakeSummariesClient client = _FakeSummariesClient(
    settings: SummarySettings(
      installed: installed,
      runtime: installed ? (gpuVisible ? 'cuda' : 'cpu') : null,
      gpuVisible: gpuVisible,
      diskFreeBytes: 64424509440,
      installRunning: installRunning,
      // The server's gate normally agrees with this device's mirror; the
      // reconcile tests pull them apart on purpose.
      enabled: serverEnabled ?? enabled,
    ),
  );
  client.settingsError = settingsError;
  // Rehydration polls during init, so a scripted progress sequence must be
  // in place BEFORE the first pump.
  if (script != null) client.script = script;
  final TranscriptionNotificationPort notificationPort =
      port ?? _RecordingPort();
  final ProviderContainer container = ProviderContainer(
    overrides: <Override>[
      settingsStoreProvider.overrideWithValue(store),
      summariesClientProvider.overrideWith(
        (ref) => Future<SummariesClient>.value(client),
      ),
      summaryInstallNotificationPortProvider
          .overrideWithValue(notificationPort),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: AiSummariesSection()),
        ),
      ),
    ),
  );
  await tester.pump();
  return _Harness(
    container: container,
    client: client,
    port: notificationPort,
    store: store,
  );
}

Finder get _toggle =>
    find.byKey(const ValueKey<String>('settings-ai-summaries-toggle'));

bool _toggleValue(WidgetTester tester) =>
    tester.widget<SwitchListTile>(_toggle).value;

/// Tap the toggle and let the settings fetch + dialog animation finish.
/// Safe to settle: no poll timer exists until an install is confirmed.
Future<void> _openWizard(WidgetTester tester) async {
  await tester.tap(_toggle);
  await tester.pumpAndSettle();
}

/// Confirm the install dialog. Discrete pumps from here on: the progress
/// poller runs a periodic timer, so pumpAndSettle would never settle.
Future<void> _confirmInstall(WidgetTester tester) async {
  await tester.tap(
    find.byKey(const ValueKey<String>('ai-summaries-install-confirm')),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump();
}

void main() {
  testWidgets('toggle seeds from the persisted setting', (tester) async {
    await _mount(tester, enabled: true, installed: true);
    expect(_toggleValue(tester), isTrue);
  });

  // ---- reconcile with the server on open ------------------------------------
  //
  // The auto-summarize gate is SERVER-side (one toggle for every device);
  // the provider is only this device's last-confirmed mirror. Another
  // device (or the API) may have flipped the gate since, so opening the
  // section must adopt the server's answer — reading, never writing.

  testWidgets(
      'server says enabled=false while this device remembers ON: the toggle '
      'lands OFF, persisted, with nothing POSTed', (tester) async {
    final _Harness h = await _mount(
      tester,
      enabled: true,
      serverEnabled: false,
      installed: true,
    );
    await tester.pumpAndSettle();

    expect(_toggleValue(tester), isFalse);
    expect(h.container.read(summariesEnabledProvider), isFalse);
    expect(h.store.aiSummariesEnabled, isFalse);
    // Reconciling is a READ: the server is the source of truth, so this
    // device must not push its stale value back.
    expect(h.client.setEnabledCalls, isEmpty);
    expect(h.client.installCalls, 0);
    expect(h.client.uninstallCalls, 0);
    expect(h.client.progressCalls, 0);
  });

  testWidgets(
      'server says enabled=true while this device remembers OFF: the toggle '
      'lands ON, persisted, with nothing POSTed', (tester) async {
    final _Harness h = await _mount(
      tester,
      enabled: false,
      serverEnabled: true,
      installed: true,
    );
    await tester.pumpAndSettle();

    expect(_toggleValue(tester), isTrue);
    expect(h.container.read(summariesEnabledProvider), isTrue);
    expect(h.store.aiSummariesEnabled, isTrue);
    expect(h.client.setEnabledCalls, isEmpty);
    expect(h.client.installCalls, 0);
    expect(h.client.uninstallCalls, 0);
    expect(h.client.progressCalls, 0);
  });

  testWidgets(
      'an unreachable server at open leaves the remembered toggle untouched',
      (tester) async {
    // No answer is not an answer of "off": the mirror keeps its last
    // confirmed value and the toggle stays interactive, as before.
    final _Harness h = await _mount(
      tester,
      enabled: true,
      serverEnabled: false,
      settingsError: Exception('connection refused'),
    );
    await tester.pumpAndSettle();

    expect(_toggleValue(tester), isTrue);
    expect(h.container.read(summariesEnabledProvider), isTrue);
    expect(h.store.aiSummariesEnabled, isTrue);
    expect(tester.widget<SwitchListTile>(_toggle).onChanged, isNotNull);
    expect(
      find.byKey(const ValueKey<String>('ai-summaries-error')),
      findsNothing,
    );
  });

  testWidgets('GPU-visible server asks with the GPU wording and the ~2.5 GB '
      'size, claiming identical accuracy', (tester) async {
    final _Harness h = await _mount(tester, gpuVisible: true);

    await _openWizard(tester);

    expect(find.text(gpuWording), findsOneWidget);
    expect(find.text(cpuWording), findsNothing);
    // The download size is named BEFORE anything starts.
    expect(find.textContaining('2.5 GB'), findsOneWidget);
    // BINDING: the GPU copy may only claim speed — accuracy is identical.
    expect(find.textContaining('accuracy is identical'), findsOneWidget);
    // Asking is not installing: nothing may be posted before Confirm.
    expect(h.client.installCalls, 0);

    h.client.script = <SummaryInstallProgress>[
      const SummaryInstallProgress(phase: 'done', percent: 100, detail: ''),
    ];
    await _confirmInstall(tester);
    expect(h.client.installCalls, 1);
  });

  testWidgets(
      'CPU-only server asks with the CPU wording, honest about slower '
      'generation and identical accuracy', (tester) async {
    final _Harness h = await _mount(tester, gpuVisible: false);

    await _openWizard(tester);

    expect(find.text(cpuWording), findsOneWidget);
    expect(find.text(gpuWording), findsNothing);
    // Honesty requirements: slower, but the SAME model — identical accuracy.
    expect(find.textContaining('slower'), findsOneWidget);
    expect(find.textContaining('same model'), findsOneWidget);
    expect(find.textContaining('accuracy is identical'), findsOneWidget);
    expect(find.textContaining('2.5 GB'), findsOneWidget);

    h.client.script = <SummaryInstallProgress>[
      const SummaryInstallProgress(phase: 'done', percent: 100, detail: ''),
    ];
    await _confirmInstall(tester);
    expect(h.client.installCalls, 1);
  });

  testWidgets(
      'install progress renders phase, percent and detail, mirrors to the '
      'notification, sets the server toggle and lands the switch ON',
      (tester) async {
    final _Harness h = await _mount(tester, gpuVisible: true);
    h.client.script = <SummaryInstallProgress>[
      const SummaryInstallProgress(
        phase: 'runtime',
        percent: 40,
        detail: 'Installing llama.cpp runtime',
      ),
      const SummaryInstallProgress(
        phase: 'weights',
        percent: 80,
        detail: 'Downloading Qwen3-4B weights',
      ),
      const SummaryInstallProgress(
        phase: 'done',
        percent: 100,
        detail: 'Install complete',
      ),
    ];

    await _openWizard(tester);
    await _confirmInstall(tester);

    // First poll fires immediately on confirm.
    expect(find.textContaining('40%'), findsOneWidget);
    expect(find.text('Installing llama.cpp runtime'), findsOneWidget);
    expect(h.recorded.shown, isNotEmpty);
    expect(h.recorded.shown.last.body, contains('40%'));

    // 2 s cadence: the next poll advances the bar and the notification.
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(find.textContaining('80%'), findsOneWidget);
    expect(h.recorded.shown.last.body, contains('80%'));

    // Terminal phase: completion notification, server gate ON, toggle
    // rests ON, persisted.
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(_toggleValue(tester), isTrue);
    expect(h.container.read(summariesEnabledProvider), isTrue);
    expect(h.store.aiSummariesEnabled, isTrue);
    expect(h.client.setEnabledCalls, <bool>[true]);
    expect(h.recorded.shown.last.title, 'AI summaries ready');
    expect(find.textContaining('80%'), findsNothing);
  });

  testWidgets('install failure surfaces the server detail with a retry that '
      're-posts the install', (tester) async {
    final _Harness h = await _mount(tester, gpuVisible: true);
    h.client.script = <SummaryInstallProgress>[
      const SummaryInstallProgress(
        phase: 'failed',
        percent: 12,
        detail: 'No space left on device',
      ),
    ];

    await _openWizard(tester);
    await _confirmInstall(tester);

    expect(find.textContaining('No space left on device'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('ai-summaries-install-retry')),
      findsOneWidget,
    );
    // A failed install must not leave the feature half-on.
    expect(_toggleValue(tester), isFalse);
    expect(h.container.read(summariesEnabledProvider), isFalse);
    expect(h.recorded.shown.last.title, contains('failed'));
    expect(h.client.installCalls, 1);

    // Retry goes straight back to POST install — the user already confirmed.
    h.client.script = <SummaryInstallProgress>[
      const SummaryInstallProgress(phase: 'done', percent: 100, detail: 'ok'),
    ];
    await tester.tap(
      find.byKey(const ValueKey<String>('ai-summaries-install-retry')),
    );
    await tester.pump();
    await tester.pump();
    expect(h.client.installCalls, 2);
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(_toggleValue(tester), isTrue);
  });

  testWidgets('wizard cancel leaves the toggle OFF and calls nothing',
      (tester) async {
    final _Harness h = await _mount(tester, gpuVisible: true);

    await _openWizard(tester);
    await tester.tap(
      find.byKey(const ValueKey<String>('ai-summaries-install-cancel')),
    );
    await tester.pumpAndSettle();

    expect(_toggleValue(tester), isFalse);
    expect(h.container.read(summariesEnabledProvider), isFalse);
    expect(h.store.aiSummariesEnabled, isFalse);
    expect(h.client.installCalls, 0);
    expect(h.client.uninstallCalls, 0);
    expect(h.client.progressCalls, 0);
    expect(h.client.setEnabledCalls, isEmpty);
  });

  testWidgets(
      'an install that completed while away leaves the toggle resting OFF; '
      'flipping it takes the no-download fast path', (tester) async {
    // Deliberate (OCR precedent): rehydration only resumes a RUNNING
    // install. A finished one changes nothing until the user opts in —
    // the feature never turns itself on.
    final _Harness h = await _mount(
      tester,
      installed: true,
      installRunning: false,
      enabled: false,
    );
    await tester.pump();

    expect(_toggleValue(tester), isFalse);
    expect(h.client.installCalls, 0);
    expect(h.client.progressCalls, 0);

    // The environment already exists: enabling asks nothing and downloads
    // nothing — it just turns the server gate on and rests the toggle.
    await _openWizard(tester);
    expect(find.text(gpuWording), findsNothing);
    expect(h.client.installCalls, 0);
    expect(h.client.setEnabledCalls, <bool>[true]);
    expect(_toggleValue(tester), isTrue);
    expect(h.store.aiSummariesEnabled, isTrue);
  });

  testWidgets('toggle off names BOTH facts — env deleted, summaries kept — '
      'and posts uninstall only on confirm', (tester) async {
    final _Harness h = await _mount(
      tester,
      gpuVisible: true,
      installed: true,
      enabled: true,
    );
    expect(_toggleValue(tester), isTrue);

    // First pass: cancel. Nothing happens.
    await _openWizard(tester);
    // Fact 1: the environment is deleted.
    expect(find.textContaining('summarizer environment'), findsOneWidget);
    // Fact 2: existing summaries are KEPT.
    expect(find.textContaining('Summaries already written'), findsOneWidget);
    expect(find.textContaining('nothing you have is lost'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey<String>('ai-summaries-uninstall-cancel')),
    );
    await tester.pumpAndSettle();
    expect(h.client.uninstallCalls, 0);
    expect(_toggleValue(tester), isTrue);
    expect(h.store.aiSummariesEnabled, isTrue);

    // Second pass: confirm. Now — and only now — the POST goes out, the
    // server gate turns off, and the toggle rests OFF.
    await _openWizard(tester);
    await tester.tap(
      find.byKey(const ValueKey<String>('ai-summaries-uninstall-confirm')),
    );
    await tester.pumpAndSettle();
    expect(h.client.uninstallCalls, 1);
    expect(h.client.setEnabledCalls, <bool>[false]);
    expect(_toggleValue(tester), isFalse);
    expect(h.container.read(summariesEnabledProvider), isFalse);
    expect(h.store.aiSummariesEnabled, isFalse);
  });

  testWidgets(
      're-entering Settings during a running install resumes the progress '
      'UI, polling, and notifications without POSTing install',
      (tester) async {
    // The user toggled ON, left Settings mid-download, and came back. The
    // server says install_running=true; the section must pick the watch
    // back up on its own — otherwise the tap on a resting OFF toggle 409s
    // into a dead-end error.
    final _Harness h = await _mount(
      tester,
      gpuVisible: true,
      installRunning: true,
      script: <SummaryInstallProgress>[
        const SummaryInstallProgress(
          phase: 'weights',
          percent: 55,
          detail: 'Downloading Qwen3-4B weights',
        ),
        const SummaryInstallProgress(
          phase: 'verify',
          percent: 85,
          detail: 'Running selftest',
        ),
        const SummaryInstallProgress(
          phase: 'done',
          percent: 100,
          detail: 'Install complete',
        ),
      ],
    );
    await tester.pump();

    // Rehydrated: progress visible, toggle locked, and NOTHING was posted.
    expect(find.textContaining('55%'), findsOneWidget);
    expect(h.client.installCalls, 0);
    expect(tester.widget<SwitchListTile>(_toggle).onChanged, isNull);
    expect(h.recorded.shown.last.body, contains('55%'));

    // Polling resumed at the 2 s cadence.
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(find.textContaining('85%'), findsOneWidget);
    expect(h.recorded.shown.last.body, contains('85%'));

    // Completion behaves exactly as if the user had never left.
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(_toggleValue(tester), isTrue);
    expect(h.container.read(summariesEnabledProvider), isTrue);
    expect(h.store.aiSummariesEnabled, isTrue);
    expect(h.recorded.shown.last.title, 'AI summaries ready');
    expect(h.client.installCalls, 0);
  });

  testWidgets(
      'a 409 from POST install attaches to the running install instead of '
      'rendering an error', (tester) async {
    // The race the settings check missed: between GET settings and the
    // confirm, an install started elsewhere. 409 means "already running" —
    // that is the outcome the user wanted, so watch it, never fail on it.
    final _Harness h = await _mount(tester, gpuVisible: true);
    h.client.installError = const ApiException(
      statusCode: 409,
      code: 'http_error',
      message: 'A summarizer environment install is already running',
    );
    h.client.script = <SummaryInstallProgress>[
      const SummaryInstallProgress(
        phase: 'weights',
        percent: 30,
        detail: 'Downloading Qwen3-4B weights',
      ),
      const SummaryInstallProgress(
        phase: 'done',
        percent: 100,
        detail: 'Install complete',
      ),
    ];

    await _openWizard(tester);
    await _confirmInstall(tester);

    // No failure UI — the section attached and is polling.
    expect(
      find.byKey(const ValueKey<String>('ai-summaries-install-retry')),
      findsNothing,
    );
    expect(find.textContaining('failed'), findsNothing);
    expect(find.textContaining('30%'), findsOneWidget);
    expect(h.client.progressCalls, greaterThanOrEqualTo(1));

    // And the attached install completes like any other.
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(_toggleValue(tester), isTrue);
    expect(h.recorded.shown.last.title, 'AI summaries ready');
  });

  testWidgets('the progress poll timer dies with the widget', (tester) async {
    final _Harness h = await _mount(tester, gpuVisible: true);
    h.client.script = <SummaryInstallProgress>[
      const SummaryInstallProgress(
        phase: 'weights',
        percent: 40,
        detail: 'Downloading Qwen3-4B weights',
      ),
    ];

    await _openWizard(tester);
    await _confirmInstall(tester);
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    final int callsWhileMounted = h.client.progressCalls;
    expect(callsWhileMounted, greaterThanOrEqualTo(2));

    // Unmount the section. A leaked periodic timer would keep polling.
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump(const Duration(seconds: 8));

    expect(h.client.progressCalls, callsWhileMounted);
  });

  testWidgets(
      'a notification plugin that throws at init does not stop the section '
      'from rehydrating and polling', (tester) async {
    // The release APK once shipped without the R8 keep rules
    // flutter_local_notifications needs; the plugin threw and the throw
    // travelled up the init path. A notification is a convenience; it may
    // never take the surrounding init down with it.
    final _ThrowingPort broken = _ThrowingPort();
    final _Harness h = await _mount(
      tester,
      gpuVisible: true,
      installRunning: true,
      port: broken,
      script: <SummaryInstallProgress>[
        const SummaryInstallProgress(
          phase: 'weights',
          percent: 55,
          detail: 'Downloading Qwen3-4B weights',
        ),
        const SummaryInstallProgress(
          phase: 'done',
          percent: 100,
          detail: 'Install complete',
        ),
      ],
    );
    await tester.pump();

    // It TRIED to notify, and failed — that is the staged defect.
    expect(broken.showAttempts, greaterThanOrEqualTo(1));
    // And init carried on regardless: rehydrated UI, live poll.
    expect(find.textContaining('55%'), findsOneWidget);
    expect(h.client.progressCalls, greaterThanOrEqualTo(1));
    expect(h.client.installCalls, 0);

    // The 2 s poll survived too, and the install still completes and lands
    // the toggle ON — nothing downstream of the notification was lost.
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(_toggleValue(tester), isTrue);
    expect(h.container.read(summariesEnabledProvider), isTrue);
    expect(h.store.aiSummariesEnabled, isTrue);
  });
}
