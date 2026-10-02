// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'settings_screen.dart';

/// Settings → Server & devices → "Show welcome message" (spec 2026-10-01).
/// Re-arms (or silences) the first-run pairing walkthrough that repeats at
/// launch while no server is paired. The dialog's own DO NOT REMIND ME
/// AGAIN checkbox flips this same preference off; this toggle is the only
/// way back on.
class WelcomeMessageSection extends ConsumerStatefulWidget {
  const WelcomeMessageSection({super.key});

  static const Key enabledKey = Key('welcome-message-enabled');

  @override
  ConsumerState<WelcomeMessageSection> createState() =>
      _WelcomeMessageSectionState();
}

class _WelcomeMessageSectionState extends ConsumerState<WelcomeMessageSection> {
  late bool _enabled = ref.read(settingsStoreProvider).showWelcomeMessage;

  Future<void> _toggle(bool on) async {
    setState(() => _enabled = on);
    await ref.read(settingsStoreProvider).setShowWelcomeMessage(on);
  }

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      key: WelcomeMessageSection.enabledKey,
      title: const Text('Show welcome message'),
      subtitle: const Text(
        'Repeats the first-time pairing steps at launch until this device '
        'is paired with a server',
      ),
      value: _enabled,
      onChanged: _toggle,
    );
  }
}
