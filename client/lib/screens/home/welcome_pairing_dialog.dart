// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
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
/// pairing flow changes there, change it here too.
class WelcomePairingDialog extends ConsumerStatefulWidget {
  const WelcomePairingDialog({super.key});

  static const Key dialogKey = Key('welcome-pairing-dialog');
  static const Key dismissForeverKey = Key('welcome-dismiss-forever');
  static const Key closeKey = Key('welcome-close');
  static const Key confirmKey = Key('welcome-confirm');

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

  Widget _step(String number, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              '$number.  ',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            Expanded(child: Text(text)),
          ],
        ),
      );

  Widget _code(BuildContext context, String text) => Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          text,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5),
        ),
      );

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
                'Recording works right now. To transcribe and sync, pair this '
                'device with your own Tangent server:',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 12),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      _step('1', 'On your PC, start the server:'),
                      _code(context, 'cd server\ndocker compose up -d'),
                      _step(
                        '2',
                        'First run only: the log prints a setup command. '
                        'Run the printed curl POST once and save the token:',
                      ),
                      _code(
                        context,
                        'docker compose logs -f tangent-server',
                      ),
                      _step(
                        '3',
                        'On this device: Settings → Server & devices → '
                        'Server → Find my server, then tap Pair next to '
                        'your server.',
                      ),
                      _step(
                        '4',
                        'The server logs a 6-digit code (expires in 120 '
                        'seconds). Read it on the PC and type it here:',
                      ),
                      _code(
                        context,
                        '# PowerShell\ndocker compose logs tangent-server --since 2m |\n'
                        '  Select-String code_issued\n'
                        '# bash\ndocker compose logs tangent-server --since 2m |\n'
                        '  grep code_issued',
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
