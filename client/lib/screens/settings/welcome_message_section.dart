// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'settings_screen.dart';

/// Settings → Server & devices → "Show welcome message" (spec 2026-10-02).
/// ONE-WAY re-arm switch for the first-run pairing walkthrough that repeats
/// at every launch. Turning it ON brings the welcome message back after the
/// dialog's DO NOT REMIND ME AGAIN + Confirm opt-out. Flipping it OFF does
/// NOT stick — the only way to remove the message is the dialog's own
/// checkbox + Confirm, so an off-flip here is ignored and the switch snaps
/// back on.
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
    if (!on) {
      // Spec 2026-10-02: the ONLY removal path is the welcome dialog's
      // checkbox + Confirm. The switch refuses to turn off.
      return;
    }
    setState(() => _enabled = true);
    await ref.read(settingsStoreProvider).setShowWelcomeMessage(true);
  }

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      key: WelcomeMessageSection.enabledKey,
      title: const Text('Show welcome message'),
      subtitle: const Text(
        'Shows the first-time pairing steps at every launch. To turn it '
        'off, check "DO NOT REMIND ME AGAIN" in the message and hit '
        'Confirm — this switch only turns it back on.',
      ),
      value: _enabled,
      onChanged: _toggle,
    );
  }
}
