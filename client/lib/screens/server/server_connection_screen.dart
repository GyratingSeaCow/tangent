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
    if (mounted) {
      setState(() {
        _urlController.text = url ?? 'http://10.0.2.2:8000';
        _tokenController.text = token ?? '';
      });
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
      final client = TranscriptionClient(
        baseUrl: _urlController.text.trim(),
        token: _tokenController.text.trim().isEmpty
            ? null
            : _tokenController.text.trim(),
      );
      await client.getServerInfo();
      final store = ref.read(secureStoreProvider);
      await store.setServerUrl(_urlController.text.trim());
      if (_tokenController.text.trim().isNotEmpty) {
        await store.setToken(_tokenController.text.trim());
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