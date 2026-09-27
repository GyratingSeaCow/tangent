// SPDX-License-Identifier: AGPL-3.0-or-later
/// v1.19.0 Part A (T2=y): the LanguageTag chip — 'ES' for an original-
/// language transcript, 'ES → EN' once translated, nothing for English or
/// unknown.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/widgets/language_tag.dart';

DumpRow _row(String id, {String? language, bool? translated}) => DumpRow(
      id: id,
      createdAt: DateTime.utc(2026, 9, 27),
      updatedAt: DateTime.utc(2026, 9, 27),
      mode: 'brain_dump',
      durationSeconds: 4,
      title: 'Nota',
      audioPath: '/audio/$id.opus',
      audioSizeBytes: 3,
      syncStatus: 'synced',
      syncAttempts: 0,
      transcriptionStatus: 'completed',
      transcriptionAttempt: 1,
      transcript: 'hola',
      language: language,
      translated: translated,
    );

void main() {
  Future<void> mount(WidgetTester tester, DumpRow row) => tester.pumpWidget(
        MaterialApp(home: Scaffold(body: Center(child: LanguageTag(row)))),
      );

  test('labelFor: the pure rule', () {
    expect(LanguageTag.labelFor(_row('a')), isNull);
    expect(LanguageTag.labelFor(_row('a', language: 'en')), isNull);
    expect(
      LanguageTag.labelFor(_row('a', language: 'en', translated: true)),
      isNull,
    );
    expect(LanguageTag.labelFor(_row('a', language: 'es')), 'ES');
    expect(
      LanguageTag.labelFor(_row('a', language: 'es', translated: false)),
      'ES',
    );
    expect(
      LanguageTag.labelFor(_row('a', language: 'es', translated: true)),
      'ES → EN',
    );
    expect(
      LanguageTag.labelFor(_row('a', language: 'ja', translated: true)),
      'JA → EN',
    );
  });

  testWidgets('renders nothing for null / English language', (tester) async {
    await mount(tester, _row('t-1'));
    expect(find.byKey(const ValueKey<String>('language-tag-t-1')), findsNothing);
    await mount(tester, _row('t-2', language: 'en'));
    expect(find.byKey(const ValueKey<String>('language-tag-t-2')), findsNothing);
  });

  testWidgets('ES for an original Spanish transcript', (tester) async {
    await mount(tester, _row('t-3', language: 'es', translated: false));
    final Finder tag = find.byKey(const ValueKey<String>('language-tag-t-3'));
    expect(tag, findsOneWidget);
    expect(find.descendant(of: tag, matching: find.text('ES')), findsOneWidget);
    expect(find.textContaining('EN'), findsNothing);
  });

  testWidgets('ES → EN once translated', (tester) async {
    await mount(tester, _row('t-4', language: 'es', translated: true));
    final Finder tag = find.byKey(const ValueKey<String>('language-tag-t-4'));
    expect(tag, findsOneWidget);
    expect(
      find.descendant(of: tag, matching: find.text('ES → EN')),
      findsOneWidget,
    );
  });
}
