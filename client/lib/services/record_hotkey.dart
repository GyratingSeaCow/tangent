// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart' show PhysicalKeyboardKey;
import 'package:hotkey_manager/hotkey_manager.dart';

/// The global record hotkey on Windows: Ctrl+Alt+R.
///
/// Linux delegates global shortcuts to the desktop environment (a KDE
/// shortcut runs `tangent --record`, which the single-instance socket
/// turns into a command). Windows has no such convention, so the owning
/// instance registers a system-wide hotkey in-process via RegisterHotKey
/// and routes it into the SAME command path the socket serves — one code
/// path for hotkey, tray, and CLI.
///
/// Registration failure (the combination is taken by another app) must
/// never take the app down: the hotkey is a convenience, not a
/// dependency. [install] reports success so the caller can log it.
class RecordHotkey {
  RecordHotkey({required Future<void> Function() onToggleRecord})
      : _onToggleRecord = onToggleRecord;

  final Future<void> Function() _onToggleRecord;

  HotKey? _registered;

  /// Registers Ctrl+Alt+R system-wide. True on success, false when the
  /// OS refused (already taken elsewhere) — the app continues without.
  Future<bool> install() async {
    // A leftover registration from a hot restart would double-fire.
    await hotKeyManager.unregisterAll();
    final hotKey = HotKey(
      key: PhysicalKeyboardKey.keyR,
      modifiers: [HotKeyModifier.control, HotKeyModifier.alt],
      scope: HotKeyScope.system,
    );
    try {
      await hotKeyManager.register(
        hotKey,
        keyDownHandler: (_) => unawaited(_onToggleRecord()),
      );
      _registered = hotKey;
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> dispose() async {
    final hotKey = _registered;
    _registered = null;
    if (hotKey != null) {
      try {
        await hotKeyManager.unregister(hotKey);
      } catch (_) {
        // Unregistering a dead registration is fine.
      }
    }
  }
}

/// Whether this platform uses the in-process hotkey (vs. delegating to
/// the desktop environment's own shortcut system).
bool get platformUsesInProcessHotkey => Platform.isWindows;
