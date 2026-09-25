// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Single-instance plumbing for desktop.
///
/// The first Tangent process becomes the owner and listens for commands.
/// Any later invocation — `tangent --record` from a KDE global shortcut,
/// a second double-click on the exe — connects, writes one command line,
/// and exits. This is what turns a system keybinding into an in-app
/// action without ever spawning a second window.
///
/// Transport differs by platform behind one API:
///  * Linux: a Unix socket in the runtime dir (as always);
///  * Windows: a loopback TCP socket whose port is written to a
///    port file — Dart's Unix-socket support on Windows is exactly what
///    the four standing single_instance test failures were, and named
///    pipes need FFI. The port file carries the rendezvous.
class SingleInstanceServer {
  SingleInstanceServer._(this._server, this.path);

  final ServerSocket _server;

  /// Rendezvous path: the socket file on Linux, the PORT file on Windows
  /// (removed on [close]).
  final String path;

  final _commands = StreamController<String>.broadcast();

  /// One event per command line a client delivers (e.g. 'toggle-record').
  Stream<String> get commands => _commands.stream;

  /// Claims ownership of [path]. Returns null when a LIVE instance already
  /// owns it — the caller must forward its command and exit.
  ///
  /// A rendezvous file whose owner died (crash, SIGKILL) is detected by a
  /// probe connect: connection refused means nobody is accepting, so the
  /// file is stale and gets replaced. Without this the app could never
  /// start again after a crash until the user deleted the file by hand.
  static Future<SingleInstanceServer?> bind(String path) =>
      Platform.isWindows ? _bindTcp(path) : _bindUnix(path);

  static Future<SingleInstanceServer?> _bindUnix(String path) async {
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

  static Future<SingleInstanceServer?> _bindTcp(String portFilePath) async {
    final port = _readPortFile(portFilePath);
    if (port != null) {
      try {
        final probe = await Socket.connect(
          InternetAddress.loopbackIPv4,
          port,
        ).timeout(const Duration(milliseconds: 500));
        probe.destroy();
        return null; // A live instance answered.
      } catch (_) {
        // Stale port file — dead owner. Claim ownership below.
      }
    }
    // Port 0 = OS-assigned: no fixed port to collide with another app.
    // Loopback only: never reachable from the network.
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    File(portFilePath)
      ..createSync(recursive: true)
      ..writeAsStringSync('${server.port}');
    final owned = SingleInstanceServer._(server, portFilePath);
    server.listen(owned._onClient, onError: (_) {});
    return owned;
  }

  static int? _readPortFile(String path) {
    try {
      return int.tryParse(File(path).readAsStringSync().trim());
    } catch (_) {
      return null; // Absent or unreadable: no owner recorded.
    }
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
    final Socket socket;
    if (Platform.isWindows) {
      final port = SingleInstanceServer._readPortFile(path);
      if (port == null) return false;
      socket = await Socket.connect(InternetAddress.loopbackIPv4, port)
          .timeout(const Duration(seconds: 1));
    } else {
      socket = await Socket.connect(
        InternetAddress(path, type: InternetAddressType.unix),
        0,
      ).timeout(const Duration(seconds: 1));
    }
    socket.add(utf8.encode('$command\n'));
    await socket.flush();
    socket.destroy();
    return true;
  } catch (_) {
    return false;
  }
}

/// Where the rendezvous lives.
///
/// Linux: the user's runtime dir when available (tmpfs, per-session,
/// correct permissions), falling back to the system temp dir. Windows:
/// a port file under %LOCALAPPDATA%\Tangent — stable across sessions,
/// per-user, and on a drive that always exists.
String defaultInstanceSocketPath() {
  if (Platform.isWindows) {
    final localAppData = Platform.environment['LOCALAPPDATA'];
    final base = (localAppData != null && localAppData.isNotEmpty)
        ? '$localAppData\\Tangent'
        : Directory.systemTemp.path;
    return '$base\\instance.port';
  }
  final runtime = Platform.environment['XDG_RUNTIME_DIR'];
  final base = (runtime != null && runtime.isNotEmpty)
      ? runtime
      : Directory.systemTemp.path;
  return '$base/tangent.sock';
}
