// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/services/notebook_password.dart';

void main() {
  test('PBKDF2 work factors above the maximum are rejected before derivation',
      () async {
    await expectLater(
      hashNotebookPassword(
        'password',
        iterations: notebookPasswordMaxIterations + 1,
      ),
      throwsFormatException,
    );

    final bool accepted = await verifyNotebookPassword(
      password: 'password',
      hash: base64Encode(List<int>.filled(32, 0)),
      salt: base64Encode(List<int>.filled(16, 0)),
      iterations: notebookPasswordMaxIterations + 1,
    ).timeout(const Duration(milliseconds: 250));
    expect(accepted, isFalse);
  });

  test(
    'unlock registry is process-local and bound to the current verifier',
    () {
      final NotebookUnlockRegistry registry = NotebookUnlockRegistry();

      expect(registry.isUnlocked('n1', 'hash-a'), isFalse);
      registry.unlock('n1', 'hash-a');
      expect(registry.isUnlocked('n1', 'hash-a'), isTrue);
      expect(
        registry.isUnlocked('n1', 'hash-b'),
        isFalse,
        reason: 'a password change invalidates the old process-local unlock',
      );
      expect(registry.isUnlocked('n2', 'hash-a'), isFalse);

      registry.lock('n1');
      expect(registry.isUnlocked('n1', 'hash-a'), isFalse);
    },
  );
}
