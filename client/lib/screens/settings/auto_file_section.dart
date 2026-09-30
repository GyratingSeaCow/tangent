// SPDX-License-Identifier: AGPL-3.0-or-later
/// Settings section for the server-side auto-file trigger.
///
/// After a capture is transcribed the server files it into the best
/// matching EXISTING folder — confidently or not at all — and the card
/// offers Undo. This toggle gates that trigger. Unlike AI summaries there
/// is nothing to install and nothing to download, so the switch is plain:
/// ON posts the server gate on, OFF posts it off. Default is ON.
///
/// Like the AI-summaries gate, the toggle is SERVER-side (one gate for
/// every device) and [autoFileEnabledProvider] is only this device's
/// last-confirmed mirror: every open RECONCILES the toggle with the
/// server's answer without POSTing anything, and an unreachable server at
/// init leaves the remembered value — the toggle stays interactive and
/// complains on use.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/summaries_client.dart';
import 'ai_summaries_section.dart' show summariesClientProvider;
import 'settings_screen.dart' show settingsStoreProvider;

/// Whether auto-file is enabled per THIS device's local mirror. Seeded from
/// the persisted setting; the section below is the only writer. The gate
/// itself is SERVER-side (one toggle for every device).
final autoFileEnabledProvider = StateProvider<bool>(
  (ref) => ref.watch(settingsStoreProvider).autoFileEnabled,
);

class AutoFileSection extends ConsumerStatefulWidget {
  const AutoFileSection({super.key});

  @override
  ConsumerState<AutoFileSection> createState() => _AutoFileSectionState();
}

class _AutoFileSectionState extends ConsumerState<AutoFileSection> {
  /// A request is in flight; the toggle must not start a second one.
  bool _busy = false;

  String? _error;

  @override
  void initState() {
    super.initState();
    _rehydrate();
  }

  /// Adopts the server's answer on open. A read, never a write: the stale
  /// local value is never pushed back (ai_summaries_section precedent).
  Future<void> _rehydrate() async {
    final AutoFileSettings settings;
    try {
      final SummariesClient client =
          await ref.read(summariesClientProvider.future);
      settings = await client.getAutoFileSettings();
    } catch (_) {
      // Unreachable server at init is not an error banner — the user did
      // nothing yet. The toggle stays interactive and complains on use.
      return;
    }
    if (!mounted) return;
    if (settings.enabled != ref.read(autoFileEnabledProvider)) {
      await _restToggle(settings.enabled);
    }
  }

  Future<void> _onToggle(bool requested) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final SummariesClient client =
          await ref.read(summariesClientProvider.future);
      final AutoFileSettings settings =
          await client.setAutoFileEnabled(requested);
      if (!mounted) return;
      await _restToggle(settings.enabled);
    } catch (e) {
      // The gate is server-side: resting the toggle over a failed write
      // would show a lie, so it stays where it was and says why.
      if (mounted) {
        setState(() => _error = 'Could not update auto-file: $e');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Lands the toggle in its final position: persisted AND live for every
  /// watcher.
  Future<void> _restToggle(bool value) async {
    await ref.read(settingsStoreProvider).setAutoFileEnabled(value);
    if (!mounted) return;
    ref.read(autoFileEnabledProvider.notifier).state = value;
  }

  @override
  Widget build(BuildContext context) {
    final bool enabled = ref.watch(autoFileEnabledProvider);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(
            'Auto-file',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
        SwitchListTile(
          key: const ValueKey<String>('settings-auto-file-toggle'),
          title: const Text('File new recordings automatically'),
          subtitle: const Text(
            'After transcription, your server moves the capture into the '
            'best matching existing folder — only when it is confident, '
            'and always with Undo. Unsure captures stay in Unfiled.',
          ),
          value: enabled,
          onChanged: _busy ? null : _onToggle,
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              _error!,
              key: const ValueKey<String>('auto-file-error'),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
      ],
    );
  }
}
