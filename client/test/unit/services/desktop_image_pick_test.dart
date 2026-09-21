// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/services/desktop_image_pick.dart';

/// Desktop image import: decode the chosen file, cap the longest edge at
/// 2048 (the same cap MainActivity.kt applies on Android — one oversized
/// photo must not balloon the notebook's durable JSON), and report true
/// intrinsic size so the editor places the block at the right aspect.
Future<Uint8List> _pngOfSize(int w, int h) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(
    ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    ui.Paint()..color = const ui.Color(0xFF3355AA),
  );
  final image = await recorder.endRecording().toImage(w, h);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  return bytes!.buffer.asUint8List();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a small image passes through at its intrinsic size', () async {
    final png = await _pngOfSize(300, 200);
    final picked = await decodePickedImage(png);
    expect(picked, isNotNull);
    expect(picked!.width, 300);
    expect(picked.height, 200);
    expect(picked.mime, 'image/png');
  });

  test('an oversized image is downscaled to the 2048 cap, aspect kept',
      () async {
    final png = await _pngOfSize(4096, 1024);
    final picked = await decodePickedImage(png);
    expect(picked, isNotNull);
    expect(picked!.width, 2048, reason: 'longest edge capped like Android');
    expect(picked.height, 512, reason: 'aspect ratio preserved');
  });

  test('garbage bytes return null instead of throwing', () async {
    final picked = await decodePickedImage(
      Uint8List.fromList(List<int>.filled(64, 7)),
    );
    expect(picked, isNull);
  });
}
