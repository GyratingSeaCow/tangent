// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../theme/tangent_tokens.dart';

/// Settings → Support the Dev: a thank-you note with the PayPal donation
/// link below it. Pure static content — no load gate, no screen state.
///
/// The donation URL is PayPal's hosted-button ("no-code payment") share
/// link for button 3L6QWSULPF4WS; it renders PayPal's own payment page, so
/// the app never embeds payment JS or a WebView.
class SupportDevSection extends StatelessWidget {
  const SupportDevSection({super.key});

  static const Key donateKey = ValueKey<String>('support-dev-donate');

  /// The PayPal hosted-button payment page.
  static const String donateUrl =
      'https://www.paypal.com/ncp/payment/3L6QWSULPF4WS';

  /// Shown verbatim above the donation link (Jeff's words, 2026-10-02).
  static const String message =
      'Even the fact that you are reading this right now means the world '
      'to me. Truly, thank you all for your support over this last while '
      'and keep kicking ass out there.';

  Future<void> _donate(BuildContext context) async {
    final bool ok = await launchUrl(
      Uri.parse(donateUrl),
      mode: LaunchMode.externalApplication,
    );
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not open the donation page — try again later.'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
          child: Row(
            children: <Widget>[
              Icon(
                Icons.favorite,
                size: 20,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Text(
                'From the dev',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
          child: Text(
            message,
            style:
                Theme.of(context).textTheme.bodyMedium?.copyWith(height: 1.45),
          ),
        ),
        Center(
          child: FilledButton.icon(
            key: donateKey,
            onPressed: () => _donate(context),
            icon: const Icon(Icons.volunteer_activism),
            label: const Text('Donate with PayPal'),
          ),
        ),
        const SizedBox(height: 8),
        const Center(
          child: Text(
            'paypal.com/ncp/payment/3L6QWSULPF4WS',
            style: TextStyle(fontSize: 12, color: TangentColors.textDim),
          ),
        ),
      ],
    );
  }
}
