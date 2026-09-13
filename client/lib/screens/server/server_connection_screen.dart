// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/secure_storage.dart';
import '../../services/transcription_client.dart';

final secureStoreProvider = Provider<SecureStore>((ref) => SecureStore());

final transcriptionClientProvider = Provider<TranscriptionClient>((ref) {
  // Caller must override this provider once async values are available.
  // Defaults to localhost which lets the app boot; real client is set in
  // main() after reading SecureStore.
  return TranscriptionClient(baseUrl: 'http://10.0.2.2:8000');
});

class ServerConnectionScreen extends ConsumerStatefulWidget {
  const ServerConnectionScreen({super.key});

  @override
  ConsumerState<ServerConnectionScreen> createState() =>
      _ServerConnectionScreenState();
}

class _ServerConnectionScreenState
    extends ConsumerState<ServerConnectionScreen> {
  final _urlController = TextEditingController();
  final _tokenController = TextEditingController();
  bool _testing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadStoredValues();
  }

  Future<void> _loadStoredValues() async {
    final store = ref.read(secureStoreProvider);
    final url = await store.getServerUrl();
    final token = await store.getToken();
    if (!mounted) return;
    // Only set the URL if the user hasn't typed anything yet. This avoids a
    // race where async load clobbers the user's typed value (which used to
    // cause an empty/host-less URL to be sent to the network layer).
    if (_urlController.text.isEmpty) {
      _urlController.text = url ?? 'http://10.0.2.2:8000';
    }
    if (_tokenController.text.isEmpty && token != null) {
      _tokenController.text = token;
    }
  }

  @override
  void dispose() {
    _urlController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  Future<void> _testAndSave() async {
    setState(() {
      _testing = true;
      _error = null;
    });
    try {
      final url = _urlController.text.trim();
      // Validate URL up-front so we fail with a clear message instead of
      // a low-level Dio "no host in url" error.
      if (url.isEmpty) {
        throw Exception('Server URL is empty');
      }
      final parsed = Uri.tryParse(url);
      if (parsed == null || parsed.host.isEmpty) {
        throw Exception('Server URL is missing a host (e.g. http://192.168.1.5:8000)');
      }
      if (parsed.scheme != 'http' && parsed.scheme != 'https') {
        throw Exception('Server URL must start with http:// or https://');
      }
      final token = _tokenController.text.trim().isEmpty
          ? null
          : _tokenController.text.trim();
      final client = TranscriptionClient(baseUrl: url, token: token);
      await client.getServerInfo();
      final store = ref.read(secureStoreProvider);
      await store.setServerUrl(url);
      if (token != null) {
        await store.setToken(token);
      }
      if (mounted) {
        Navigator.of(context).pushReplacementNamed('/home');
      }
    } catch (e) {
      setState(() => _error = 'Connection failed: $e');
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Connect to Server')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Enter your server URL and API token.',
              style: TextStyle(fontSize: 16),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _urlController,
              decoration: const InputDecoration(
                labelText: 'Server URL',
                hintText: 'http://homelab.lan:8000',
              ),
              keyboardType: TextInputType.url,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _tokenController,
              decoration: const InputDecoration(
                labelText: 'API Token (optional)',
              ),
              obscureText: true,
            ),
            const SizedBox(height: 24),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            FilledButton(
              onPressed: _testing ? null : _testAndSave,
              child: _testing
                  ? const SizedBox(
                      height: 16,
                      width: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Test & Connect'),
            ),
          ],
        ),
      ),
    );
  }
}