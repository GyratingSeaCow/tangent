// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Single-instance plumbing for desktop: a Unix socket in the runtime dir.
///
/// The first Tangent process binds the socket and listens for commands.
/// Any later invocation — most importantly `tangent --record` fired from a
/// KDE global shortcut — connects, writes one command line, and exits.
/// This is what turns a system keybinding into an in-app action without
/// ever spawning a second window.
class SingleInstanceServer {
  SingleInstanceServer._(this._server, this.path);

  final ServerSocket _server;

  /// Filesystem path of the bound socket (removed on [close]).
  final String path;

  final _commands = StreamController<String>.broadcast();

  /// One event per command line a client delivers (e.g. 'toggle-record').
  Stream<String> get commands => _commands.stream;

  /// Binds [path]. Returns null when a LIVE instance already owns it —
  /// the caller must forward its command and exit.
  ///
  /// A socket file whose owner died (crash, SIGKILL) is detected by a probe
  /// connect: connection refused means nobody is accepting, so the file is
  /// stale and gets replaced. Without this the app could never start again
  /// after a crash until the user deleted the file by hand.
  static Future<SingleInstanceServer?> bind(String path) async {
    final address = InternetAddress(path, type: InternetAddressType.unix);
    if (FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound) {
      try {
        final probe = await Socket.connect(address, 0)
            .timeout(const Duration(milliseconds: 500));
        // Somebody answered: a real instance is running.
        probe.destroy();
        return null;
      } catch (_) {
        // Nobody home — stale file from a dead process. Claim it.
        try {
          File(path).deleteSync();
        } catch (_) {
          // Deletion failing means we cannot bind either; fall through and
          // let bind() throw a real error instead of guessing.
        }
      }
    }
    final server = await ServerSocket.bind(address, 0);
    final owned = SingleInstanceServer._(server, path);
    server.listen(owned._onClient, onError: (_) {});
    return owned;
  }

  void _onClient(Socket client) {
    client
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
      (line) {
        final command = line.trim();
        if (command.isNotEmpty) _commands.add(command);
      },
      onError: (_) {},
      onDone: client.destroy,
    );
  }

  Future<void> close() async {
    await _server.close();
    await _commands.close();
    try {
      File(path).deleteSync();
    } catch (_) {
      // Already gone is fine; the socket being unbound is what matters.
    }
  }
}

/// Delivers one [command] to the instance owning [path].
///
/// True when the command was written to a live instance; false when nobody
/// is listening (caller should start the app normally instead). Never hangs:
/// the connect is timeboxed.
Future<bool> sendInstanceCommand(String path, String command) async {
  try {
    final socket = await Socket.connect(
      InternetAddress(path, type: InternetAddressType.unix),
      0,
    ).timeout(const Duration(seconds: 1));
    socket.add(utf8.encode('$command\n'));
    await socket.flush();
    socket.destroy();
    return true;
  } catch (_) {
    return false;
  }
}

/// Where the socket lives: the user's runtime dir when available (tmpfs,
/// per-session, correct permissions), falling back to the system temp dir.
String defaultInstanceSocketPath() {
  final runtime = Platform.environment['XDG_RUNTIME_DIR'];
  final base = (runtime != null && runtime.isNotEmpty)
      ? runtime
      : Directory.systemTemp.path;
  return '$base/tangent.sock';
}
