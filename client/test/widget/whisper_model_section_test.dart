// SPDX-License-Identifier: AGPL-3.0-or-later
/// The Whisper model section is the ONLY place a user can change what their
/// server transcribes with, and picking an uninstalled model downloads up to
/// ~3.1 GB onto that server — so the accuracy-first copy, the Installed
/// badges, the size-naming confirm, the install→select chaining, the
/// rehydration door and the offline fallback are all pinned here.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/settings_store.dart';
import 'package:tangent/screens/settings/settings_screen.dart'
    show settingsStoreProvider;
import 'package:tangent/screens/settings/whisper_model_section.dart';
import 'package:tangent/services/transcription_notifications.dart';
import 'package:tangent/services/whisper_model_client.dart';

WhisperModelInfo _model(
  String name, {
  required bool installed,
  required int approx,
}) =>
    WhisperModelInfo(
      name: name,
      installed: installed,
      sizeBytesOnDisk: installed ? approx : 0,
      approxDownloadBytes: approx,
    );

/// The server's accuracy order, with only large-v3 installed — the shape a
/// stock container actually has.
WhisperModelCatalog _catalog({
  String active = 'large-v3',
  Set<String> installed = const <String>{'large-v3'},
}) =>
    WhisperModelCatalog(
      active: active,
      models: <WhisperModelInfo>[
        _model(
          'large-v3',
          installed: installed.contains('large-v3'),
          approx: 3100000000,
        ),
        _model(
          'medium',
          installed: installed.contains('medium'),
          approx: 1500000000,
        ),
        _model(
          'small',
          installed: installed.contains('small'),
          approx: 484000000,
        ),
        _model(
          'base',
          installed: installed.contains('base'),
          approx: 145000000,
        ),
        _model(
          'tiny',
          installed: installed.contains('tiny'),
          approx: 75000000,
        ),
      ],
    );

class _FakeWhisperModelClient extends WhisperModelClient {
  _FakeWhisperModelClient({required WhisperModelCatalog catalog})
      : _catalogue = catalog,
        super(baseUrl: 'http://unused.invalid');

  WhisperModelCatalog _catalogue;

  final List<String> selectCalls = <String>[];
  final List<String> installCalls = <String>[];
  final List<String> deleteCalls = <String>[];
  int modelsCalls = 0;
  int progressCalls = 0;

  /// Progress responses handed out in order; the last one repeats.
  List<WhisperInstallProgress> script = <WhisperInstallProgress>[];

  /// When set, [getModels] throws it — an unreachable server.
  Object? modelsError;

  /// When set, [selectModel] records the call and then throws it.
  Object? selectError;

  /// When set, [startInstall] records the call and then throws it.
  Object? installError;

  @override
  Future<WhisperModelCatalog> getModels() async {
    modelsCalls += 1;
    final Object? err = modelsError;
    if (err != null) throw err;
    return _catalogue;
  }

  @override
  Future<WhisperModelCatalog> selectModel(String name) async {
    selectCalls.add(name);
    final Object? err = selectError;
    if (err != null) throw err;
    _catalogue = WhisperModelCatalog(
      active: name,
      models: _catalogue.models,
    );
    return _catalogue;
  }

  @override
  Future<void> startInstall(String name) async {
    installCalls.add(name);
    final Object? err = installError;
    if (err != null) throw err;
  }

  @override
  Future<WhisperInstallProgress> getInstallProgress() async {
    progressCalls += 1;
    if (script.isEmpty) {
      return const WhisperInstallProgress(
        phase: 'idle',
        percent: 0,
        detail: '',
      );
    }
    return script.length > 1 ? script.removeAt(0) : script.first;
  }

  @override
  Future<WhisperModelCatalog> deleteModel(String name) async {
    deleteCalls.add(name);
    return _catalogue;
  }

  /// Marks [name] installed server-side, the way a finished install does.
  void markInstalled(String name) {
    _catalogue = WhisperModelCatalog(
      active: _catalogue.active,
      models: _catalogue.models
          .map(
            (WhisperModelInfo m) => m.name == name
                ? WhisperModelInfo(
                    name: m.name,
                    installed: true,
                    sizeBytesOnDisk: m.approxDownloadBytes,
                    approxDownloadBytes: m.approxDownloadBytes,
                  )
                : m,
          )
          .toList(),
    );
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

/// The notification plugin broken exactly as the release build broke it.
class _ThrowingPort implements TranscriptionNotificationPort {
  int showAttempts = 0;

  @override
  Future<void> show(TranscriptionNotice notice) async {
    showAttempts += 1;
    throw PlatformException(code: 'error', message: 'TypeToken');
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
  final _FakeWhisperModelClient client;
  final TranscriptionNotificationPort port;
  final SettingsStore store;

  _RecordingPort get recorded => port as _RecordingPort;
}

Future<_Harness> _mount(
  WidgetTester tester, {
  WhisperModelCatalog? catalog,
  Object? modelsError,
  List<WhisperInstallProgress>? script,
  String rememberedModel = 'large-v3',
  TranscriptionNotificationPort? port,
  bool clientUnavailable = false,
}) async {
  final SettingsStore store = SettingsStore(whisperModel: rememberedModel);
  final _FakeWhisperModelClient client =
      _FakeWhisperModelClient(catalog: catalog ?? _catalog());
  client.modelsError = modelsError;
  // Rehydration polls during init, so a scripted sequence must be in place
  // BEFORE the first pump.
  if (script != null) client.script = script;
  final TranscriptionNotificationPort notificationPort =
      port ?? _RecordingPort();
  final ProviderContainer container = ProviderContainer(
    overrides: <Override>[
      settingsStoreProvider.overrideWithValue(store),
      whisperModelClientProvider.overrideWith(
        (ref) => clientUnavailable
            ? Future<WhisperModelClient>.error(
                StateError('no server configured'),
              )
            : Future<WhisperModelClient>.value(client),
      ),
      whisperModelInstallNotificationPortProvider
          .overrideWithValue(notificationPort),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: WhisperModelSection()),
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

Finder _row(String name) =>
    find.byKey(ValueKey<String>('whisper-model-row-$name'));

String? _selected(WidgetTester tester) {
  final Iterable<RadioListTile<String>> tiles =
      tester.widgetList<RadioListTile<String>>(
    find.byType(RadioListTile<String>),
  );
  for (final RadioListTile<String> tile in tiles) {
    if (tile.value == tile.groupValue) return tile.value;
  }
  return null;
}

bool _rowEnabled(WidgetTester tester, String name) =>
    tester.widget<RadioListTile<String>>(_row(name)).onChanged != null;

/// Tap a row and let the (possible) dialog animate in. Safe to settle: no
/// poll timer exists until an install starts.
Future<void> _tapRow(WidgetTester tester, String name) async {
  await tester.tap(_row(name));
  await tester.pumpAndSettle();
}

/// Confirm the install dialog. Discrete pumps from here: the progress poller
/// runs a periodic timer, so pumpAndSettle would never settle.
Future<void> _confirmInstall(WidgetTester tester) async {
  await tester.tap(
    find.byKey(const ValueKey<String>('whisper-model-install-confirm')),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump();
}

void main() {
  testWidgets(
      'renders every model in the server\'s accuracy order with '
      'accuracy-first copy and sizes', (tester) async {
    await _mount(tester);
    await tester.pumpAndSettle();

    final List<String> rendered = tester
        .widgetList<RadioListTile<String>>(find.byType(RadioListTile<String>))
        .map((RadioListTile<String> t) => t.value)
        .toList();
    expect(rendered, <String>['large-v3', 'medium', 'small', 'base', 'tiny']);

    // Requirement 9's literal copy for the two ends of the range.
    expect(
      find.textContaining('Most accurate — recommended · ~3.1 GB'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Fastest, least accurate · ~75 MB'),
      findsOneWidget,
    );
    expect(find.textContaining('~1.5 GB'), findsOneWidget);
    expect(find.textContaining('~484 MB'), findsOneWidget);
    expect(find.textContaining('~145 MB'), findsOneWidget);

    // Requirement 11: no row may sell a smaller model as the better choice.
    expect(find.textContaining('better for most people'), findsNothing);
    expect(find.textContaining('recommended for most'), findsNothing);
  });

  testWidgets(
      'every row carries an Installed / Not installed badge and the active '
      'model is the selected radio', (tester) async {
    await _mount(
      tester,
      catalog: _catalog(
        active: 'large-v3',
        installed: <String>{'large-v3', 'small'},
      ),
    );
    await tester.pumpAndSettle();

    expect(_selected(tester), 'large-v3');
    // Installed is a per-row FACT, not a property of the active model: small
    // is installed but not active, medium is neither.
    expect(
      find.descendant(of: _row('large-v3'), matching: find.text('Installed')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: _row('small'), matching: find.text('Installed')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: _row('medium'),
        matching: find.text('Not installed'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: _row('tiny'), matching: find.text('Not installed')),
      findsOneWidget,
    );
  });

  testWidgets(
      'selecting an INSTALLED model PUTs immediately and snackbars '
      'Now transcribing with it — no dialog, no install', (tester) async {
    final _Harness h = await _mount(
      tester,
      catalog: _catalog(installed: <String>{'large-v3', 'small'}),
    );
    await tester.pumpAndSettle();

    await _tapRow(tester, 'small');

    expect(h.client.selectCalls, <String>['small']);
    expect(h.client.installCalls, isEmpty);
    expect(find.text('Now transcribing with small'), findsOneWidget);
    expect(_selected(tester), 'small');
    // The local mirror follows, so an offline reopen shows the truth.
    expect(h.store.whisperModel, 'small');
  });

  testWidgets('tapping the already-active model changes nothing',
      (tester) async {
    final _Harness h = await _mount(tester);
    await tester.pumpAndSettle();

    await _tapRow(tester, 'large-v3');

    expect(h.client.selectCalls, isEmpty);
    expect(h.client.installCalls, isEmpty);
  });

  testWidgets(
      'selecting an UNINSTALLED model asks first, naming the download size, '
      'and cancelling installs nothing', (tester) async {
    final _Harness h = await _mount(tester);
    await tester.pumpAndSettle();

    await _tapRow(tester, 'medium');

    // The size is named BEFORE anything is downloaded — that is the whole
    // point of the confirm.
    expect(find.textContaining('~1.5 GB'), findsWidgets);
    expect(find.textContaining('medium'), findsWidgets);
    expect(h.client.installCalls, isEmpty);
    expect(h.client.selectCalls, isEmpty);

    await tester.tap(
      find.byKey(const ValueKey<String>('whisper-model-install-cancel')),
    );
    await tester.pumpAndSettle();

    expect(h.client.installCalls, isEmpty);
    expect(h.client.selectCalls, isEmpty);
    // Cancel is a full stop: the radio stays where it was.
    expect(_selected(tester), 'large-v3');
  });

  testWidgets(
      'install then auto-select: confirm downloads the model, progress runs, '
      'and done PUTs the selection with a snackbar', (tester) async {
    // Requirement 10's chain. The server deliberately does NOT switch the
    // active model on install, so if the client drops this step the user
    // waits out a 1.5 GB download and is still on the old model.
    final _Harness h = await _mount(tester);
    await tester.pumpAndSettle();
    h.client.script = <WhisperInstallProgress>[
      const WhisperInstallProgress(
        phase: 'downloading',
        percent: 45,
        detail: 'Fetching model.bin',
        model: 'medium',
      ),
      const WhisperInstallProgress(
        phase: 'done',
        percent: 100,
        detail: 'Install complete',
        model: 'medium',
      ),
    ];

    await _tapRow(tester, 'medium');
    h.client.markInstalled('medium');
    await _confirmInstall(tester);

    expect(h.client.installCalls, <String>['medium']);
    // Installing is not selecting: nothing is PUT until the install lands.
    expect(h.client.selectCalls, isEmpty);
    expect(find.textContaining('45%'), findsOneWidget);

    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    await tester.pump();

    expect(h.client.selectCalls, <String>['medium']);
    expect(_selected(tester), 'medium');
    expect(h.store.whisperModel, 'medium');
    expect(find.text('Now transcribing with medium'), findsOneWidget);
    expect(find.textContaining('45%'), findsNothing);
  });

  testWidgets(
      'install progress renders inline and mirrors to the notification',
      (tester) async {
    final _Harness h = await _mount(tester);
    await tester.pumpAndSettle();
    h.client.script = <WhisperInstallProgress>[
      const WhisperInstallProgress(
        phase: 'downloading',
        percent: 30,
        detail: 'Fetching model.bin',
        model: 'small',
      ),
      const WhisperInstallProgress(
        phase: 'verifying',
        percent: 90,
        detail: 'Checking the download',
        model: 'small',
      ),
      const WhisperInstallProgress(
        phase: 'done',
        percent: 100,
        detail: 'Install complete',
        model: 'small',
      ),
    ];

    await _tapRow(tester, 'small');
    h.client.markInstalled('small');
    await _confirmInstall(tester);

    expect(find.textContaining('30%'), findsOneWidget);
    expect(find.text('Fetching model.bin'), findsOneWidget);
    expect(h.recorded.shown, isNotEmpty);
    expect(h.recorded.shown.last.body, contains('30%'));

    // 2 s cadence, same as the summaries wizard.
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(find.textContaining('90%'), findsOneWidget);
    expect(h.recorded.shown.last.body, contains('90%'));

    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    await tester.pump();
    expect(h.recorded.shown.last.title, contains('small'));
    expect(h.recorded.shown.last.body, contains('Now transcribing'));
  });

  testWidgets(
      'install failure surfaces the server detail with a Retry, and the '
      'radio falls back to the previously active model', (tester) async {
    final _Harness h = await _mount(tester);
    await tester.pumpAndSettle();
    h.client.script = <WhisperInstallProgress>[
      const WhisperInstallProgress(
        phase: 'failed',
        percent: 12,
        detail: 'No space left on device',
        model: 'medium',
      ),
    ];

    await _tapRow(tester, 'medium');
    await _confirmInstall(tester);

    expect(find.textContaining('No space left on device'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('whisper-model-install-retry')),
      findsOneWidget,
    );
    // A failed download must never leave the picker claiming the new model.
    expect(_selected(tester), 'large-v3');
    expect(h.client.selectCalls, isEmpty);
    expect(h.recorded.shown.last.title, contains('failed'));

    // Retry goes straight back to POST install — the size was already agreed.
    h.client.script = <WhisperInstallProgress>[
      const WhisperInstallProgress(
        phase: 'done',
        percent: 100,
        detail: 'ok',
        model: 'medium',
      ),
    ];
    h.client.markInstalled('medium');
    await tester.tap(
      find.byKey(const ValueKey<String>('whisper-model-install-retry')),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(h.client.installCalls, <String>['medium', 'medium']);
    expect(h.client.selectCalls, <String>['medium']);
    expect(_selected(tester), 'medium');
  });

  testWidgets(
      'a 409 already-running from POST install attaches to it instead of '
      'rendering an error', (tester) async {
    final _Harness h = await _mount(tester);
    await tester.pumpAndSettle();
    h.client.installError = const WhisperInstallAlreadyRunningException(
      message: 'A model install is already running',
    );
    h.client.script = <WhisperInstallProgress>[
      const WhisperInstallProgress(
        phase: 'downloading',
        percent: 20,
        detail: 'Fetching model.bin',
        model: 'medium',
      ),
      const WhisperInstallProgress(
        phase: 'done',
        percent: 100,
        detail: 'Install complete',
        model: 'medium',
      ),
    ];

    await _tapRow(tester, 'medium');
    h.client.markInstalled('medium');
    await _confirmInstall(tester);

    expect(
      find.byKey(const ValueKey<String>('whisper-model-install-retry')),
      findsNothing,
    );
    expect(find.textContaining('failed'), findsNothing);
    expect(find.textContaining('20%'), findsOneWidget);

    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    await tester.pump();
    expect(h.client.selectCalls, <String>['medium']);
  });

  testWidgets(
      'a 409 not-installed from PUT routes into the install wizard rather '
      'than an error', (tester) async {
    // The catalogue said installed, the server disagreed (weights deleted
    // out from under us). The fix is the same install flow, not a dead end.
    final _Harness h = await _mount(
      tester,
      catalog: _catalog(installed: <String>{'large-v3', 'small'}),
    );
    await tester.pumpAndSettle();
    h.client.selectError = const WhisperModelNotInstalledException(
      model: 'small',
      message: "Model 'small' is not installed",
    );

    await _tapRow(tester, 'small');
    await tester.pumpAndSettle();

    expect(h.client.selectCalls, <String>['small']);
    expect(
      find.byKey(const ValueKey<String>('whisper-model-install-confirm')),
      findsOneWidget,
    );
    expect(find.textContaining('~484 MB'), findsWidgets);
  });

  testWidgets(
      'reopening Settings during an install re-attaches to the progress '
      'without POSTing a second install', (tester) async {
    final _Harness h = await _mount(
      tester,
      script: <WhisperInstallProgress>[
        const WhisperInstallProgress(
          phase: 'downloading',
          percent: 55,
          detail: 'Fetching model.bin',
          model: 'medium',
        ),
        const WhisperInstallProgress(
          phase: 'done',
          percent: 100,
          detail: 'Install complete',
          model: 'medium',
        ),
      ],
    );
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('55%'), findsOneWidget);
    expect(h.client.installCalls, isEmpty);
    expect(h.recorded.shown.last.body, contains('55%'));
    // Rows are locked while someone else's install runs.
    expect(_rowEnabled(tester, 'small'), isFalse);

    h.client.markInstalled('medium');
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    await tester.pump();

    // The install it adopted completes exactly like one it started.
    expect(h.client.selectCalls, <String>['medium']);
    expect(h.client.installCalls, isEmpty);
  });

  testWidgets(
      'an unreachable server renders the rows disabled around the last '
      'remembered model with an explanation, never an empty list',
      (tester) async {
    final _Harness h = await _mount(
      tester,
      modelsError: Exception('connection refused'),
      rememberedModel: 'small',
    );
    await tester.pumpAndSettle();

    expect(find.byType(RadioListTile<String>), findsNWidgets(5));
    expect(_selected(tester), 'small');
    for (final String name in <String>[
      'large-v3',
      'medium',
      'small',
      'base',
      'tiny',
    ]) {
      expect(_rowEnabled(tester, name), isFalse, reason: '$name must be off');
    }
    expect(
      find.byKey(const ValueKey<String>('whisper-model-offline')),
      findsOneWidget,
    );
    expect(h.client.selectCalls, isEmpty);
  });

  testWidgets('a server that cannot even be addressed degrades the same way',
      (tester) async {
    // Secure storage unreadable / no server paired: the provider itself
    // fails. The section must still render, disabled.
    await _mount(tester, clientUnavailable: true, rememberedModel: 'base');
    await tester.pumpAndSettle();

    expect(find.byType(RadioListTile<String>), findsNWidgets(5));
    expect(_selected(tester), 'base');
    expect(_rowEnabled(tester, 'tiny'), isFalse);
    expect(
      find.byKey(const ValueKey<String>('whisper-model-offline')),
      findsOneWidget,
    );
  });

  testWidgets('the progress poll timer dies with the widget', (tester) async {
    final _Harness h = await _mount(tester);
    await tester.pumpAndSettle();
    h.client.script = <WhisperInstallProgress>[
      const WhisperInstallProgress(
        phase: 'downloading',
        percent: 40,
        detail: 'Fetching model.bin',
        model: 'tiny',
      ),
    ];

    await _tapRow(tester, 'tiny');
    await _confirmInstall(tester);
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    final int whileMounted = h.client.progressCalls;
    expect(whileMounted, greaterThanOrEqualTo(2));

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump(const Duration(seconds: 8));

    expect(h.client.progressCalls, whileMounted);
  });

  testWidgets(
      'a notification plugin that throws does not stop the install from '
      'completing and selecting', (tester) async {
    final _ThrowingPort broken = _ThrowingPort();
    final _Harness h = await _mount(tester, port: broken);
    await tester.pumpAndSettle();
    h.client.script = <WhisperInstallProgress>[
      const WhisperInstallProgress(
        phase: 'downloading',
        percent: 50,
        detail: 'Fetching model.bin',
        model: 'tiny',
      ),
      const WhisperInstallProgress(
        phase: 'done',
        percent: 100,
        detail: 'Install complete',
        model: 'tiny',
      ),
    ];

    await _tapRow(tester, 'tiny');
    h.client.markInstalled('tiny');
    await _confirmInstall(tester);

    expect(broken.showAttempts, greaterThanOrEqualTo(1));
    expect(find.textContaining('50%'), findsOneWidget);

    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    await tester.pump();
    expect(h.client.selectCalls, <String>['tiny']);
    expect(_selected(tester), 'tiny');
  });

  testWidgets('a model the client has no copy for still renders with the '
      'server\'s own size', (tester) async {
    // Forward compatibility: a newer server offering a name this build has
    // never heard of must appear, not vanish from the list.
    await _mount(
      tester,
      catalog: WhisperModelCatalog(
        active: 'large-v3',
        models: <WhisperModelInfo>[
          _model('large-v3', installed: true, approx: 3100000000),
          _model('distil-large-v3', installed: false, approx: 1600000000),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(_row('distil-large-v3'), findsOneWidget);
    expect(find.textContaining('~1.6 GB'), findsOneWidget);
  });
}
