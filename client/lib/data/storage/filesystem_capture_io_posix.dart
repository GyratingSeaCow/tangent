// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';
import 'package:path/path.dart' as p;
import 'filesystem_capture_io.dart';
import 'storage_contract.dart';
import 'storage_codec.dart';

final class _Libc {
  static final dll = DynamicLibrary.open('libc.so.6');
  static final alloc = dll.lookupFunction<
      Pointer<Void> Function(IntPtr, IntPtr),
      Pointer<Void> Function(int, int)>('calloc');
  static final free = dll.lookupFunction<Void Function(Pointer<Void>),
      void Function(Pointer<Void>)>('free');
  static final openat = dll.lookupFunction<
      Int32 Function(Int32, Pointer<Uint8>, Int32, Uint32),
      int Function(int, Pointer<Uint8>, int, int)>('openat');
  static final close =
      dll.lookupFunction<Int32 Function(Int32), int Function(int)>('close');
  static final statx = dll.lookupFunction<
      Int32 Function(Int32, Pointer<Uint8>, Int32, Uint32, Pointer<Uint8>),
      int Function(int, Pointer<Uint8>, int, int, Pointer<Uint8>)>('statx');
  static final seek = dll.lookupFunction<Int64 Function(Int32, Int64, Int32),
      int Function(int, int, int)>('lseek');
  static final read = dll.lookupFunction<
      IntPtr Function(Int32, Pointer<Uint8>, IntPtr),
      int Function(int, Pointer<Uint8>, int)>('read');
  static final write = dll.lookupFunction<
      IntPtr Function(Int32, Pointer<Uint8>, IntPtr),
      int Function(int, Pointer<Uint8>, int)>('write');
  static final sync =
      dll.lookupFunction<Int32 Function(Int32), int Function(int)>('fsync');
  static final errno =
      dll.lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>(
    '__errno_location',
  );
  static Pointer<Uint8> memory(int size) {
    final data = alloc(size, 1).cast<Uint8>();
    if (data == nullptr) {
      captureIoFault(ProblemCode.io, 'Capture allocation failed');
    }
    return data;
  }

  static Pointer<Uint8> text(String text) {
    final bytes = utf8.encode(text);
    final data = memory(bytes.length + 1);
    data.asTypedList(bytes.length).setAll(0, bytes);
    return data;
  }

  static Never fail(String operation) {
    final e = errno().value;
    final code = switch (e) {
      2 => ProblemCode.absent,
      13 || 1 => ProblemCode.denied,
      17 || 20 || 40 => ProblemCode.conflict,
      38 || 95 => ProblemCode.unsupported,
      _ => ProblemCode.io
    };
    captureIoFault(code, 'Linux capture $operation failed ($e)');
  }

  static int open(
    int parent,
    String path,
    bool directory,
    bool writable,
    bool create,
  ) {
    final textPath = text(path);
    try {
      // O_NOFOLLOW on EVERY path component. Never O_TRUNC. O_NONBLOCK
      // lets statx reject FIFOs/devices without waiting for a peer opener.
      final fd = openat(
        parent,
        textPath,
        0x20000 |
            0x800 |
            0x80000 |
            (directory ? 0x10000 : 0) |
            (writable || create ? 2 : 0) |
            (create ? 0x40 | 0x80 : 0),
        384,
      );
      if (fd < 0) fail('openat');
      return fd;
    } finally {
      free(textPath.cast());
    }
  }
}

final class PosixCaptureHandle extends CaptureFileHandle {
  PosixCaptureHandle._(this.path, this.isDirectory, this._fd, this._parents);
  @override
  final String path;
  @override
  final bool isDirectory;
  final int _fd;
  final List<PosixCaptureHandle> _parents;
  bool _closed = false;
  static PosixCaptureHandle open(
    String path, {
    bool directory = false,
    bool writable = false,
    bool create = false,
  }) {
    if (Abi.current() != Abi.linuxX64) {
      captureIoFault(
        ProblemCode.unsupported,
        'Linux capture requires the verified x64 ABI',
      );
    }
    if (!p.posix.isAbsolute(path) ||
        path.contains('\u0000') ||
        path.split('/').any((s) => s == '.' || s == '..')) {
      captureIoFault(ProblemCode.invalid, 'Invalid Linux capture path');
    }
    final parts = path.split('/').where((s) => s.isNotEmpty).toList();
    final parents = <PosixCaptureHandle>[];
    var fd = -100;
    var current = '/';
    try {
      if (parts.isNotEmpty) {
        fd = _Libc.open(-100, '/', true, false, false);
        final root = PosixCaptureHandle._('/', true, fd, []);
        parents.add(root);
        root._stat();
      }
      for (var i = 0; i < parts.length - 1; i++) {
        fd = _Libc.open(fd, parts[i], true, false, false);
        current = p.posix.join(current, parts[i]);
        final parent = PosixCaptureHandle._(current, true, fd, []);
        parents.add(parent);
        parent._stat();
      }
      final result = PosixCaptureHandle._(
        path,
        directory,
        _Libc.open(
          fd,
          parts.isEmpty ? '/' : parts.last,
          directory,
          writable,
          create,
        ),
        parents,
      );
      try {
        result._stat();
        return result;
      } catch (_) {
        _Libc.close(result._fd);
        rethrow;
      }
    } catch (_) {
      for (final parent in parents.reversed) {
        parent.close();
      }
      rethrow;
    }
  }

  ByteData _stat() {
    if (_closed) throw StateError('Capture handle closed');
    final buffer = _Libc.memory(256);
    final empty = _Libc.text('');
    try {
      // Linux statx ABI: AT_EMPTY_PATH | AT_SYMLINK_NOFOLLOW, TYPE/INO/SIZE/BTIME.
      if (_Libc.statx(_fd, empty, 0x1000 | 0x100, 0xb01, buffer) != 0) {
        _Libc.fail('statx');
      }
      final value =
          ByteData.sublistView(Uint8List.fromList(buffer.asTypedList(256)));
      if ((value.getUint32(0, Endian.little) & 0x301) != 0x301) {
        captureIoFault(
          ProblemCode.unsupported,
          'Linux identity fields unavailable',
        );
      }
      final type = value.getUint16(28, Endian.little) & 0xf000;
      if (type != (isDirectory ? 0x4000 : 0x8000)) {
        captureIoFault(ProblemCode.conflict, 'Capture object is not regular');
      }
      return value;
    } finally {
      _Libc.free(buffer.cast());
      _Libc.free(empty.cast());
    }
  }

  @override
  CaptureObjectIdentity get identity {
    final stat = _stat();
    final inode = (BigInt.from(stat.getUint32(36, Endian.little)) << 32) |
        BigInt.from(stat.getUint32(32, Endian.little));
    final hasBirth = stat.getUint32(0, Endian.little) & 0x800 != 0;
    return (
      kind: 'posix-file',
      scope:
          '${stat.getUint32(136, Endian.little)}:${stat.getUint32(140, Endian.little)}',
      objectId: inode.toString(),
      generation: hasBirth
          ? '${stat.getInt64(80, Endian.little)}:${stat.getUint32(88, Endian.little).toString().padLeft(9, '0')}'
          : null
    );
  }

  @override
  int get size {
    if (isDirectory) {
      captureIoFault(ProblemCode.invalid, 'Directory has no capture content');
    }
    final size = _stat().getInt64(40, Endian.little);
    if (size < 0) {
      captureIoFault(ProblemCode.unsupported, 'Unsupported capture length');
    }
    return size;
  }

  @override
  Uint8List readBytes() {
    final expected = size;
    if (_Libc.seek(_fd, 0, 0) < 0) _Libc.fail('seek');
    final buffer = _Libc.memory(65536);
    final bytes = BytesBuilder(copy: true);
    try {
      while (true) {
        final count = _Libc.read(_fd, buffer, 65536);
        if (count < 0) _Libc.fail('read');
        if (count == 0) break;
        bytes.add(buffer.asTypedList(count));
        if (bytes.length > expected) {
          captureIoFault(
            ProblemCode.conflict,
            'Capture content changed during read',
          );
        }
      }
      if (bytes.length != expected || size != expected) {
        captureIoFault(ProblemCode.conflict, 'Capture content length changed');
      }
      return bytes.takeBytes();
    } finally {
      _Libc.free(buffer.cast());
    }
  }

  @override
  void initialize(CaptureObjectIdentity expected, Uint8List bytes) {
    if (identity != expected) {
      captureIoFault(ProblemCode.conflict, 'Capture handle identity mismatch');
    }
    verifyAssociation();
    if (size != 0 || bytes.isEmpty) {
      captureIoFault(
        ProblemCode.conflict,
        'Only owned empty capture files may be initialized',
      );
    }
    if (_Libc.seek(_fd, 0, 0) < 0) _Libc.fail('seek');
    final buffer = _Libc.memory(bytes.length);
    try {
      buffer.asTypedList(bytes.length).setAll(0, bytes);
      var offset = 0;
      while (offset < bytes.length) {
        final count = _Libc.write(_fd, buffer + offset, bytes.length - offset);
        if (count <= 0) _Libc.fail('write');
        offset += count;
      }
      if (_Libc.sync(_fd) != 0) _Libc.fail('fsync');
      if (identity != expected) {
        captureIoFault(
          ProblemCode.conflict,
          'Capture identity changed after initialization',
        );
      }
      verifyAssociation();
    } finally {
      _Libc.free(buffer.cast());
    }
  }

  @override
  CaptureFileHandle openChild(
    String name, {
    bool create = false,
    bool writable = false,
    void Function(String)? onCreated,
  }) {
    _stat();
    if (!isDirectory) {
      captureIoFault(ProblemCode.invalid, 'Capture parent is not a directory');
    }
    StorageCodec.validateLiteralId(name);
    verifyAssociation();
    final child = PosixCaptureHandle._(
      p.posix.join(path, name),
      false,
      _Libc.open(_fd, name, false, writable, create),
      [],
    );
    try {
      if (create) onCreated?.call(child.path);
      child._stat();
      verifyAssociation();
      child.verifyAssociation();
      return child;
    } catch (_) {
      child.close();
      rethrow;
    }
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _Libc.close(_fd);
    for (final parent in _parents.reversed) {
      parent.close();
    }
  }
}
