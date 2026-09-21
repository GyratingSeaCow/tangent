// SPDX-License-Identifier: AGPL-3.0-or-later
/// Shows pending pairing codes so a NEW device can be paired without anyone
/// reading docker logs. This screen runs on an ALREADY-paired device: it
/// polls the authenticated /v1/pair/pending every 5 s while visible (codes
/// live 120 s and new requests appear when the other device taps "Find my
/// server") and renders each code BIG enough to read across the room.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/api_exception.dart';
import '../../models/pair_pending.dart';
import 'server_connection_screen.dart' show transcriptionClientProvider;

/// Seconds between refetches of the pending list.
const int _pollEverySeconds = 5;

class PairNewDeviceScreen extends ConsumerStatefulWidget {
  const PairNewDeviceScreen({super.key, this.clock});

  /// Test seam for the countdown: production leaves it null (wall clock).
  final DateTime Function()? clock;

  @override
  ConsumerState<PairNewDeviceScreen> createState() =>
      _PairNewDeviceScreenState();
}

class _PairNewDeviceScreenState extends ConsumerState<PairNewDeviceScreen> {
  List<PairPendingEntry> _entries = const <PairPendingEntry>[];
  bool _loading = true;
  String? _error;

  /// One 1 s ticker drives BOTH the countdown repaint and (every 5th tick)
  /// the refetch — one timer to cancel means one timer that can leak.
  Timer? _ticker;
  int _sinceFetch = 0;

  DateTime get _now => (widget.clock ?? DateTime.now)();

  @override
  void initState() {
    super.initState();
    _fetch();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  void _tick() {
    _sinceFetch += 1;
    if (_sinceFetch >= _pollEverySeconds) {
      _sinceFetch = 0;
      _fetch();
      return; // _fetch repaints when it lands.
    }
    if (mounted) setState(() {}); // countdown repaint
  }

  Future<void> _fetch() async {
    try {
      final List<PairPendingEntry> entries =
          await ref.read(transcriptionClientProvider).pairPending();
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _error = null;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.statusCode == 401
            ? 'This device is not authorized to view pairing codes — its '
                'token may have been revoked. Re-pair it from the Server '
                'screen.'
            : 'The server said no (HTTP ${e.statusCode}): ${e.message}';
        _loading = false;
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not reach the server: $e';
        _loading = false;
      });
    }
  }

  Future<void> _retry() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    await _fetch();
  }

  /// 123456 → "123 456": grouped digits survive being read aloud.
  static String _grouped(String code) =>
      code.length == 6 ? '${code.substring(0, 3)} ${code.substring(3)}' : code;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Pair a new device')),
      body: _body(context),
    );
  }

  Widget _body(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final String? error = _error;
    if (error != null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              error,
              textAlign: TextAlign.center,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            const SizedBox(height: 16),
            FilledButton.tonal(
              key: const ValueKey<String>('pair-pending-retry'),
              onPressed: _retry,
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }
    if (_entries.isEmpty) {
      // The empty state must TEACH the flow: pairing starts on the OTHER
      // device, and this screen is where its code will surface.
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            const Icon(Icons.devices_other, size: 48),
            const SizedBox(height: 16),
            Text(
              'No pairing requests yet.\n\n'
              'On the new device: open Tangent, tap "Find my server", pick '
              'this server, and its 6-digit code will appear here within a '
              'few seconds.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      );
    }
    final DateTime now = _now;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        for (final PairPendingEntry entry in _entries)
          Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Column(
                children: <Widget>[
                  Text(
                    entry.displayName,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${entry.platform} · expires in '
                    '${_remainingSeconds(entry, now)} s',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  // The payload. Read across the room, typed on the other
                  // device: big, tabular digits, generous spacing.
                  Text(
                    _grouped(entry.code),
                    key: ValueKey<String>('pair-pending-code-${entry.pairId}'),
                    style: const TextStyle(
                      fontSize: 56,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 4,
                      fontFeatures: <FontFeature>[
                        FontFeature.tabularFigures(),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  /// Never negative: an expired row shows 0 s until the next poll (when the
  /// server stops listing it and it disappears).
  static int _remainingSeconds(PairPendingEntry entry, DateTime now) {
    final int remaining = entry.expiresAt.difference(now).inSeconds;
    return remaining < 0 ? 0 : remaining;
  }
}
