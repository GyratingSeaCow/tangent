// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../data/secure_storage.dart';
import '../../services/pairing_client.dart';
import '../../services/server_discovery.dart';
import '../../services/transcription_client.dart';

final secureStoreProvider = Provider<SecureStore>((ref) => SecureStore());

final transcriptionClientProvider = StateProvider<TranscriptionClient>((ref) {
  // Caller must override this provider once async values are available.
  // Defaults to localhost which lets the app boot; real client is set in
  // main() after reading SecureStore.
  return TranscriptionClient(baseUrl: 'http://10.0.2.2:8000');
});

class ServerConnectionScreen extends ConsumerStatefulWidget {
  const ServerConnectionScreen({
    super.key,
    this.discoveryFactory,
    this.pairingFactory,
    this.localAddress,
    this.clientFactory,
  });

  /// Test seams: widget tests inject fakes so the sweep and the pairing
  /// handshake run without sockets. Production leaves them null.
  final ServerDiscovery Function()? discoveryFactory;
  final PairingClient Function(String baseUrl)? pairingFactory;
  final Future<String?> Function()? localAddress;

  /// Seam for the post-pair token verification call.
  final TranscriptionClient Function(String baseUrl, String token)?
      clientFactory;

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

  // ---- Discovery state ----
  ServerDiscovery? _discovery;
  bool _scanning = false;
  String? _scanSubnet;
  final List<DiscoveredServer> _found = <DiscoveredServer>[];

  // ---- Pairing state ----
  bool _pairing = false;

  @override
  void initState() {
    super.initState();
    _loadStoredValues();
  }

  Future<void> _loadStoredValues() async {
    final store = ref.read(secureStoreProvider);
    String? url;
    String? token;
    try {
      url = await store.getServerUrl();
      token = await store.getToken();
    } catch (e) {
      // Linux: flutter_secure_storage needs a running Secret Service
      // (KWallet >= 5.97 or gnome-keyring). Without one, every read throws.
      // The screen must still stand — but silently empty fields would read
      // as "never paired", so say what actually happened.
      if (mounted) {
        setState(() {
          _error = 'Could not read secure storage (saved server/token '
              'unavailable): $e';
        });
      }
      return;
    }
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
    _discovery?.cancel();
    _urlController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  /// The device's own LAN IPv4, or null when there is none (cellular,
  /// airplane mode). Sweeping a carrier NAT range is pointless and looks
  /// like scanning behaviour, so no address means no sweep.
  Future<String?> _localIPv4() async {
    try {
      final List<NetworkInterface> interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLinkLocal: false,
      );
      for (final NetworkInterface iface in interfaces) {
        for (final InternetAddress addr in iface.addresses) {
          if (!addr.isLoopback) return addr.address;
        }
      }
    } on Object {
      // Fall through: no address, no sweep.
    }
    return null;
  }

  Future<void> _scan() async {
    final String? self = await (widget.localAddress ?? _localIPv4)();
    if (!mounted) return;
    if (self == null) {
      setState(() {
        _error = 'No local network found. If your server is on Tailscale or '
            'another VPN, enter its address below.';
      });
      return;
    }
    setState(() {
      _scanning = true;
      _error = null;
      _found.clear();
      _scanSubnet = self.substring(0, self.lastIndexOf('.'));
    });
    final ServerDiscovery discovery =
        widget.discoveryFactory?.call() ?? ServerDiscovery();
    _discovery = discovery;
    // Findings land in the list LIVE — a sheet that fills in as it scans
    // reads as working; a spinner that dumps results at the end reads hung.
    await discovery.sweep(
      selfAddress: self,
      onFound: (DiscoveredServer server) {
        if (mounted) setState(() => _found.add(server));
      },
    );
    if (mounted) setState(() => _scanning = false);
  }

  /// Pair with [baseUrl]: request a code, prompt for it, claim a token,
  /// and connect. The code lives on the server's screen/log — proving the
  /// user actually controls that machine.
  Future<void> _pair(String baseUrl) async {
    setState(() {
      _pairing = true;
      _error = null;
    });
    try {
      final PairingClient pairing = widget.pairingFactory?.call(baseUrl) ??
          PairingClient(baseUrl: baseUrl);
      final SecureStore store = ref.read(secureStoreProvider);
      // One stable id per install: reuse the sync engine's device id when
      // it exists so the server sees one device, not one per pairing.
      final String deviceId = await store.getDeviceId() ?? const Uuid().v4();
      await store.setDeviceId(deviceId);

      final PairingTicket? ticket = await pairing.request(
        deviceId: deviceId,
        displayName: Platform.localHostname,
        platform: Platform.operatingSystem,
      );
      if (ticket == null) {
        setState(
          () => _error = 'Could not start pairing. Is the server reachable?',
        );
        return;
      }
      if (!mounted) return;

      final String? token = await _promptForCode(pairing, ticket);
      if (token == null) return; // cancelled or failed; error already set

      // Token in hand: verify it works, then persist exactly like the
      // manual path so the rest of the app cannot tell the difference.
      final TranscriptionClient client =
          widget.clientFactory?.call(baseUrl, token) ??
              TranscriptionClient(baseUrl: baseUrl, token: token);
      await client.getServerInfo();
      await store.setServerUrl(baseUrl);
      await store.setToken(token);
      ref.read(transcriptionClientProvider.notifier).state = client;
      if (mounted) {
        await Navigator.of(context).pushReplacementNamed<void, void>('/home');
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'Pairing failed: $e');
    } finally {
      if (mounted) setState(() => _pairing = false);
    }
  }

  /// Code-entry dialog. Returns the minted token, or null on cancel/void.
  Future<String?> _promptForCode(
    PairingClient pairing,
    PairingTicket ticket,
  ) {
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _PairingCodeDialog(pairing: pairing, ticket: ticket),
    );
  }

  Future<void> _testAndSave() async {
    setState(() {
      _testing = true;
      _error = null;
    });
    try {
      // Trim aggressively and reject anything that isn't a valid http(s) URL
      // with a host. This prevents low-level Dio/HttpClient errors like
      // "no host specific in url" from leaking through to the user.
      var url = _urlController.text.trim();
      // Strip invisible characters some keyboards insert.
      url = url.replaceAll(RegExp(r'[\u200B-\u200F\uFEFF]'), '');
      // Common typo: missing scheme → prepend http://
      if (!url.startsWith('http://') && !url.startsWith('https://')) {
        url = 'http://$url';
      }
      // Strip trailing slashes (Dio joins baseUrl + '/' + path if both end/start
      // with a slash, which can produce a malformed URI in some scenarios).
      while (url.endsWith('/')) {
        url = url.substring(0, url.length - 1);
      }
      if (url.isEmpty) {
        throw Exception('Server URL is empty');
      }
      final parsed = Uri.tryParse(url);
      if (parsed == null || parsed.host.isEmpty) {
        throw Exception(
          'Server URL is missing a host. Got: "${_urlController.text}" → normalized to "$url"',
        );
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
      // Secure storage is for the next launch; replace the live client too.
      ref.read(transcriptionClientProvider.notifier).state = client;
      if (mounted) {
        await Navigator.of(context).pushReplacementNamed<void, void>('/home');
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
            // ---- Discovery: the zero-typing path ----
            FilledButton.tonalIcon(
              key: const ValueKey<String>('discover-servers'),
              onPressed: _scanning || _pairing ? null : _scan,
              icon: _scanning
                  ? const SizedBox(
                      height: 16,
                      width: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.wifi_find),
              label: Text(
                _scanning
                    ? 'Scanning ${_scanSubnet ?? ''}.x …'
                    : 'Find my server',
              ),
            ),
            if (_found.isNotEmpty) ...[
              const SizedBox(height: 8),
              for (final DiscoveredServer server in _found)
                Card(
                  child: ListTile(
                    key: ValueKey<String>('found-${server.host}'),
                    leading: const Icon(Icons.dns),
                    title: Text(server.name),
                    subtitle: Text(
                      '${server.baseUrl}'
                      '${server.version.isEmpty ? '' : ' · v${server.version}'}',
                    ),
                    trailing: FilledButton(
                      onPressed: _pairing ? null : () => _pair(server.baseUrl),
                      child: const Text('Pair'),
                    ),
                  ),
                ),
            ] else if (!_scanning && _scanSubnet != null) ...[
              const SizedBox(height: 8),
              Text(
                'No servers found on $_scanSubnet.x. '
                'Enter the address manually below.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 16),
            const Row(
              children: [
                Expanded(child: Divider()),
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12),
                  child: Text('or connect manually'),
                ),
                Expanded(child: Divider()),
              ],
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

/// Owns the code field's controller so it dies with the ROUTE, not with the
/// showDialog future — disposing in the caller's finally raced the dialog's
/// exit animation, which still renders the TextField for a few frames.
class _PairingCodeDialog extends StatefulWidget {
  const _PairingCodeDialog({required this.pairing, required this.ticket});

  final PairingClient pairing;
  final PairingTicket ticket;

  @override
  State<_PairingCodeDialog> createState() => _PairingCodeDialogState();
}

class _PairingCodeDialogState extends State<_PairingCodeDialog> {
  final TextEditingController _code = TextEditingController();
  String? _feedback;
  bool _claiming = false;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _claim() async {
    setState(() => _claiming = true);
    final PairClaimResult result = await widget.pairing.claim(
      pairId: widget.ticket.pairId,
      code: _code.text.trim(),
    );
    if (!mounted) return;
    switch (result.status) {
      case PairClaimStatus.success:
        Navigator.of(context).pop(result.token);
        return;
      case PairClaimStatus.wrongCode:
        final int? left = result.attemptsRemaining;
        setState(() {
          _feedback = left == null
              ? 'Incorrect code.'
              : "Incorrect. $left attempt${left == 1 ? '' : 's'} left.";
        });
      case PairClaimStatus.gone:
        setState(() {
          _feedback = 'That code expired — cancel and tap Pair again.';
        });
      case PairClaimStatus.unreachable:
        setState(() => _feedback = 'Server unreachable. Try again.');
    }
    setState(() => _claiming = false);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Enter pairing code'),
      // Scrollable: with the soft keyboard up on a phone the dialog gets
      // very little height, and clipped content here means the user cannot
      // see the error text under the field.
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Text(
              "A 6-digit code is showing in your server's log "
              '(docker compose logs tangent-server) and on any '
              'already-connected device.',
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey<String>('pairing-code-field'),
              controller: _code,
              autofocus: true,
              keyboardType: TextInputType.number,
              maxLength: 6,
              decoration: InputDecoration(
                counterText: '',
                hintText: '000000',
                errorText: _feedback,
              ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey<String>('pairing-code-submit'),
          onPressed: _claiming ? null : _claim,
          child: const Text('Pair'),
        ),
      ],
    );
  }
}
