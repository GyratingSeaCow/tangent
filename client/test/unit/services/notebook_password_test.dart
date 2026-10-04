// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/services/notebook_password.dart';

void main() {
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
