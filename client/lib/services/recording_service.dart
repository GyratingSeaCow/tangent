// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:record/record.dart';

import 'communication_routing.dart';

class RecordingResult {
  final String path;
  final int durationSeconds;
  final int sizeBytes;

  const RecordingResult({
    required this.path,
    required this.durationSeconds,
    required this.sizeBytes,
  });
}

abstract class RecordingService {
  bool get isRecording;
  String? get currentPath;

  Future<bool> requestPermission();
  Stream<double> amplitudeStream(Duration interval);
  Future<String> start({required String stagingPath});
  Future<RecordingResult?> stop();
  Future<void> dispose();

  /// Input devices the platform currently reports, for the Settings picker.
  ///
  /// Call this from Settings, never from the record path. Returns an empty
  /// list rather than throwing when enumeration is unavailable (for example
  /// when BLUETOOTH_CONNECT has not been granted on Android 12+).
  Future<List<InputDevice>> listInputDevices() async => const <InputDevice>[];

  /// Chooses the microphone to record with. Passing null returns the recorder
  /// to the system default input.
  Future<void> selectInputDevice(InputDevice? device) async {}

  /// Re-applies the remembered headset route, if any.
  ///
  /// Call when the app returns to the foreground so a Bluetooth headset is
  /// routed before the user taps record. No-op when nothing is selected.
  Future<void> warmRoute() async {}

  /// Releases the headset route unless a recording is in flight.
  Future<void> releaseRouteIfIdle() async {}
}

/// Default no-op input-device behaviour for services that do not select a
/// microphone (stubs, fakes, and platforms without device enumeration).
mixin NoInputDeviceSelection implements RecordingService {
  @override
  Future<List<InputDevice>> listInputDevices() async => const <InputDevice>[];

  @override
  Future<void> selectInputDevice(InputDevice? device) async {}

  @override
  Future<void> warmRoute() async {}

  @override
  Future<void> releaseRouteIfIdle() async {}
}

/// The slice of `package:record`'s [AudioRecorder] this app depends on.
///
/// Declared so tests can substitute a fake without real hardware.
abstract class InputAwareAudioRecorder {
  Future<bool> hasPermission();
  Future<List<InputDevice>> listInputDevices();
  Future<void> start(RecordConfig config, {required String path});
  Future<String?> stop();
  Stream<Amplitude> onAmplitudeChanged(Duration interval);
  Future<void> dispose();
}

/// Adapts the concrete [AudioRecorder] to [InputAwareAudioRecorder].
class PlatformAudioRecorder implements InputAwareAudioRecorder {
  PlatformAudioRecorder([AudioRecorder? inner])
      : _inner = inner ?? AudioRecorder();

  final AudioRecorder _inner;

  @override
  Future<bool> hasPermission() => _inner.hasPermission();

  @override
  Future<List<InputDevice>> listInputDevices() => _inner.listInputDevices();

  @override
  Future<void> start(RecordConfig config, {required String path}) =>
      _inner.start(config, path: path);

  @override
  Future<String?> stop() => _inner.stop();

  @override
  Stream<Amplitude> onAmplitudeChanged(Duration interval) =>
      _inner.onAmplitudeChanged(interval);

  @override
  Future<void> dispose() => _inner.dispose();
}

class DefaultRecordingService implements RecordingService {
  InputAwareAudioRecorder? _recorder;
  final Directory _outputDir;
  String? _currentPath;
  DateTime? _startedAt;
  bool _isRecording = false;

  /// The user's chosen microphone, or null for the system default.
  InputDevice? _selectedDevice;

  /// Whether [_selectedDevice] was present the last time we enumerated.
  ///
  /// Selection and the Settings picker both refresh this, so [start] can
  /// honour the choice without paying for a platform round trip. It is only
  /// null when the choice was restored from settings and never verified.
  bool? _selectedDeviceAvailable;

  DefaultRecordingService({
    Directory? outputDir,
    InputAwareAudioRecorder? recorder,
    InputDevice? initialDevice,
    CommunicationRouting? routing,
  })  : _recorder = recorder,
        _routing = routing ?? CommunicationRouting(),
        _selectedDevice = initialDevice,
        _outputDir = outputDir ??
            (throw ArgumentError('A staging output directory is required'));

  /// Routes capture to a Bluetooth headset mic. See [CommunicationRouting]:
  /// the `record` plugin's own Bluetooth handling does not bring SCO up on
  /// this project's target hardware.
  final CommunicationRouting _routing;

  /// Device id the communication route is currently applied to, if any.
  ///
  /// Lets [start] skip a redundant round trip when selection already warmed
  /// the route, while still re-asserting it after a clear (backgrounding, or
  /// the end of a previous recording).
  String? _routedDeviceId;

  InputAwareAudioRecorder get _ensureRecorder =>
      _recorder ??= PlatformAudioRecorder();

  @override
  bool get isRecording => _isRecording;

  @override
  String? get currentPath => _currentPath;

  /// The microphone currently selected, or null for the system default.
  InputDevice? get selectedDevice => _selectedDevice;

  @override
  Future<bool> requestPermission() => _ensureRecorder.hasPermission();

  @override
  Stream<double> amplitudeStream(Duration interval) => _ensureRecorder
      .onAmplitudeChanged(interval)
      .map((value) => value.current);

  @override
  Future<List<InputDevice>> listInputDevices() async {
    final List<InputDevice> devices;
    try {
      devices = await _ensureRecorder.listInputDevices();
    } catch (_) {
      // Enumeration is best-effort: a denied BLUETOOTH_CONNECT permission or a
      // platform without device selection must not surface as an error.
      return const <InputDevice>[];
    }
    final selected = _selectedDevice;
    if (selected != null) {
      _selectedDeviceAvailable =
          devices.any((device) => device.id == selected.id);
    }
    return devices;
  }

  @override
  Future<void> selectInputDevice(InputDevice? device) async {
    _selectedDevice = device;
    // A device handed to us by the picker was, by construction, just listed.
    _selectedDeviceAvailable = device == null ? null : true;
    // Warm the route NOW rather than at record time. Device evidence: firing
    // it on the record tap was too late — the applied device reached
    // role:output type:bt_sco, but capture still read `source client=MIC`
    // because the recorder bound its input stream before the asynchronous
    // route landed. Warming at selection gets SCO up ahead of the tap without
    // putting any delay on the tap itself. Choosing the default releases it so
    // the phone does not sit in call-audio mode.
    if (device == null) {
      _routedDeviceId = null;
      await _routing.clear().catchError((_) {});
    } else {
      _routedDeviceId = device.id;
      await _routing.route(device.id).catchError(
            (_) => CommunicationRoute.unavailable,
          );
    }
  }

  /// Re-applies the remembered headset route.
  ///
  /// Called when the app returns to the foreground so SCO is live again by the
  /// time the user reaches for record. Safe to call with no selection.
  @override
  Future<void> warmRoute() async {
    final selected = _selectedDevice;
    if (selected == null) return;
    _routedDeviceId = selected.id;
    await _routing.route(selected.id).catchError(
          (_) => CommunicationRoute.unavailable,
        );
  }

  /// Releases the route unless a recording is in flight.
  ///
  /// Backgrounding the app must not yank the microphone out from under an
  /// active capture, but an idle app should not pin the phone into call-audio
  /// mode either — that degrades the user's music playback and holds the
  /// headset in its low-quality SCO profile.
  @override
  Future<void> releaseRouteIfIdle() async {
    if (_isRecording) return;
    _routedDeviceId = null;
    await _routing.clear().catchError((_) {});
  }

  /// Drops the cached availability verdict so the next [start] re-checks.
  ///
  /// Used by tests and by restore-from-settings, where the remembered headset
  /// may since have been switched off.
  @visibleForTesting
  void debugForgetAvailability() => _selectedDeviceAvailable = null;

  /// Resolves the device to record with, falling back to the system default.
  ///
  /// Costs a platform round trip ONLY when a device was chosen and its
  /// availability is unknown (first record after launch). With no selection —
  /// the default for every user who never opened the picker — this is free.
  Future<InputDevice?> _resolveDevice() async {
    final selected = _selectedDevice;
    if (selected == null) return null;
    if (_selectedDeviceAvailable ?? false) return selected;
    final devices = await listInputDevices();
    for (final device in devices) {
      if (device.id == selected.id) return device;
    }
    // Headset gone: record on the system default rather than failing. The
    // preference is kept so it re-engages when the headset comes back.
    return null;
  }

  @override
  Future<String> start({required String stagingPath}) async {
    if (_isRecording) throw StateError('Already recording');
    final recorder = _ensureRecorder;
    if (!await recorder.hasPermission()) {
      throw StateError('Microphone permission not granted');
    }
    if (!p.isAbsolute(stagingPath) ||
        !p.equals(p.dirname(stagingPath), _outputDir.path)) {
      throw ArgumentError('Recording requires the reserved staging path');
    }
    await _outputDir.create(recursive: true);
    final path = stagingPath;
    await File(path).create(exclusive: true);
    final device = await _resolveDevice();
    // Ask the platform to route capture to the headset, but DO NOT await it.
    // Bringing up an SCO link takes hundreds of milliseconds to over a second,
    // and this app just had a 5.8s stall removed from the record tap. Capture
    // starts immediately; the route lands a moment later. Errors are swallowed
    // by CommunicationRouting, so a dead headset can never block a recording.
    // Normally the route was already warmed when the device was chosen (or on
    // resume), so this is a no-op. It still re-asserts after a clear — for
    // example the app was backgrounded, or a previous recording released it.
    //
    // Deliberately NOT awaited: bringing up an SCO link takes hundreds of ms
    // to over a second, and T6 removed a 5.8s stall from this exact path.
    if (device != null && _routedDeviceId != device.id) {
      _routedDeviceId = device.id;
      unawaited(
        _routing.route(device.id).catchError(
          // Belt and braces: CommunicationRouting already swallows platform
          // faults, but a throw escaping an unawaited future would become an
          // unhandled async error and could crash in debug builds.
          (_) => CommunicationRoute.unavailable,
        ),
      );
    }
    await recorder.start(
      RecordConfig(
        encoder: AudioEncoder.opus,
        sampleRate: 16000,
        numChannels: 1,
        bitRate: 32000,
        device: device,
      ),
      path: path,
    );
    _currentPath = path;
    _startedAt = DateTime.now();
    _isRecording = true;
    return path;
  }

  @override
  Future<RecordingResult?> stop() async {
    if (!_isRecording) return null;
    final startedAt = _startedAt;
    String? path;
    try {
      path = await _ensureRecorder.stop();
    } finally {
      _isRecording = false;
      _currentPath = null;
      _startedAt = null;
      // Release the headset route. Leaving it applied keeps the phone in
      // call-audio mode, which degrades music playback and pins the headset to
      // its low-quality SCO profile. In the finally block so it happens even
      // when the recorder throws on stop.
      _routedDeviceId = null;
      unawaited(_routing.clear().catchError((_) {}));
    }
    if (path == null || startedAt == null) return null;
    final file = File(path);
    if (!await file.exists()) {
      throw StateError('Recorder stopped without producing an audio file');
    }
    final size = await file.length();
    if (size <= 0) throw StateError('Recorder produced an empty audio file');
    return RecordingResult(
      path: path,
      durationSeconds: DateTime.now().difference(startedAt).inSeconds,
      sizeBytes: size,
    );
  }

  @override
  Future<void> dispose() async {
    await _recorder?.dispose();
    _recorder = null;
    _isRecording = false;
    _currentPath = null;
    _startedAt = null;
  }
}

class StubRecordingService with NoInputDeviceSelection implements RecordingService {
  bool _isRecording = false;
  String? _path;
  bool _disposed = false;
  final List<String> events = [];
  final StreamController<double> _amplitudes = StreamController.broadcast();

  @override
  bool get isRecording => _isRecording;
  @override
  String? get currentPath => _path;

  @override
  Future<bool> requestPermission() async {
    events.add('permission');
    return true;
  }

  @override
  Stream<double> amplitudeStream(Duration interval) {
    events.add('amplitude:${interval.inMilliseconds}');
    return _amplitudes.stream;
  }

  void emitAmplitude(double dbfs) => _amplitudes.add(dbfs);
  void emitAmplitudeError(Object error) => _amplitudes.addError(error);

  @override
  Future<String> start({required String stagingPath}) async {
    events.add('start');
    _isRecording = true;
    _path = stagingPath;
    return _path!;
  }

  @override
  Future<RecordingResult?> stop() async {
    events.add('stop');
    if (!_isRecording) return null;
    _isRecording = false;
    final path = _path!;
    _path = null;
    return RecordingResult(path: path, durationSeconds: 5, sizeBytes: 100);
  }

  @override
  Future<void> dispose() async {
    events.add('dispose');
    if (!_disposed) {
      _disposed = true;
      await _amplitudes.close();
    }
  }
}
