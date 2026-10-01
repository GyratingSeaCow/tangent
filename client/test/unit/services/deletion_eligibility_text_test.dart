// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/services/deletion_eligibility_text.dart';

void main() {
  test('every eligibility (and loading) has distinct, non-empty wording', () {
    final List<String> texts = <String>[
      for (final Eligibility e in Eligibility.values) eligibilityReason(e),
      eligibilityReason(null),
    ];
    expect(texts.every((String t) => t.trim().isNotEmpty), isTrue);
    expect(texts.toSet(), hasLength(texts.length));
  });

  test('the reasons the Ask sheet and Recordings list show are pinned', () {
    expect(eligibilityReason(Eligibility.nonterminal),
        'Transcription in progress',);
    expect(eligibilityReason(Eligibility.busy), 'Recording is in use');
    expect(eligibilityReason(Eligibility.missing), 'Recording unavailable');
    expect(eligibilityReason(null), 'Checking availability');
  });
}
