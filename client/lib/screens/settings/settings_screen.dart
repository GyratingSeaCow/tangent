// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/settings_store.dart';
import '../server/server_connection_screen.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  TriggerMode _triggerMode = TriggerMode.tap;
  bool _wifiOnly = false;
  String _serverUrl = '';
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final settings = ref.read(settingsStoreProvider);
    final store = ref.read(secureStoreProvider);
    final url = await store.getServerUrl();
    if (mounted) {
      setState(() {
        _triggerMode = settings.triggerMode;
        _wifiOnly = settings.wifiOnlySync;
        _serverUrl = url ?? '';
        _loaded = true;
      });
    }
  }

  Future<void> _save() async {
    final settings = ref.read(settingsStoreProvider);
    await settings.setTriggerMode(_triggerMode);
    await settings.setWifiOnlySync(_wifiOnly);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Settings saved')),
      );
    }
  }

  Future<void> _changeServer() async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => const ServerConnectionScreen(),
    ));
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
                'Wait for Wi-Fi before uploading recordings to the server'),
            value: _wifiOnly,
            onChanged: (v) => setState(() => _wifiOnly = v),
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