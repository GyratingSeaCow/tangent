// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../support/resolved_temp.dart';
import '../../support/storage_fixture.dart';

void main() {
  test(
    'deleteTempTree waits out a file handle that is still closing',
    () async {
      // Reproduces the tag-build failure on windows-2022: drift's isolate
      // still held fixture.sqlite when the fixture deleted its root, so
      // NTFS refused (errno 32) and the test timed out. Hold a handle open
      // for a moment ourselves and require the delete to outlast it.
      final root = resolvedSystemTemp().createTempSync('tangent-temp-tree');
      final file = File('${root.path}${Platform.pathSeparator}held.bin');
      final raf = await file.open(mode: FileMode.write);
      await raf.writeString('x');

      // Release the handle 150 ms from now, i.e. after several retries.
      final release = Future<void>.delayed(
        const Duration(milliseconds: 150),
        () async => raf.close(),
      );

      await deleteTempTree(root);
      await release;
      expect(root.existsSync(), isFalse);
    },
    // Only NTFS enforces the sharing violation; on POSIX an open file
    // unlinks fine and this proves nothing.
    skip: !Platform.isWindows,
  );

  test(
    'deleteTempTree gives up loudly on a handle that never closes',
    () async {
      final root =
          resolvedSystemTemp().createTempSync('tangent-temp-tree-stuck');
      final file = File('${root.path}${Platform.pathSeparator}held.bin');
      final raf = await file.open(mode: FileMode.write);
      addTearDown(() async {
        await raf.close();
        if (root.existsSync()) root.deleteSync(recursive: true);
      });

      await expectLater(
        deleteTempTree(root),
        throwsA(isA<FileSystemException>()),
      );
    },
    skip: !Platform.isWindows,
  );
}
