// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:tangent/services/platform_audio.dart';

void main() {
  test(
    'desktop playback routes just_audio through media_kit (libmpv)',
    () {
      // just_audio ships no Linux or Windows platform implementation at
      // all: without an installed backend every AudioPlayer call throws
      // MissingPluginException and playback of synced recordings is
      // silently dead on desktop.
      //
      // Only Linux can assert this in a test: libmpv is a system library
      // there, present on the bare test host. On Windows the mpv DLL ships
      // inside the built app bundle (media_kit_libs_windows_audio), so
      // ensureInitialized can only succeed in a real app process — the
      // wiring is exercised by launching the built exe, not here.
      initPlatformAudio();
      expect(
        JustAudioPlatform.instance,
        isA<JustAudioMediaKit>(),
        reason: 'desktop playback must be bridged to libmpv via media_kit',
      );
    },
    skip: Platform.isLinux
        ? false
        : 'libmpv lives in the app bundle off-Linux; untestable on a bare '
            'test host',
  );

  test(
    'mobile platforms keep their native just_audio backend',
    () {
      initPlatformAudio();
      expect(JustAudioPlatform.instance, isNot(isA<JustAudioMediaKit>()));
    },
    skip: (Platform.isLinux || Platform.isWindows)
        ? 'desktop routes through media_kit by design'
        : false,
  );
}
