// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/screens/recording/recording_waveform.dart';

void main() {
  testWidgets('waveform exposes semantics and paints silence center line',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: RecordingWaveform(
          samples: List<double>.filled(72, 0),
          color: Colors.pink,
        ),
      ),
    ),);

    expect(find.bySemanticsLabel('Live microphone waveform'), findsOneWidget);
    final waveformPaint = find.descendant(
      of: find.byType(RecordingWaveform),
      matching: find.byType(CustomPaint),
    );
    expect(waveformPaint, findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('nonzero newest-right sample renders without overflow',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: RecordingWaveform(
          samples: List<double>.filled(72, 0)..[71] = 1,
          color: Colors.pink,
        ),
      ),
    ),);

    final waveformPaint = find.descendant(
      of: find.byType(RecordingWaveform),
      matching: find.byType(CustomPaint),
    );
    final paint = tester.widget<CustomPaint>(waveformPaint);
    final painter = paint.painter! as RecordingWaveformPainter;
    expect(painter.samples.last, 1);
    expect(painter.samples.first, 0);
    expect(tester.takeException(), isNull);
  });
}
