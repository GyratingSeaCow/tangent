// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// What the global create sheet can ask for.
///
/// The voice/text kinds are not performed where the sheet was opened — they
/// are delivered to the Capture screen, which already owns the recording
/// state machine and the compose entry point. Mirrors the pop-result
/// contract the Recordings-list FAB has always used, generalized so any
/// screen can raise it.
enum CreateRequest { recording, meeting, textNote, notebook, todo }

/// A broadcast funnel for [CreateRequest]s.
///
/// Same shape as the instance-command spine: the Capture screen subscribes
/// once and every trigger (global FAB, Recordings-list create flow)
/// collapses into the one handler, so the paths can never diverge.
class CreateRequests {
  final StreamController<CreateRequest> _controller =
      StreamController<CreateRequest>.broadcast();

  Stream<CreateRequest> get stream => _controller.stream;

  void send(CreateRequest request) {
    if (!_controller.isClosed) _controller.add(request);
  }

  void dispose() {
    _controller.close();
  }
}

final createRequestsProvider = Provider<CreateRequests>((ref) {
  final CreateRequests requests = CreateRequests();
  ref.onDispose(requests.dispose);
  return requests;
});
