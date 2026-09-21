// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';

import 'package:flutter/services.dart';

import 'desktop_image_pick.dart';

/// An image the user chose to import into a notebook.
class PickedImage {
  const PickedImage({
    required this.bytes,
    required this.mime,
    required this.width,
    required this.height,
  });

  /// The image bytes, exactly as stored in the chosen file.
  final Uint8List bytes;

  /// The file's MIME type (image/jpeg, image/png, ...).
  final String mime;

  /// Intrinsic pixel size, decoded natively so the editor can place the
  /// image at its true aspect ratio without decoding the bytes twice.
  final int width;
  final int height;
}

/// Opens the system picker for a single image file.
///
/// The native side reads the chosen document's bytes and intrinsic size and
/// returns them directly: the picture is entirely ours before anything is
/// committed to the page, so a transient content:// grant cannot expire
/// mid-import. Oversized picks are downscaled natively (longest edge capped)
/// so one 50 MP photo cannot balloon the notebook's durable JSON.
class ImageFilePicker {
  ImageFilePicker({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('dev.tangent.tangent/audio');

  final MethodChannel _channel;

  /// Returns the picked image, or null if the user cancelled.
  Future<PickedImage?> pick() async {
    // Desktop: no platform channel exists — the Android side implements
    // pickImageFile in MainActivity.kt. Linux uses the GTK file dialog
    // and decodes/caps in Dart with the same 2048 longest-edge rule.
    if (Platform.isLinux) return pickImageDesktop();
    final Map<Object?, Object?>? picked =
        await _channel.invokeMapMethod<Object?, Object?>('pickImageFile');
    if (picked == null) return null;
    final Uint8List? bytes = picked['bytes'] as Uint8List?;
    final int width = (picked['width'] as num?)?.toInt() ?? 0;
    final int height = (picked['height'] as num?)?.toInt() ?? 0;
    if (bytes == null || bytes.isEmpty || width <= 0 || height <= 0) {
      return null;
    }
    return PickedImage(
      bytes: bytes,
      mime: (picked['mime'] as String?) ?? 'image/jpeg',
      width: width,
      height: height,
    );
  }
}
