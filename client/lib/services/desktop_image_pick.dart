// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';

import 'image_file_picker.dart';

/// The longest-edge cap for imported images.
///
/// Mirrors MainActivity.kt's maxImageEdge on Android exactly: image blocks
/// are stored base64 inside the notebook's durable JSON, so one 50 MP
/// photo would balloon the file and every sync of it.
const int kMaxImageEdge = 2048;

/// Decodes [bytes], downscaling so the longest edge is at most
/// [kMaxImageEdge] (aspect preserved). Returns null on undecodable input —
/// the caller treats that as "no pick", matching the picker contract.
///
/// Re-encodes to PNG only when downscaling was needed; small images pass
/// through byte-identical so a crisp screenshot stays crisp.
Future<PickedImage?> decodePickedImage(Uint8List bytes) async {
  final ui.Codec codec;
  try {
    codec = await ui.instantiateImageCodec(bytes);
  } catch (_) {
    return null;
  }
  final ui.FrameInfo frame;
  try {
    frame = await codec.getNextFrame();
  } catch (_) {
    codec.dispose();
    return null;
  }
  final ui.Image image = frame.image;
  final int width = image.width;
  final int height = image.height;
  final int longest = width > height ? width : height;

  if (longest <= kMaxImageEdge) {
    image.dispose();
    codec.dispose();
    return PickedImage(
      bytes: bytes,
      mime: _sniffMime(bytes),
      width: width,
      height: height,
    );
  }

  final double scale = kMaxImageEdge / longest;
  final int targetWidth = (width * scale).round();
  final int targetHeight = (height * scale).round();
  image.dispose();
  codec.dispose();

  final ui.Codec scaledCodec = await ui.instantiateImageCodec(
    bytes,
    targetWidth: targetWidth,
    targetHeight: targetHeight,
  );
  final ui.FrameInfo scaledFrame = await scaledCodec.getNextFrame();
  final ByteData? png =
      await scaledFrame.image.toByteData(format: ui.ImageByteFormat.png);
  scaledFrame.image.dispose();
  scaledCodec.dispose();
  if (png == null) return null;
  return PickedImage(
    bytes: png.buffer.asUint8List(),
    mime: 'image/png',
    width: targetWidth,
    height: targetHeight,
  );
}

String _sniffMime(Uint8List bytes) {
  if (bytes.length >= 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47) {
    return 'image/png';
  }
  if (bytes.length >= 3 &&
      bytes[0] == 0xFF &&
      bytes[1] == 0xD8 &&
      bytes[2] == 0xFF) {
    return 'image/jpeg';
  }
  if (bytes.length >= 12 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50) {
    return 'image/webp';
  }
  return 'image/png';
}

/// Desktop implementation of the image pick: GTK file dialog via
/// file_selector, decode + cap in Dart. Same return contract as the
/// Android channel — null means cancelled or unreadable.
Future<PickedImage?> pickImageDesktop() async {
  const XTypeGroup images = XTypeGroup(
    label: 'Images',
    extensions: <String>['png', 'jpg', 'jpeg', 'webp', 'bmp', 'gif'],
  );
  final XFile? file = await openFile(acceptedTypeGroups: <XTypeGroup>[images]);
  if (file == null) return null;
  final Uint8List bytes;
  try {
    bytes = await file.readAsBytes();
  } catch (_) {
    return null;
  }
  if (bytes.isEmpty) return null;
  return decodePickedImage(bytes);
}
