// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';

import 'package:just_audio_media_kit/just_audio_media_kit.dart';

/// Installs the desktop audio backend for `just_audio`.
///
/// just_audio has no Linux implementation of its own: without this every
/// AudioPlayer call throws MissingPluginException and playback of synced
/// recordings is silently dead on desktop — exactly the kind of quiet
/// failure this project refuses to ship. `just_audio_media_kit` bridges the
/// just_audio platform interface to libmpv via media_kit.
///
/// Must run before the first [AudioPlayer] is constructed; call it from
/// `main()` ahead of any provider wiring. A no-op on platforms that ship
/// their own just_audio backend (Android/iOS/macOS/web).
void initPlatformAudio() {
  if (!Platform.isLinux) return;
  JustAudioMediaKit.ensureInitialized(linux: true);
}
