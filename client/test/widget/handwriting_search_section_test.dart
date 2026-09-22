// SPDX-License-Identifier: AGPL-3.0-or-later
/// The handwriting-search Settings section is the ONLY way the OCR feature
/// gets turned on, and turning it on installs gigabytes onto the user's
/// server — so the wizard's exact wording, its cancel path, and its
/// destructive-uninstall confirmation are all pinned here verbatim.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/settings_store.dart';
import 'package:tangent/models/api_exception.dart';
import 'package:tangent/screens/settings/handwriting_search_section.dart';
import 'package:tangent/screens/settings/settings_screen.dart'
    show settingsStoreProvider;
import 'package:tangent/services/ocr_settings_client.dart';
import 'package:tangent/services/transcription_notifications.dart';

/// Jeff's wording, verbatim. A GPU-visible server MUST ask exactly this.
const String rtxWording =
    'Are you sure you want to install the RTX 50 Series OCR ability?';

/// The CPU counterpart — same shape, honest about what changes (speed) and
/// what does not (accuracy: both flavours run the same model).
const String cpuWording =
    'Are you sure you want to install the CPU OCR ability?';

class _FakeOcrClient extends OcrSettingsClient {
  _FakeOcrClient({required OcrCapability capability})
      : _capability = capability,
        super(baseUrl: 'http://unused.invalid');

  final OcrCapability _capability;
  final List<String> installCalls = <String>[];
  int uninstallCalls = 0;
  int progressCalls = 0;

  /// Progress responses handed out in order; the last one repeats.
  List<OcrInstallProgress> script = <OcrInstallProgress>[];

  /// When set, [startInstall] records the call and then throws this —
  /// how the 409 'install already running' race is staged.
  ApiException? installError;

  @override
  Future<OcrCapability> getCapability() async => _capability;

  @override
  Future<void> startInstall({required String flavour}) async {
    installCalls.add(flavour);
    final ApiException? err = installError;
    if (err != null) throw err;
  }

  @override
  Future<OcrInstallProgress> getInstallProgress() async {
    progressCalls += 1;
    if (script.isEmpty) {
      return const OcrInstallProgress(phase: 'idle', percent: 0, detail: '');
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
  final _FakeOcrClient client;
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
  bool installRunning = false,
  List<OcrInstallProgress>? script,
  TranscriptionNotificationPort? port,
}) async {
  final SettingsStore store =
      SettingsStore(handwritingSearchEnabled: enabled);
  final _FakeOcrClient client = _FakeOcrClient(
    capability: OcrCapability(
      installed: installed,
      flavour: installed ? (gpuVisible ? 'gpu' : 'cpu') : null,
      gpuVisible: gpuVisible,
      diskFreeBytes: 64424509440,
      installRunning: installRunning,
    ),
  );
  // Rehydration polls during init, so a scripted progress sequence must be
  // in place BEFORE the first pump.
  if (script != null) client.script = script;
  final TranscriptionNotificationPort notificationPort =
      port ?? _RecordingPort();
  final ProviderContainer container = ProviderContainer(
    overrides: <Override>[
      settingsStoreProvider.overrideWithValue(store),
      ocrSettingsClientProvider.overrideWith(
        (ref) => Future<OcrSettingsClient>.value(client),
      ),
      ocrInstallNotificationPortProvider.overrideWithValue(notificationPort),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: HandwritingSearchSection()),
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
    find.byKey(const ValueKey<String>('settings-handwriting-search-toggle'));

bool _toggleValue(WidgetTester tester) =>
    tester.widget<SwitchListTile>(_toggle).value;

/// Tap the toggle and let the capability fetch + dialog animation finish.
/// Safe to settle: no poll timer exists until an install is confirmed.
Future<void> _openWizard(WidgetTester tester) async {
  await tester.tap(_toggle);
  await tester.pumpAndSettle();
}

/// Confirm the install dialog. Discrete pumps from here on: the progress
/// poller runs a periodic timer, so pumpAndSettle would never settle.
Future<void> _confirmInstall(WidgetTester tester) async {
  await tester.tap(
    find.byKey(const ValueKey<String>('handwriting-install-confirm')),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump();
}

void main() {
  testWidgets('GPU-visible server asks with the exact RTX 50 Series wording',
      (tester) async {
    final _Harness h = await _mount(tester, gpuVisible: true);

    await _openWizard(tester);

    expect(find.text(rtxWording), findsOneWidget);
    expect(find.text(cpuWording), findsNothing);
    // Asking is not installing: nothing may be posted before Confirm.
    expect(h.client.installCalls, isEmpty);

    h.client.script = <OcrInstallProgress>[
      const OcrInstallProgress(phase: 'done', percent: 100, detail: ''),
    ];
    await _confirmInstall(tester);
    expect(h.client.installCalls, <String>['gpu']);
  });

  testWidgets(
      'CPU-only server asks with the CPU wording, honest about slower '
      'indexing and same accuracy', (tester) async {
    final _Harness h = await _mount(tester, gpuVisible: false);

    await _openWizard(tester);

    expect(find.text(cpuWording), findsOneWidget);
    expect(find.text(rtxWording), findsNothing);
    // Honesty requirements: slower, but the SAME model — same accuracy.
    expect(find.textContaining('slower'), findsOneWidget);
    expect(find.textContaining('same recognition model'), findsOneWidget);

    h.client.script = <OcrInstallProgress>[
      const OcrInstallProgress(phase: 'done', percent: 100, detail: ''),
    ];
    await _confirmInstall(tester);
    expect(h.client.installCalls, <String>['cpu']);
  });

  testWidgets(
      'install progress renders phase, percent and detail, mirrors to the '
      'notification, and lands the toggle ON', (tester) async {
    final _Harness h = await _mount(tester, gpuVisible: true);
    h.client.script = <OcrInstallProgress>[
      const OcrInstallProgress(
        phase: 'torch',
        percent: 40,
        detail: 'Downloading PyTorch (CUDA)',
      ),
      const OcrInstallProgress(
        phase: 'weights',
        percent: 80,
        detail: 'Fetching trocr-base weights',
      ),
      const OcrInstallProgress(
        phase: 'done',
        percent: 100,
        detail: 'Install complete',
      ),
    ];

    await _openWizard(tester);
    await _confirmInstall(tester);

    // First poll fires immediately on confirm.
    expect(find.textContaining('40%'), findsOneWidget);
    expect(find.text('Downloading PyTorch (CUDA)'), findsOneWidget);
    expect(h.recorded.shown, isNotEmpty);
    expect(h.recorded.shown.last.body, contains('40%'));

    // 2 s cadence: the next poll advances the bar and the notification.
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(find.textContaining('80%'), findsOneWidget);
    expect(h.recorded.shown.last.body, contains('80%'));

    // Terminal phase: completion notification, toggle rests ON, persisted.
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(_toggleValue(tester), isTrue);
    expect(h.container.read(handwritingSearchEnabledProvider), isTrue);
    expect(h.store.handwritingSearchEnabled, isTrue);
    expect(h.recorded.shown.last.title, 'Handwriting search ready');
    expect(find.textContaining('80%'), findsNothing);
  });

  testWidgets('install failure surfaces the server detail with a retry that '
      're-posts the install', (tester) async {
    final _Harness h = await _mount(tester, gpuVisible: true);
    h.client.script = <OcrInstallProgress>[
      const OcrInstallProgress(
        phase: 'failed',
        percent: 12,
        detail: 'No space left on device',
      ),
    ];

    await _openWizard(tester);
    await _confirmInstall(tester);

    expect(find.textContaining('No space left on device'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('handwriting-install-retry')),
      findsOneWidget,
    );
    // A failed install must not leave the feature half-on.
    expect(_toggleValue(tester), isFalse);
    expect(h.container.read(handwritingSearchEnabledProvider), isFalse);
    expect(h.recorded.shown.last.title, contains('failed'));
    expect(h.client.installCalls, hasLength(1));

    // Retry goes straight back to POST install — the user already confirmed.
    h.client.script = <OcrInstallProgress>[
      const OcrInstallProgress(phase: 'done', percent: 100, detail: 'ok'),
    ];
    await tester.tap(
      find.byKey(const ValueKey<String>('handwriting-install-retry')),
    );
    await tester.pump();
    await tester.pump();
    expect(h.client.installCalls, hasLength(2));
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(_toggleValue(tester), isTrue);
  });

  testWidgets('wizard cancel leaves the toggle OFF and calls nothing',
      (tester) async {
    final _Harness h = await _mount(tester, gpuVisible: true);

    await _openWizard(tester);
    await tester.tap(
      find.byKey(const ValueKey<String>('handwriting-install-cancel')),
    );
    await tester.pumpAndSettle();

    expect(_toggleValue(tester), isFalse);
    expect(h.container.read(handwritingSearchEnabledProvider), isFalse);
    expect(h.store.handwritingSearchEnabled, isFalse);
    expect(h.client.installCalls, isEmpty);
    expect(h.client.uninstallCalls, 0);
    expect(h.client.progressCalls, 0);
  });

  testWidgets('toggle off names the destructive consequence and posts '
      'uninstall only on confirm', (tester) async {
    final _Harness h = await _mount(
      tester,
      gpuVisible: true,
      installed: true,
      enabled: true,
    );
    expect(_toggleValue(tester), isTrue);

    // First pass: cancel. The index survives.
    await _openWizard(tester);
    expect(find.textContaining('OCR environment'), findsOneWidget);
    expect(find.textContaining('handwriting search index'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey<String>('handwriting-uninstall-cancel')),
    );
    await tester.pumpAndSettle();
    expect(h.client.uninstallCalls, 0);
    expect(_toggleValue(tester), isTrue);
    expect(h.store.handwritingSearchEnabled, isTrue);

    // Second pass: confirm. Now — and only now — the POST goes out.
    await _openWizard(tester);
    await tester.tap(
      find.byKey(const ValueKey<String>('handwriting-uninstall-confirm')),
    );
    await tester.pumpAndSettle();
    expect(h.client.uninstallCalls, 1);
    expect(_toggleValue(tester), isFalse);
    expect(h.container.read(handwritingSearchEnabledProvider), isFalse);
    expect(h.store.handwritingSearchEnabled, isFalse);
  });

  testWidgets(
      're-entering Settings during a running install resumes the progress '
      'UI, polling, and notifications without POSTing install',
      (tester) async {
    // The user toggled ON, left Settings mid-download, and came back. The
    // server says install_running=true; the section must pick the watch
    // back up on its own — the old behavior showed a resting OFF toggle
    // whose tap 409'd into a dead-end error.
    final _Harness h = await _mount(
      tester,
      gpuVisible: true,
      installRunning: true,
      script: <OcrInstallProgress>[
        const OcrInstallProgress(
          phase: 'torch',
          percent: 55,
          detail: 'Downloading PyTorch (CUDA)',
        ),
        const OcrInstallProgress(
          phase: 'weights',
          percent: 85,
          detail: 'Fetching trocr-base weights',
        ),
        const OcrInstallProgress(
          phase: 'done',
          percent: 100,
          detail: 'Install complete',
        ),
      ],
    );
    await tester.pump();

    // Rehydrated: progress visible, toggle locked, and NOTHING was posted.
    expect(find.textContaining('55%'), findsOneWidget);
    expect(h.client.installCalls, isEmpty);
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
    expect(h.container.read(handwritingSearchEnabledProvider), isTrue);
    expect(h.store.handwritingSearchEnabled, isTrue);
    expect(h.recorded.shown.last.title, 'Handwriting search ready');
    expect(h.client.installCalls, isEmpty);
  });

  testWidgets(
      'a 409 from POST install attaches to the running install instead of '
      'rendering an error', (tester) async {
    // The race the capability check missed: between GET capability and the
    // confirm, an install started elsewhere. 409 means "already running" —
    // that is the outcome the user wanted, so watch it, never fail on it.
    final _Harness h = await _mount(tester, gpuVisible: true);
    h.client.installError = const ApiException(
      statusCode: 409,
      code: 'http_error',
      message: 'an install is already running',
    );
    h.client.script = <OcrInstallProgress>[
      const OcrInstallProgress(
        phase: 'torch',
        percent: 30,
        detail: 'Downloading PyTorch (CUDA)',
      ),
      const OcrInstallProgress(
        phase: 'done',
        percent: 100,
        detail: 'Install complete',
      ),
    ];

    await _openWizard(tester);
    await _confirmInstall(tester);

    // No failure UI — the section attached and is polling.
    expect(
      find.byKey(const ValueKey<String>('handwriting-install-retry')),
      findsNothing,
    );
    expect(find.textContaining('failed'), findsNothing);
    expect(find.textContaining('30%'), findsOneWidget);
    expect(h.client.progressCalls, greaterThanOrEqualTo(1));

    // And the attached install completes like any other.
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(_toggleValue(tester), isTrue);
    expect(h.recorded.shown.last.title, 'Handwriting search ready');
  });

  testWidgets('the progress poll timer dies with the widget', (tester) async {
    final _Harness h = await _mount(tester, gpuVisible: true);
    h.client.script = <OcrInstallProgress>[
      const OcrInstallProgress(
        phase: 'torch',
        percent: 40,
        detail: 'Downloading PyTorch (CUDA)',
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
    // THE FOURTH E2E DEFECT, at this layer. The release APK shipped without
    // the R8 keep rules flutter_local_notifications needs; the plugin threw
    // "TypeToken must be created with a type argument" and the throw
    // travelled up the init path — rehydration died on its first notify and
    // the poll that should have followed never started, which downstream
    // read to the user as "can't connect to the server". A notification is a
    // convenience; it may never take the surrounding init down with it.
    final _ThrowingPort broken = _ThrowingPort();
    final _Harness h = await _mount(
      tester,
      gpuVisible: true,
      installRunning: true,
      port: broken,
      script: <OcrInstallProgress>[
        const OcrInstallProgress(
          phase: 'torch',
          percent: 55,
          detail: 'Downloading PyTorch (CUDA)',
        ),
        const OcrInstallProgress(
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
    expect(h.client.installCalls, isEmpty);

    // The 2 s poll survived too, and the install still completes and lands
    // the toggle ON — nothing downstream of the notification was lost.
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(_toggleValue(tester), isTrue);
    expect(h.container.read(handwritingSearchEnabledProvider), isTrue);
    expect(h.store.handwritingSearchEnabled, isTrue);
  });
}
