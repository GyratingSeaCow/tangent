// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import '../data/storage/storage_contract.dart';

/// Adapts an actual transport Future, not a timeout wrapper, to shared ownership.
/// Construct inside RecordingMutationCoordinator.runIo so admission is retained
/// before invoking the transport. A caller's timeout never settles this object.
final class RetainedFutureIo<T> implements IoOperation<T> {
  RetainedFutureIo(this.id, Future<T> Function() start) {
    result = _run(start);
  }
  @override
  final String id;
  @override
  late final Future<T> result;
  final _done = Completer<void>();
  @override
  Future<void> get settled => _done.future;

  Future<T> _run(Future<T> Function() start) async {
    try {
      return await start();
    } finally {
      _done.complete();
    }
  }
}
