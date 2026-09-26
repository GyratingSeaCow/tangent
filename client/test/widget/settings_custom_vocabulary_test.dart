// SPDX-License-Identifier: AGPL-3.0-or-later
/// The custom-vocabulary editor is the ONLY writer of a server setting that
/// changes how every device's recordings are transcribed, so its gates are
/// pinned here: hidden when unpaired, seeded from the server, a live count
/// that follows the server's rules as you type, Save only when dirty and
/// sending the RAW text, the server's canonical answer adopted, Clear behind
/// a confirm, and a 422 shown in the server's own words.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/models/api_exception.dart';
import 'package:tangent/screens/settings/custom_vocabulary_section.dart';
import 'package:tangent/screens/settings/whisper_model_section.dart'
    show whisperModelClientProvider;
import 'package:tangent/services/vocabulary.dart';
import 'package:tangent/services/whisper_model_client.dart';

/// Builds the response the real server would give for [text]: canonical
/// terms, comma-joined text, len // 4 tokens, over-budget flag.
VocabularySettings _canonical(String text) {
  final List<String> terms = normalizeVocabulary(text);
  final int tokens = estimateVocabularyTokens(terms);
  return VocabularySettings(
    terms: terms,
    text: vocabularyText(terms),
    tokenEstimate: tokens,
    overBudget: tokens > kVocabularyTokenBudget,
  );
}

class _FakeClient extends WhisperModelClient {
  _FakeClient({VocabularySettings? initial})
      : _current = initial ?? VocabularySettings.empty,
        super(baseUrl: 'http://unused.invalid');

  VocabularySettings _current;

  final List<String> putCalls = <String>[];
  int fetchCalls = 0;

  /// When set, [setVocabulary] records the call and throws it.
  Object? putError;

  /// When set, [fetchVocabulary] throws it.
  Object? fetchError;

  @override
  Future<VocabularySettings> fetchVocabulary() async {
    fetchCalls += 1;
    final Object? err = fetchError;
    if (err != null) throw err;
    return _current;
  }

  @override
  Future<VocabularySettings> setVocabulary(String text) async {
    putCalls.add(text);
    final Object? err = putError;
    if (err != null) throw err;
    _current = _canonical(text);
    return _current;
  }
}

Future<_FakeClient> _mount(
  WidgetTester tester, {
  bool paired = true,
  VocabularySettings? initial,
  Object? putError,
  Object? fetchError,
}) async {
  final _FakeClient client = _FakeClient(initial: initial);
  client.putError = putError;
  client.fetchError = fetchError;
  final ProviderContainer container = ProviderContainer(
    overrides: <Override>[
      vocabularyPairedProvider.overrideWith((ref) async => paired),
      whisperModelClientProvider.overrideWith(
        (ref) => Future<WhisperModelClient>.value(client),
      ),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: CustomVocabularySection()),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return client;
}

Finder get _editor => find.byKey(const ValueKey<String>('vocab-editor'));
Finder get _status => find.byKey(const ValueKey<String>('vocab-status'));
Finder get _save => find.byKey(const ValueKey<String>('vocab-save'));
Finder get _clear => find.byKey(const ValueKey<String>('vocab-clear'));

String _statusText(WidgetTester tester) =>
    tester.widget<Text>(_status).data ?? '';

bool _enabled(WidgetTester tester, Finder button) =>
    tester.widget<ButtonStyleButton>(button).enabled;

String _editorText(WidgetTester tester) =>
    tester.widget<TextField>(_editor).controller!.text;

void main() {
  testWidgets('hidden entirely when the app is not paired', (tester) async {
    final _FakeClient client = await _mount(tester, paired: false);
    expect(_editor, findsNothing);
    expect(_status, findsNothing);
    expect(_save, findsNothing);
    expect(_clear, findsNothing);
    expect(find.text('Custom vocabulary'), findsNothing);
    // Nothing is fetched for a section that is not shown.
    expect(client.fetchCalls, 0);
  });

  testWidgets('seeds the editor and status from the fetch', (tester) async {
    await _mount(
      tester,
      initial: const VocabularySettings(
        terms: <String>['Hermes', 'CachyOS'],
        text: 'Hermes, CachyOS',
        tokenEstimate: 3,
        overBudget: false,
      ),
    );
    expect(_editorText(tester), 'Hermes, CachyOS');
    // The SERVER's numbers while the field matches what it confirmed.
    expect(_statusText(tester), '2 terms · ~3 tokens');
    expect(_enabled(tester, _save), isFalse);
    expect(_enabled(tester, _clear), isTrue);
    expect(
      find.textContaining('One term per line or comma-separated'),
      findsOneWidget,
    );
  });

  testWidgets('typing updates vocab-status with the server rules',
      (tester) async {
    await _mount(tester);
    expect(_statusText(tester), '0 terms · ~0 tokens');
    expect(_enabled(tester, _clear), isFalse);

    // Commas AND newlines split; duplicates collapse case-insensitively.
    await tester.enterText(_editor, 'Hermes, CachyOS\nTangent\nhermes');
    await tester.pump();
    // "Hermes, CachyOS, Tangent" = 24 chars → 6 tokens.
    expect(_statusText(tester), '3 terms · ~6 tokens');
    expect(_enabled(tester, _save), isTrue);
    expect(_enabled(tester, _clear), isTrue);
  });

  testWidgets('over-budget message appears past 223 estimated tokens',
      (tester) async {
    await _mount(tester);
    // 100 distinct 9-char terms → "term-000, term-001, …" = 100*8 + 99*2
    // = 998 chars → 249 tokens > 223.
    final String text = List<String>.generate(
      100,
      (int i) => 'term-${i.toString().padLeft(3, '0')}',
    ).join('\n');
    await tester.enterText(_editor, text);
    await tester.pump();
    expect(
      _statusText(tester),
      '100 terms · ~249 tokens — over the 223-token budget; later terms '
      'will be ignored',
    );
    final Text status = tester.widget<Text>(_status);
    final BuildContext ctx = tester.element(_status);
    expect(status.style?.color, Theme.of(ctx).colorScheme.error);

    // Under budget again → plain form, no error colour.
    await tester.enterText(_editor, 'Hermes');
    await tester.pump();
    expect(_statusText(tester), '1 terms · ~1 tokens');
    expect(
      tester.widget<Text>(_status).style?.color,
      isNot(Theme.of(ctx).colorScheme.error),
    );
  });

  testWidgets(
      'Save is disabled until dirty, PUTs the raw text, adopts the canonical '
      'response', (tester) async {
    final _FakeClient client = await _mount(tester);
    expect(_enabled(tester, _save), isFalse);

    const String raw = 'b\n a,b';
    await tester.enterText(_editor, raw);
    await tester.pump();
    expect(_enabled(tester, _save), isTrue);
    expect(client.putCalls, isEmpty, reason: 'no autosave');

    await tester.tap(_save);
    await tester.pumpAndSettle();

    expect(client.putCalls, <String>[raw]);
    // The server's canonical text replaces what was typed…
    expect(_editorText(tester), 'b, a');
    expect(_statusText(tester), '2 terms · ~1 tokens');
    // …and the field is clean again.
    expect(_enabled(tester, _save), isFalse);
    expect(find.text('Vocabulary saved'), findsOneWidget);
  });

  testWidgets('Clear asks first; cancel PUTs nothing', (tester) async {
    final _FakeClient client = await _mount(
      tester,
      initial: _canonical('Hermes, Tangent'),
    );
    await tester.tap(_clear);
    await tester.pumpAndSettle();
    expect(find.text('Clear custom vocabulary?'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('vocab-clear-cancel')));
    await tester.pumpAndSettle();

    expect(client.putCalls, isEmpty);
    expect(_editorText(tester), 'Hermes, Tangent');
    expect(_statusText(tester), '2 terms · ~3 tokens');
  });

  testWidgets('Clear confirm PUTs blank text and empties the editor',
      (tester) async {
    final _FakeClient client = await _mount(
      tester,
      initial: _canonical('Hermes, Tangent'),
    );
    await tester.tap(_clear);
    await tester.pumpAndSettle();
    await tester
        .tap(find.byKey(const ValueKey<String>('vocab-clear-confirm')));
    await tester.pumpAndSettle();

    expect(client.putCalls, <String>['']);
    expect(_editorText(tester), '');
    expect(_statusText(tester), '0 terms · ~0 tokens');
    expect(_enabled(tester, _save), isFalse);
    expect(_enabled(tester, _clear), isFalse);
    expect(find.text('Vocabulary cleared'), findsOneWidget);
  });

  testWidgets('422 surfaces the server detail and keeps the text',
      (tester) async {
    final _FakeClient client = await _mount(
      tester,
      putError: const ApiException(
        statusCode: 422,
        code: 'http_error',
        message: 'vocabulary term too long',
      ),
    );
    final String tooLong = 'x' * 65;
    await tester.enterText(_editor, tooLong);
    await tester.pump();
    await tester.tap(_save);
    await tester.pumpAndSettle();

    expect(client.putCalls, <String>[tooLong]);
    expect(find.text('vocabulary term too long'), findsOneWidget);
    // Nothing was adopted: the user's text stays put and still needs saving.
    expect(_editorText(tester), tooLong);
    expect(_enabled(tester, _save), isTrue);
  });

  testWidgets('an unreachable server at init leaves an empty, usable editor',
      (tester) async {
    await _mount(tester, fetchError: StateError('down'));
    expect(_editor, findsOneWidget);
    expect(_editorText(tester), '');
    expect(_statusText(tester), '0 terms · ~0 tokens');
  });
}
