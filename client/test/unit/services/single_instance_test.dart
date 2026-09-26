// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/services/single_instance.dart';
import '../../support/resolved_temp.dart';

/// Desktop hotkey plumbing: one Tangent instance owns a Unix socket; later
/// invocations (`tangent --record` from a KDE global shortcut) deliver a
/// command to it and exit instead of starting a second app.
void main() {
  late Directory dir;
  late String sock;

  setUp(() async {
    dir = await createResolvedTemp('tangent-sock-test-');
    sock = '${dir.path}/tangent.sock';
  });

  tearDown(() async {
    await dir.delete(recursive: true);
  });

  test('first instance binds and receives a forwarded command', () async {
    final server = await SingleInstanceServer.bind(sock);
    expect(server, isNotNull);
    final received = <String>[];
    server!.commands.listen(received.add);

    final delivered = await sendInstanceCommand(sock, 'toggle-record');
    expect(delivered, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(received, ['toggle-record']);

    await server.close();
  });

  test('second bind on a live socket yields null (instance exists)', () async {
    final first = await SingleInstanceServer.bind(sock);
    final second = await SingleInstanceServer.bind(sock);
    expect(
      second,
      isNull,
      reason: 'a live owner means this process must forward, not serve',
    );
    await first!.close();
  });

  test('a stale socket file from a crashed instance is taken over', () async {
    // Crash leaves the file behind with nobody accepting. bind() must
    // detect the dead owner and claim it, or the app can never start
    // again until the user manually deletes the file.
    File(sock).writeAsStringSync('');
    final server = await SingleInstanceServer.bind(sock);
    expect(server, isNotNull);
    await server!.close();
  });

  test('sendInstanceCommand to nobody reports failure, not a hang', () async {
    final delivered = await sendInstanceCommand(sock, 'toggle-record')
        .timeout(const Duration(seconds: 2));
    expect(delivered, isFalse);
  });

  test('close removes the socket file', () async {
    final server = await SingleInstanceServer.bind(sock);
    await server!.close();
    expect(File(sock).existsSync(), isFalse);
  });
}
