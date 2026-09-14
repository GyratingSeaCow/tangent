// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';

abstract class ScreenAwake {
  Future<void> setEnabled(bool enabled);
}

class PlatformScreenAwake implements ScreenAwake {
  static const _channel = MethodChannel('dev.tangent.tangent/storage');

  @override
  Future<void> setEnabled(bool enabled) => _channel.invokeMethod<void>(
        'setKeepScreenAwake',
        {'enabled': enabled},
      );
}

final screenAwakeProvider =
    Provider<ScreenAwake>((ref) => PlatformScreenAwake());
