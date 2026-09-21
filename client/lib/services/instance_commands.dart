// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Commands delivered by other invocations of the app (desktop only).
///
/// A KDE global shortcut runs `tangent --record`; that process forwards
/// 'toggle-record' over the single-instance socket and exits. main() owns
/// the socket server and overrides this provider with its command stream.
/// The default is an empty stream so Android and tests without an override
/// behave exactly as before.
final instanceCommandsProvider =
    Provider<Stream<String>>((ref) => const Stream<String>.empty());
