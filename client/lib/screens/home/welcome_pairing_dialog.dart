// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../settings/settings_screen.dart' show settingsStoreProvider;

/// First-run welcome and pairing wizard shown on every launch until the user
/// explicitly opts out on its final page.
class WelcomePairingDialog extends ConsumerStatefulWidget {
  const WelcomePairingDialog({super.key});

  static const Key dialogKey = Key('welcome-pairing-dialog');
  static const Key dismissForeverKey = Key('welcome-dismiss-forever');
  static const Key closeKey = Key('welcome-close');
  static const Key confirmKey = Key('welcome-confirm');
  static const Key copyStartServerKey = Key('welcome-copy-start-server');
  static const Key copyServerLogKey = Key('welcome-copy-server-log');
  static const Key copyPairingLogKey = Key('welcome-copy-pairing-log');
  static const Key setUpServerKey = Key('welcome-set-up-server');
  static const Key nextKey = Key('welcome-next');
  static const Key backKey = Key('welcome-back');

  static Key pageKey(int page) => ValueKey<String>('welcome-page-$page');

  /// Exact texts placed on the clipboard — pinned by widget tests.
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
  static const int _pageCount = 4;
  int _pageIndex = 0;
  bool _dismissForever = false;

  void _showPage(int pageIndex) {
    if (pageIndex < 0 || pageIndex >= _pageCount) return;
    setState(() => _pageIndex = pageIndex);
  }

  void _onDismissForeverChanged(bool? checked) {
    setState(() => _dismissForever = checked ?? false);
  }

  Future<void> _confirmDismissForever() async {
    await ref.read(settingsStoreProvider).setShowWelcomeMessage(false);
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  String get _title => switch (_pageIndex) {
    0 => 'Welcome to Tangent',
    1 => 'Start the server',
    2 => 'Watch the server say hello',
    _ => 'Pair this device',
  };

  // Page 1 has no location context: the approved deck and mockup render a
  // bare "1 of 4" there (Vera batch-E item 1).
  String? get _contextLabel => switch (_pageIndex) {
    0 => null,
    1 || 2 => 'On your PC',
    _ => 'On this device',
  };

  Widget _bodyForPage() => switch (_pageIndex) {
    0 => const _WelcomePage(),
    1 => const _StartServerPage(),
    2 => const _ServerHelloPage(),
    _ => const _PairDevicePage(),
  };

  Widget _actions(BuildContext context) {
    if (_pageIndex == 0) {
      return _ActionWrap(
        children: <Widget>[
          TextButton(
            key: WelcomePairingDialog.closeKey,
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Skip for now'),
          ),
          FilledButton(
            key: WelcomePairingDialog.setUpServerKey,
            onPressed: () => _showPage(1),
            child: const Text('Set up my server'),
          ),
        ],
      );
    }
    if (_pageIndex < _pageCount - 1) {
      return _ActionWrap(
        children: <Widget>[
          TextButton(
            key: WelcomePairingDialog.backKey,
            onPressed: () => _showPage(_pageIndex - 1),
            child: const Text('Back'),
          ),
          FilledButton(
            key: WelcomePairingDialog.nextKey,
            onPressed: () => _showPage(_pageIndex + 1),
            child: const Text('Next'),
          ),
        ],
      );
    }
    return _ActionWrap(
      children: <Widget>[
        TextButton(
          key: WelcomePairingDialog.backKey,
          onPressed: () => _showPage(2),
          child: const Text('Back'),
        ),
        TextButton(
          key: WelcomePairingDialog.closeKey,
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
        FilledButton(
          key: WelcomePairingDialog.confirmKey,
          onPressed: _dismissForever ? _confirmDismissForever : null,
          child: const Text('Confirm'),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      key: WelcomePairingDialog.dialogKey,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.arrowLeft): () {
            if (_pageIndex > 0) _showPage(_pageIndex - 1);
          },
          const SingleActivator(LogicalKeyboardKey.arrowRight): () {
            if (_pageIndex < _pageCount - 1) _showPage(_pageIndex + 1);
          },
        },
        child: Focus(
          autofocus: true,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560, maxHeight: 720),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  _WizardProgress(
                    page: _pageIndex + 1,
                    pageCount: _pageCount,
                    contextLabel: _contextLabel,
                  ),
                  const SizedBox(height: 14),
                  Semantics(
                    header: true,
                    child: Text(
                      _title,
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Flexible(
                    child: Semantics(
                      key: WelcomePairingDialog.pageKey(_pageIndex + 1),
                      container: true,
                      liveRegion: true,
                      label: 'Page ${_pageIndex + 1} of $_pageCount: $_title',
                      child: SingleChildScrollView(child: _bodyForPage()),
                    ),
                  ),
                  const Divider(height: 18),
                  if (_pageIndex == _pageCount - 1) ...<Widget>[
                    Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 320),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            Checkbox(
                              key: WelcomePairingDialog.dismissForeverKey,
                              value: _dismissForever,
                              onChanged: _onDismissForeverChanged,
                            ),
                            const Flexible(
                              child: Text(
                                "DON'T SHOW THIS AGAIN",
                                style: TextStyle(fontWeight: FontWeight.w600),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                  ],
                  _actions(context),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _WizardProgress extends StatelessWidget {
  const _WizardProgress({
    required this.page,
    required this.pageCount,
    required this.contextLabel,
  });
  final int page;
  final int pageCount;
  final String? contextLabel;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: contextLabel == null
          ? 'Page $page of $pageCount'
          : 'Page $page of $pageCount, $contextLabel',
      child: ExcludeSemantics(
        child: Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            SizedBox(
              width: 70,
              child: Row(
                children: List<Widget>.generate(
                  pageCount,
                  (int index) => AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    width: index == page - 1 ? 22 : 8,
                    height: 8,
                    margin: const EdgeInsets.only(right: 6),
                    decoration: BoxDecoration(
                      color: index == page - 1
                          ? scheme.primary
                          : scheme.outlineVariant,
                      borderRadius: BorderRadius.circular(99),
                    ),
                  ),
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: scheme.secondaryContainer,
                borderRadius: BorderRadius.circular(99),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    '$page of $pageCount',
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: scheme.onSecondaryContainer,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (contextLabel != null) ...<Widget>[
                    const SizedBox(width: 6),
                    Container(
                      width: 1,
                      height: 12,
                      color: scheme.onSecondaryContainer.withValues(
                        alpha: 0.35,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      contextLabel!,
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: scheme.onSecondaryContainer,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WelcomePage extends StatelessWidget {
  const _WelcomePage();
  @override
  Widget build(BuildContext context) {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          'Tangent is your private recorder and notebook. Everything below '
          'already works, right now, fully offline:',
        ),
        SizedBox(height: 12),
        _FeatureCard(
          lines: <String>[
            '✓ Record voice notes and meetings',
            '✓ Notebooks with ink, text, images and PDFs',
            '✓ To-dos with a kanban board',
          ],
        ),
        SizedBox(height: 14),
        Text(
          'Pairing with your own Tangent server (a free program you run on '
          'your PC) unlocks:',
        ),
        SizedBox(height: 12),
        _FeatureCard(
          accented: true,
          lines: <String>[
            '+ Transcription — recordings become searchable text',
            '+ Sync — notebooks and to-dos on all your devices',
          ],
        ),
        SizedBox(height: 14),
        _Footnote(
          text:
              'No account, no cloud — your data only ever touches hardware '
              'you own.',
        ),
      ],
    );
  }
}

class _StartServerPage extends StatelessWidget {
  const _StartServerPage();
  @override
  Widget build(BuildContext context) {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _Step(
          number: '1',
          text:
              'On the PC that will host your server, open a terminal '
              '(PowerShell on Windows) inside the Tangent folder you '
              'downloaded, and run:',
        ),
        SizedBox(height: 10),
        _CodeCard(
          command: WelcomePairingDialog.startServerCommand,
          copyKey: WelcomePairingDialog.copyStartServerKey,
        ),
        SizedBox(height: 12),
        _Callout(
          text:
              'What this does: starts the Tangent server inside Docker. It '
              'keeps running in the background and restarts with your PC — '
              'you only ever do this once.',
        ),
        SizedBox(height: 10),
        _Callout(
          text:
              'Needs Docker? Install Docker Desktop first — '
              "docker.com/get-started. Tangent's server is free and runs "
              'entirely on your machine.',
        ),
      ],
    );
  }
}

class _ServerHelloPage extends StatelessWidget {
  const _ServerHelloPage();
  @override
  Widget build(BuildContext context) {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _Step(
          number: '2',
          text: "In the same terminal, follow the server's log:",
        ),
        SizedBox(height: 10),
        _CodeCard(
          command: WelcomePairingDialog.serverLogCommand,
          copyKey: WelcomePairingDialog.copyServerLogKey,
        ),
        SizedBox(height: 12),
        _Callout(
          text:
              "What you'll see: on its very first run the log prints a "
              'one-time setup command. Run that command once — it answers '
              'with an admin token. Save the token somewhere safe (a '
              "password manager is perfect): it's the master key for adding "
              'devices later.',
        ),
        SizedBox(height: 10),
        _Callout(
          text:
              "Done already? If you set this server up before, there's "
              'nothing to re-run — just continue.',
        ),
      ],
    );
  }
}

class _PairDevicePage extends StatelessWidget {
  const _PairDevicePage();
  @override
  Widget build(BuildContext context) {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _Step(
          number: '3',
          text:
              'Open Settings → Server & devices → Find my server. Your PC '
              'appears automatically when both are on the same network — tap '
              'Pair next to it.',
        ),
        SizedBox(height: 12),
        _Step(
          number: '4',
          text:
              'The PC log shows a 6-digit code — type it here. The code '
              'lives for 120 seconds; if it lapsed, read the log again for a '
              'fresh one:',
        ),
        SizedBox(height: 10),
        _CodeCard(
          command: WelcomePairingDialog.pairingLogCommand,
          copyKey: WelcomePairingDialog.copyPairingLogKey,
        ),
        SizedBox(height: 12),
        _Callout(
          text:
              'Why a code: it proves you control both machines, so nobody '
              'else on the network can attach to your server.',
        ),
        SizedBox(height: 12),
        _Footnote(
          text:
              'You can always come back: this whole guide lives in Settings '
              '→ Server & devices.',
        ),
      ],
    );
  }
}

class _FeatureCard extends StatelessWidget {
  const _FeatureCard({required this.lines, this.accented = false});
  final List<String> lines;
  final bool accented;
  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: accented
            ? scheme.primaryContainer.withValues(alpha: 0.45)
            : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: accented
              ? scheme.primary.withValues(alpha: 0.35)
              : scheme.outlineVariant,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          for (int index = 0; index < lines.length; index++) ...<Widget>[
            Text(lines[index]),
            if (index != lines.length - 1) const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.number, required this.text});
  final String number;
  final String text;
  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: 'Step $number. $text',
      child: ExcludeSemantics(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Container(
              width: 26,
              height: 26,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: scheme.primaryContainer,
                shape: BoxShape.circle,
              ),
              child: Text(
                number,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: scheme.onPrimaryContainer,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Text(text),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Callout extends StatelessWidget {
  const _Callout({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 11, 12, 11),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        border: Border(left: BorderSide(color: scheme.primary, width: 3)),
      ),
      child: Text(
        text,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(height: 1.4),
      ),
    );
  }
}

class _Footnote extends StatelessWidget {
  const _Footnote({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
        fontStyle: FontStyle.italic,
        height: 1.35,
      ),
    );
  }
}

class _ActionWrap extends StatelessWidget {
  const _ActionWrap({required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerRight,
      child: Wrap(
        alignment: WrapAlignment.end,
        spacing: 8,
        runSpacing: 4,
        children: children,
      ),
    );
  }
}

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
