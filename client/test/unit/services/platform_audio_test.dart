// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:tangent/services/platform_audio.dart';

void main() {
  test(
    'Linux playback routes just_audio through media_kit (libmpv)',
    () {
      // just_audio ships no Linux platform implementation at all: without an
      // installed backend every AudioPlayer call throws MissingPluginException
      // and playback of synced recordings is silently dead on desktop.
      initPlatformAudio();
      expect(
        JustAudioPlatform.instance,
        isA<JustAudioMediaKit>(),
        reason: 'desktop playback must be bridged to libmpv via media_kit',
      );
    },
    skip: Platform.isLinux ? false : 'Linux-only playback backend wiring',
  );

  test(
    'non-Linux platforms keep their native just_audio backend',
    () {
      initPlatformAudio();
      expect(JustAudioPlatform.instance, isNot(isA<JustAudioMediaKit>()));
    },
    skip: Platform.isLinux ? 'covered by the Linux test above' : false,
  );
}
