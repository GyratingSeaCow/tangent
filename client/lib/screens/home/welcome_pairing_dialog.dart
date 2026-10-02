// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../settings/settings_screen.dart' show settingsStoreProvider;

/// First-run welcome: the pairing walkthrough shown over Capture on EVERY
/// launch — paired or not — until the user opts out (spec 2026-10-02).
///
/// Dismissal contract:
/// - Close: the reminder returns on the next launch (it is a REMINDER).
/// - The ONLY permanent removal: check the bottom-centre "DO NOT REMIND ME
///   AGAIN" checkbox AND press Confirm. That persists
///   `showWelcomeMessage = false` and closes. The checkbox alone does
///   nothing permanent; Confirm is disabled until it is checked.
/// - Settings → Server & devices → "Show welcome message" can re-arm the
///   message (one-way — see [WelcomeMessageSection]).
///
/// The steps mirror server/README.md (Quick start + Pairing devices); if the
/// pairing flow changes there, change it here too. One deliberate
/// simplification: where the README shows separate PowerShell/bash grep
/// variants for re-reading the pairing code, this dialog shows the single
/// shell-neutral `--since 2m` form — the same command works in both shells.
class WelcomePairingDialog extends ConsumerStatefulWidget {
  const WelcomePairingDialog({super.key});

  static const Key dialogKey = Key('welcome-pairing-dialog');
  static const Key dismissForeverKey = Key('welcome-dismiss-forever');
  static const Key closeKey = Key('welcome-close');
  static const Key confirmKey = Key('welcome-confirm');
  static const Key copyStartServerKey = Key('welcome-copy-start-server');
  static const Key copyServerLogKey = Key('welcome-copy-server-log');
  static const Key copyPairingLogKey = Key('welcome-copy-pairing-log');

  /// Exact texts placed on the clipboard — pinned by the widget tests so the
  /// walkthrough never drifts from the real commands.
  static const String startServerCommand = 'cd server\ndocker compose up -d';
  static const String serverLogCommand =
      'docker compose logs -f tangent-server';
  static const String pairingLogCommand =
      'docker compose logs tangent-server --since 2m';

  @override
  ConsumerState<WelcomePairingDialog> createState() =>
      _WelcomePairingDialogState();
}

class _WelcomePairingDialogState extends ConsumerState<WelcomePairingDialog> {
  bool _dismissForever = false;

  /// The checkbox only arms Confirm — it persists nothing and never closes
  /// the dialog on its own (spec 2026-10-02).
  void _onDismissForeverChanged(bool? checked) {
    setState(() => _dismissForever = checked ?? false);
  }

  /// The ONLY permanent removal path: checkbox checked + Confirm pressed.
  Future<void> _confirmDismissForever() async {
    await ref.read(settingsStoreProvider).setShowWelcomeMessage(false);
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  /// Phase label ("On your PC", "On this device") with a leading icon.
  Widget _sectionHeader(BuildContext context, IconData icon, String label) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 10),
      child: Row(
        children: <Widget>[
          Icon(icon, size: 18, color: scheme.primary),
          const SizedBox(width: 8),
          Text(
            label,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: scheme.primary,
                  fontWeight: FontWeight.w600,
                ),
          ),
        ],
      ),
    );
  }

  /// Numbered step: a small circled badge followed by one short sentence.
  Widget _step(BuildContext context, String number, String text) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            width: 22,
            height: 22,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: scheme.primaryContainer,
              shape: BoxShape.circle,
            ),
            child: Text(
              number,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: scheme.onPrimaryContainer,
                    fontWeight: FontWeight.bold,
                  ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                text,
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(height: 1.35),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      key: WelcomePairingDialog.dialogKey,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 640),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                'Welcome to Tangent',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 4),
              Text(
                'Recording works right now — nothing to set up. Pairing '
                'with your own Tangent server adds transcription and sync.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 12),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      _sectionHeader(
                        context,
                        Icons.desktop_windows_outlined,
                        'On your PC — one-time',
                      ),
                      _step(
                        context,
                        '1',
                        'Start the server from the repo folder:',
                      ),
                      const _CodeCard(
                        command: WelcomePairingDialog.startServerCommand,
                        copyKey: WelcomePairingDialog.copyStartServerKey,
                      ),
                      _step(
                        context,
                        '2',
                        'Follow the log. On the first run it prints a '
                            'one-time setup command — run that once and save '
                            'the token it returns:',
                      ),
                      const _CodeCard(
                        command: WelcomePairingDialog.serverLogCommand,
                        copyKey: WelcomePairingDialog.copyServerLogKey,
                      ),
                      _sectionHeader(
                        context,
                        Icons.smartphone_outlined,
                        'On this device',
                      ),
                      _step(
                        context,
                        '3',
                        'Open Settings → Server & devices → Find my '
                            'server, then tap Pair next to your server.',
                      ),
                      _step(
                        context,
                        '4',
                        'Type the 6-digit code from the PC log here. It '
                            'expires in 120 seconds — if you missed it, '
                            're-read the log:',
                      ),
                      const _CodeCard(
                        command: WelcomePairingDialog.pairingLogCommand,
                        copyKey: WelcomePairingDialog.copyPairingLogKey,
                      ),
                    ],
                  ),
                ),
              ),
              const Divider(height: 16),
              // Spec: checkbox at the bottom CENTRE of the dialog. Checking
              // it only enables Confirm; Confirm is what persists the
              // opt-out and closes. Close is this-launch-only.
              Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Checkbox(
                      key: WelcomePairingDialog.dismissForeverKey,
                      value: _dismissForever,
                      onChanged: _onDismissForeverChanged,
                    ),
                    const Text('DO NOT REMIND ME AGAIN'),
                  ],
                ),
              ),
              Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    TextButton(
                      key: WelcomePairingDialog.closeKey,
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Close'),
                    ),
                    const SizedBox(width: 12),
                    FilledButton(
                      key: WelcomePairingDialog.confirmKey,
                      onPressed:
                          _dismissForever ? _confirmDismissForever : null,
                      child: const Text('Confirm'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A command the user can copy with one tap: monospace text in a rounded
/// card with a trailing copy button that flips to a check for two seconds
/// as the "copied" acknowledgement.
class _CodeCard extends StatefulWidget {
  const _CodeCard({required this.command, required this.copyKey});

  final String command;
  final Key copyKey;

  @override
  State<_CodeCard> createState() => _CodeCardState();
}

class _CodeCardState extends State<_CodeCard> {
  bool _copied = false;
  Timer? _resetTimer;

  @override
  void dispose() {
    _resetTimer?.cancel();
    super.dispose();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.command));
    if (!mounted) return;
    setState(() => _copied = true);
    _resetTimer?.cancel();
    _resetTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      // Left margin aligns the card under the step text, past the badge.
      margin: const EdgeInsets.only(left: 30, bottom: 10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
              child: Text(
                widget.command,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12.5,
                  height: 1.4,
                ),
              ),
            ),
          ),
          IconButton(
            key: widget.copyKey,
            onPressed: _copy,
            tooltip: _copied ? 'Copied' : 'Copy',
            visualDensity: VisualDensity.compact,
            icon: Icon(
              _copied ? Icons.check : Icons.copy_rounded,
              size: 18,
              color: _copied ? scheme.primary : scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
