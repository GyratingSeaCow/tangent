// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/settings_store.dart';
import '../server/server_connection_screen.dart';
import 'storage_settings_section.dart';

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
  ServerInfoSnapshot? _serverInfo;
  bool _loaded = false;
  bool _serverBusy = false;
  String? _serverError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final settings = ref.read(settingsStoreProvider);
    final store = ref.read(secureStoreProvider);
    final url = await store.getServerUrl();
    if (!mounted) return;
    setState(() {
      _triggerMode = settings.triggerMode;
      _wifiOnly = settings.wifiOnlySync;
      _keepScreenAwake = settings.keepScreenAwakeWhileRecording;
      _serverUrl = url ?? '';
      _loaded = true;
      _serverBusy = url != null && url.isNotEmpty;
      _serverError = null;
      _serverInfo = null;
    });
    ServerInfoSnapshot? info;
    String? infoError;
    if (url != null && url.isNotEmpty) {
      try {
        final client = ref.read(transcriptionClientProvider);
        info = ServerInfoSnapshot.fromInfo(await client.getServerInfo());
      } catch (e) {
        infoError = e.toString();
      }
    }
    if (mounted) {
      setState(() {
        _serverInfo = info;
        _serverError = infoError;
        _serverBusy = false;
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

  Future<void> _changeServer() async {
    await Navigator.of(context).push<void>(MaterialPageRoute<void>(
      builder: (_) => const ServerConnectionScreen(),
    ),);
    await _load();
  }

  Future<void> _refreshServerInfo() async {
    setState(() {
      _serverBusy = true;
      _serverError = null;
    });
    try {
      final client = ref.read(transcriptionClientProvider);
      final info = await client.getServerInfo();
      if (mounted) {
        setState(() => _serverInfo = ServerInfoSnapshot.fromInfo(info));
      }
    } catch (e) {
      if (mounted) setState(() => _serverError = e.toString());
    } finally {
      if (mounted) setState(() => _serverBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        actions: [
          TextButton(
            onPressed: _loaded ? _save : null,
            child: const Text('SAVE'),
          ),
        ],
      ),
      body: ListView(
        children: [
          const StorageSettingsSection(),
          const Divider(),
          if (!_loaded)
            const ListTile(title: Text('Loading settings…'))
          else ...[
          ListTile(
            title: const Text('Server'),
            subtitle: Text(_serverUrl.isEmpty ? '(not set)' : _serverUrl),
            trailing: const Icon(Icons.chevron_right),
            onTap: _serverBusy ? null : _changeServer,
          ),
          const Divider(),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              'Transcription',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          ListTile(
            title: Text(_serverInfo?.title ?? 'Server transcription'),
            subtitle: Text(_serverInfoText()),
            trailing: _serverBusy
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : IconButton(
                    tooltip: 'Refresh server info',
                    onPressed: _serverUrl.isEmpty ? null : _refreshServerInfo,
                    icon: const Icon(Icons.refresh),
                  ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: Text(
              'Audio is uploaded to your personal Docker container '
              'over the LAN (or cellular). The server transcribes with '
              'faster-whisper and streams the result back. Recordings taken '
              'without connectivity will be queued and transcribed when you '
              'next open the app with network access.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),
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
        ],
      ),
    );
  }

  String _serverInfoText() {
    if (_serverBusy) return 'Loading server information…';
    if (_serverError != null) return 'Server unreachable: $_serverError';
    final info = _serverInfo;
    if (info == null) return 'Not configured — tap Server above to set up';
    final parts = <String>['Connected'];
    if (info.model != null) parts.add('default model: ${info.model}');
    if (info.models != null) parts.add('available: ${info.models!.join(", ")}');
    if (info.dumpCount != null) parts.add('${info.dumpCount} dumps');
    if (info.setupComplete == false) parts.add('SETUP INCOMPLETE — open the server URL in a browser');
    return parts.join(' · ');
  }
}

class ServerInfoSnapshot {
  const ServerInfoSnapshot({
    required this.setupComplete,
    this.model,
    this.models,
    this.dumpCount,
  });

  factory ServerInfoSnapshot.fromInfo(dynamic info) {
    return ServerInfoSnapshot(
      setupComplete: info.setupComplete as bool,
      model: info.defaultModel as String?,
      models: (info.availableModels as List?)?.map((e) => e.toString()).toList(),
      dumpCount: info.dumpCount as int?,
    );
  }

  final bool setupComplete;
  final String? model;
  final List<String>? models;
  final int? dumpCount;

  String get title => 'Server transcription';
}

/// Provider for the in-memory settings store.
/// Production wires this up to a persistent implementation in main().
final settingsStoreProvider = Provider<SettingsStore>((ref) => SettingsStore());
