// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:ffi';
import 'dart:typed_data';
import 'package:path/path.dart' as p;
import 'filesystem_capture_io.dart';
import 'storage_contract.dart';
import 'storage_codec.dart';

final class _Win {
  static final dll = DynamicLibrary.open('kernel32.dll');
  static final crt = DynamicLibrary.open('msvcrt.dll');
  static final alloc = crt.lookupFunction<
      Pointer<Void> Function(IntPtr, IntPtr),
      Pointer<Void> Function(int, int)>('calloc');
  static final free = crt.lookupFunction<Void Function(Pointer<Void>),
      void Function(Pointer<Void>)>('free');
  static final create = dll.lookupFunction<
      Pointer<Void> Function(
        Pointer<Uint16>,
        Uint32,
        Uint32,
        Pointer<Void>,
        Uint32,
        Uint32,
        Pointer<Void>,
      ),
      Pointer<Void> Function(
        Pointer<Uint16>,
        int,
        int,
        Pointer<Void>,
        int,
        int,
        Pointer<Void>,
      )>('CreateFileW');
  static final close = dll.lookupFunction<Int32 Function(Pointer<Void>),
      int Function(Pointer<Void>)>('CloseHandle');
  static final info = dll.lookupFunction<
      Int32 Function(Pointer<Void>, Int32, Pointer<Void>, Uint32),
      int Function(
        Pointer<Void>,
        int,
        Pointer<Void>,
        int,
      )>('GetFileInformationByHandleEx');
  static final time = dll.lookupFunction<
      Int32 Function(
        Pointer<Void>,
        Pointer<Void>,
        Pointer<Void>,
        Pointer<Void>,
      ),
      int Function(
        Pointer<Void>,
        Pointer<Void>,
        Pointer<Void>,
        Pointer<Void>,
      )>('GetFileTime');
  static final length = dll.lookupFunction<
      Int32 Function(Pointer<Void>, Pointer<Int64>),
      int Function(Pointer<Void>, Pointer<Int64>)>('GetFileSizeEx');
  static final seek = dll.lookupFunction<
      Int32 Function(Pointer<Void>, Int64, Pointer<Int64>, Uint32),
      int Function(
        Pointer<Void>,
        int,
        Pointer<Int64>,
        int,
      )>('SetFilePointerEx');
  static final read = dll.lookupFunction<
      Int32 Function(
        Pointer<Void>,
        Pointer<Void>,
        Uint32,
        Pointer<Uint32>,
        Pointer<Void>,
      ),
      int Function(
        Pointer<Void>,
        Pointer<Void>,
        int,
        Pointer<Uint32>,
        Pointer<Void>,
      )>('ReadFile');
  static final write = dll.lookupFunction<
      Int32 Function(
        Pointer<Void>,
        Pointer<Void>,
        Uint32,
        Pointer<Uint32>,
        Pointer<Void>,
      ),
      int Function(
        Pointer<Void>,
        Pointer<Void>,
        int,
        Pointer<Uint32>,
        Pointer<Void>,
      )>('WriteFile');
  static final flush = dll.lookupFunction<Int32 Function(Pointer<Void>),
      int Function(Pointer<Void>)>('FlushFileBuffers');
  static final error =
      dll.lookupFunction<Uint32 Function(), int Function()>('GetLastError');
  static Pointer<Uint8> memory(int length) {
    final result = alloc(length, 1).cast<Uint8>();
    if (result == nullptr) {
      captureIoFault(ProblemCode.io, 'Capture allocation failed');
    }
    return result;
  }

  static Never fail(String operation, [int? capturedError]) {
    final e = capturedError ?? error();
    final code = switch (e) {
      2 || 3 => ProblemCode.absent,
      5 => ProblemCode.denied,
      80 || 183 || 32 => ProblemCode.conflict,
      1 || 50 || 87 => ProblemCode.unsupported,
      _ => ProblemCode.io
    };
    captureIoFault(code, 'Windows capture $operation failed ($e)');
  }

  static String u64(ByteData data, int offset) =>
      ((BigInt.from(data.getUint32(offset + 4, Endian.little)) << 32) |
              BigInt.from(data.getUint32(offset, Endian.little)))
          .toString();
}

final class WindowsCaptureHandle extends CaptureFileHandle {
  WindowsCaptureHandle._(
    this.path,
    this.isDirectory,
    this._handle,
    this._ownedParents,
  );
  @override
  final String path;
  @override
  final bool isDirectory;
  final Pointer<Void> _handle;
  final List<WindowsCaptureHandle> _ownedParents;
  bool _closed = false;

  static WindowsCaptureHandle open(
    String path, {
    bool directory = false,
    bool writable = false,
    bool create = false,
    void Function(String)? onCreated,
  }) {
    if (Abi.current() != Abi.windowsX64) {
      captureIoFault(
        ProblemCode.unsupported,
        'Windows capture requires the verified x64 ABI',
      );
    }
    if (!p.windows.isAbsolute(path) ||
        path.contains('\u0000') ||
        p.windows.split(path).any((s) => s == '.' || s == '..') ||
        path.startsWith(r'\\?\') ||
        path.startsWith(r'\\.\')) {
      captureIoFault(
        ProblemCode.invalid,
        'Invalid native Windows capture path',
      );
    }
    final root = p.windows.rootPrefix(path);
    final pieces = p.windows.split(path).skip(1).toList();
    final parents = <WindowsCaptureHandle>[];
    var current = root;
    try {
      if (pieces.isNotEmpty) {
        parents.add(_openOne(root, true, false, false, []));
      }
      for (var i = 0; i < pieces.length - 1; i++) {
        current = p.windows.join(current, pieces[i]);
        parents.add(_openOne(current, true, false, false, []));
      }
      return _openOne(path, directory, writable, create, parents, onCreated);
    } catch (_) {
      for (final parent in parents.reversed) {
        parent.close();
      }
      rethrow;
    }
  }

  static WindowsCaptureHandle _openOne(
    String path,
    bool directory,
    bool writable,
    bool create,
    List<WindowsCaptureHandle> parents, [
    void Function(String)? onCreated,
  ]) {
    if (create && directory) {
      captureIoFault(ProblemCode.invalid, 'Capture cannot create directories');
    }
    final text = _Win.memory((path.length + 1) * 2).cast<Uint16>();
    text.asTypedList(path.length + 1).setAll(0, path.codeUnits);
    Pointer<Void> handle;
    var openError = 0;
    try {
      // Share reads/writes, never deletion: held ancestors cannot be replaced.
      // OPEN_REPARSE_POINT is checked on every ancestor and final handle.
      handle = _Win.create(
        text,
        writable || create ? 0xc0000000 : 0x80000000,
        3,
        nullptr,
        create ? 1 : 3,
        0x00200000 | 0x02000000,
        nullptr,
      );
      openError = _Win.error();
    } finally {
      _Win.free(text.cast());
    }
    if (handle.address == -1 || handle.address == 0xffffffffffffffff) {
      _Win.fail('open', openError);
    }
    final result = WindowsCaptureHandle._(path, directory, handle, parents);
    try {
      if (create) onCreated?.call(path);
      result._regular();
      result.identity;
      return result;
    } catch (_) {
      _Win.close(handle);
      rethrow;
    }
  }

  void _live() {
    if (_closed) throw StateError('Capture handle closed');
  }

  void _regular() {
    _live();
    final data = _Win.memory(8);
    try {
      if (_Win.info(_handle, 9, data.cast(), 8) == 0) _Win.fail('attributes');
      final attributes = data.cast<Uint32>().value;
      if ((attributes & 0x400) != 0 ||
          ((attributes & 0x10) != 0) != isDirectory) {
        captureIoFault(
          ProblemCode.conflict,
          'Capture object is a reparse point or wrong type',
        );
      }
    } finally {
      _Win.free(data.cast());
    }
  }

  @override
  CaptureObjectIdentity get identity {
    _regular();
    final data = _Win.memory(24);
    final birth = _Win.memory(8);
    try {
      if (_Win.info(_handle, 18, data.cast(), 24) == 0) _Win.fail('FileIdInfo');
      final bytes = data.asTypedList(24);
      final view = ByteData.sublistView(bytes);
      final serial =
          BigInt.parse(_Win.u64(view, 0)).toRadixString(16).padLeft(16, '0');
      final id =
          bytes.skip(8).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      final hasBirth = _Win.time(_handle, birth.cast(), nullptr, nullptr) != 0;
      return (
        kind: 'windows-file',
        scope: serial,
        objectId: id,
        generation: hasBirth
            ? _Win.u64(ByteData.sublistView(birth.asTypedList(8)), 0)
            : null
      );
    } finally {
      _Win.free(data.cast());
      _Win.free(birth.cast());
    }
  }

  @override
  int get size {
    _regular();
    if (isDirectory) {
      captureIoFault(ProblemCode.invalid, 'Directory has no capture content');
    }
    final length = _Win.memory(8).cast<Int64>();
    try {
      if (_Win.length(_handle, length) == 0) _Win.fail('size');
      if (length.value < 0) {
        captureIoFault(ProblemCode.unsupported, 'Unsupported capture length');
      }
      return length.value;
    } finally {
      _Win.free(length.cast());
    }
  }

  @override
  Uint8List readBytes() {
    final expected = size;
    if (_Win.seek(_handle, 0, nullptr, 0) == 0) _Win.fail('seek');
    final buffer = _Win.memory(65536);
    final count = _Win.memory(4).cast<Uint32>();
    final bytes = BytesBuilder(copy: true);
    try {
      while (true) {
        if (_Win.read(_handle, buffer.cast(), 65536, count, nullptr) == 0) {
          _Win.fail('read');
        }
        if (count.value == 0) break;
        bytes.add(buffer.asTypedList(count.value));
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
      _Win.free(buffer.cast());
      _Win.free(count.cast());
    }
  }

  @override
  void initialize(CaptureObjectIdentity expected, Uint8List bytes) {
    _regular();
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
    if (_Win.seek(_handle, 0, nullptr, 0) == 0) _Win.fail('seek');
    final buffer = _Win.memory(bytes.length);
    final count = _Win.memory(4).cast<Uint32>();
    try {
      buffer.asTypedList(bytes.length).setAll(0, bytes);
      var offset = 0;
      while (offset < bytes.length) {
        final length =
            bytes.length - offset > 65536 ? 65536 : bytes.length - offset;
        if (_Win.write(
                  _handle,
                  (buffer + offset).cast(),
                  length,
                  count,
                  nullptr,
                ) ==
                0 ||
            count.value == 0) {
          _Win.fail('write');
        }
        offset += count.value;
      }
      if (_Win.flush(_handle) == 0) _Win.fail('flush');
      if (identity != expected) {
        captureIoFault(
          ProblemCode.conflict,
          'Capture identity changed after initialization',
        );
      }
      verifyAssociation();
    } finally {
      _Win.free(buffer.cast());
      _Win.free(count.cast());
    }
  }

  @override
  CaptureFileHandle openChild(
    String name, {
    bool create = false,
    bool writable = false,
    void Function(String)? onCreated,
  }) {
    _regular();
    if (!isDirectory) {
      captureIoFault(ProblemCode.invalid, 'Capture parent is not a directory');
    }
    StorageCodec.validateLiteralId(name);
    verifyAssociation();
    if (name.contains(':') || name.endsWith('.') || name.endsWith(' ')) {
      captureIoFault(ProblemCode.invalid, 'Ambiguous Windows component name');
    }
    final child = open(
      p.windows.join(path, name),
      create: create,
      writable: writable,
      onCreated: onCreated,
    );
    try {
      verifyAssociation();
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
    _Win.close(_handle);
    for (final parent in _ownedParents.reversed) {
      parent.close();
    }
  }
}
