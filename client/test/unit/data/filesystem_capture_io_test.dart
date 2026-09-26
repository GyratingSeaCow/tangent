// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tangent/data/storage/filesystem_capture_io.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/data/storage/capture_publication_codec.dart';
import '../../support/resolved_temp.dart';

Future<void> _unblockFixtureFifo((String, SendPort) args) async {
  args.$2.send(null);
  await Future<void>.delayed(const Duration(seconds: 2));
  final writer = File(args.$1).openSync(mode: FileMode.append);
  writer.closeSync();
}

void main() {
  late Directory root;
  setUp(() {
    root = createResolvedTempSync('tangent-capture-identity-');
  });
  tearDown(() {
    root.deleteSync(recursive: true);
  });
  if (Platform.isLinux) {
    test('nonregular FIFO is rejected without waiting for another opener',
        () async {
      final path = p.join(root.path, 'fixture-fifo');
      expect(Process.runSync('mkfifo', [path]).exitCode, 0);
      final ready = ReceivePort();
      final writer =
          await Isolate.spawn(_unblockFixtureFifo, (path, ready.sendPort));
      try {
        await ready.first;
        final elapsed = Stopwatch()..start();
        expect(() => openCaptureHandle(path), throwsA(isA<StorageFault>()));
        expect(elapsed.elapsed, lessThan(const Duration(seconds: 1)));
      } finally {
        writer.kill(priority: Isolate.immediate);
        ready.close();
      }
    });
  }
  if (Platform.isWindows) {
    test(
        'Windows ambiguous names and alternate streams are rejected before create',
        () {
      final directory = openCaptureHandle(root.path, directory: true);
      try {
        for (final name in ['fixture:stream', 'fixture.', 'fixture ']) {
          CaptureFileHandle? opened;
          try {
            expect(
              () {
                opened =
                    directory.openChild(name, create: true, writable: true);
              },
              throwsA(isA<StorageFault>()),
            );
          } finally {
            opened?.close();
          }
        }
        expect(Directory(root.path).listSync(), isEmpty);
      } finally {
        directory.close();
      }
    });
  }
  test(
      'real platform exclusive create and native identity survive close reopen',
      () {
    final directory = openCaptureHandle(root.path, directory: true);
    try {
      final target =
          directory.openChild('fixture.opus', create: true, writable: true);
      final identity = target.identity;
      expect(identity.kind, Platform.isWindows ? 'windows-file' : 'posix-file');
      expect(
        CapturePublicationCodec.decodeIdentity(
          CapturePublicationCodec.encodeIdentity(identity),
        ),
        identity,
      );
      expect(target.size, 0);
      target.close();
      final reopened = directory.openChild('fixture.opus');
      try {
        expect(reopened.identity, identity);
      } finally {
        reopened.close();
      }
      expect(
        () => directory.openChild('fixture.opus', create: true),
        throwsA(isA<StorageFault>()),
      );
      expect(File(p.join(root.path, 'fixture.opus')).lengthSync(), 0);
    } finally {
      directory.close();
    }
  });
  test('real handle initializes empty target and refuses nonempty overwrite',
      () {
    final target = openCaptureHandle(
      p.join(root.path, 'fixture.opus'),
      create: true,
      writable: true,
    );
    try {
      final identity = target.identity;
      target.initialize(identity, Uint8List.fromList([1, 2, 3]));
      expect(target.readBytes(), [1, 2, 3]);
      expect(target.identity, identity);
      expect(
        () => target.initialize(identity, Uint8List.fromList([9])),
        throwsA(isA<StorageFault>()),
      );
      expect(target.readBytes(), [1, 2, 3]);
    } finally {
      target.close();
    }
  });
  test('real replacement with equal bytes cannot satisfy old identity', () {
    final path = p.join(root.path, 'fixture.opus');
    final first = openCaptureHandle(path, create: true, writable: true);
    final old = first.identity;
    first.initialize(old, Uint8List.fromList([1, 2, 3]));
    first.close();
    File(path).renameSync('$path.old');
    File(path).writeAsBytesSync([1, 2, 3]);
    final replacement = openCaptureHandle(path, writable: true);
    try {
      expect(replacement.identity, isNot(old));
      expect(
        () => replacement.initialize(old, Uint8List.fromList([9])),
        throwsA(isA<StorageFault>()),
      );
      expect(replacement.readBytes(), [1, 2, 3]);
    } finally {
      replacement.close();
    }
  });
  test(
      'real directory and component links are rejected without touching target',
      () {
    final target = File(p.join(root.path, 'fixture-target'))
      ..writeAsBytesSync([7, 8]);
    final link = Link(p.join(root.path, 'fixture-link'))
      ..createSync(target.path);
    expect(
      () => openCaptureHandle(link.path, writable: true),
      throwsA(isA<StorageFault>()),
    );
    final dir = Directory(p.join(root.path, 'fixture-dir'))..createSync();
    File(p.join(dir.path, 'fixture.opus')).writeAsBytesSync([3]);
    final dirLink = Link(p.join(root.path, 'fixture-dir-link'))
      ..createSync(dir.path);
    expect(
      () => openCaptureHandle(p.join(dirLink.path, 'fixture.opus')),
      throwsA(isA<StorageFault>()),
    );
    expect(target.readAsBytesSync(), [7, 8]);
  });
  test('opened root replacement is rejected or prevented by native handle', () {
    final directoryPath = p.join(root.path, 'fixture-root');
    Directory(directoryPath).createSync();
    final handle = openCaptureHandle(directoryPath, directory: true);
    try {
      if (Platform.isWindows) {
        expect(
          () => Directory(directoryPath).renameSync('$directoryPath.old'),
          throwsA(isA<FileSystemException>()),
        );
        handle.verifyAssociation();
      } else {
        Directory(directoryPath).renameSync('$directoryPath.old');
        Directory(directoryPath).createSync();
        expect(
          () => handle.openChild('fixture.opus', create: true),
          throwsA(isA<StorageFault>()),
        );
        expect(
          File(p.join(directoryPath, 'fixture.opus')).existsSync(),
          isFalse,
        );
        expect(
          File(p.join('$directoryPath.old', 'fixture.opus')).existsSync(),
          isFalse,
        );
      }
    } finally {
      handle.close();
    }
  });
}
