// SPDX-License-Identifier: AGPL-3.0-or-later
/// Password hashing and process-local notebook unlock state.
library;

import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// PBKDF2-HMAC-SHA256 work factor for newly protected notebooks.
///
/// The iteration count is stored beside each hash, so it can be raised later
/// without making existing notebooks unreadable.
const int notebookPasswordIterations = 210000;
const int notebookPasswordMinIterations = 100000;
const int notebookPasswordMaxIterations = 1000000;
const int _saltLength = 16;
const int _derivedKeyLength = 32;

class NotebookPasswordMetadata {
  const NotebookPasswordMetadata({
    required this.hash,
    required this.salt,
    required this.iterations,
  });

  /// Base64-encoded 256-bit derived key. Never a plaintext password.
  final String hash;

  /// Base64-encoded per-notebook random salt.
  final String salt;
  final int iterations;
}

/// Hashes [password] using a fresh cryptographically secure random salt.
Future<NotebookPasswordMetadata> hashNotebookPassword(
  String password, {
  Random? random,
  int iterations = notebookPasswordIterations,
}) async {
  if (password.isEmpty) {
    throw const FormatException('Password must not be empty');
  }
  if (iterations < notebookPasswordMinIterations ||
      iterations > notebookPasswordMaxIterations) {
    throw const FormatException('PBKDF2 iteration count is out of range');
  }
  final Random source = random ?? Random.secure();
  final Uint8List salt = Uint8List.fromList(
    List<int>.generate(_saltLength, (_) => source.nextInt(256)),
  );
  final Uint8List key = await Isolate.run(
    () => _pbkdf2Sha256(utf8.encode(password), salt, iterations),
  );
  return NotebookPasswordMetadata(
    hash: base64Encode(key),
    salt: base64Encode(salt),
    iterations: iterations,
  );
}

/// Verifies [password] without short-circuiting on the first different byte.
Future<bool> verifyNotebookPassword({
  required String password,
  required String hash,
  required String salt,
  required int iterations,
}) async {
  // Check the work factor before decoding or entering the isolate. Synced and
  // durable metadata are untrusted; without an upper bound a hostile verifier
  // can turn one password attempt into effectively unbounded CPU work.
  if (password.isEmpty ||
      iterations < notebookPasswordMinIterations ||
      iterations > notebookPasswordMaxIterations) {
    return false;
  }
  late final Uint8List expected;
  late final Uint8List decodedSalt;
  try {
    expected = base64Decode(hash);
    decodedSalt = base64Decode(salt);
  } on FormatException {
    return false;
  }
  if (expected.length != _derivedKeyLength ||
      decodedSalt.length < _saltLength) {
    return false;
  }
  final Uint8List actual = await Isolate.run(
    () => _pbkdf2Sha256(utf8.encode(password), decodedSalt, iterations),
  );
  var difference = expected.length ^ actual.length;
  for (var i = 0; i < expected.length && i < actual.length; i++) {
    difference |= expected[i] ^ actual[i];
  }
  return difference == 0;
}

Uint8List _pbkdf2Sha256(List<int> password, List<int> salt, int iterations) {
  final Hmac hmac = Hmac(sha256, password);
  final Uint8List firstInput = Uint8List(salt.length + 4)
    ..setRange(0, salt.length, salt)
    ..setRange(salt.length, salt.length + 4, const <int>[0, 0, 0, 1]);
  var u = Uint8List.fromList(hmac.convert(firstInput).bytes);
  final Uint8List result = Uint8List.fromList(u);
  for (var round = 1; round < iterations; round++) {
    u = Uint8List.fromList(hmac.convert(u).bytes);
    for (var i = 0; i < result.length; i++) {
      result[i] ^= u[i];
    }
  }
  return result;
}

/// Unlocks last only for the current process and exact password hash.
///
/// Binding an unlock to the hash means a password changed by sync immediately
/// invalidates the old session instead of leaving the notebook open under stale
/// credentials.
class NotebookUnlockRegistry {
  final Map<String, String> _unlockedHashes = <String, String>{};

  bool isUnlocked(String notebookId, String? passwordHash) =>
      passwordHash != null && _unlockedHashes[notebookId] == passwordHash;

  void unlock(String notebookId, String passwordHash) {
    _unlockedHashes[notebookId] = passwordHash;
  }

  void lock(String notebookId) => _unlockedHashes.remove(notebookId);
}

final notebookUnlockRegistryProvider = Provider<NotebookUnlockRegistry>(
  (ref) => NotebookUnlockRegistry(),
);
