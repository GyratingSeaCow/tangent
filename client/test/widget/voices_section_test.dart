// SPDX-License-Identifier: AGPL-3.0-or-later
/// v1.36.0: Settings → Voices — the remembered voices from the server's
/// voice book, one row per name with a per-row Forget. Hidden entirely when
/// the server does not diarize. No wipe-all control exists, by decision.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/models/api_exception.dart';
import 'package:tangent/screens/settings/ai_summaries_section.dart'
    show summariesClientProvider;
import 'package:tangent/screens/settings/voices_section.dart';
import 'package:tangent/services/summaries_client.dart';

class _FakeClient extends SummariesClient {
  _FakeClient(this.voices) : super(baseUrl: 'http://unused.invalid');

  List<VoiceEntry> voices;
  final List<String> forgotten = <String>[];
  Object? listError;

  @override
  Future<List<VoiceEntry>> listVoices() async {
    final Object? err = listError;
    if (err != null) throw err;
    return List<VoiceEntry>.of(voices);
  }

  @override
  Future<void> forgetVoice(String name) async {
    forgotten.add(name);
    voices = voices.where((v) => v.name != name).toList();
  }
}

VoiceEntry _voice(String name, int samples) => VoiceEntry(
      name: name,
      samples: samples,
      updatedAt: DateTime.utc(2026, 9, 29),
    );

Future<_FakeClient> _mount(
  WidgetTester tester, {
  required bool diarization,
  List<VoiceEntry> voices = const <VoiceEntry>[],
  Object? listError,
}) async {
  final _FakeClient client = _FakeClient(voices)..listError = listError;
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        summariesClientProvider.overrideWith(
          (ref) => Future<SummariesClient>.value(client),
        ),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: VoicesSection(available: diarization),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  return client;
}

Finder _k(String key) => find.byKey(ValueKey<String>(key));

void main() {
  testWidgets('hidden entirely when the server does not diarize',
      (tester) async {
    await _mount(
      tester,
      diarization: false,
      voices: <VoiceEntry>[_voice('Jeff', 1)],
    );
    expect(_k('voices-section'), findsNothing);
    expect(find.text('Voices'), findsNothing);
  });

  testWidgets('empty state copy', (tester) async {
    await _mount(tester, diarization: true);
    expect(find.text('Voices'), findsOneWidget);
    expect(
      tester.widget<Text>(_k('voices-empty')).data,
      'No remembered voices yet. Rename a speaker on a recording and '
      'Tangent will recognise them next time.',
    );
  });

  testWidgets('rows show name and taught-by count, singular and plural',
      (tester) async {
    await _mount(
      tester,
      diarization: true,
      voices: <VoiceEntry>[_voice("Jeff O'Neil", 3), _voice('Tom', 1)],
    );
    expect(find.text("Jeff O'Neil"), findsOneWidget);
    expect(find.text('taught by 3 recordings'), findsOneWidget);
    expect(find.text('Tom'), findsOneWidget);
    expect(find.text('taught by 1 recording'), findsOneWidget);
    expect(_k("voice-forget-Jeff O'Neil"), findsOneWidget);
  });

  testWidgets('Forget: dialog copy, confirm → forgetVoice(name), row gone',
      (tester) async {
    final _FakeClient client = await _mount(
      tester,
      diarization: true,
      voices: <VoiceEntry>[_voice('Tom', 1), _voice('Jeff', 2)],
    );
    await tester.tap(_k('voice-forget-Tom'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        "Forget Tom's voice? Recordings already naming Tom keep their names.",
      ),
      findsOneWidget,
    );
    await tester.tap(_k('voices-forget-confirm'));
    await tester.pumpAndSettle();
    expect(client.forgotten, <String>['Tom']);
    expect(find.text('Tom'), findsNothing);
    expect(find.text('Jeff'), findsOneWidget);
  });

  testWidgets('Forget: cancel → nothing called, row stays', (tester) async {
    final _FakeClient client = await _mount(
      tester,
      diarization: true,
      voices: <VoiceEntry>[_voice('Tom', 1)],
    );
    await tester.tap(_k('voice-forget-Tom'));
    await tester.pumpAndSettle();
    await tester.tap(_k('voices-forget-cancel'));
    await tester.pumpAndSettle();
    expect(client.forgotten, isEmpty);
    expect(find.text('Tom'), findsOneWidget);
  });

  testWidgets('no wipe-all control exists', (tester) async {
    await _mount(
      tester,
      diarization: true,
      voices: <VoiceEntry>[_voice('Tom', 1), _voice('Jeff', 2)],
    );
    expect(find.textContaining('Forget all'), findsNothing);
    expect(find.textContaining('Clear'), findsNothing);
    expect(find.byIcon(Icons.delete_sweep), findsNothing);
    expect(find.byIcon(Icons.delete_outline), findsNWidgets(2));
  });

  testWidgets('list failure is shown with Retry, not swallowed',
      (tester) async {
    final _FakeClient client = await _mount(
      tester,
      diarization: true,
      listError: const ApiException(
        statusCode: 503,
        code: 'down',
        message: 'server down',
      ),
    );
    expect(find.textContaining('Could not load voices'), findsOneWidget);
    client.listError = null;
    client.voices = <VoiceEntry>[_voice('Jeff', 1)];
    await tester.tap(_k('voices-retry'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Jeff'), findsOneWidget);
  });
}
