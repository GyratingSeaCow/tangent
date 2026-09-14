// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/settings_store.dart';
import '../home/home_providers.dart' show onDeviceTranscriptionProvider;
import '../server/server_connection_screen.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  TriggerMode _triggerMode = TriggerMode.tap;
  bool _wifiOnly = false;
  bool _keepScreenAwake = true;
  String _serverUrl = '';
  bool _loaded = false;
  bool? _modelInstalled;
  bool _modelBusy = false;
  double? _modelProgress;
  String? _modelError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final settings = ref.read(settingsStoreProvider);
    final store = ref.read(secureStoreProvider);
    final url = await store.getServerUrl();
    bool? modelInstalled;
    try {
      modelInstalled = await ref.read(onDeviceTranscriptionProvider).isModelInstalled();
    } catch (_) {
      modelInstalled = null;
    }
    if (mounted) {
      setState(() {
        _triggerMode = settings.triggerMode;
        _wifiOnly = settings.wifiOnlySync;
        _keepScreenAwake = settings.keepScreenAwakeWhileRecording;
        _serverUrl = url ?? '';
        _loaded = true;
        _modelInstalled = modelInstalled;
      });
    }
  }

  Future<void> _save() async {
    final settings = ref.read(settingsStoreProvider);
    await settings.setTriggerMode(_triggerMode);
    await settings.setWifiOnlySync(_wifiOnly);
    await settings.setKeepScreenAwakeWhileRecording(_keepScreenAwake);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Settings saved')),
      );
    }
  }

  Future<void> _downloadModel() async {
    setState(() {
      _modelBusy = true;
      _modelError = null;
      _modelProgress = 0;
    });
    try {
      await ref.read(onDeviceTranscriptionProvider).installModel(
        onProgress: (received, total) {
          if (!mounted) return;
          setState(() => _modelProgress = total > 0 ? received / total : null);
        },
      );
      if (mounted) setState(() => _modelInstalled = true);
    } catch (error) {
      if (mounted) setState(() => _modelError = error.toString());
    } finally {
      if (mounted) setState(() => _modelBusy = false);
    }
  }

  void _cancelModelDownload() {
    ref.read(onDeviceTranscriptionProvider).cancel();
    setState(() => _modelError = 'Model download cancellation requested');
  }

  Future<void> _changeServer() async {
    await Navigator.of(context).push<void>(MaterialPageRoute<void>(
      builder: (_) => const ServerConnectionScreen(),
    ),);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        actions: [
          TextButton(
            onPressed: _save,
            child: const Text('SAVE'),
          ),
        ],
      ),
      body: ListView(
        children: [
          ListTile(
            title: const Text('Server'),
            subtitle: Text(_serverUrl.isEmpty ? '(not set)' : _serverUrl),
            trailing: const Icon(Icons.chevron_right),
            onTap: _changeServer,
          ),
          const Divider(),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              'On-device transcription',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          ListTile(
            title: const Text('Whisper large-v3-turbo'),
            subtitle: Text(
              _modelError ??
                  (_modelBusy
                      ? _modelProgress == null
                          ? 'Downloading and verifying…'
                          : 'Downloading ${(_modelProgress! * 100).round()}%'
                      : _modelInstalled == true
                          ? 'Installed and verified'
                          : _modelInstalled == false
                              ? 'Not installed — about 1.5 GB, one-time verified download'
                              : 'Status unavailable'),
            ),
            trailing: _modelBusy
                ? IconButton(
                    tooltip: 'Cancel model download',
                    onPressed: _cancelModelDownload,
                    icon: const Icon(Icons.cancel_outlined),
                  )
                : FilledButton.tonal(
                    onPressed: _modelInstalled == true ? null : _downloadModel,
                    child: Text(_modelError == null ? 'Download' : 'Retry'),
                  ),
          ),
          if (_modelBusy && _modelProgress != null)
            LinearProgressIndicator(value: _modelProgress),
          const Divider(),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              'Recording trigger',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          RadioListTile<TriggerMode>(
            title: const Text('Tap to toggle'),
            subtitle: const Text('Tap once to start, tap again to stop'),
            value: TriggerMode.tap,
            groupValue: _triggerMode,
            onChanged: (v) => setState(() => _triggerMode = v!),
          ),
          RadioListTile<TriggerMode>(
            title: const Text('Hold to record'),
            subtitle: const Text('Press and hold the record button'),
            value: TriggerMode.hold,
            groupValue: _triggerMode,
            onChanged: (v) => setState(() => _triggerMode = v!),
          ),
          const Divider(),
          SwitchListTile(
            title: const Text('Wi-Fi only sync'),
            subtitle: const Text(
                'Wait for Wi-Fi before uploading recordings to the server',),
            value: _wifiOnly,
            onChanged: (v) => setState(() => _wifiOnly = v),
          ),
          SwitchListTile(
            title: const Text('Keep screen awake while recording'),
            subtitle: const Text(
              'Prevents screen sleep only while an active recording is running',
            ),
            value: _keepScreenAwake,
            onChanged: (value) => setState(() => _keepScreenAwake = value),
          ),
          const Divider(),
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Tangent v1.0.0 — AGPL-3.0',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey),
            ),
          ),
        ],
      ),
    );
  }
}

/// Provider for the in-memory settings store.
/// Production wires this up to a persistent implementation in main().
final settingsStoreProvider = Provider<SettingsStore>((ref) => SettingsStore());
